import Foundation

/// The pure half of the live-session eye decision (AUR-723b / AUR-742a / AUR-757).
///
/// The conversation starts AUDIO-ONLY. The eye — whichever eye — opens only on explicit intent
/// inside the session and is glasses-first: DAT glasses that are registered AND connected win,
/// the phone's rear camera serves otherwise. Dismissing the eye shuts whatever is running.
/// Kept free of AVFoundation/DAT so it compiles in a plain `swiftc` harness
/// (`OpenVisionTests/LiveEyePlanTests.swift` documents the cases; the XCTest bundle is blocked on
/// the simulator by the KokoroSwift codesign issue, so run
/// `swiftc -parse-as-library OpenVision/Views/VoiceAgent/LiveEyePlan.swift <harness main>`).
enum LiveEyePlan: Equatable {
    /// Shut everything: phone camera off, glasses stream off (LED off).
    case off
    /// Use the glasses; `startStream` says whether their stream still has to be brought up.
    case glasses(startStream: Bool)
    /// No glasses able to serve as the eye → the phone's rear camera.
    case phone

    /// - requested: the wearer asked for the eye («включи камеру» / "camera on" / the toggle).
    /// - glassesAvailable: registered AND a device is connected (`startStreaming()` needs both).
    /// - glassesStreaming: their camera stream is already running.
    static func decide(requested: Bool, glassesAvailable: Bool, glassesStreaming: Bool) -> LiveEyePlan {
        guard requested else { return .off }
        if glassesAvailable { return .glasses(startStream: !glassesStreaming) }
        return .phone
    }
}
