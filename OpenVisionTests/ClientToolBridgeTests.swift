import XCTest
@testable import OpenVision

/// AUR-792: the phone.* client-tool rail — manifest shape, dispatch, timeout, unknown, busy,
/// permission mapping, truncation. Fake tools only; no EventKit / notifications are touched.
@MainActor
final class ClientToolBridgeTests: XCTestCase {

    // MARK: - Fakes

    struct FakeTool: NativeTool {
        let name: String
        var description: String = "fake"
        var parametersSchema: [String: Any] = ["type": "object", "properties": [:]]
        var permissionKind: String? = nil
        var body: @Sendable ([String: Any]) async throws -> String = { _ in "ok" }
        func execute(args: [String: Any]) async throws -> String { try await body(args) }
    }

    struct Boom: Error {}

    /// A bridge with the given tools, an "active" session, captured sends, and a fixed
    /// connections snapshot (calendar granted, reminders denied, notifications unknown).
    private func makeBridge(_ tools: [NativeTool],
                            connections: PhoneConnections = PhoneConnections(calendar: .granted, reminders: .denied, notifications: .unknown))
    -> (ClientToolBridge, Sent) {
        let sent = Sent()
        // A FRESH pending-clipboard per bridge (AUR-845): `.shared` is the app's singleton and a
        // test must never leave its `onApplied` pointing at a dead bridge.
        let bridge = ClientToolBridge(tools: tools, connectionsProvider: { connections },
                                      pendingClipboard: PendingClipboard(notifier: ClipboardToolTests.FakeNotifier(), appState: { .active }))
        bridge.send = { sent.append($0) }
        return (bridge, sent)
    }

    /// Captured outbound payloads + an expectation per arrival.
    final class Sent {
        private(set) var payloads: [[String: Any]] = []
        private var waiters: [(Int, XCTestExpectation)] = []
        func append(_ p: [String: Any]) {
            payloads.append(p)
            for (count, exp) in waiters where payloads.count >= count { exp.fulfill() }
            waiters.removeAll { payloads.count >= $0.0 }
        }
        func expectation(count: Int) -> XCTestExpectation {
            let exp = XCTestExpectation(description: "sent \(count)")
            if payloads.count >= count { exp.fulfill() } else { waiters.append((count, exp)) }
            return exp
        }
        var results: [[String: Any]] { payloads.filter { ($0["type"] as? String) == "aurelia.tool_result" } }
        var manifests: [[String: Any]] { payloads.filter { ($0["type"] as? String) == "aurelia.client_tools" } }
    }

    private func call(_ bridge: ClientToolBridge, id: String, name: String, args: [String: Any] = [:], timeoutMs: Int? = nil) {
        var json: [String: Any] = ["type": "aurelia.tool_call", "id": id, "name": name, "args": args]
        if let timeoutMs { json["timeoutMs"] = timeoutMs }
        bridge.handleToolCall(json)
    }

    private func waitFor(_ sent: Sent, count: Int, timeout: TimeInterval = 5) async {
        await fulfillment(of: [sent.expectation(count: count)], timeout: timeout)
    }

    // MARK: - Names

    func testWireNameIsPhonePrefixPlusSnakeCase() {
        XCTAssertEqual(ClientToolBridge.wireName(for: "set_timer"), "phone.set_timer")
        XCTAssertEqual(ClientToolBridge.wireName(for: "calendar"), "phone.calendar")
        XCTAssertEqual(ClientToolBridge.wireName(for: "createReminder"), "phone.create_reminder")
        XCTAssertEqual(ClientToolBridge.wireName(for: "Spotify Play-Now"), "phone.spotify_play_now")
        XCTAssertEqual(ClientToolBridge.wireName(for: "__weird__"), "phone.weird")
        XCTAssertEqual(ClientToolBridge.wireName(for: "héllo"), "phone.h_llo")
        // Clipped to the 40-char body.
        let long = ClientToolBridge.wireName(for: String(repeating: "a", count: 60))
        XCTAssertEqual(long.count, "phone.".count + 40)
        XCTAssertTrue(ClientToolBridge.isValidWireName(long))
        XCTAssertFalse(ClientToolBridge.isValidWireName("phone."))
        XCTAssertFalse(ClientToolBridge.isValidWireName("set_timer"))
        XCTAssertFalse(ClientToolBridge.isValidWireName("phone.Set_Timer"))
    }

