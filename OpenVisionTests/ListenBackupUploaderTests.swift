import XCTest
@testable import OpenVision

/// AUR-823: the stem the server keys recordings by (UTC minute), the legacy filename → startedAt
/// parse (local zone), the request the app sends, and the Captures index round-trip. Pure — no
/// network, no device.
final class ListenBackupUploaderTests: XCTestCase {

    /// Today's file: listen-20260820-133453.m4a, written at 13:34:53 CEST → 11:34:53Z →
    /// stem 2026-08-20-1134-recording (the ticket's worked example).
    func testStemIsUTCMinuteFromLocalStart() throws {
        let ams = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        let started = try XCTUnwrap(ListenBackupStem.startedAt(fromFilename: "listen-20260820-133453.m4a", timeZone: ams))
        XCTAssertEqual(ListenBackupStem.iso8601UTC(started), "2026-08-20T11:34:53Z")
        XCTAssertEqual(ListenBackupStem.stem(for: started), "2026-08-20-1134-recording")

        // A different zone, same wall-clock name → a different instant and stem (UTC-3, no DST).
        let mvd = try XCTUnwrap(TimeZone(identifier: "America/Montevideo"))
        let startedMVD = try XCTUnwrap(ListenBackupStem.startedAt(fromFilename: "listen-20260820-133453.m4a", timeZone: mvd))
        XCTAssertEqual(ListenBackupStem.iso8601UTC(startedMVD), "2026-08-20T16:34:53Z")
        XCTAssertEqual(ListenBackupStem.stem(for: startedMVD), "2026-08-20-1634-recording")

        // Day rollover across the UTC boundary: 00:20 CEST on the 21st is still the 20th in UTC.
        let late = try XCTUnwrap(ListenBackupStem.startedAt(fromFilename: "listen-20260821-002010.m4a", timeZone: ams))
        XCTAssertEqual(ListenBackupStem.stem(for: late), "2026-08-20-2220-recording")
    }

    func testLegacyFilenameParsing() {
        let utc = TimeZone(identifier: "UTC")!
        // Full path or bare name, with or without the extension.
        let a = ListenBackupStem.startedAt(fromFilename: "/var/mobile/Documents/Captures/listen-20260820-133453.m4a", timeZone: utc)
        let b = ListenBackupStem.startedAt(fromFilename: "listen-20260820-133453", timeZone: utc)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.map(ListenBackupStem.iso8601UTC), "2026-08-20T13:34:53Z")
        // Not a listen backup / malformed stamp → nil, never a guess.
        XCTAssertNil(ListenBackupStem.startedAt(fromFilename: "photo-20260820-133453.jpg", timeZone: utc))
        XCTAssertNil(ListenBackupStem.startedAt(fromFilename: "listen-2026-08-20.m4a", timeZone: utc))
        XCTAssertNil(ListenBackupStem.startedAt(fromFilename: "index.json", timeZone: utc))
    }

    /// The exact request: POST <base>/voice/recordings/<stem>/audio?startedAt=…&durationMs=…,
    /// Bearer = the realtime JWT, Content-Type audio/mp4. Trailing slash on the base tolerated.
    func testUploadRequestShape() throws {
        let started = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T11:34:53Z"))
        let capture = ListenCapture(file: "listen-20260820-133453.m4a", startedAt: started, durationMs: 1_039_828)
        XCTAssertEqual(capture.stem, "2026-08-20-1134-recording")

        let req = try XCTUnwrap(ListenBackupStem.request(baseURL: "https://brain.intch.cc/v1/", token: "jwt.abc.def", capture: capture))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://brain.intch.cc/v1/voice/recordings/2026-08-20-1134-recording/audio?startedAt=2026-08-20T11:34:53Z&durationMs=1039828")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer jwt.abc.def")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        XCTAssertNil(req.httpBody, "the body rides as the file in the background upload task")

        XCTAssertNil(ListenBackupStem.request(baseURL: "   ", token: "x", capture: capture))
    }

    func testServerResponseDescription() {
        let ok = ListenBackupStem.describe(response: ["ok": true, "words": 2840, "segments": 212, "speakers": 3, "durationMs": 1039828])
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.text, "2840 words, 3 speakers, 212 segments")
        let bad = ListenBackupStem.describe(response: ["ok": false, "error": "recording not found"])
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.text, "error: recording not found")
    }

    /// index.json survives a write → read with dates intact (ISO8601) and the uploaded/result fields.
    func testIndexRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aur823-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.json")

        let started = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T11:34:53Z"))
        var done = ListenCapture(file: "listen-20260820-133453.m4a", startedAt: started, durationMs: 1_039_828)
        done.uploaded = true
        done.result = "2840 words, 3 speakers"
        done.uploadedAt = started.addingTimeInterval(1200)
        let pending = ListenCapture(file: "listen-20260820-150001.m4a", startedAt: started.addingTimeInterval(5108), durationMs: 42_000)
        let index = ListenCaptureIndex(captures: [done, pending])

        try index.save(to: url)
        let back = ListenCaptureIndex.load(from: url)
        XCTAssertEqual(back, index)
        XCTAssertEqual(back.captures[0].stem, "2026-08-20-1134-recording")
        XCTAssertEqual(back.captures[1].stem, "2026-08-20-1300-recording")   // 11:34:53Z + 85 min 8 s
        XCTAssertFalse(back.captures[1].uploaded)
        XCTAssertNil(back.captures[1].result)

        // The on-disk form is readable by a human / the server agent: ISO dates, sorted keys.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"startedAt\" : \"2026-08-20T11:34:53Z\""), text)
        XCTAssertTrue(text.contains("\"stem\" : \"2026-08-20-1134-recording\""))

        // Missing / garbage file → empty index, never a crash.
        XCTAssertEqual(ListenCaptureIndex.load(from: dir.appendingPathComponent("nope.json")).captures.count, 0)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ListenCaptureIndex.load(from: url).captures.count, 0)
    }

    /// A fresh uploader over an empty dir + a legacy file: reload() indexes it from the filename.
    @MainActor
    func testReloadIndexesLegacyFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aur823-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Not a real m4a (duration resolves to 0) — the row still appears, keyed by the filename.
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("listen-20260820-133453.m4a"))
        try Data([0]).write(to: dir.appendingPathComponent("photo-20260820-133453.jpg"))

        let uploader = ListenBackupUploader(capturesDirectory: dir)
        XCTAssertTrue(uploader.captures.isEmpty)
        await uploader.reload()
        XCTAssertEqual(uploader.captures.count, 1)
        let row = try XCTUnwrap(uploader.captures.first)
        XCTAssertEqual(row.file, "listen-20260820-133453.m4a")
        XCTAssertEqual(row.stem, ListenBackupStem.stem(for: ListenBackupStem.startedAt(fromFilename: row.file)!))
        XCTAssertFalse(row.uploaded)
        // …and it was persisted.
        XCTAssertEqual(ListenCaptureIndex.load(from: dir.appendingPathComponent("index.json")).captures, uploader.captures)

        // register() on a known file keeps its upload state, refreshes timing.
        let again = uploader.register(fileURL: dir.appendingPathComponent(row.file), startedAt: row.startedAt, durationMs: 1_039_828)
        XCTAssertEqual(again.durationMs, 1_039_828)
        XCTAssertEqual(uploader.captures.count, 1)
    }
}
