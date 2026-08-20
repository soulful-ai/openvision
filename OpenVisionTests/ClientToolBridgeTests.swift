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
        let bridge = ClientToolBridge(tools: tools, connectionsProvider: { connections })
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
