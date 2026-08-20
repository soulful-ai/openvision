// OpenVision - ListenBackupUploader.swift
// AUR-823: backup audio → server re-transcription.
//
// LISTEN mode (AUR-776) streams the mic to the server AND writes a local safety copy,
// Documents/Captures/listen-YYYYMMDD-HHmmss.m4a (LOCAL time in the name). When the live
// transcript comes out thin (2026-08-20: a 17-min English meeting → 16 words, server STT pinned
// to ru-RU), the phone still has the audio. This file is the client half of the repair rail:
//
//   POST <openAIBaseURL>/voice/recordings/{stem}/audio?startedAt=<ISO8601 UTC>&durationMs=<n>
//   Authorization: Bearer <the same JWT the app uses for /v1/realtime>   Content-Type: audio/mp4
//   body = the raw m4a bytes (≤ 64 MB)
//   → {ok:true, words, segments, speakers, durationMs} | {ok:false, error}
//
// {stem} = the server's recording file stem = the UTC start time formatted `yyyy-MM-dd-HHmm`
// + "-recording" (local 13:34:53 CEST → 2026-08-20-1134-recording). The server re-transcribes
// with Deepgram prerecorded (multilingual + diarization), rebuilds transcript + summary and
// pushes the result to the user's Telegram — the client only has to get the bytes there.
//
// Pieces:
//   ListenBackupStem      pure helpers: stem(for:), legacy filename → startedAt, the request.
//   ListenCapture(+Index) Documents/Captures/index.json — one row per backup (file, startedAt,
//                         durationMs, stem, uploaded, result) so files that predate the index
//                         (today's listen-20260820-133453.m4a) are reconciled from the filename
//                         (local → UTC via TimeZone.current) + AVURLAsset duration and can be
//                         uploaded after the fact from Settings → Debug → Listen backups.
//   ListenBackupUploader  background URLSession (`app.soulless.openvision.listen-upload`, survives
//                         app backgrounding), 3 attempts with backoff, one upload per capture,
//                         logs `📤 listen backup upload <stem> <bytes> → ok/err`.
//
// Auto-upload policy (deterministic, AUR-823 §2): every finished backup ≥ 60 s is uploaded ONCE
// when `AppSettings.listenBackupUpload` is on; the server decides whether to keep the live
// transcript or the re-transcription.

import AVFoundation
import Foundation

// MARK: - Stem + request helpers (pure, tested)

enum ListenBackupStem {
    static let suffix = "-recording"
    /// Wire cap (server rejects above this).
    static let maxUploadBytes = 64 * 1024 * 1024

    /// The server's recording file stem for a recording that started at `startedAt`:
    /// UTC `yyyy-MM-dd-HHmm` + "-recording". Minute resolution, always UTC.
    static func stem(for startedAt: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: startedAt) + suffix
    }

    /// Parse the LOCAL-time stamp out of a legacy backup name (`listen-20260820-133453.m4a`,
    /// written by VoiceActionService.stamp() in the phone's zone) into an absolute instant.
    /// `timeZone` = the zone the phone was in when the file was written (default: now).
    static func startedAt(fromFilename name: String, timeZone: TimeZone = .current) -> Date? {
        var base = (name as NSString).lastPathComponent
        if base.hasSuffix(".m4a") { base = String(base.dropLast(4)) }
        guard base.hasPrefix("listen-") else { return nil }
        let stamp = String(base.dropFirst("listen-".count))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: stamp)
    }

    /// `2026-08-20T11:34:53Z` — second resolution, UTC, the form the server parses.
    static func iso8601UTC(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// `<base>/voice/recordings/<stem>/audio?startedAt=…&durationMs=…` — `base` is the app's
    /// OpenAI-backend base URL (`https://brain.intch.cc/v1`), trailing slash tolerated.
    static func endpoint(baseURL: String, stem: String, startedAt: Date, durationMs: Int) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty, var comps = URLComponents(string: base + "/voice/recordings/\(stem)/audio") else {
            return nil
        }
        comps.queryItems = [
            URLQueryItem(name: "startedAt", value: iso8601UTC(startedAt)),
            URLQueryItem(name: "durationMs", value: String(durationMs))
        ]
        return comps.url
    }

    /// The upload request (headers + URL; the body rides as the file in a background upload task).
    static func request(baseURL: String, token: String, capture: ListenCapture) -> URLRequest? {
        guard let url = endpoint(baseURL: baseURL, stem: capture.stem,
                                 startedAt: capture.startedAt, durationMs: capture.durationMs) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        return req
    }

    /// Human line for the Debug list + the log from the server's JSON (`{ok, words, speakers,…}`).
    static func describe(response json: [String: Any]) -> (ok: Bool, text: String) {
        if (json["ok"] as? Bool) == true {
            var parts: [String] = []
            if let w = json["words"] as? Int { parts.append("\(w) words") }
            if let s = json["speakers"] as? Int { parts.append("\(s) speaker\(s == 1 ? "" : "s")") }
            if let seg = json["segments"] as? Int { parts.append("\(seg) segments") }
            return (true, parts.isEmpty ? "ok" : parts.joined(separator: ", "))
        }
        let err = (json["error"] as? String) ?? "server said ok:false"
        return (false, "error: \(err)")
    }
}

