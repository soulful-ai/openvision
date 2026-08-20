// OpenVision - ClientToolBridge.swift
// AUR-792: the phone's native tools on the realtime wire — the door the phone-body plan
// (docs/product/2026-08-20-phone-body-plan.md §1) needs and nothing else.
//
// Before this the `NativeToolRegistry` (timer, pomodoro, reminder, calendar, note, clipboard,
// document search) was reachable ONLY from the push-to-ask HTTP backends, which AUR-744 banked
// behind `pushToAskEnabled=false`; inside the one-conversation realtime call the brain had no way
// to touch the phone. The bridge is ADDITIVE: the registry is shared, the push-to-ask path is
// untouched, and nothing here runs unless the realtime session is open.
//
//   client → server   aurelia.client_tools {tools:[{name,description,parameters,timeoutMs}],
//                                           connections:{calendar,reminders,notifications,spotify}}
//                     — right after the session's session.update on every (re)connect, and again
//                       whenever a connection state changes (app became active after a prompt,
//                       a tool just hit a permission wall).
//   server → client   aurelia.tool_call {id, name:"phone.<tool>", args, timeoutMs}
//   client → server   aurelia.tool_result {id, ok:true, result:"<≤1024 chars>"}
//                     aurelia.tool_result {id, ok:false, error:"permission_required:calendar" |
//                                          "not_linked:spotify" | "timeout" | "busy" |
//                                          "unknown_tool" | "<short>"}
//
// Names: `phone.` + snake_case of the registry name (`^phone\.[a-z0-9_]{1,40}$`), ≤32 tools,
// schema ≤4 KB each, one call in flight per name (a second is answered `busy`), per-call timeout
// (default 8 s, 15 s for document search; the server's `timeoutMs` on the call wins when present).

import Foundation
import EventKit
import UserNotifications
import UIKit

// MARK: - Connections (the permission / link states the manifest carries)

/// What the wire says about one integration. `granted`/`denied`/`unknown` for OS permissions;
/// integrations that need an account link (Spotify, AUR-793) use `linked`/`unlinked`.
enum PhoneConnectionState: String, Equatable {
    case granted, denied, unknown
}

/// Snapshot of every connection the manifest reports. Equatable so a re-check after the app comes
/// back to the foreground only re-sends the manifest when something actually changed.
struct PhoneConnections: Equatable {
    var calendar: PhoneConnectionState = .unknown
    var reminders: PhoneConnectionState = .unknown
    var notifications: PhoneConnectionState = .unknown
    /// AUR-793 placeholder — a constant until the Spotify link lands (the key is on the wire now
    /// so the server half and the Connections UI have the field to grow into).
    var spotify: String = "unlinked"

    /// The `connections` object as sent.
    var wire: [String: String] {
        [
            "calendar": calendar.rawValue,
            "reminders": reminders.rawValue,
            "notifications": notifications.rawValue,
            "spotify": spotify
        ]
    }

    /// Ordered rows for the Settings → Debug read-out.
    var rows: [(kind: String, state: String)] {
        [("Calendar", calendar.rawValue), ("Reminders", reminders.rawValue),
         ("Notifications", notifications.rawValue), ("Spotify", spotify)]
    }

    /// Read the REAL states — no prompts, no side effects. EventKit is synchronous; the
    /// notification settings are async.
    static func current() async -> PhoneConnections {
        var c = PhoneConnections()
        c.calendar = eventKitState(.event)
        c.reminders = eventKitState(.reminder)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: c.notifications = .granted
        case .notDetermined: c.notifications = .unknown
        case .denied: c.notifications = .denied
        @unknown default: c.notifications = .unknown
        }
        return c
    }

    private static func eventKitState(_ entity: EKEntityType) -> PhoneConnectionState {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .unknown
        case .denied, .restricted, .writeOnly: return .denied
        @unknown default: return .unknown
        }
    }
}

/// What one tool call produced: the text to send, or the wire error code.
enum ClientToolOutcome: Equatable {
    case success(String)
    case failure(String)
}

