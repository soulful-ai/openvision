// OpenVision - ClipboardTool.swift
// AUR-833: the clipboard that LANDS. The ride-home analysis (2026-08-20 §F5) showed 5 × `ok:true`
// and 0 pastes: the old tool read only `args["text"]`, wrote `UIPasteboard.general.string` with no
// read-back, answered "There's nothing to copy." as a SUCCESS, and never looked at the app state —
// iOS does not propagate a general-pasteboard write from a non-foreground app, and he was in
// Notes / Safari for most of the copies. Now: tolerant arg keys, `setItems` on the main actor,
// a read-back that decides `ok`, a pending re-apply when the app is not in front, typed failures.
//
// AUR-845: ...and the morning after (2026-08-21 §E R1) the copy STILL did not land: the call ran in
// `appState background` (a glasses call, the phone in the pocket / another app in front), the
// result promised a re-apply "when the app is in front" — and the wearer never brought the app to
// the front: he went to the target app and pasted nothing, twice. What iOS actually allows:
//   • the general pasteboard is FOREGROUND-ONLY since iOS 9/10 — a write from a backgrounded (or
//     already-resigning, `inactive`) process is silently not propagated and a read returns nil
//     (Apple dev forums thread 13760: "the pasteboard is even blocked before the App is actually
//     in the background. Even in applicationWillResignActive: the pasteboard already returns
//     nil"); no entitlement, option or background task lifts it. `UIPasteboard.setItems(_:options:)`
//     options (`localOnly`, `expirationDate`) shape Universal Clipboard + lifetime, not the
//     foreground rule; `beginBackgroundTask` keeps the PROCESS alive, it does not make it frontmost.
//   • so the honest contract is: in front → write + read-back → «Скопировано»; not in front →
//     try anyway (background task + explicit options, read-back decides — if a future iOS or a
//     corner case DOES land it we report the truth and queue nothing), else QUEUE the text and
//     say «Скопирую, как только откроешь приложение». The queue re-applies on
//     `willEnterForeground` (first chance) and `didBecomeActive` (the write iOS honours), verifies
//     by read-back, and reports `aurelia.client_tool.applied` on the realtime wire (the bridge
//     sends it) so the brain can speak / log the landing. A local notification («нажми, чтобы
//     применить») is the one-tap way to bring the app to the front from wherever he is pasting.
//   • ORDER MATTERS on every path: write, THEN read back. Reading a pasteboard whose items came
//     from another app raises the iOS 16+ "…would like to paste from…" alert; reading back what
//     we just wrote ourselves does not. No path here reads before it writes.
import Foundation
import UIKit
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Pasteboard seam (tests inject a fake; the app uses UIPasteboard.general)

/// The three pasteboard operations the tool needs. Main-actor: `UIPasteboard` is UI state.
@MainActor
protocol PasteboardWriting {
    /// Write ONE plain-text item, replacing the pasteboard contents.
    func writePlainText(_ text: String)
    /// What the pasteboard says it holds now (the read-back).
    var string: String? { get }
    var hasStrings: Bool { get }
}

/// `UIPasteboard.general` behind the seam.
@MainActor
struct SystemPasteboard: PasteboardWriting {
    func writePlainText(_ text: String) {
        // AUR-845: the explicit "legit" options — `localOnly:false` = let Universal Clipboard
        // carry it (the default, spelled out), no `expirationDate` (a copy that vanishes before he
        // finds the field is worse than a late one). Neither lifts the foreground-only rule.
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: [.localOnly: false])
    }
    var string: String? { UIPasteboard.general.string }
    var hasStrings: Bool { UIPasteboard.general.hasStrings }
}

// MARK: - The "open the app" affordance (a local notification he can tap from the target app)

/// Posts / clears the one pending-clipboard notification. Seam so the tests never touch
/// `UNUserNotificationCenter`.
@MainActor
protocol PendingClipboardNotifying {
    func post(preview: String)
    func clear()
}

@MainActor
struct SystemPendingClipboardNotifier: PendingClipboardNotifying {
    static let identifier = "aurelia.clipboard.pending"

    func post(preview: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else {
                ovLog("📋 pending-copy notification skipped (notifications \(status.rawValue))")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Скопирую, как только откроешь приложение"
            content.body = "Нажми, чтобы применить: \(preview)"
            content.sound = nil
            let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
                ovLog("📋 pending-copy notification posted")
            } catch {
                ovLog("📋 pending-copy notification failed: \(error.localizedDescription)")
            }
        }
    }

    func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }
}

// MARK: - Pending re-apply (the app was not in front when the copy came in)