// MARK: - Index model

/// One listen backup on disk and what happened to it.
struct ListenCapture: Codable, Equatable, Identifiable {
    /// File name inside Documents/Captures (the index lives next to it; paths move between
    /// app containers, names do not).
    var file: String
    /// The absolute start instant (encoded ISO8601 UTC in index.json).
    var startedAt: Date
    var durationMs: Int
    var stem: String
    var uploaded: Bool = false
    /// "1234 words, 2 speakers" after a good upload, "error: …" after a failed one, nil = never tried.
    var result: String? = nil
    var uploadedAt: Date? = nil

    var id: String { file }

    init(file: String, startedAt: Date, durationMs: Int, stem: String? = nil,
         uploaded: Bool = false, result: String? = nil, uploadedAt: Date? = nil) {
        self.file = file
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.stem = stem ?? ListenBackupStem.stem(for: startedAt)
        self.uploaded = uploaded
        self.result = result
        self.uploadedAt = uploadedAt
    }
}

/// `Documents/Captures/index.json` — `{ "captures": [ … ] }`, dates as ISO8601.
struct ListenCaptureIndex: Codable, Equatable {
    var captures: [ListenCapture] = []

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func load(from url: URL) -> ListenCaptureIndex {
        guard let data = try? Data(contentsOf: url),
              let idx = try? decoder().decode(ListenCaptureIndex.self, from: data) else {
            return ListenCaptureIndex()
        }
        return idx
    }