// MARK: - Bridge

@MainActor
final class ClientToolBridge {

    // MARK: Limits (the wire contract)

    static let namePrefix = "phone."
    static let namePattern = #"^phone\.[a-z0-9_]{1,40}$"#
    static let maxTools = 32
    static let maxSchemaBytes = 4096
    static let maxResultChars = 1024
    static let defaultTimeoutMs = 8000
    /// Registry-name → timeout override. Document search reads + ranks chunks; give it room.
    static let timeoutOverrides: [String: Int] = ["search_docs": 15000]
    static let minTimeoutMs = 500
    static let maxTimeoutMs = 60_000

    /// One advertised tool: the wire name, the tool, its default timeout.
    struct Entry {
        let wireName: String
        let tool: NativeTool
        let timeoutMs: Int
    }

    // MARK: State

    /// The advertised set, in registry order, already filtered to the wire limits.
    private(set) var entries: [Entry] = []
    /// Where `aurelia.client_tools` / `aurelia.tool_result` go. The realtime service sets this to
    /// its own JSON send; tests capture it.
    var send: (([String: Any]) -> Void)?
    /// How the bridge reads permission states — injectable so tests never touch EventKit.
    var connectionsProvider: () async -> PhoneConnections
    /// Last connections snapshot that went out (Settings → Debug shows it).
    private(set) var lastSentConnections: PhoneConnections?
    private(set) var lastManifestSentAt: Date?
    /// True between `sessionDidConnect` and `sessionDidDisconnect` — nothing is sent otherwise.
    private(set) var isSessionActive = false

    private struct InFlight {
        let wireName: String
        let startedAt: Date
        let exec: Task<Void, Never>
        let timeout: Task<Void, Never>
    }
    private var inFlight: [String: InFlight] = [:]     // call id → work
    private var busyNames: Set<String> = []            // one call per wire name
    private var appActiveObserver: NSObjectProtocol?
    private var manifestTask: Task<Void, Never>?

    // MARK: Init

    init(tools: [NativeTool],
         connectionsProvider: @escaping () async -> PhoneConnections = { await PhoneConnections.current() }) {
        self.connectionsProvider = connectionsProvider
        self.entries = Self.buildEntries(tools)
    }

    // MARK: Manifest