    // MARK: - Manifest

    func testManifestShapeNamesLimitsAndConnections() {
        let tools: [NativeTool] = [
            FakeTool(name: "set_timer", description: "Set a timer",
                     parametersSchema: ["type": "object", "properties": ["seconds": ["type": "integer"]], "required": ["seconds"]]),
            FakeTool(name: "search_docs", description: "Search"),
            FakeTool(name: "calendar")
        ]
        let (bridge, _) = makeBridge(tools)
        XCTAssertEqual(bridge.toolNames, ["phone.set_timer", "phone.search_docs", "phone.calendar"])

        let m = bridge.manifest(connections: PhoneConnections(calendar: .granted, reminders: .denied, notifications: .unknown))
        XCTAssertEqual(m["type"] as? String, "aurelia.client_tools")
        let sent = m["tools"] as? [[String: Any]]
        XCTAssertEqual(sent?.count, 3)
        XCTAssertEqual(sent?[0]["name"] as? String, "phone.set_timer")
        XCTAssertEqual(sent?[0]["description"] as? String, "Set a timer")
        XCTAssertEqual(sent?[0]["timeoutMs"] as? Int, 8000)
        XCTAssertEqual((sent?[0]["parameters"] as? [String: Any])?["required"] as? [String], ["seconds"])
        // Document search gets the longer budget.
        XCTAssertEqual(sent?[1]["timeoutMs"] as? Int, 15000)
        // Every advertised name matches the wire regex.
        for t in sent ?? [] { XCTAssertTrue(ClientToolBridge.isValidWireName(t["name"] as? String ?? "")) }
        // Connections as sent.
        let c = m["connections"] as? [String: String]
        XCTAssertEqual(c?["calendar"], "granted")
        XCTAssertEqual(c?["reminders"], "denied")
        XCTAssertEqual(c?["notifications"], "unknown")
        XCTAssertEqual(c?["spotify"], "unlinked")
        // The whole thing serialises (no non-JSON types leaked in).
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: m))
    }

    func testManifestCapsAtThirtyTwoAndDropsOversizeSchemasAndDuplicates() {
        var tools: [NativeTool] = (0..<40).map { FakeTool(name: "tool_\($0)") }
        // Oversize schema (> 4 KB) is dropped.
        let fat = String(repeating: "x", count: 5000)
        tools.insert(FakeTool(name: "fat", parametersSchema: ["type": "object", "description": fat]), at: 0)
        // Two registry names that snake-case to the same wire name keep the first.
        tools.insert(FakeTool(name: "Tool 1"), at: 0)   // → phone.tool_1, same as tool_1
        let (bridge, _) = makeBridge(tools)
        XCTAssertEqual(bridge.toolNames.count, ClientToolBridge.maxTools)
        XCTAssertFalse(bridge.toolNames.contains("phone.fat"))
        XCTAssertEqual(bridge.toolNames.filter { $0 == "phone.tool_1" }.count, 1)
        XCTAssertEqual(bridge.toolNames.first, "phone.tool_1")
    }

    func testManifestIsSentOnConnectAndOnlyWhenConnectionsChange() async {
        let (bridge, sent) = makeBridge([FakeTool(name: "set_timer")])
        // Nothing goes out before the session is up.
        bridge.sendManifest(reason: "too early")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sent.manifests.isEmpty)

        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)
        XCTAssertEqual(sent.manifests.count, 1)
        XCTAssertEqual(bridge.lastSentConnections?.calendar, .granted)
        XCTAssertNotNil(bridge.lastManifestSentAt)

        // Same states again → no re-send.
        bridge.refreshConnections(reason: "app active")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sent.manifests.count, 1)

        // A state flips → re-sent with the new snapshot.
        bridge.connectionsProvider = { PhoneConnections(calendar: .granted, reminders: .granted, notifications: .granted) }
        bridge.refreshConnections(reason: "prompt answered")
        await waitFor(sent, count: 2)
        XCTAssertEqual(sent.manifests.count, 2)
        XCTAssertEqual((sent.manifests[1]["connections"] as? [String: String])?["reminders"], "granted")

        // After disconnect nothing is sent.
        bridge.sessionDidDisconnect()
        bridge.refreshConnections(reason: "gone")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sent.manifests.count, 2)
    }

    // MARK: - Dispatch

    func testDispatchReturnsToolResult() async {
        let echo = FakeTool(name: "echo", body: { args in "you said \(args["text"] as? String ?? "?")" })
        let (bridge, sent) = makeBridge([echo])
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)   // the manifest

        call(bridge, id: "tc_1", name: "phone.echo", args: ["text": "hi"])
        await waitFor(sent, count: 2)
        let r = sent.results.first
        XCTAssertEqual(r?["type"] as? String, "aurelia.tool_result")
        XCTAssertEqual(r?["id"] as? String, "tc_1")
        XCTAssertEqual(r?["ok"] as? Bool, true)
        XCTAssertEqual(r?["result"] as? String, "you said hi")
        XCTAssertNil(r?["error"])
    }

    func testUnknownToolIsAnError() async {
        let (bridge, sent) = makeBridge([FakeTool(name: "echo")])
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)
        call(bridge, id: "tc_x", name: "phone.teleport")
        await waitFor(sent, count: 2)
        let r = sent.results.first
        XCTAssertEqual(r?["id"] as? String, "tc_x")
        XCTAssertEqual(r?["ok"] as? Bool, false)
        XCTAssertEqual(r?["error"] as? String, "unknown_tool")
        XCTAssertNil(r?["result"])
    }

    func testNothingRunsWithoutASession() async {
        let ran = Flag()
        let tool = FakeTool(name: "echo", body: { _ in ran.set(); return "ran" })
        let (bridge, sent) = makeBridge([tool])
        call(bridge, id: "tc_0", name: "phone.echo")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(sent.payloads.isEmpty)
        XCTAssertFalse(ran.value)
    }

    final class Flag: @unchecked Sendable {
        private(set) var value = false
        func set() { value = true }
    }

    // MARK: - Timeout

    func testTimeoutAnswersTimeoutAndFreesTheName() async {
        let slow = FakeTool(name: "slow", body: { _ in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return "late"
        })
        let (bridge, sent) = makeBridge([slow])
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)

        let t0 = Date()
        call(bridge, id: "tc_slow", name: "phone.slow", timeoutMs: 500)
        await waitFor(sent, count: 2)
        let r = sent.results.first
        XCTAssertEqual(r?["ok"] as? Bool, false)
        XCTAssertEqual(r?["error"] as? String, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5, "timeout must not wait for the tool")

        // The name is free again: a second call is not `busy` (it times out like the first).
        call(bridge, id: "tc_again", name: "phone.slow", timeoutMs: 500)
        await waitFor(sent, count: 3)
        XCTAssertEqual(sent.results.last?["error"] as? String, "timeout")   // still the slow body
        XCTAssertNotEqual(sent.results.last?["error"] as? String, "busy")
    }

    // MARK: - Busy

    func testSecondCallOnSameNameIsBusyUntilTheFirstFinishes() async {
        let gate = Gate()
        let blocking = FakeTool(name: "block", body: { _ in
            await gate.wait()
            return "done"
        })
        let (bridge, sent) = makeBridge([blocking, FakeTool(name: "other")])
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)

        call(bridge, id: "tc_a", name: "phone.block")
        call(bridge, id: "tc_b", name: "phone.block")      // → busy
        call(bridge, id: "tc_c", name: "phone.other")      // a different name runs
        await waitFor(sent, count: 3)
        let busy = sent.results.first { ($0["id"] as? String) == "tc_b" }
        XCTAssertEqual(busy?["ok"] as? Bool, false)
        XCTAssertEqual(busy?["error"] as? String, "busy")
        let other = sent.results.first { ($0["id"] as? String) == "tc_c" }
        XCTAssertEqual(other?["ok"] as? Bool, true)

        gate.open()
        await waitFor(sent, count: 4)
        let a = sent.results.first { ($0["id"] as? String) == "tc_a" }
        XCTAssertEqual(a?["ok"] as? Bool, true)
        XCTAssertEqual(a?["result"] as? String, "done")

        // Name free again.
        call(bridge, id: "tc_d", name: "phone.block")
        await waitFor(sent, count: 5)
        XCTAssertEqual(sent.results.last?["id"] as? String, "tc_d")
        XCTAssertEqual(sent.results.last?["ok"] as? Bool, true)
    }

    /// A one-shot async gate (already-open state is remembered).
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        nonisolated func open() { Task { await self.release() } }
        private func release() {
            isOpen = true
            for w in waiters { w.resume() }
            waiters.removeAll()
        }
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    // MARK: - Permission mapping + other errors

    func testPermissionErrorsMapToWireCodes() async {
        let cal = FakeTool(name: "calendar", body: { _ in throw NativeToolError.permissionRequired(kind: "calendar") })
        let spot = FakeTool(name: "spotify_play", body: { _ in throw NativeToolError.notLinked(service: "spotify") })
        let boom = FakeTool(name: "boom", body: { _ in throw Boom() })
        let (bridge, sent) = makeBridge([cal, spot, boom])
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)

        call(bridge, id: "p1", name: "phone.calendar")
        call(bridge, id: "p2", name: "phone.spotify_play")
        call(bridge, id: "p3", name: "phone.boom")
        await waitFor(sent, count: 4)
        let byId = Dictionary(uniqueKeysWithValues: sent.results.map { ($0["id"] as! String, $0) })
        XCTAssertEqual(byId["p1"]?["ok"] as? Bool, false)
        XCTAssertEqual(byId["p1"]?["error"] as? String, "permission_required:calendar")
        XCTAssertEqual(byId["p2"]?["error"] as? String, "not_linked:spotify")
        XCTAssertEqual(byId["p3"]?["ok"] as? Bool, false)
        let short = byId["p3"]?["error"] as? String ?? ""
        XCTAssertFalse(short.isEmpty)
        XCTAssertLessThanOrEqual(short.count, 80)
        XCTAssertFalse(short.contains("\n"))
    }

    func testTypedErrorKeepsTheSpokenSentenceForPushToAsk() {
        // The legacy path reads the error's sentence out; the bridge uses the code.
        let e = NativeToolError.permissionRequired(kind: "calendar")
        XCTAssertEqual(e.wireCode, "permission_required:calendar")
        XCTAssertEqual(e.errorDescription, "I need Calendar access — enable it in Settings, then ask again.")
        XCTAssertEqual(NativeToolError.notLinked(service: "spotify").wireCode, "not_linked:spotify")
    }

    // MARK: - Truncation

    func testLongResultsAreTruncatedTo1024Chars() async {
        let big = FakeTool(name: "big", body: { _ in String(repeating: "я", count: 5000) })
        let (bridge, sent) = makeBridge([big])
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)
        call(bridge, id: "tc_big", name: "phone.big")
        await waitFor(sent, count: 2)
        let result = sent.results.first?["result"] as? String ?? ""
        XCTAssertEqual(result.count, ClientToolBridge.maxResultChars)
        XCTAssertTrue(result.hasSuffix("…"))
        // Short results pass through untouched.
        XCTAssertEqual(ClientToolBridge.truncated("short"), "short")
        XCTAssertEqual(ClientToolBridge.truncated(String(repeating: "a", count: 1024)).count, 1024)
    }

    // MARK: - AUR-837: every result carries appState + permissionState

    func testEveryResultCarriesAppStateAndPermissionState() async {
        let (bridge, sent) = makeBridge([FakeTool(name: "note")])
        bridge.appStateProvider = { .background }
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)
        call(bridge, id: "r1", name: "phone.note", args: ["text": "x"])
        call(bridge, id: "r2", name: "phone.nope")
        await waitFor(sent, count: 3)
        for r in sent.results {
            XCTAssertEqual(r["appState"] as? String, "background", "\(r)")
            XCTAssertEqual(r["permissionState"] as? String, "n/a", "a tool without a permission kind says n/a: \(r)")
        }
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: sent.results.first!))
        // The Debug read-out remembers the calls, newest first.
        // r2 (unknown_tool) is recorded synchronously at call time; r1 finishes after it.
        XCTAssertEqual(bridge.recentCalls.map(\.id), ["r1", "r2"])
        XCTAssertEqual(bridge.recentCalls.first?.appState, .background)
    }

    func testRecentCallsKeepsTheLastTen() async {
        let (bridge, sent) = makeBridge([FakeTool(name: "echo")])
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)
        for i in 0..<13 {
            call(bridge, id: "c\(i)", name: "phone.echo")
            await waitFor(sent, count: 2 + i)
        }
        XCTAssertEqual(bridge.recentCalls.count, ClientToolBridge.recentCallsKept)
        XCTAssertEqual(bridge.recentCalls.first?.id, "c12")
        XCTAssertEqual(bridge.recentCalls.last?.id, "c3")
        XCTAssertEqual(bridge.recentCalls.first?.statusText, "ok")
        XCTAssertEqual(bridge.recentCalls.first?.shortName, "echo")
    }

    // MARK: - AUR-836: pre-flight mapping + permission prompts as a state

    func testPreflightMappingOnTheRealRegistry() {
        let bridge = ClientToolBridge(tools: NativeToolRegistry.shared.allTools, connectionsProvider: { PhoneConnections() },
                                      pendingClipboard: PendingClipboard(notifier: ClipboardToolTests.FakeNotifier(), appState: { .active }))
        XCTAssertEqual(bridge.permissionKind(for: "phone.calendar"), "calendar")
        XCTAssertEqual(bridge.permissionKind(for: "phone.create_reminder"), "reminders")
        XCTAssertEqual(bridge.permissionKind(for: "phone.set_timer"), "notifications")
        XCTAssertEqual(bridge.permissionKind(for: "phone.start_pomodoro"), "notifications")
        XCTAssertNil(bridge.permissionKind(for: "phone.copy_to_clipboard"))
        XCTAssertNil(bridge.permissionKind(for: "phone.search_docs"))
        XCTAssertNil(bridge.permissionKind(for: "phone.nope"))
        // The manifest `unknown` is the result's `notDetermined`.
        XCTAssertEqual(PhoneConnectionState.unknown.permissionStateWire, "notDetermined")
        XCTAssertEqual(PhoneConnectionState.granted.permissionStateWire, "granted")
        XCTAssertEqual(PhoneConnectionState.denied.permissionStateWire, "denied")
        XCTAssertEqual(PhoneConnections(calendar: .denied).state(for: "calendar"), .denied)
        XCTAssertNil(PhoneConnections().state(for: "spotify"))
    }

    func testGrantedPreflightRunsTheToolAndSaysGranted() async {
        let ran = Flag()
        let cal = FakeTool(name: "calendar", permissionKind: "calendar", body: { _ in ran.set(); return "2 events" })
        let (bridge, sent) = makeBridge([cal], connections: PhoneConnections(calendar: .granted))
        var prompted = false
        bridge.permissionRequester = { _ in prompted = true; return true }
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)
        call(bridge, id: "g1", name: "phone.calendar", args: ["action": "today"])
        await waitFor(sent, count: 2)
        let r = sent.results.first
        XCTAssertEqual(r?["ok"] as? Bool, true)
        XCTAssertEqual(r?["result"] as? String, "2 events")
        XCTAssertEqual(r?["permissionState"] as? String, "granted")
        XCTAssertTrue(ran.value)
        XCTAssertFalse(prompted, "granted never prompts")
    }

    func testDeniedPreflightAnswersPermissionRequiredWithoutPromptOrRun() async {
        let ran = Flag()
        let rem = FakeTool(name: "create_reminder", permissionKind: "reminders", body: { _ in ran.set(); return "added" })
        let (bridge, sent) = makeBridge([rem], connections: PhoneConnections(reminders: .denied))
        var prompted = false
        bridge.permissionRequester = { _ in prompted = true; return true }
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)
        call(bridge, id: "d1", name: "phone.create_reminder", args: ["title": "milk"])
        await waitFor(sent, count: 2)
        let r = sent.results.first
        XCTAssertEqual(r?["id"] as? String, "d1")
        XCTAssertEqual(r?["ok"] as? Bool, false)
        XCTAssertEqual(r?["error"] as? String, "permission_required:reminders")
        XCTAssertEqual(r?["permissionState"] as? String, "denied")
        XCTAssertFalse(prompted, "denied never prompts")
        XCTAssertFalse(ran.value, "denied never runs the tool")
        // The name is free again right away.
        call(bridge, id: "d2", name: "phone.create_reminder", args: ["title": "milk"])
        await waitFor(sent, count: 3)
        XCTAssertEqual(sent.results.last?["error"] as? String, "permission_required:reminders")
    }

    func testNotDeterminedAnswersAtOncePromptsThenSendsTheLateOkForTheSameId() async {
        let runs = Counter()
        let timer = FakeTool(name: "set_timer", permissionKind: "notifications", body: { _ in runs.bump(); return "Timer set for 10 minutes." })
        let (bridge, sent) = makeBridge([timer], connections: PhoneConnections(notifications: .unknown))
        let prompt = Gate()
        var prompts = 0
        bridge.permissionRequester = { kind in
            prompts += 1
            XCTAssertEqual(kind, "notifications")
            await prompt.wait()                      // the user is riding; he taps Allow later
            return true
        }
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)

        let t0 = Date()
        call(bridge, id: "n1", name: "phone.set_timer", args: ["seconds": 600], timeoutMs: 500)
        // 1. permission_required goes out at once — long before any 8-s / 500-ms timeout.
        await waitFor(sent, count: 2)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.4)
        let first = sent.results.first
        XCTAssertEqual(first?["id"] as? String, "n1")
        XCTAssertEqual(first?["ok"] as? Bool, false)
        XCTAssertEqual(first?["error"] as? String, "permission_required:notifications")
        XCTAssertEqual(first?["permissionState"] as? String, "notDetermined")
        XCTAssertEqual(runs.value, 0, "the tool does not run before the prompt resolves")
        XCTAssertEqual(prompts, 1)

        // 2. A second call of the same kind while the prompt is up: answered as the state, no
        //    second prompt, not `busy`.
        call(bridge, id: "n2", name: "phone.set_timer", args: ["seconds": 60])
        await waitFor(sent, count: 3)
        XCTAssertEqual(sent.results.last?["id"] as? String, "n2")
        XCTAssertEqual(sent.results.last?["error"] as? String, "permission_required:notifications")
        XCTAssertEqual(prompts, 1)

        // 3. No timeout fires while the prompt is up (the 500-ms budget has long passed).
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(sent.results.filter { ($0["error"] as? String) == "timeout" }.count, 0)
        XCTAssertEqual(sent.manifests.count, 1)

        // 4. He taps Allow: the manifest is re-sent with the new state, the ORIGINAL call re-runs,
        //    and its ok goes out as a LATE result for the SAME id.
        bridge.connectionsProvider = { PhoneConnections(notifications: .granted) }
        prompt.open()
        await waitFor(sent, count: 5)
        XCTAssertEqual(sent.manifests.count, 2)
        XCTAssertEqual((sent.manifests.last?["connections"] as? [String: String])?["notifications"], "granted")
        let late = sent.results.last
        XCTAssertEqual(late?["id"] as? String, "n1")
        XCTAssertEqual(late?["ok"] as? Bool, true)
        XCTAssertEqual(late?["result"] as? String, "Timer set for 10 minutes.")
        XCTAssertEqual(late?["permissionState"] as? String, "granted")
        XCTAssertEqual(runs.value, 1, "re-run exactly once")
        XCTAssertEqual(bridge.recentCalls.first?.late, true)
        XCTAssertEqual(bridge.recentCalls.first?.statusText, "ok (late)")

        // 5. Name free again; the next call pre-flights granted and runs straight away.
        call(bridge, id: "n3", name: "phone.set_timer", args: ["seconds": 60])
        await waitFor(sent, count: 6)
        XCTAssertEqual(sent.results.last?["id"] as? String, "n3")
        XCTAssertEqual(sent.results.last?["ok"] as? Bool, true)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(runs.value, 2)
    }

    func testNotDeterminedThenDeniedAtThePromptSendsNoLateResult() async {
        let runs = Counter()
        let cal = FakeTool(name: "calendar", permissionKind: "calendar", body: { _ in runs.bump(); return "x" })
        let (bridge, sent) = makeBridge([cal], connections: PhoneConnections(calendar: .unknown))
        bridge.permissionRequester = { _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return false
        }
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)
        call(bridge, id: "x1", name: "phone.calendar")
        await waitFor(sent, count: 2)
        XCTAssertEqual(sent.results.first?["error"] as? String, "permission_required:calendar")
        bridge.connectionsProvider = { PhoneConnections(calendar: .denied) }
        await waitFor(sent, count: 3)                 // the manifest after the prompt
        XCTAssertEqual(sent.manifests.count, 2)
        XCTAssertEqual((sent.manifests.last?["connections"] as? [String: String])?["calendar"], "denied")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sent.results.count, 1, "no late result after a denied prompt")
        XCTAssertEqual(runs.value, 0)
        // Name free again.
        call(bridge, id: "x2", name: "phone.calendar")
        await waitFor(sent, count: 4)
        XCTAssertEqual(sent.results.last?["id"] as? String, "x2")
        XCTAssertEqual(sent.results.last?["error"] as? String, "permission_required:calendar")
        XCTAssertEqual(sent.results.last?["permissionState"] as? String, "denied")
    }

    func testDisconnectDuringThePromptSendsNothingLater() async {
        let runs = Counter()
        let cal = FakeTool(name: "calendar", permissionKind: "calendar", body: { _ in runs.bump(); return "x" })
        let (bridge, sent) = makeBridge([cal], connections: PhoneConnections(calendar: .unknown))
        let prompt = Gate()
        bridge.permissionRequester = { _ in await prompt.wait(); return true }
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)
        call(bridge, id: "z1", name: "phone.calendar")
        await waitFor(sent, count: 2)
        bridge.sessionDidDisconnect()
        prompt.open()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sent.payloads.count, 2, "no manifest, no late result on a closed socket")
        XCTAssertEqual(runs.value, 0)
    }

    final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: - Disconnect cancels in flight

    func testDisconnectDropsInFlightWithoutAnswering() async {
        let slow = FakeTool(name: "slow", body: { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            return "late"
        })
        let (bridge, sent) = makeBridge([slow])
        bridge.sessionDidConnect()
        await waitFor(sent, count: 1)
        call(bridge, id: "tc_s", name: "phone.slow")
        bridge.sessionDidDisconnect()
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(sent.results.isEmpty, "a closed socket gets no late tool_result")
    }
}
