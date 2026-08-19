import XCTest
@testable import OpenVision

/// AUR-776: the `aurelia.action` wire model — parsing, the three camera modes, the ack shape.
final class VoiceActionTests: XCTestCase {
    func testParsesEveryActionAndMode() {
        let a = VoiceAction(json: ["type": "aurelia.action", "id": "1", "action": "photo", "mode": NSNull()])
        XCTAssertEqual(a, VoiceAction(id: "1", kind: .photo, mode: nil))

        let v = VoiceAction(json: ["id": "2", "action": "video.start", "mode": "assist"])
        XCTAssertEqual(v?.kind, .videoStart)
        XCTAssertEqual(v?.effectiveMode, .assist)

        let s = VoiceAction(json: ["id": "3", "action": "video.start", "mode": "silent"])
        XCTAssertEqual(s?.effectiveMode, .silent)

        XCTAssertEqual(VoiceAction(json: ["id": "4", "action": "audio.start"])?.kind, .audioStart)
        XCTAssertEqual(VoiceAction(json: ["id": "5", "action": "audio.stop"])?.kind, .audioStop)
        XCTAssertEqual(VoiceAction(json: ["id": "6", "action": "video.stop"])?.kind, .videoStop)
        XCTAssertEqual(VoiceAction(json: ["id": "e1", "action": "eye.on"])?.kind, .eyeOn)
        XCTAssertEqual(VoiceAction(json: ["id": "e2", "action": "eye.off"])?.kind, .eyeOff)
    }

    func testVideoStartDefaultsToSilentAndAssistAliasIsAccepted() {
        // No mode → a recording, not a conversation (Meta's "record a video").
        XCTAssertEqual(VoiceAction(json: ["id": "7", "action": "video.start"])?.effectiveMode, .silent)
        // The early draft's "video.start_assist" still means video.start / assist.
        let alias = VoiceAction(json: ["id": "8", "action": "video.start_assist"])
        XCTAssertEqual(alias?.kind, .videoStart)
        XCTAssertEqual(alias?.mode, .assist)
        // An explicit mode wins over the alias' implied one.
        XCTAssertEqual(VoiceAction(json: ["id": "9", "action": "video.start_assist", "mode": "silent"])?.mode, .silent)
    }

    func testUnknownActionIsRejected() {
        XCTAssertNil(VoiceAction(json: ["id": "x", "action": "teleport"]))
        XCTAssertNil(VoiceAction(json: ["id": "x"]))
    }

    func testAckJSONShape() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let ack = VoiceActionAck(id: "abc", action: "photo", ok: true, detail: "glasses frame",
                                 artifact: VoiceActionArtifact(kind: .photo, uri: url, durationMs: nil))
        let json = ack.json
        XCTAssertEqual(json["type"] as? String, "aurelia.action.ack")
        XCTAssertEqual(json["id"] as? String, "abc")
        XCTAssertEqual(json["action"] as? String, "photo")
        XCTAssertEqual(json["ok"] as? Bool, true)
        let artifact = json["artifact"] as? [String: Any]
        XCTAssertEqual(artifact?["kind"] as? String, "photo")
        XCTAssertEqual(artifact?["uri"] as? String, url.absoluteString)
        XCTAssertTrue(artifact?["durationMs"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))

        let nack = VoiceActionAck(id: "z", action: "video.stop", ok: false, detail: "no video recording running", artifact: nil)
        XCTAssertTrue(nack.json["artifact"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(nack.json))
    }

    func testEarconPerAction() {
        XCTAssertEqual(VoiceActionKind.photo.earcon.label, "photo")
        XCTAssertEqual(VoiceActionKind.videoStart.earcon.label, "video.start")
        XCTAssertEqual(VoiceActionKind.videoStop.earcon.label, "video.stop")
        XCTAssertEqual(VoiceActionKind.audioStart.earcon.label, "audio.start")
        XCTAssertEqual(VoiceActionKind.audioStop.earcon.label, "audio.stop")
        // Every cue is short (≤ 300 ms).
        XCTAssertEqual(VoiceActionKind.eyeOn.earcon.label, "eye.on")
        XCTAssertEqual(VoiceActionKind.eyeOff.earcon.label, "eye.off")
        for cue: CallEarconService.Cue in [.photo, .videoStart, .videoStop, .audioStart, .audioStop, .eyeOn, .eyeOff] {
            XCTAssertLessThanOrEqual(cue.notes.reduce(0) { $0 + $1.seconds }, 0.3, cue.label)
        }
    }

    func testPhraseHelpListsTheCanonicalTen() {
        XCTAssertEqual(VoicePhraseHelpSheet.phrases.count, 10)
        XCTAssertEqual(VoicePhraseHelpSheet.phrases.map(\.ru),
                       ["Сделай фото", "Запиши видео", "Снимай и смотри", "Стоп видео", "Смотри",
                        "Не смотри", "Слушай", "Стоп запись", "Стоп", "Пока"])
    }

    func testRecordingBadgeClock() {
        XCTAssertEqual(RecordingBadge.clock(0), "00:00")
        XCTAssertEqual(RecordingBadge.clock(72), "01:12")
        XCTAssertEqual(RecordingBadge.clock(3725), "1:02:05")
    }
}
