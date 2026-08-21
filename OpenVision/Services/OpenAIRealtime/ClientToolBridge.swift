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
//                       a permission prompt just resolved).
//   server → client   aurelia.tool_call {id, name:"phone.<tool>", args, timeoutMs}
//   client → client   aurelia.tool_result {id, ok:true, result:"<≤1024 chars>",
//                                          appState:"active"|"background"|"inactive",
//                                          permissionState:"granted"|"denied"|"notDetermined"|"n/a"}
//                     aurelia.tool_result {id, ok:false, error:"permission_required:calendar" |
//                                          "not_linked:spotify" | "timeout" | "busy" |
//                                          "unknown_tool" | "nothing_to_copy" | "<short>",
//                                          appState, permissionState}
//
// Names: `phone.` + snake_case of the registry name (`^phone\.[a-z0-9_]{1,40}$`), ≤32 tools,
// schema ≤4 KB each, one call in flight per name (a second is answered `busy`), per-call timeout
// (default 8 s, 15 s for document search; the server's `timeoutMs` on the call wins when present).
//
// AUR-836 — permission prompts are a STATE, not a timeout. The ride-home analysis (2026-08-20 F9)
// had three first-use prompts = three 8-s timeouts with the late `ok` dropped on both sides.
// Now every permission-bound tool is pre-flighted BEFORE it runs:
//   granted        → run as before (8-s timeout).
//   denied         → `permission_required:<kind>` + permissionState:"denied" at once; no prompt.
//   notDetermined  → `permission_required:<kind>` + permissionState:"notDetermined" at once (the
//                    brain speaks the one sentence), THEN the system prompt is requested; when it
//                    resolves the manifest is re-sent with the new connections and, if granted, the
//                    ORIGINAL call is re-executed and its `ok` goes out as a LATE result for the
//                    SAME id — the server parks the call for 30 s and accepts it. No timeout runs
//                    while the prompt is up (a prompt is not a slow tool).
// AUR-837 — observability: every result carries `appState` + `permissionState`; the bridge keeps
// the last 10 calls for the Debug → Phone tools read-out; the log line carries appState.
// AUR-845 — deferred effects are told as such, and their landing is reported:
//   client → server   aurelia.tool_result {…, ok:true, deferred:true}  — the tool accepted the call
//                     but iOS defers the effect (a clipboard write from the background); the
//                     `result` text says so («Скопирую, как только откроешь приложение: …»).
//   client → server   aurelia.client_tool.applied {id:"<the tool_call id>", tool:"phone.copy_to_clipboard",
//                     ok:true|false, verifiedByReadback:true|false,
//                     stage:"foreground"|"active"|"manual", queuedMs:<int>, appState:"active",
//                     chars:<int>} — sent once when the queued effect is finished (verified on
//                     read-back when the app came to the front, or, on `didBecomeActive`, the
//                     final failure). Only while a session is open; otherwise logged + kept in the
//                     Debug read-out. The server half (log / speak «скопировано») is not here —
//                     see docs/native-tools.md § "Deferred effects".

import Foundation
import CoreLocation
import EventKit
import UserNotifications
import UIKit

// MARK: - Connections (the permission / link states the manifest carries)

/// What the wire says about one integration. `granted`/`denied`/`unknown` for OS permissions;
/// integrations that need an account link (Spotify, AUR-793) use `linked`/`unlinked`.
enum PhoneConnectionState: String, Equatable {
    case granted, denied, unknown

    /// The `permissionState` spelling on `aurelia.tool_result` (AUR-837): `unknown` on the
    /// manifest IS `notDetermined` on the result — the wording the server spec uses.
    var permissionStateWire: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .unknown: return "notDetermined"
        }
    }
}

/// Snapshot of every connection the manifest reports. Equatable so a re-check after the app comes
/// back to the foreground only re-sends the manifest when something actually changed.
struct PhoneConnections: Equatable {
    var calendar: PhoneConnectionState = .unknown
    var reminders: PhoneConnectionState = .unknown
    var notifications: PhoneConnectionState = .unknown
    /// AUR-794: Location — not a tool gate of its own, but the Wi-Fi network NAME in
    /// `phone.status` is unreadable without it (and contextual notes lose their place tag), so the
    /// brain and the Connections UI both get to see the state.
    var location: PhoneConnectionState = .unknown
    /// AUR-793 placeholder — a constant until the Spotify link lands (the key is on the wire now
    /// so the server half and the Connections UI have the field to grow into).
    var spotify: String = "unlinked"

