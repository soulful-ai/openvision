// OpenVision - ClipboardTool.swift
// AUR-833: the clipboard that LANDS. The ride-home analysis (2026-08-20 §F5) showed 5 × `ok:true`
// and 0 pastes: the old tool read only `args["text"]`, wrote `UIPasteboard.general.string` with no
// read-back, answered "There's nothing to copy." as a SUCCESS, and never looked at the app state —
// iOS does not propagate a general-pasteboard write from a non-foreground app, and he was in
// Notes / Safari for most of the copies. Now: tolerant arg keys, `setItems` on the main actor,
// a read-back that decides `ok`, a pending re-apply when the app is not in front, typed failures.
import Foundation
import UIKit
import UniformTypeIdentifiers

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
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [:])
    }
    var string: String? { UIPasteboard.general.string }
    var hasStrings: Bool { UIPasteboard.general.hasStrings }
}

// MARK: - Pending re-apply (the app was not in front when the copy came in)

/// Holds the last text the tool wrote while the app was in the background / inactive and writes
/// it again the moment the app becomes active — the write that iOS will actually honour. One
/// slot: a newer copy replaces an older pending one (the user wants the latest thing he asked for).
@MainActor
final class PendingClipboard {
    static let shared = PendingClipboard()

    private(set) var text: String?
    private(set) var queuedAt: Date?
    private(set) var appliedCount = 0
    private var pasteboard: PasteboardWriting?
    private var observer: NSObjectProtocol?

    init() {}

    /// Remember `text` and arm the did-become-active observer (idempotent).
    func queue(_ text: String, pasteboard: PasteboardWriting) {
        self.text = text
        self.queuedAt = Date()
        self.pasteboard = pasteboard
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyPending(reason: "app active") }
            }
        }
    }

    /// Re-write the pending text (if any) and clear the slot. Returns true when something landed.
    @discardableResult
    func applyPending(reason: String) -> Bool {
        guard let text, let pasteboard else { return false }
        pasteboard.writePlainText(text)
        let landed = pasteboard.string == text
        ovLog("📋 pending copy re-applied (\(reason)) \(text.count) chars readback=\(landed ? "ok" : "mismatch")")
        self.text = nil
        self.queuedAt = nil
        appliedCount += 1
        return landed
    }

    func clear() { text = nil; queuedAt = nil }
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

    /// Seams (tests inject; the registry uses the defaults).
    var pasteboard: @MainActor () -> PasteboardWriting = { SystemPasteboard() }
    var appState: @MainActor () -> AppForegroundState = { AppForegroundState.current() }
    var pending: @MainActor () -> PendingClipboard = { PendingClipboard.shared }

    init() {}
    init(pasteboard: @escaping @MainActor () -> PasteboardWriting,
         appState: @escaping @MainActor () -> AppForegroundState,
         pending: @escaping @MainActor () -> PendingClipboard) {
        self.pasteboard = pasteboard
        self.appState = appState
        self.pending = pending
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
        let readbackOK: Bool
        let queued: Bool
        /// The spoken result.
        var result: String {
            let p = ClipboardTool.preview(text)
            return queued ? "Copied (will apply when the app is in front): \(p)" : "Copied to clipboard: \(p)"
        }
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let text = Self.textArgument(args) else {
            throw NativeToolError.failed(code: "nothing_to_copy", spoken: "There's nothing to copy.")
        }
        let outcome = try await copy(text)
        return outcome.result
    }

    /// The whole main-actor dance: write → read back → decide. Throws the typed failures.
    @MainActor
    func copy(_ text: String) async throws -> Outcome {
        let board = pasteboard()
        let state = appState()
        board.writePlainText(text)
        let readback = board.string
        let readbackOK = readback == text
        let hasStrings = board.hasStrings
        ovLog("📋 copy \(text.count) chars appState=\(state.rawValue) readback=\(readbackOK ? "ok" : "mismatch")")

        if state != .active {
            // iOS may not honour a pasteboard write from a non-foreground app: keep the text and
            // re-apply it on didBecomeActive. The spoken result says so (the user hears WHY his
            // paste is empty right now, and what makes it land).
            pending().queue(text, pasteboard: board)
            return Outcome(text: text, appState: state, readbackOK: readbackOK, queued: true)
        }
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
