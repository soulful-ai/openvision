import XCTest
@testable import OpenVision

/// AUR-794: the phone talking about itself — battery, Wi-Fi, thermal, storage, glasses battery.
/// The rule under test everywhere here: **absent, never faked**. A missing Wi-Fi name says WHY
/// (`location_permission` / `entitlement` / `not_wifi`), and the glasses battery — which the pinned
/// DAT 0.4.0 exposes no accessor for — comes back with its reason instead of a number.
@MainActor
final class PhoneStatusToolTests: XCTestCase {

    private func tool(_ s: PhoneStatusSnapshot) -> PhoneStatusTool {
        PhoneStatusTool(reader: { s })
    }

    // MARK: - The spoken line

    func testBatteryChargingAndSSID() async throws {
        var s = PhoneStatusSnapshot()
        s.batteryPercent = 72
        s.charging = .charging
        s.link = .wifi
        s.ssid = "Kabelnoord-5G"
        s.freeBytes = 24_300_000_000
        s.glassesBatteryMiss = "dat_0.4.0_no_public_accessor"
        let out = try await tool(s).execute(args: [:])
        XCTAssertTrue(out.contains("battery 72%, charging"), out)
        XCTAssertTrue(out.contains("Wi-Fi \"Kabelnoord-5G\""), out)
        XCTAssertTrue(out.contains("24 GB free"), out)
        XCTAssertTrue(out.contains("glasses battery unavailable (dat_0.4.0_no_public_accessor)"), out)
        // A nominal thermal state is not worth saying out loud.
        XCTAssertFalse(out.contains("thermal"), out)
    }

    func testCellularSaysExpensiveAndNeverInventsAnSSID() async throws {
        var s = PhoneStatusSnapshot()
        s.batteryPercent = 14
        s.charging = .unplugged
        s.link = .cellular
        s.expensive = true
        s.constrained = true
        s.ssidMiss = .notWifi
        let out = try await tool(s).execute(args: [:])
        XCTAssertTrue(out.contains("battery 14%, on battery"), out)
        XCTAssertTrue(out.contains("cellular"), out)
        XCTAssertTrue(out.contains("expensive link"), out)
        XCTAssertTrue(out.contains("low data mode"), out)
        XCTAssertFalse(out.contains("Wi-Fi"), out)
    }

    /// On Wi-Fi with no SSID the tool must name the fix, not stay silent and not guess.
    func testMissingSSIDNamesItsReason() async throws {
        for miss in [PhoneStatusSnapshot.SSIDMiss.locationPermission, .entitlement, .simulator] {
            var s = PhoneStatusSnapshot()
            s.link = .wifi
            s.ssidMiss = miss
            let out = try await tool(s).execute(args: [:])
            XCTAssertTrue(out.contains("network name unavailable: \(miss.rawValue)"), out)
        }
    }

    func testThermalAndUnknownBatteryAreToldPlainly() async throws {
        var s = PhoneStatusSnapshot()
        s.thermal = "serious"
        s.link = .offline
        let out = try await tool(s).execute(args: [:])
        XCTAssertTrue(out.contains("battery unknown"), out)
        XCTAssertTrue(out.contains("offline"), out)
        XCTAssertTrue(out.contains("thermal serious"), out)
    }

    func testGlassesBatteryIsSpokenWhenAFutureSDKSuppliesIt() async throws {
        var s = PhoneStatusSnapshot()
        s.batteryPercent = 50
        s.glassesBatteryPercent = 31
        let out = try await tool(s).execute(args: [:])
        XCTAssertTrue(out.contains("glasses battery 31%"), out)
    }

    func testStorageFormatting() {
        XCTAssertEqual(PhoneStatusSnapshot.gb(24_300_000_000), "24 GB")
        XCTAssertEqual(PhoneStatusSnapshot.gb(1_500_000_000), "1.5 GB")
    }

    // MARK: - The real reader (bounded, single-resume, honest on the simulator)

    func testPathReadAlwaysAnswersAndOnlyOnce() async {
        let p = await PhoneStatusReader.path()
        XCTAssertTrue([PhoneStatusSnapshot.Link.wifi, .cellular, .wired, .other, .offline].contains(p.link))
    }

    func testThermalAndFreeSpaceAreReadableHere() {
        XCTAssertTrue(["nominal", "fair", "serious", "critical"].contains(PhoneStatusReader.thermal()))
        XCTAssertNotNil(PhoneStatusReader.freeBytes())
    }

    /// The DAT SDK we are pinned to (0.4.0) publishes `DeviceState.batteryLevel` but no way to
    /// obtain a `DeviceState` — so the manager reports the absence with its reason.
    func testGlassesBatteryIsAbsentWithAReasonOnTheCurrentSDK() {
        let g = GlassesManager.shared.glassesBatteryPercent
        XCTAssertNil(g.percent)
        XCTAssertEqual(g.miss, "dat_0.4.0_no_public_accessor")
    }

    func testNonWifiLinkShortCircuitsTheSSIDRead() async {
        let (ssid, miss) = await PhoneStatusReader.ssid(link: .cellular)
        XCTAssertNil(ssid)
        XCTAssertEqual(miss, .notWifi)
    }

    // MARK: - Registry + wire

    func testRegisteredOnTheRealRegistryWithNoPermissionGate() {
        let bridge = ClientToolBridge(tools: NativeToolRegistry.shared.allTools,
                                      connectionsProvider: { PhoneConnections() },
                                      pendingClipboard: PendingClipboard(notifier: ClipboardToolTests.FakeNotifier(),
                                                                         appState: { .active }))
        XCTAssertTrue(bridge.toolNames.contains("phone.status"))
        // Battery must never be gated behind a location prompt.
        XCTAssertNil(bridge.permissionKind(for: "phone.status"))
        XCTAssertTrue(NativeToolRegistry.shared.isNativeTool("status"))
        let schema = PhoneStatusTool().parametersSchema
        XCTAssertTrue(JSONSerialization.isValidJSONObject(schema))
    }

    /// The Location state is on the wire the brain reads (AUR-794 adds the key).
    func testConnectionsWireCarriesLocation() {
        var c = PhoneConnections()
        c.location = .denied
        XCTAssertEqual(c.wire["location"], "denied")
        XCTAssertEqual(c.state(for: "location"), .denied)
        XCTAssertEqual(PhoneConnections().wire["location"], "unknown")
        XCTAssertTrue(PhoneConnections().rows.contains { $0.kind == "Location" })
    }
}
