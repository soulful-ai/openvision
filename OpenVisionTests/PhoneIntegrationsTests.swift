import XCTest
@testable import OpenVision

/// AUR-795: Connections — one row per integration, and **the switch state is what the wire
/// carries**. These tests pin exactly that: the `connections` map has one key per row, a killed row
/// reports `off` AND its tools disappear from the advertised set, and a call for a killed tool is
/// answered `disabled:<row>` rather than the misleading `unknown_tool`.
@MainActor
final class PhoneIntegrationsTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "aurelia.tests.integrations.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> PhoneIntegrationStore { PhoneIntegrationStore(defaults: suite) }

    // MARK: - The map from rows to tools

    /// Every tool the registry ships belongs to exactly one Connections row — otherwise a tool
    /// would be un-killable (and invisible in the UI) the day it is added.
    func testEveryRegistryToolIsOwnedByExactlyOneRow() {
        for tool in NativeToolRegistry.shared.allTools {
            let owners = PhoneIntegration.allCases.filter { $0.toolNames.contains(tool.name) }
            XCTAssertEqual(owners.count, 1, "\(tool.name) is owned by \(owners.map(\.rawValue))")
        }
    }

    func testRowPermissionKindsMatchTheToolsTheyOwn() {
        for integration in PhoneIntegration.allCases {
            for name in integration.toolNames {
                guard let tool = NativeToolRegistry.shared.allTools.first(where: { $0.name == name }),
                      let kind = tool.permissionKind else { continue }
                XCTAssertEqual(integration.permissionKind, kind,
                               "\(integration.rawValue) owns \(name) which needs \(kind)")
            }
        }
    }

    // MARK: - The store (persisted, default-on)

    func testDefaultsToEverythingOnAndPersistsOffSwitches() {
        let s = store()
        XCTAssertTrue(PhoneIntegration.allCases.allSatisfy { s.isEnabled($0) })
        XCTAssertTrue(s.disabledWireNames.isEmpty)

        s.setEnabled(.notifications, false)
        XCTAssertFalse(s.isEnabled(.notifications))
        XCTAssertEqual(s.disabledToolNames, ["set_timer", "start_pomodoro"])
        XCTAssertEqual(s.disabledWireNames, ["phone.set_timer", "phone.start_pomodoro"])

        // Survives a relaunch (a new store over the same defaults).
        let reopened = PhoneIntegrationStore(defaults: suite)
        XCTAssertFalse(reopened.isEnabled(.notifications))
        XCTAssertTrue(reopened.isEnabled(.calendar))

        s.setEnabled(.notifications, true)
        XCTAssertTrue(PhoneIntegrationStore(defaults: suite).isEnabled(.notifications))
    }

    func testUnknownStoredRowsAreIgnored() {
        suite.set(["notifications", "myspace"], forKey: PhoneIntegrationStore.storageKey)
        let s = PhoneIntegrationStore(defaults: suite)
        XCTAssertEqual(s.disabled, ["notifications"])
    }

    // MARK: - The wire

    func testConnectionsMapHasOneKeyPerRowAndOffWins() {
        var c = PhoneConnections(calendar: .granted, reminders: .denied, notifications: .unknown)
        XCTAssertEqual(Set(c.wire.keys), Set(PhoneIntegration.allCases.map(\.rawValue)))
        XCTAssertEqual(c.wire["calendar"], "granted")
        XCTAssertEqual(c.wire["reminders"], "denied")
        XCTAssertEqual(c.wire["notifications"], "unknown")
        XCTAssertEqual(c.wire["spotify"], "unlinked")
        // A row that needs neither a permission nor an account is simply on.
        XCTAssertEqual(c.wire["device"], "on")
        XCTAssertEqual(c.wire["clipboard"], "on")

        // Killed beats everything — even a granted permission.
        c.disabled = ["calendar", "spotify", "device"]
        XCTAssertEqual(c.wire["calendar"], "off")
        XCTAssertEqual(c.wire["spotify"], "off")
        XCTAssertEqual(c.wire["device"], "off")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(c.wire))
    }

    func testRowsReadOutFollowsTheSameStates() {
        var c = PhoneConnections(calendar: .granted)
        c.disabled = ["notes"]
        let rows = Dictionary(uniqueKeysWithValues: c.rows.map { ($0.kind, $0.state) })
        XCTAssertEqual(rows["Calendar"], "granted")
        XCTAssertEqual(rows["Notes"], "off")
        XCTAssertEqual(c.rows.count, PhoneIntegration.allCases.count)
    }

    // MARK: - The bridge honours the kill switches

    private func makeBridge(disabled: Set<String>, connections: PhoneConnections = PhoneConnections())
    -> (ClientToolBridge, () -> [[String: Any]]) {
        var sent: [[String: Any]] = []
        let bridge = ClientToolBridge(tools: NativeToolRegistry.shared.allTools,
                                      connectionsProvider: { connections },
                                      pendingClipboard: PendingClipboard(notifier: ClipboardToolTests.FakeNotifier(),
                                                                         appState: { .active }))
        bridge.disabledToolsProvider = { disabled }
        bridge.send = { sent.append($0) }
        bridge.appStateProvider = { .active }
        return (bridge, { sent })
    }

    func testKilledRowDropsItsToolsFromTheAdvertisedSet() {
        let (all, _) = makeBridge(disabled: [])
        XCTAssertTrue(all.toolNames.contains("phone.set_timer"))
        XCTAssertTrue(all.toolNames.contains("phone.start_pomodoro"))

        let (killed, _) = makeBridge(disabled: ["phone.set_timer", "phone.start_pomodoro"])
        XCTAssertFalse(killed.toolNames.contains("phone.set_timer"))
        XCTAssertFalse(killed.toolNames.contains("phone.start_pomodoro"))
        XCTAssertTrue(killed.toolNames.contains("phone.calendar"))
        XCTAssertEqual(killed.toolNames.count, all.toolNames.count - 2)

        var conns = PhoneConnections()
        conns.disabled = ["notifications"]
        let manifest = killed.manifest(connections: conns)
        let names = (manifest["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertFalse(names.contains("phone.set_timer"))
        XCTAssertEqual((manifest["connections"] as? [String: String])?["notifications"], "off")
    }

    /// A call for a switched-off tool must not read as "I have no such tool" — the brain should be
    /// able to say «выключено в Connections».
    func testCallForAKilledToolIsAnsweredDisabledNotUnknown() async throws {
        let (bridge, sent) = makeBridge(disabled: ["phone.set_timer"])
        bridge.sessionDidConnect()
        bridge.handleToolCall(["type": "aurelia.tool_call", "id": "k1", "name": "phone.set_timer",
                               "args": ["seconds": 60]])
        let result = try XCTUnwrap(sent().first { ($0["type"] as? String) == "aurelia.tool_result" })
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "disabled:notifications")
        XCTAssertEqual(bridge.recentCalls.first?.error, "disabled:notifications")

        // A name that never existed still says unknown_tool.
        bridge.handleToolCall(["type": "aurelia.tool_call", "id": "k2", "name": "phone.nope", "args": [:]])
        let unknown = try XCTUnwrap(sent().last)
        XCTAssertEqual(unknown["error"] as? String, "unknown_tool")
    }

    /// Flipping a switch mid-call re-advertises at once — the brain must not keep the old list.
    func testSwitchFlipReAdvertisesDuringALiveSession() async {
        var conns = PhoneConnections(calendar: .granted, reminders: .granted, notifications: .granted)
        var sent: [[String: Any]] = []
        let bridge = ClientToolBridge(tools: NativeToolRegistry.shared.allTools,
                                      connectionsProvider: { conns },
                                      pendingClipboard: PendingClipboard(notifier: ClipboardToolTests.FakeNotifier(),
                                                                         appState: { .active }))
        bridge.disabledToolsProvider = { [] }
        bridge.send = { sent.append($0) }
        bridge.sessionDidConnect()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let first = sent.filter { ($0["type"] as? String) == "aurelia.client_tools" }.count
        XCTAssertEqual(first, 1)

        conns.disabled = ["clipboard"]
        NotificationCenter.default.post(name: PhoneIntegrationStore.didChange, object: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)

        let manifests = sent.filter { ($0["type"] as? String) == "aurelia.client_tools" }
        XCTAssertEqual(manifests.count, 2, "a flipped switch must re-send the manifest")
        XCTAssertEqual((manifests.last?["connections"] as? [String: String])?["clipboard"], "off")

        bridge.sessionDidDisconnect()
    }
}