    /// The `connections` object as sent.
    var wire: [String: String] {
        [
            "calendar": calendar.rawValue,
            "reminders": reminders.rawValue,
            "notifications": notifications.rawValue,
            "location": location.rawValue,
            "spotify": spotify
        ]
    }

    /// Ordered rows for the Settings → Debug read-out.
    var rows: [(kind: String, state: String)] {
        [("Calendar", calendar.rawValue), ("Reminders", reminders.rawValue),
         ("Notifications", notifications.rawValue), ("Location", location.rawValue),
         ("Spotify", spotify)]
    }

    /// The state for one permission kind (a tool's `permissionKind`); nil for an unknown kind.
    func state(for kind: String) -> PhoneConnectionState? {
        switch kind {
        case "calendar": return calendar
        case "reminders": return reminders
        case "notifications": return notifications
        case "location": return location
        default: return nil
        }
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
        c.location = locationState()
        return c
    }

    /// AUR-794: Location — read only, never prompts (`CLLocationManager()` init is cheap and its
    /// `authorizationStatus` is a plain read).
    private static func locationState() -> PhoneConnectionState {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return .granted
        case .notDetermined: return .unknown
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    private static func eventKitState(_ entity: EKEntityType) -> PhoneConnectionState {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .unknown
        case .denied, .restricted, .writeOnly: return .denied
        @unknown default: return .unknown
        }
    }

    /// Show the system prompt for one kind (AUR-836). Returns true when access was granted.
    /// Only ever called after a `notDetermined` read — a granted/denied state never prompts.
    static func requestPermission(kind: String) async -> Bool {
        switch kind {
        case "calendar":
            let store = EKEventStore()
            if #available(iOS 17.0, *) { return (try? await store.requestFullAccessToEvents()) ?? false }
            return (try? await store.requestAccess(to: .event)) ?? false
        case "reminders":
            let store = EKEventStore()
            if #available(iOS 17.0, *) { return (try? await store.requestFullAccessToReminders()) ?? false }
            return (try? await store.requestAccess(to: .reminder)) ?? false
        case "notifications":
            return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        case "location":
            return await LocationHelper.shared.requestWhenInUse()
        default:
            return false
        }
    }
}

/// What one tool call produced: the text to send, or the wire error code.
enum ClientToolOutcome: Equatable {
    case success(String)
    case failure(String)
}

/// One finished call, for the Debug → Phone tools read-out (AUR-837): the last 10 are kept.
struct ClientToolCallRecord: Identifiable, Equatable {
    let id: String
    let wireName: String
    let ok: Bool
    /// The error code for a failure, nil for success.
    let error: String?
    let ms: Int
    let appState: AppForegroundState
    let permissionState: String
    let late: Bool
    let at: Date
    /// AUR-845: `ok` but the effect lands later (`aurelia.tool_result.deferred:true`).
    var deferred: Bool = false
    /// AUR-845: this row IS the later landing (`aurelia.client_tool.applied`), not a call.
    var applied: Bool = false

    var shortName: String { wireName.hasPrefix(ClientToolBridge.namePrefix) ? String(wireName.dropFirst(ClientToolBridge.namePrefix.count)) : wireName }
    var statusText: String {
        if applied { return ok ? "applied" : "err \(error ?? "not_applied")" }
        if ok { return deferred ? "ok (deferred)" : (late ? "ok (late)" : "ok") }
        return "err \(error ?? "?")"
    }
}

// MARK: - Bridge

@MainActor
final class ClientToolBridge: ObservableObject {

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
    static let recentCallsKept = 10

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
    /// How the bridge shows a system permission prompt (AUR-836) — injectable; returns granted?
    var permissionRequester: (String) async -> Bool = { await PhoneConnections.requestPermission(kind: $0) }
    /// How the bridge reads the app's foreground state (AUR-837) — injectable.
    var appStateProvider: () -> AppForegroundState = { AppForegroundState.current() }
    /// Last connections snapshot that went out (Settings → Debug shows it).
    private(set) var lastSentConnections: PhoneConnections?
    private(set) var lastManifestSentAt: Date?
    /// True between `sessionDidConnect` and `sessionDidDisconnect` — nothing is sent otherwise.
    private(set) var isSessionActive = false
    /// The last 10 finished calls, newest first (AUR-837 Debug read-out).
    @Published private(set) var recentCalls: [ClientToolCallRecord] = []