/// One finished re-apply — the body of `aurelia.client_tool.applied` (AUR-845).
struct ClipboardApplied: Equatable {
    /// The `aurelia.tool_call` id that queued the copy; nil for the push-to-ask path.
    let callId: String?
    let wireName: String
    /// True when the text is on the pasteboard now (verified by read-back).
    let ok: Bool
    /// Always the truth of a read-back: `ok` IS `verifiedByReadback` here (kept as its own field
    /// on the wire so a future "landed but unverifiable" path can say so).
    let verifiedByReadback: Bool
    /// "foreground" (willEnterForeground) | "active" (didBecomeActive) | "manual".
    let stage: String
    /// How long the text waited.
    let queuedMs: Int
    let appState: AppForegroundState
    let chars: Int
}

/// Holds the last text the tool wrote while the app was in the background / inactive and writes
/// it again the moment the app comes to the front — the write that iOS will actually honour. One
/// slot: a newer copy replaces an older pending one (the user wants the latest thing he asked for).
@MainActor
final class PendingClipboard {
    static let shared = PendingClipboard()

    private(set) var text: String?
    private(set) var queuedAt: Date?
    private(set) var call: NativeToolCall?
    private(set) var appliedCount = 0
    /// The last finished re-apply (Debug read-out + tests).
    private(set) var lastApplied: ClipboardApplied?
    /// AUR-845: where a finished re-apply goes — the realtime bridge sets this to send
    /// `aurelia.client_tool.applied`.
    var onApplied: ((ClipboardApplied) -> Void)?
    /// Seams.
    var notifier: PendingClipboardNotifying
    var appState: () -> AppForegroundState
    private var pasteboard: PasteboardWriting?
    private var observers: [NSObjectProtocol] = []

    /// Both seams default to the real thing — as `nil` sentinels, because a default-argument
    /// expression is evaluated in a NONISOLATED context and `SystemPendingClipboardNotifier()` /
    /// `AppForegroundState.current()` are both main-actor.
    init(notifier: PendingClipboardNotifying? = nil,
         appState: (() -> AppForegroundState)? = nil) {
        self.notifier = notifier ?? SystemPendingClipboardNotifier()
        self.appState = appState ?? { AppForegroundState.current() }
    }

    var isPending: Bool { text != nil }

    /// Remember `text`, arm the foreground observers (idempotent), post the tap-to-apply note.
    func queue(_ text: String, pasteboard: PasteboardWriting, call: NativeToolCall? = nil) {
        self.text = text
        self.queuedAt = Date()
        self.call = call
        self.pasteboard = pasteboard
        if observers.isEmpty {
            let center = NotificationCenter.default
            // First chance: the scene is coming back (the write may already be honoured here).
            observers.append(center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyPending(stage: "foreground", final: false) }
            })
            // The write iOS honours for sure; the last word either way.
            observers.append(center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyPending(stage: "active", final: true) }
            })
        }
        notifier.post(preview: ClipboardTool.preview(text))
        ovLog("📋 copy queued for the foreground (\(text.count) chars\(call.map { ", call \($0.id)" } ?? ""))")
    }

    /// Re-apply the pending text (if any). Returns the event when the attempt FINISHED (verified,
    /// or `final` and still not there — then the slot is cleared and the failure reported); nil
    /// when nothing is pending or a non-final attempt did not verify yet (the slot stays).
    @discardableResult
    func applyPending(stage: String, final: Bool) -> ClipboardApplied? {
        guard let text, let pasteboard else { return nil }
        // WRITE FIRST, then read back — never the other way round. A read of a pasteboard whose
        // items came from ANOTHER app raises the iOS 16+ system alert ("OpenVision would like to
        // paste from Safari"); a read of what we just wrote ourselves does not. So the pre-check
        // "did the background write land after all?" is not worth an alert in the wearer's face —
        // and it is answerable for free anyway: `copy()` already read back in the background and
        // only queued because that read failed.
        pasteboard.writePlainText(text)
        let landed = pasteboard.string == text
        let queuedMs = Int(Date().timeIntervalSince(queuedAt ?? Date()) * 1000)
        ovLog("📋 pending copy re-apply (\(stage)) \(text.count) chars readback=\(landed ? "ok" : "mismatch")\(final ? " final" : "")")
        guard landed || final else { return nil }   // try again on didBecomeActive
        let event = ClipboardApplied(callId: call?.id,
                                     wireName: call?.wireName ?? ClientToolBridge.wireName(for: ClipboardTool().name),
                                     ok: landed, verifiedByReadback: landed,
                                     stage: stage, queuedMs: queuedMs, appState: appState(), chars: text.count)
        self.text = nil
        self.queuedAt = nil
        self.call = nil
        appliedCount += 1
        lastApplied = event
        notifier.clear()
        onApplied?(event)
        return event
    }

    func clear() { text = nil; queuedAt = nil; call = nil; notifier.clear() }
}

// MARK: - Tool

