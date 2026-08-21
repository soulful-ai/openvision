import XCTest
@testable import OpenVision

/// AUR-803b: the `session.update.metadata` dict carries the phone's time zone so the brain's
/// session clock follows the wearer (metadata → `?tz=` → profile → Europe/Amsterdam). Pure
/// builder, no socket.
/// AUR-845: the same dict now carries `appState`, re-declared on every foreground change — the
/// brain must know the phone is in the wearer's pocket to read a `deferred` clipboard result.
final class SessionMetadataTests: XCTestCase {

    func testMetadataCarriesIdentityRouteAecTimeZoneAndAppState() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "America/Montevideo"))   // UTC-3, no DST
        let md = OpenAIRealtimeService.clientMetadata(route: "a2dp+phone-mic", aec: true, timeZone: tz,
                                                      appState: .active)

        XCTAssertEqual(md["client"] as? String, "openvision")
        XCTAssertEqual(md["proto"] as? String, "aurelia.v2")
        XCTAssertEqual(md["route"] as? String, "a2dp+phone-mic")
        XCTAssertEqual(md["aec"] as? Bool, true)
        XCTAssertEqual(md["tz"] as? String, "America/Montevideo")
        XCTAssertEqual(md["utcOffsetMin"] as? Int, -180)
        XCTAssertEqual(md["appState"] as? String, "active")
        XCTAssertEqual(md.count, 7, "exactly the seven keys the brain reads — no accidental extras")

        // DST-aware: the offset is the CURRENT one for that zone, east of UTC in minutes.
        let ams = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        let amsMd = OpenAIRealtimeService.clientMetadata(route: "unknown", aec: false, timeZone: ams,
                                                         appState: .background)
        XCTAssertEqual(amsMd["tz"] as? String, "Europe/Amsterdam")
        XCTAssertEqual(amsMd["utcOffsetMin"] as? Int, ams.secondsFromGMT() / 60)
        XCTAssertTrue([60, 120].contains(amsMd["utcOffsetMin"] as? Int ?? 0))
        XCTAssertEqual(amsMd["appState"] as? String, "background")
        // And it serialises — the dict goes straight into the JSON wire frame.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(amsMd))
    }

    /// The three states the wire can carry — the raw values the brain switches on.
    func testAppStateWireValues() {
        XCTAssertEqual(AppForegroundState.active.rawValue, "active")
        XCTAssertEqual(AppForegroundState.inactive.rawValue, "inactive")
        XCTAssertEqual(AppForegroundState.background.rawValue, "background")
        for state in [AppForegroundState.active, .inactive, .background] {
            let md = OpenAIRealtimeService.clientMetadata(route: "r", aec: false, appState: state)
            XCTAssertEqual(md["appState"] as? String, state.rawValue)
        }
    }
}