    func save(to url: URL) throws {
        let data = try Self.encoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Uploader

@MainActor
final class ListenBackupUploader: NSObject, ObservableObject {
    static let shared = ListenBackupUploader()

    static let sessionIdentifier = "app.soulless.openvision.listen-upload"
    /// Auto-upload floor: anything shorter is a false start / a test tap, not a meeting.
    static let autoUploadMinMs = 60_000
    static let maxAttempts = 3
    /// Seconds before attempt 2 and 3.
    static let backoff: [TimeInterval] = [5, 20]

    @Published private(set) var captures: [ListenCapture] = []
    /// Stems with an upload task in flight (the Debug list shows a spinner).
    @Published private(set) var inFlight: Set<String> = []
    @Published private(set) var lastError: String?

    private let capturesDir: URL
    private let indexURL: URL
    private var attempts: [String: Int] = [:]
    private var reloaded = false

    /// Delegate callbacks arrive on the session's own serial queue — the bodies are collected
    /// there and handed to the main actor once per task.
    private let responseBodies = ResponseBodies()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(capturesDirectory: URL = VoiceActionService.capturesDirectory()) {
        capturesDir = capturesDirectory
        indexURL = capturesDirectory.appendingPathComponent("index.json")
        super.init()
        captures = ListenCaptureIndex.load(from: indexURL).captures.sorted { $0.startedAt > $1.startedAt }
    }

    var pending: [ListenCapture] { captures.filter { !$0.uploaded } }

    /// Call once at launch: re-creates the background session so an upload that finished while
    /// the app was suspended/relaunched still reports into the index (its stem rides in
    /// `taskDescription`); also marks those tasks in flight so the Debug list shows them.
    func reattachBackgroundSession() {
        session.getAllTasks { [weak self] tasks in
            let stems = tasks.compactMap(\.taskDescription).filter { !$0.isEmpty }
            guard !stems.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for s in stems { self.inFlight.insert(s); self.attempts[s] = self.attempts[s] ?? Self.maxAttempts }
                ovLog("[ListenBackup] reattached \(stems.count) in-flight upload(s): \(stems.joined(separator: ", "))")
            }
        }
    }

    // MARK: Index maintenance

    /// Re-read the index and reconcile with the directory: legacy `listen-*.m4a` files that
    /// predate the index get a row (startedAt from the filename, duration from the asset);
    /// rows whose file is gone are dropped. Cheap enough to run on every Debug screen open.
    func reload() async {
        var index = ListenCaptureIndex.load(from: indexURL)
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: capturesDir.path)) ?? [])
            .filter { $0.hasPrefix("listen-") && $0.hasSuffix(".m4a") }
        let known = Set(index.captures.map(\.file))
        for name in names where !known.contains(name) {
            guard let startedAt = ListenBackupStem.startedAt(fromFilename: name) else { continue }
            let url = capturesDir.appendingPathComponent(name)
            let durationMs = await Self.durationMs(of: url)
            index.captures.append(ListenCapture(file: name, startedAt: startedAt, durationMs: durationMs))
            ovLog("[ListenBackup] indexed legacy backup \(name) → \(ListenBackupStem.stem(for: startedAt)) \(durationMs) ms")
        }
        let present = Set(names)
        index.captures.removeAll { !present.contains($0.file) }
        index.captures.sort { $0.startedAt > $1.startedAt }
        captures = index.captures
        persist()
        reloaded = true
    }

    /// A backup just finished (audio.stop / session end): record it, then auto-upload when the
    /// policy says so. `startedAt` is the instant the audio.start ran on the phone.
    @discardableResult
    func register(fileURL: URL, startedAt: Date, durationMs: Int) -> ListenCapture {
        let name = fileURL.lastPathComponent
        var capture = ListenCapture(file: name, startedAt: startedAt, durationMs: durationMs)
        if let i = captures.firstIndex(where: { $0.file == name }) {
            capture.uploaded = captures[i].uploaded
            capture.result = captures[i].result
            capture.uploadedAt = captures[i].uploadedAt
            captures[i] = capture
        } else {
            captures.insert(capture, at: 0)
        }
        persist()
        return capture
    }

    /// Record + the AUR-823 auto-upload rule: ≥ 60 s, setting on, not uploaded yet → upload once.
    func registerAndAutoUpload(fileURL: URL, startedAt: Date, durationMs: Int) {
        let capture = register(fileURL: fileURL, startedAt: startedAt, durationMs: durationMs)
        let enabled = SettingsManager.shared.settings.listenBackupUpload
        guard enabled, durationMs >= Self.autoUploadMinMs else {
            ovLog("[ListenBackup] \(capture.stem) kept local only (\(durationMs) ms, auto-upload \(enabled ? "on" : "off"))")
            return
        }
        upload(capture)
    }

    // MARK: Upload

    func uploadAllPending() {
        for c in pending where !inFlight.contains(c.stem) { upload(c) }
    }

    /// One upload per capture: skipped while in flight; a row already uploaded is re-sent only
    /// when the user taps it again (the server then overwrites — harmless).
    func upload(_ capture: ListenCapture, attempt: Int = 1) {
        guard !inFlight.contains(capture.stem) else { return }
        let fileURL = capturesDir.appendingPathComponent(capture.file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard bytes > 0 else {
            finish(stem: capture.stem, ok: false, text: "error: file missing or empty", retryable: false)
            return
        }
        guard bytes <= ListenBackupStem.maxUploadBytes else {
            finish(stem: capture.stem, ok: false, text: "error: \(bytes) bytes > 64 MB cap", retryable: false)
            return
        }
        let settings = SettingsManager.shared.settings
        guard !settings.openAIAPIKey.isEmpty,
              let request = ListenBackupStem.request(baseURL: settings.openAIBaseURL,
                                                     token: settings.openAIAPIKey, capture: capture) else {
            finish(stem: capture.stem, ok: false, text: "error: backend URL / token not configured", retryable: false)
            return
        }
        attempts[capture.stem] = attempt
        inFlight.insert(capture.stem)
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = capture.stem
        task.resume()
        ovLog("📤 listen backup upload \(capture.stem) \(bytes) bytes → started (attempt \(attempt)/\(Self.maxAttempts)) \(request.url?.absoluteString ?? "")")
    }

    private func finish(stem: String, ok: Bool, text: String, retryable: Bool) {
        inFlight.remove(stem)
        let attempt = attempts[stem] ?? 1
        if !ok, retryable, attempt < Self.maxAttempts,
           let capture = captures.first(where: { $0.stem == stem }) {
            let delay = Self.backoff[min(attempt - 1, Self.backoff.count - 1)]
            ovLog("📤 listen backup upload \(stem) → err (\(text)), retry in \(Int(delay)) s")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self?.upload(capture, attempt: attempt + 1)
            }
            return
        }
        if let i = captures.firstIndex(where: { $0.stem == stem }) {
            captures[i].result = text
            if ok {
                captures[i].uploaded = true
                captures[i].uploadedAt = Date()
            }
        }
        lastError = ok ? nil : text
        attempts[stem] = nil
        persist()
        ovLog("📤 listen backup upload \(stem) → \(ok ? "ok" : "err") (\(text))")
    }

    private func persist() {
        do {
            try ListenCaptureIndex(captures: captures).save(to: indexURL)
        } catch {
            ovLog("[ListenBackup] index save failed: \(error)")
        }
    }

    /// Duration of an existing m4a (legacy files without an index row).
    static func durationMs(of url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration), d.isNumeric else { return 0 }
        return Int((CMTimeGetSeconds(d) * 1000).rounded())
    }

    /// Result plumbing from the session queue → main actor.
    fileprivate func taskCompleted(stem: String, status: Int?, body: Data?, error: Error?) {
        if let error {
            finish(stem: stem, ok: false, text: "error: \(error.localizedDescription)", retryable: true)
            return
        }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        if let json {
            let d = ListenBackupStem.describe(response: json)
            // A server-side refusal (4xx / ok:false) is final; a 5xx ok:false gets the retries.
            let retryable = (status ?? 500) >= 500
            finish(stem: stem, ok: d.ok, text: d.text, retryable: !d.ok && retryable)
            return
        }
        let code = status ?? 0
        finish(stem: stem, ok: false, text: "error: HTTP \(code), no JSON", retryable: code == 0 || code >= 500)
    }
}

// MARK: - URLSession delegate (session queue → main actor)

/// Per-task response body, collected on the session's delegate queue.
private final class ResponseBodies: @unchecked Sendable {
    private var bodies: [Int: Data] = [:]
    private let lock = NSLock()
    func append(_ data: Data, for task: Int) {
        lock.lock(); defer { lock.unlock() }
        bodies[task, default: Data()].append(data)
    }
    func take(_ task: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return bodies.removeValue(forKey: task)
    }
}

extension ListenBackupUploader: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBodies.append(data, for: dataTask.taskIdentifier)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let stem = task.taskDescription ?? ""
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let body = responseBodies.take(task.taskIdentifier)
        guard !stem.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.taskCompleted(stem: stem, status: status, body: body, error: error)
        }
    }
}