    private struct InFlight {
        let wireName: String
        let startedAt: Date
        let args: [String: Any]
        let timeoutMs: Int
        let permissionKind: String?
        /// The whole pipeline (pre-flight → run, or pre-flight → prompt → late run).
        var pipeline: Task<Void, Never>?
        /// The deadline for the tool body — armed only when a body is actually running.
        var timeout: Task<Void, Never>?
        /// Pre-flight result, the `permissionState` the answer carries.
        var permissionState: PhoneConnectionState?
        /// True once the immediate `permission_required` went out: the next answer is the late one.
        var late = false
    }
    private var inFlight: [String: InFlight] = [:]     // call id → work
    private var busyNames: Set<String> = []            // one call per wire name
    /// Permission kinds with a system prompt currently up (AUR-836): a second call that needs
    /// the same kind is answered `permission_required:<kind>` at once, not prompted twice.
    private var promptingKinds: Set<String> = []
    private var appActiveObserver: NSObjectProtocol?
    private var manifestTask: Task<Void, Never>?

    // MARK: Init

    init(tools: [NativeTool],
         connectionsProvider: @escaping () async -> PhoneConnections = { await PhoneConnections.current() },
         pendingClipboard: PendingClipboard = .shared) {
        self.connectionsProvider = connectionsProvider
        self.entries = Self.buildEntries(tools)
        // AUR-845: the clipboard's foreground re-apply reports back through the bridge.
        pendingClipboard.onApplied = { [weak self] event in self?.reportApplied(event) }
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

    /// Wire name → the permission kind the tool pre-flights (nil = none). The AUR-836 mapping,
    /// exposed for the tests and the Debug read-out.
    func permissionKind(for wireName: String) -> String? {
        entries.first(where: { $0.wireName == wireName })?.tool.permissionKind
    }

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
        for (_, work) in inFlight { work.pipeline?.cancel(); work.timeout?.cancel() }
        inFlight.removeAll()
        busyNames.removeAll()
        promptingKinds.removeAll()
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

    /// `aurelia.tool_call {id, name, args, timeoutMs}` → pre-flight, run the tool, answer
    /// `aurelia.tool_result`.
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
            sendResult(id: id, .failure("unknown_tool"), permissionState: nil)
            record(id: id, wireName: name, .failure("unknown_tool"), ms: 0, permissionState: "n/a", late: false)
            return
        }
        guard inFlight[id] == nil else {
            ovLog("📱 tool_call \(name) \(id) — duplicate id, ignored")
            return
        }
        let kind = entry.tool.permissionKind
        // A prompt for this kind is already up (another tool of the same kind asked first):
        // answer the state, don't queue a second prompt behind it.
        if let kind, promptingKinds.contains(kind) {
            ovLog("📱 tool_call \(name) \(id) → err permission_required:\(kind) (prompt already up) appState=\(appStateProvider().rawValue)")
            sendResult(id: id, .failure("permission_required:\(kind)"), permissionState: .unknown)
            record(id: id, wireName: name, .failure("permission_required:\(kind)"), ms: 0,
                   permissionState: PhoneConnectionState.unknown.permissionStateWire, late: false)
            return
        }
        guard !busyNames.contains(name) else {
            ovLog("📱 tool_call \(name) \(id) → err busy (one in flight per tool)")
            sendResult(id: id, .failure("busy"), permissionState: nil)
            record(id: id, wireName: name, .failure("busy"), ms: 0, permissionState: "n/a", late: false)
            return
        }

        let requested = (json["timeoutMs"] as? Double).map { Int($0) } ?? (json["timeoutMs"] as? Int)
        let timeoutMs = min(Self.maxTimeoutMs, max(Self.minTimeoutMs, requested ?? entry.timeoutMs))
        let startedAt = Date()
        busyNames.insert(name)
        ovLog("📱 tool_call \(name) \(id) ▶ (\(args.keys.sorted().joined(separator: ", "))) timeout \(timeoutMs) ms appState=\(appStateProvider().rawValue)\(kind.map { " permission=\($0)" } ?? "")")