/// Copy text to the device clipboard so the user can paste it elsewhere.
struct ClipboardTool: NativeTool {
    let name = "copy_to_clipboard"
    let description = "Copy text to the clipboard. Use when the user says 'copy that' or wants a result saved to paste elsewhere."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string", "description": "The text to copy"]],
        "required": ["text"]
    ]

    /// The arg keys the model has actually sent for "the text" — `text` is the schema, the rest
    /// are the variants seen / expected from different model generations. First non-empty wins.
    static let acceptedKeys = ["text", "content", "value", "string"]
    static let previewChars = 60

    /// The two honest results (AUR-845). The wearer hears exactly which one happened.
    static let copiedPrefix = "Скопировано"
    static let queuedPrefix = "Скопирую, как только откроешь приложение"

    /// Seams (tests inject; the registry uses the defaults).
    var pasteboard: @MainActor () -> PasteboardWriting = { SystemPasteboard() }
    var appState: @MainActor () -> AppForegroundState = { AppForegroundState.current() }
    var pending: @MainActor () -> PendingClipboard = { PendingClipboard.shared }
    /// Begin a background task around the not-in-front write; returns the "end" closure. The
    /// default is the real `UIApplication` pair; tests inject a no-op.
    var backgroundTask: @MainActor () -> (() -> Void) = {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "aurelia.clipboard.write") {
            UIApplication.shared.endBackgroundTask(id); id = .invalid
        }
        return { if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid } }
    }

    init() {}
    init(pasteboard: @escaping @MainActor () -> PasteboardWriting,
         appState: @escaping @MainActor () -> AppForegroundState,
         pending: @escaping @MainActor () -> PendingClipboard,
         backgroundTask: @escaping @MainActor () -> (() -> Void) = { {} }) {
        self.pasteboard = pasteboard
        self.appState = appState
        self.pending = pending
        self.backgroundTask = backgroundTask
    }

    /// The text to copy out of a tolerant arg dict — nil when no accepted key carries text.
    static func textArgument(_ args: [String: Any]) -> String? {
        for key in acceptedKeys {
            if let s = args[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
            // A number the model "copied" (a code, a total) still deserves to land.
            if let n = args[key] as? NSNumber, !(args[key] is Bool) { return n.stringValue }
        }
        return nil
    }

    static func preview(_ text: String) -> String {
        text.count > previewChars ? String(text.prefix(previewChars)) + "…" : text
    }

    /// Outcome of one copy, for the log line and the tests.
    struct Outcome: Equatable {
        let text: String
        let appState: AppForegroundState
        /// The read-back right after OUR write matched (in front, or — surprise — from the back).
        let readbackOK: Bool
        /// The text waits for the foreground (the `aurelia.client_tool.applied` event follows).
        let queued: Bool
        /// The spoken result: «Скопировано: …» only when verified; «Скопирую, как только
        /// откроешь приложение: …» when queued. Never the first for the second.
        var result: String {
            let p = ClipboardTool.preview(text)
            return queued ? "\(ClipboardTool.queuedPrefix): \(p)" : "\(ClipboardTool.copiedPrefix): \(p)"
        }
    }

    func execute(args: [String: Any]) async throws -> String {
        try await execute(args: args, call: nil).text
    }

    func execute(args: [String: Any], call: NativeToolCall?) async throws -> NativeToolReply {
        guard let text = Self.textArgument(args) else {
            throw NativeToolError.failed(code: "nothing_to_copy", spoken: "There's nothing to copy.")
        }
        let outcome = try await copy(text, call: call)
        return NativeToolReply(text: outcome.result, deferred: outcome.queued)
    }

    /// The whole main-actor dance: write → read back → decide. Throws the typed failures.
    @MainActor
    func copy(_ text: String, call: NativeToolCall? = nil) async throws -> Outcome {
        let board = pasteboard()
        let state = appState()

        if state != .active {
            // Not in front. Try anyway, the legit way (background task + explicit options), and
            // let the READ-BACK decide — the doc says iOS drops it, the field gets to disagree.
            let end = backgroundTask()
            board.writePlainText(text)
            let landed = board.string == text
            end()
            ovLog("📋 copy \(text.count) chars appState=\(state.rawValue) background-write readback=\(landed ? "ok" : "mismatch")")
            if landed {
                // It landed from the back: say «Скопировано», queue nothing (a queued re-apply
                // would only risk clobbering a newer copy he makes before opening the app).
                return Outcome(text: text, appState: state, readbackOK: true, queued: false)
            }
            pending().queue(text, pasteboard: board, call: call)
            return Outcome(text: text, appState: state, readbackOK: false, queued: true)
        }

        board.writePlainText(text)
        let readbackOK = board.string == text
        let hasStrings = board.hasStrings
        ovLog("📋 copy \(text.count) chars appState=\(state.rawValue) readback=\(readbackOK ? "ok" : "mismatch")")
        guard hasStrings else {
            throw NativeToolError.failed(code: "pasteboard_write_failed",
                                         spoken: "I couldn't write to the clipboard — the pasteboard stayed empty.")
        }
        guard readbackOK else {
            throw NativeToolError.failed(code: "pasteboard_write_failed",
                                         spoken: "I couldn't write to the clipboard — the read-back did not match.")
        }
        return Outcome(text: text, appState: state, readbackOK: true, queued: false)
    }
}
