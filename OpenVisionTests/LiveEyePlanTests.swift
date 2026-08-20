import XCTest
@testable import OpenVision

/// AUR-757: the eye is opt-in for glasses too — a call starts audio-only.
final class LiveEyePlanTests: XCTestCase {
    func testNothingRequestedIsOffEvenWithGlassesStreaming() {
        XCTAssertEqual(LiveEyePlan.decide(requested: false, glassesAvailable: true, glassesStreaming: true), .off)
        XCTAssertEqual(LiveEyePlan.decide(requested: false, glassesAvailable: true, glassesStreaming: false), .off)
        XCTAssertEqual(LiveEyePlan.decide(requested: false, glassesAvailable: false, glassesStreaming: false), .off)
    }

    func testRequestedPrefersGlassesAndStartsTheirStream() {
        XCTAssertEqual(LiveEyePlan.decide(requested: true, glassesAvailable: true, glassesStreaming: false),
                       .glasses(startStream: true))
        XCTAssertEqual(LiveEyePlan.decide(requested: true, glassesAvailable: true, glassesStreaming: true),
                       .glasses(startStream: false))
    }

    func testRequestedWithoutGlassesFallsBackToPhone() {
        XCTAssertEqual(LiveEyePlan.decide(requested: true, glassesAvailable: false, glassesStreaming: false), .phone)
        // A stray stream flag with no connected device still means the phone (startStreaming would refuse).
        XCTAssertEqual(LiveEyePlan.decide(requested: true, glassesAvailable: false, glassesStreaming: true), .phone)
    }

    /// AUR-742: the in-call pick "Phone" wins over paired glasses; "Off" still wins over everything.
    func testPreferPhoneOverridesGlassesOnlyWhenRequested() {
        XCTAssertEqual(LiveEyePlan.decide(requested: true, glassesAvailable: true, glassesStreaming: true, preferPhone: true), .phone)
        XCTAssertEqual(LiveEyePlan.decide(requested: true, glassesAvailable: true, glassesStreaming: false, preferPhone: true), .phone)
        XCTAssertEqual(LiveEyePlan.decide(requested: false, glassesAvailable: true, glassesStreaming: false, preferPhone: true), .off)
        // Default keeps the glasses-first rule.
        XCTAssertEqual(LiveEyePlan.decide(requested: true, glassesAvailable: true, glassesStreaming: false, preferPhone: false),
                       .glasses(startStream: true))
    }
}