        var work = InFlight(wireName: name, startedAt: startedAt, args: args, timeoutMs: timeoutMs,
                            permissionKind: kind)
        work.pipeline = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let kind else {
                // No permission involved: straight to the body.
                self.runBody(id: id, tool: entry.tool, late: false)
                return
            }
            // AUR-836 pre-flight: read the REAL status, no side effects.
            let state = (await self.connectionsProvider()).state(for: kind) ?? .unknown
            guard !Task.isCancelled, self.inFlight[id] != nil else { return }
            self.inFlight[id]?.permissionState = state
            switch state {
            case .granted:
                self.runBody(id: id, tool: entry.tool, late: false)
            case .denied:
                self.finish(id: id, .failure("permission_required:\(kind)"))
            case .unknown:
                // Answer NOW (the brain speaks the one sentence) — then prompt, then maybe run.
                self.ovLogPermission("pre-flight notDetermined — answering permission_required:\(kind) before the prompt", name: name, id: id)
                self.sendResult(id: id, .failure("permission_required:\(kind)"), permissionState: .unknown)
                self.inFlight[id]?.late = true
                self.promptingKinds.insert(kind)
                let granted = await self.permissionRequester(kind)
                self.promptingKinds.remove(kind)
                guard !Task.isCancelled, self.isSessionActive else { return }
                // The manifest goes out right after the prompt resolves — not only on app-active.
                self.sendManifest(reason: "permission prompt resolved: \(kind)=\(granted ? "granted" : "denied")")
                guard self.inFlight[id] != nil else { return }
                self.inFlight[id]?.permissionState = granted ? .granted : .denied
                if granted {
                    self.ovLogPermission("prompt granted — re-running the original call (late result for the same id)", name: name, id: id)
                    self.runBody(id: id, tool: entry.tool, late: true)
                } else {
                    self.ovLogPermission("prompt denied — no late result", name: name, id: id)
                    self.drop(id: id)
                }
            }
        }
        inFlight[id] = work
    }

    private func ovLogPermission(_ what: String, name: String, id: String) {
        ovLog("📱 tool_call \(name) \(id) ⏳ \(what)")
    }

    /// Run the tool body with its timeout (the 8-s budget is for genuinely slow tools, never for
    /// the permission path — it is armed here, after the pre-flight decided to run).
    private func runBody(id: String, tool: NativeTool, late: Bool) {
        guard let work = inFlight[id] else { return }
        let args = work.args
        let call = NativeToolCall(id: id, wireName: work.wireName)
        let exec = Task { [weak self] in
            let outcome: Outcome
            var deferred = false
            do {
                let reply = try await tool.execute(args: args, call: call)
                outcome = .success(reply.text)
                deferred = reply.deferred
            } catch let typed as NativeToolError {
                outcome = .failure(typed.wireCode)
            } catch is CancellationError {
                outcome = .failure("timeout")
            } catch {
                outcome = .failure(Self.shortError(error))
            }
            await self?.finish(id: id, outcome, deferred: deferred)
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(work.timeoutMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.finish(id: id, .failure("timeout"))
        }
        // The body task replaces the pipeline slot (the pipeline is finishing now anyway); the
        // timeout is armed only here.
        inFlight[id]?.pipeline = exec
        inFlight[id]?.timeout = timeout
        inFlight[id]?.late = late
    }

    typealias Outcome = ClientToolOutcome

    /// Remove the in-flight record and free the name WITHOUT answering (a denied prompt: the
    /// `permission_required` already went out).
    private func drop(id: String) {
        guard let work = inFlight.removeValue(forKey: id) else { return }
        work.timeout?.cancel()
        busyNames.remove(work.wireName)
        let ms = Int(Date().timeIntervalSince(work.startedAt) * 1000)
        record(id: id, wireName: work.wireName, .failure("permission_required:\(work.permissionKind ?? "?")"),
               ms: ms, permissionState: (work.permissionState ?? .denied).permissionStateWire, late: false)
    }

    /// First writer wins: remove the in-flight record, free the name, answer the wire, log.
    /// `deferred` (AUR-845): the tool accepted the call, the effect lands later.
    private func finish(id: String, _ outcome: Outcome, deferred: Bool = false) {
        guard let work = inFlight.removeValue(forKey: id) else { return }   // already answered
        work.pipeline?.cancel()
        work.timeout?.cancel()
        busyNames.remove(work.wireName)
        let ms = Int(Date().timeIntervalSince(work.startedAt) * 1000)
        let appState = appStateProvider()
        let permState = work.permissionKind == nil ? "n/a" : (work.permissionState ?? .unknown).permissionStateWire
        let lateTag = (work.late ? " (late, after permission)" : "") + (deferred ? " (deferred)" : "")
        switch outcome {
        case .success(let text):
            ovLog("📱 tool_call \(work.wireName) \(id) → ok\(lateTag) in \(ms) ms (\(text.count) chars) appState=\(appState.rawValue) permission=\(permState)")
        case .failure(let code):
            ovLog("📱 tool_call \(work.wireName) \(id) → err \(code)\(lateTag) in \(ms) ms appState=\(appState.rawValue) permission=\(permState)")
            // A permission wall may have just shown (or been dismissed) inside the tool body —
            // tell the brain the new state without waiting for the next foreground hop.
            if code.hasPrefix("permission_required:") { refreshConnections(reason: "after \(code)") }
        }
        record(id: id, wireName: work.wireName, outcome, ms: ms, permissionState: permState, late: work.late,
               deferred: deferred)
        guard isSessionActive else { return }
        sendResult(id: id, outcome, permissionState: work.permissionKind == nil ? nil : (work.permissionState ?? .unknown),
                   deferred: deferred)
    }

    /// `aurelia.tool_result` with the AUR-837 fields. `permissionState` nil → "n/a".
    /// `deferred:true` (AUR-845) only on an ok whose effect lands later — absent otherwise.
    private func sendResult(id: String, _ outcome: Outcome, permissionState: PhoneConnectionState?,
                            deferred: Bool = false) {
        var payload: [String: Any] = ["type": "aurelia.tool_result", "id": id]
        switch outcome {
        case .success(let text):
            payload["ok"] = true
            payload["result"] = Self.truncated(text)
            if deferred { payload["deferred"] = true }
        case .failure(let code):
            payload["ok"] = false
            payload["error"] = code
        }
        payload["appState"] = appStateProvider().rawValue
        payload["permissionState"] = permissionState?.permissionStateWire ?? "n/a"
        send?(payload)
    }

    /// Keep the last 10 finished calls, newest first (AUR-837).
    private func record(id: String, wireName: String, _ outcome: Outcome, ms: Int, permissionState: String, late: Bool,
                        deferred: Bool = false) {
        let ok: Bool, error: String?
        switch outcome {
        case .success: ok = true; error = nil
        case .failure(let code): ok = false; error = code
        }
        let rec = ClientToolCallRecord(id: id, wireName: wireName, ok: ok, error: error, ms: ms,
                                       appState: appStateProvider(), permissionState: permissionState,
                                       late: late, at: Date(), deferred: deferred)
        push(rec)
    }

    private func push(_ rec: ClientToolCallRecord) {
        recentCalls.insert(rec, at: 0)
        if recentCalls.count > Self.recentCallsKept { recentCalls.removeLast(recentCalls.count - Self.recentCallsKept) }
    }

    // MARK: Deferred effects landing (AUR-845)

    /// The `aurelia.client_tool.applied` frame for one finished re-apply. Pure, so the tests pin
    /// the exact JSON the server half is wired against.
    static func appliedPayload(_ e: ClipboardApplied) -> [String: Any] {
        var p: [String: Any] = [
            "type": "aurelia.client_tool.applied",
            "tool": e.wireName,
            "ok": e.ok,
            "verifiedByReadback": e.verifiedByReadback,
            "stage": e.stage,
            "queuedMs": e.queuedMs,
            "appState": e.appState.rawValue,
            "chars": e.chars
        ]
        if let id = e.callId { p["id"] = id }
        return p
    }

    /// A queued effect finished (the clipboard re-apply on foreground): tell the brain, keep a
    /// Debug row. `lastApplied` survives for the read-out even when no session is open to hear it.
    private(set) var lastApplied: ClipboardApplied?
    func reportApplied(_ e: ClipboardApplied) {
        lastApplied = e
        ovLog("📱 client_tool.applied \(e.wireName) \(e.callId ?? "-") → \(e.ok ? "ok" : "NOT applied") stage=\(e.stage) readback=\(e.verifiedByReadback ? "ok" : "mismatch") after \(e.queuedMs) ms appState=\(e.appState.rawValue)\(isSessionActive ? "" : " (no session — not sent)")")
        push(ClientToolCallRecord(id: "\(e.callId ?? "manual")#applied", wireName: e.wireName, ok: e.ok,
                                  error: e.ok ? nil : "not_applied", ms: e.queuedMs, appState: e.appState,
                                  permissionState: "n/a", late: true, at: Date(), applied: true))
        guard isSessionActive else { return }
        send?(Self.appliedPayload(e))
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
