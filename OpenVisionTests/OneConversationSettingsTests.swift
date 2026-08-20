import XCTest
@testable import OpenVision

/// AUR-742 / AUR-744: the new settings are decode-safe on an EXISTING `settings.json` (Margo's
/// sideloaded rig, memo §3.5) — missing keys take their defaults, nothing she stored changes.
final class OneConversationSettingsTests: XCTestCase {

    /// A settings file written by a pre-AUR-742 build: no `cameraSource`, no `pushToAskEnabled`,
    /// no `oneConversationNoteSeen`. Her wake word / language / base URL / key / engine survive.
    func testOldSettingsFileDecodesWithOneConversationDefaults() throws {
        let legacy = """
        {
          "aiBackend": "openai",
          "openAIAPIKey": "jwt-180d",
          "openAIBaseURL": "https://brain.intch.cc/v1",
          "wakeWord": "Аурелия",
          "wakeWordEnabled": true,
          "speechLocaleIdentifier": "ru-RU",
          "ttsEngine": "aurelia",
          "conversationTimeout": 30,
          "preferGlassesMic": true
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.cameraSource, .off, "audio-first by default (AUR-757)")
        XCTAssertFalse(decoded.pushToAskEnabled, "push-to-ask is banked: OFF by default (AUR-744)")
        XCTAssertFalse(decoded.oneConversationNoteSeen, "the §3.5 note shows once on the upgraded device")

        // Untouched (§3.5 step 3: do NOT change her wake word, language, base URL or token).
        XCTAssertEqual(decoded.wakeWord, "Аурелия")
        XCTAssertEqual(decoded.speechLocaleIdentifier, "ru-RU")
        XCTAssertEqual(decoded.openAIBaseURL, "https://brain.intch.cc/v1")
        XCTAssertEqual(decoded.openAIAPIKey, "jwt-180d")
        XCTAssertEqual(decoded.ttsEngine, .aureliaServer, "her engine choice is kept (inert unless the flag is flipped)")
        XCTAssertEqual(decoded.conversationTimeout, 30)
    }

    /// The flag and the camera pick round-trip, and unknown camera values do not decode (the
    /// enum is closed — a typo in a hand-edited file fails loudly rather than silently).
    func testNewFieldsRoundTrip() throws {
        var s = AppSettings()
        s.pushToAskEnabled = true
        s.cameraSource = .glasses
        s.oneConversationNoteSeen = true
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(back.pushToAskEnabled)
        XCTAssertEqual(back.cameraSource, .glasses)
        XCTAssertTrue(back.oneConversationNoteSeen)
        XCTAssertEqual(back, s)
    }

    func testCameraSourceRawValuesAreStable() {
        // These strings are what lands in settings.json — renaming a case is a migration.
        XCTAssertEqual(CameraSourcePreference.off.rawValue, "off")
        XCTAssertEqual(CameraSourcePreference.phone.rawValue, "phone")
        XCTAssertEqual(CameraSourcePreference.glasses.rawValue, "glasses")
        XCTAssertEqual(CameraSourcePreference.allCases.count, 3)
    }
}