    /// `phone.` + snake_case of the registry name, clipped to the wire's 40-char body.
    static func wireName(for toolName: String) -> String {
        var out = ""
        var prevLowerOrDigit = false
        for scalar in toolName.unicodeScalars {
            let ch = Character(scalar)
            if ch.isASCII && ch.isUppercase {
                if prevLowerOrDigit { out.append("_") }
                out.append(ch.lowercased())
                prevLowerOrDigit = false
            } else if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch.lowercased())
                prevLowerOrDigit = true
            } else {
                out.append("_")
                prevLowerOrDigit = false
            }
        }
        // Collapse runs of "_" and trim the ends — a registry name like "my  tool" or "-x-".
        var collapsed = ""
        var lastUnderscore = true
        for ch in out {
            if ch == "_" {
                if !lastUnderscore { collapsed.append(ch) }
                lastUnderscore = true
            } else {
                collapsed.append(ch)
                lastUnderscore = false
            }
        }
        while collapsed.hasSuffix("_") { collapsed.removeLast() }
        let body = String(collapsed.prefix(40))
        return namePrefix + body
    }

    static func isValidWireName(_ name: String) -> Bool {
        name.range(of: namePattern, options: .regularExpression) != nil
    }

    /// Apply the wire limits once: bad names / oversize schemas are dropped (logged), the set is
    /// capped at 32, duplicates after snake-casing keep the first.
    private static func buildEntries(_ tools: [NativeTool]) -> [Entry] {
        var seen: Set<String> = []
        var out: [Entry] = []
        for tool in tools {
            let wire = wireName(for: tool.name)
            guard isValidWireName(wire) else {
                ovLog("📱 client_tools: dropping \"\(tool.name)\" — wire name \"\(wire)\" invalid")
                continue
            }
            guard !seen.contains(wire) else {
                ovLog("📱 client_tools: dropping \"\(tool.name)\" — duplicate wire name \(wire)")
                continue
            }
            guard let schemaData = try? JSONSerialization.data(withJSONObject: tool.parametersSchema),
                  schemaData.count <= maxSchemaBytes else {
                ovLog("📱 client_tools: dropping \"\(tool.name)\" — schema > \(maxSchemaBytes) bytes or not JSON")
                continue
            }
            guard out.count < maxTools else {
                ovLog("📱 client_tools: dropping \"\(tool.name)\" — more than \(maxTools) tools")
                continue
            }
            seen.insert(wire)
            out.append(Entry(wireName: wire, tool: tool,
                             timeoutMs: timeoutOverrides[tool.name] ?? defaultTimeoutMs))
        }
        return out
    }

    /// The advertised wire names, in order.
    var toolNames: [String] { entries.map(\.wireName) }

    /// The `aurelia.client_tools` payload for a given connections snapshot.
    func manifest(connections: PhoneConnections) -> [String: Any] {
        let tools: [[String: Any]] = entries.map { e in
            [
                "name": e.wireName,
                "description": e.tool.description,
                "parameters": e.tool.parametersSchema,
                "timeoutMs": e.timeoutMs
            ]
        }
        return [
            "type": "aurelia.client_tools",
            "tools": tools,
            "connections": connections.wire
        ]
    }

    // MARK: Session lifecycle (called by the realtime service)

    /// The socket is up and our session.update went out: advertise the tools, then watch for
    /// permission changes (the app comes back to the foreground after every system prompt).
    func sessionDidConnect() {
        isSessionActive = true
        sendManifest(reason: "connected")
        if appActiveObserver == nil {
            appActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshConnections(reason: "app active") }
            }
        }
    }

    /// The socket is gone (drop, swap, hang-up): nothing can be answered on it — cancel what is
    /// in flight silently. The next `sessionDidConnect` re-advertises.
    func sessionDidDisconnect() {
        isSessionActive = false
        manifestTask?.cancel(); manifestTask = nil
        if let appActiveObserver {
            NotificationCenter.default.removeObserver(appActiveObserver)
            self.appActiveObserver = nil
        }
        if !inFlight.isEmpty {
            ovLog("📱 client_tools: socket closed with \(inFlight.count) call(s) in flight — cancelled")
        }
        for (_, work) in inFlight { work.exec.cancel(); work.timeout.cancel() }
        inFlight.removeAll()
        busyNames.removeAll()
    }

    /// Read the real states; if they differ from what the brain last saw, send the manifest again.
    func refreshConnections(reason: String) {
        guard isSessionActive else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = await self.connectionsProvider()
            guard self.isSessionActive else { return }
            if now != self.lastSentConnections {
                self.sendManifest(reason: reason, connections: now)
            }
        }
    }

    /// Send `aurelia.client_tools` now (with a fresh connections read unless one is supplied).
    func sendManifest(reason: String, connections: PhoneConnections? = nil) {
        manifestTask?.cancel()
        manifestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let conns: PhoneConnections
            if let connections { conns = connections } else { conns = await self.connectionsProvider() }
            guard !Task.isCancelled, self.isSessionActive else { return }
            let payload = self.manifest(connections: conns)
            self.lastSentConnections = conns
            self.lastManifestSentAt = Date()
            self.send?(payload)
            ovLog("📱 client_tools sent (\(reason)): \(self.entries.count) tools [\(self.toolNames.joined(separator: ", "))] connections \(conns.wire.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
    }

    // MARK: Tool calls

    /// `aurelia.tool_call {id, name, args, timeoutMs}` → run the tool, answer `aurelia.tool_result`.
    func handleToolCall(_ json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else {
            ovLog("📱 tool_call without id — ignored")
            return
        }
        let name = (json["name"] as? String) ?? ""
        let args = (json["args"] as? [String: Any]) ?? [:]

        guard isSessionActive else {
            ovLog("📱 tool_call \(name) \(id) with no session — dropped")
            return
        }
        guard let entry = entries.first(where: { $0.wireName == name }) else {
            ovLog("📱 tool_call \(name) \(id) → err unknown_tool")
            sendResult(id: id, .failure("unknown_tool"))
            return
        }
        guard inFlight[id] == nil else {
            ovLog("📱 tool_call \(name) \(id) — duplicate id, ignored")
            return
        }
        guard !busyNames.contains(name) else {
            ovLog("📱 tool_call \(name) \(id) → err busy (one in flight per tool)")
            sendResult(id: id, .failure("busy"))
            return
        }

        let requested = (json["timeoutMs"] as? Double).map { Int($0) } ?? (json["timeoutMs"] as? Int)
        let timeoutMs = min(Self.maxTimeoutMs, max(Self.minTimeoutMs, requested ?? entry.timeoutMs))
        let startedAt = Date()
        busyNames.insert(name)
        ovLog("📱 tool_call \(name) \(id) ▶ (\(args.keys.sorted().joined(separator: ", "))) timeout \(timeoutMs) ms")

        // Two unstructured tasks race; `finish` is idempotent so whichever lands second is a no-op.
        // A tool that ignores cancellation (EventKit does) still answers the wire on time — the
        // late result is simply dropped.
        let tool = entry.tool
        let exec = Task { [weak self] in
            let outcome: Outcome
            do {
                let text = try await tool.execute(args: args)
                outcome = .success(text)
            } catch let typed as NativeToolError {
                outcome = .failure(typed.wireCode)
            } catch is CancellationError {
                outcome = .failure("timeout")
            } catch {
                outcome = .failure(Self.shortError(error))
            }
            await self?.finish(id: id, outcome)
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.finish(id: id, .failure("timeout"))
        }
        inFlight[id] = InFlight(wireName: name, startedAt: startedAt, exec: exec, timeout: timeout)
    }

    typealias Outcome = ClientToolOutcome

    /// First writer wins: remove the in-flight record, free the name, answer the wire, log.
    private func finish(id: String, _ outcome: Outcome) {
        guard let work = inFlight.removeValue(forKey: id) else { return }   // already answered
        work.exec.cancel()
        work.timeout.cancel()
        busyNames.remove(work.wireName)
        let ms = Int(Date().timeIntervalSince(work.startedAt) * 1000)
        switch outcome {
        case .success(let text):
            ovLog("📱 tool_call \(work.wireName) \(id) → ok in \(ms) ms (\(text.count) chars)")
        case .failure(let code):
            ovLog("📱 tool_call \(work.wireName) \(id) → err \(code) in \(ms) ms")
            // A permission wall may have just shown (or been dismissed) — tell the brain the
            // new state without waiting for the next foreground hop.
            if code.hasPrefix("permission_required:") { refreshConnections(reason: "after \(code)") }
        }
        guard isSessionActive else { return }
        sendResult(id: id, outcome)
    }

    private func sendResult(id: String, _ outcome: Outcome) {
        var payload: [String: Any] = ["type": "aurelia.tool_result", "id": id]
        switch outcome {
        case .success(let text):
            payload["ok"] = true
            payload["result"] = Self.truncated(text)
        case .failure(let code):
            payload["ok"] = false
            payload["error"] = code
        }
        send?(payload)
    }

    /// ≤1024 chars; a clipped result ends in "…" so the brain knows it is a prefix.
    static func truncated(_ text: String) -> String {
        guard text.count > maxResultChars else { return text }
        return String(text.prefix(maxResultChars - 1)) + "…"
    }

    /// One short line for the wire (no newlines, ≤80 chars).
    static func shortError(_ error: Error) -> String {
        let raw = (error as NSError).localizedDescription
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let s = oneLine.isEmpty ? String(describing: error) : oneLine
        return String(s.prefix(80))
    }
}
