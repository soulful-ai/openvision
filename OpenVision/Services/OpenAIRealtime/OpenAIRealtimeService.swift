// OpenVision - OpenAIRealtimeService.swift
// Full-duplex WebSocket client for the Aurelia realtime brain (OpenAI Realtime wire) — AUR-723.
//
// Before AUR-723 this client was HALF duplex: `sendAudio`/`sendVideoFrame` dropped everything
// while `isModelSpeaking` (set on the first audio delta, cleared on `response.done`), so the
// server's `interrupt_response` was unreachable mid-reply — "the app can never barge in over the
// mic" (plan fault B1) — and `input_audio_buffer.speech_started` only flipped flags while seconds
// of already-buffered speech kept coming out of the ear (fault B2).
//
// The mic now streams for the whole session and the client is a pure audio I/O device around the
// brain's turn-taking (AUR-724 server side):
//
//   server → client                                  client reaction
//   ─────────────────────────────────────────────    ─────────────────────────────────────────
//   input_audio_buffer.speech_started (onset)        pause playback NOW, keep the buffer
//   output_audio_buffer.cleared        (confirmed)   flush the buffer + send conversation.item.truncate
//   response.done {status:"cancelled"}               same (idempotent with the above)
//   aurelia.playback.resume            (false alarm) resume from where we paused
//   aurelia.server.draining {resume_in_ms}           reconnect after the hint with ?resume=<id>
//
//   client → server: aurelia.playback.done {item_id, played_ms} when an item finishes playing
//                    (ends the server's play-out hold), conversation.item.truncate on every cut.
//
// Any socket drop (pod swap, Cloudflare, phone sleep) reconnects with `?resume=<session_id>` on an
// exponential backoff, keeping the session id — the wearer hears a hiccup, not "Live mode ended"
// (fault B8 client half, server side AUR-728).

import Foundation
import AVFoundation

/// Backend-agnostic surface for the live audio + video mode. GeminiLiveService and
/// OpenAIRealtimeService both conform, so the view layer can pick one at runtime.
@MainActor
protocol LiveVideoService: AnyObject {
    var onAudioReceived: ((Data) -> Void)? { get set }
    var onInputTranscription: ((String) -> Void)? { get set }
    var onOutputTranscription: ((String) -> Void)? { get set }
    var onTurnComplete: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }

    /// Sample rate (Hz) this backend expects for uploaded mic audio (PCM16 mono).
    var inputSampleRate: Int { get }
    /// Sample rate (Hz) of the audio this backend returns (PCM16 mono).
    var outputSampleRate: Int { get }

    func connect() async throws
    func disconnect() async
    func sendAudio(data: Data)
    func sendVideoFrame(imageData: Data)
}

/// OpenAI Realtime WebSocket Service
///
/// Connects to `wss://<host>/realtime` for real-time voice + vision. The user's OpenAI API key
/// (already configured for the chat backend) is reused; the Realtime endpoint is derived from
/// `openAIBaseURL`, so OpenAI-compatible gateways that expose /realtime work too.
@MainActor
final class OpenAIRealtimeService: ObservableObject, LiveVideoService {
    // MARK: - Singleton

    static let shared = OpenAIRealtimeService()

    // MARK: - Published State

    @Published var connectionState: AIConnectionState = .disconnected
    @Published var isProcessing: Bool = false
    @Published var isModelSpeaking: Bool = false
    @Published var lastError: String?

    // MARK: - Configuration

    private var settings: AppSettings { SettingsManager.shared.settings }
    private var apiKey: String { settings.openAIAPIKey }

    private var videoFPS: Int {
        max(1, settings.geminiVideoFPS)   // reuse the shared "live video fps" preference
    }

    let inputSampleRate = Constants.OpenAIRealtime.inputSampleRate
    let outputSampleRate = Constants.OpenAIRealtime.outputSampleRate

    // MARK: - Callbacks

    var onAudioReceived: ((Data) -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?

    /// AUR-723: the ring-buffer player. When set, audio deltas go straight into it (with their
    /// item id) so barge-in can pause/flush and count what was actually heard. Without it the
    /// service falls back to `onAudioReceived` (the legacy Gemini-style path).
    weak var playback: (any RealtimePlaybackSink)? {
        didSet { wirePlaybackCallbacks() }
    }

    /// Route tag reported to the brain in `session.update.metadata.route` ("a2dp+phone-mic", …).
    var routeTag: String = "unknown"

    // MARK: - WebSocket

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var isSessionReady: Bool = false

    // MARK: - Session identity / reconnect (AUR-728 client half)

    /// Server session id (`session.created`) — replayed as `?resume=` on every reconnect.
    private(set) var sessionId: String?
    /// True while `disconnect()` was called by us: no reconnect, fire `onDisconnected`.
    private var intentionalClose = false
    /// Bumped on every teardown. A receive loop only acts while its generation is current, so a
    /// dying socket can never tear down its replacement or feed playback/turns (AUR-723c).
    private var socketGeneration = 0
    /// Exactly one open attempt at a time — concurrent `connect()`/reconnect would leave two
    /// live sockets for one app instance (server side: `live:2` for the same user).
    private var isOpening = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var pingTask: Task<Void, Never>?

    /// Mic frames captured while the socket is down (bounded ring) — replayed after a resume so a
    /// pod swap costs a hiccup, not a lost question.
    private var offlineAudio: [Data] = []
    private var offlineAudioBytes = 0
    private var offlineAudioLimitBytes: Int {
        Int(Double(inputSampleRate) * 2 * Constants.RealtimeAudio.offlineRingSeconds)
    }

    // MARK: - Barge-in state

    /// Item id of the reply currently being spoken (target of `conversation.item.truncate`).
    private var currentItemId: String?
    /// When `input_audio_buffer.speech_started` landed — used for the flush-latency log line.
    private var onsetAt: Date?
    /// Item ids already truncated, so `cleared` + cancelled `response.done` do not double-send.
    private var truncatedItems: Set<String> = []

    // MARK: - Video Throttling

    private var lastFrameTime: Date = .distantPast
    private var frameInterval: TimeInterval { 1.0 / Double(videoFPS) }

    // MARK: - Initialization

    private init() {}

    // MARK: - Connection

    func connect() async throws {
        guard !apiKey.isEmpty else { throw AIBackendError.notConfigured }
        guard !connectionState.isUsable, !connectionState.isAttempting, !isOpening else { return }
        intentionalClose = false
        try await openSocket(resuming: false)
        reconnectAttempt = 0
    }

    /// Open the socket and wait for `session.created` + our `session.update` to be accepted.
    private func openSocket(resuming: Bool) async throws {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }

        // ONE socket, always: whatever was open (and its receive loop, ping task and URLSession)
        // dies BEFORE the replacement is created. Skipping this is how a resume left the old
        // socket alive — the stale loop then reported ITS death as the live socket's death,
        // tore down the new one and scheduled another reconnect, while the server still counted
        // the abandoned session as live.
        closeWebSocket()
        let generation = socketGeneration

        connectionState = resuming ? .reconnecting(attempt: reconnectAttempt) : .connecting
        onConnectionStateChanged?(connectionState)

        do {
            guard let url = buildWebSocketURL(resume: resuming ? sessionId : nil) else {
                throw AIBackendError.connectionFailed
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            urlSession = URLSession(configuration: config)
            webSocket = urlSession?.webSocketTask(with: request)
            webSocket?.resume()

            startReceiving(generation: generation)

            // Wait for the socket to come up.
            var running = false
            for _ in 0..<15 {
                if webSocket?.state == .running { running = true; break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard running else { throw AIBackendError.connectionTimeout }

            // The server sends `session.created`; once we see it we push our session config and
            // mark the session ready (isSessionReady).
            for _ in 0..<50 {
                if isSessionReady { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard isSessionReady else { throw AIBackendError.connectionFailed }

            connectionState = .connected
            onConnectionStateChanged?(connectionState)
            startPinging()
            flushOfflineAudio()
            print("[OpenAIRealtime] Connected socket #\(generation) (session \(sessionId ?? "?"), resumed: \(resuming), route \(routeTag))")

        } catch {
            lastError = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
            onConnectionStateChanged?(connectionState)
            closeWebSocket()
            throw error
        }
    }

    func disconnect() async {
        guard connectionState != .disconnected else { return }
        print("[OpenAIRealtime] Disconnecting")
        intentionalClose = true
        reconnectTask?.cancel(); reconnectTask = nil
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        closeWebSocket()
        sessionId = nil
        offlineAudio.removeAll(); offlineAudioBytes = 0
        onDisconnected?()
    }

    /// Derive the Realtime WebSocket URL from the configured OpenAI base URL.
    /// e.g. https://api.openai.com/v1 → wss://api.openai.com/v1/realtime?model=gpt-realtime
    /// `resume` adds `?resume=<session_id>` so the brain continues the same conversation (AUR-728).
    private func buildWebSocketURL(resume: String? = nil) -> URL? {
        var base = settings.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        if base.hasPrefix("https://") {
            base = "wss://" + base.dropFirst("https://".count)
        } else if base.hasPrefix("http://") {
            base = "ws://" + base.dropFirst("http://".count)
        }
        let model = settings.openAIRealtimeModel.isEmpty
            ? Constants.OpenAIRealtime.modelName : settings.openAIRealtimeModel
        var components = URLComponents(string: base + Constants.OpenAIRealtime.websocketPath)
        var items = [URLQueryItem(name: "model", value: model)]
        // The brain uses `?lang=` as the STT/TTS language hint (ru-RU for Margo's rig).
        let locale = settings.speechLocaleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !locale.isEmpty { items.append(URLQueryItem(name: "lang", value: locale)) }
        if let resume, !resume.isEmpty { items.append(URLQueryItem(name: "resume", value: resume)) }
        components?.queryItems = items
        return components?.url
    }

    private func closeWebSocket() {
        // Invalidate every in-flight receive loop for the socket being dropped.
        socketGeneration &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isSessionReady = false
        isModelSpeaking = false
        isProcessing = false
        currentItemId = nil
        onsetAt = nil
    }

    // MARK: - Session setup

    /// Configure the session: PCM16 in/out at 24 kHz, server VAD turn-taking, audio output with a
    /// voice, and input transcription so spoken commands surface as text. `metadata.proto` tells
    /// the brain this client flushes its own playback, so it can drop the legacy play-out hold.
    private func sendSessionUpdate() async throws {
        let voice = settings.openAIRealtimeVoice.isEmpty
            ? Constants.OpenAIRealtime.voice : settings.openAIRealtimeVoice

        let session: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": buildSystemPrompt(),
                "output_modalities": ["audio"],
                "metadata": [
                    "client": Constants.RealtimeAudio.clientTag,
                    "proto": Constants.RealtimeAudio.protocolTag,
                    "route": routeTag
                ],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": inputSampleRate
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500,
                            "create_response": true,
                            "interrupt_response": true
                        ],
                        "transcription": [
                            "model": "gpt-4o-mini-transcribe"
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": outputSampleRate
                        ],
                        "voice": voice
                    ]
                ]
            ]
        ]
        try await sendJSON(session)
    }

    private func buildSystemPrompt() -> String {
        var prompt = """
        You are a helpful AI assistant integrated with smart glasses. You can see what the user sees through their glasses camera.

        Keep responses concise and conversational - the user is wearing glasses and expects quick, natural interactions.

        If the user asks you to do something beyond your capabilities, explain what you can help with instead.
        """

        let userPrompt = settings.userPrompt
        if !userPrompt.isEmpty {
            prompt += "\n\nAdditional instructions from user:\n\(userPrompt)"
        }

        let memories = settings.memories
        if !memories.isEmpty {
            prompt += "\n\nThings to remember about the user:"
            for (key, value) in memories {
                prompt += "\n- \(key): \(value)"
            }
        }
        return prompt
    }

    // MARK: - Send Audio

    /// AUR-723: mic frames flow ALWAYS while the session is live — this is the whole point of
    /// full duplex. The `!isModelSpeaking` guard that used to sit here is what made the server's
    /// barge-in unreachable. While the socket is down the frames go into a bounded ring and are
    /// replayed on the resumed session.
    func sendAudio(data: Data) {
        guard connectionState.isUsable, webSocket != nil else {
            bufferOfflineAudio(data)
            return
        }
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
        Task { try? await sendJSON(message) }
    }

    private func bufferOfflineAudio(_ data: Data) {
        guard !intentionalClose, sessionId != nil else { return }
        offlineAudio.append(data)
        offlineAudioBytes += data.count
        while offlineAudioBytes > offlineAudioLimitBytes, !offlineAudio.isEmpty {
            offlineAudioBytes -= offlineAudio.removeFirst().count
        }
    }

    private func flushOfflineAudio() {
        guard !offlineAudio.isEmpty else { return }
        let frames = offlineAudio
        offlineAudio.removeAll(); offlineAudioBytes = 0
        print("[OpenAIRealtime] Replaying \(frames.count) mic frames captured during the reconnect")
        for frame in frames {
            let message: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": frame.base64EncodedString()
            ]
            Task { try? await sendJSON(message) }
        }
    }

    // MARK: - Send Video

    func sendVideoFrame(imageData: Data) {
        // No `isModelSpeaking` gate any more: a frame is context for the NEXT answer and the
        // brain only stores the newest one, so holding frames back while she speaks just made
        // the vision context stale.
        guard connectionState.isUsable else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        // Add the frame as an image message. It becomes visual context for the model's next reply;
        // it does NOT trigger a response on its own (server VAD drives responses off speech).
        let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        let message: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_image", "image_url": dataURL]
                ]
            ]
        ]
        Task { try? await sendJSON(message) }
    }

    // MARK: - Send JSON

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket = webSocket else { throw AIBackendError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await webSocket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func send(_ object: [String: Any]) {
        Task { try? await sendJSON(object) }
    }

    // MARK: - Receive Loop

    private func startReceiving(generation: Int) {
        let socket = webSocket
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let socket,
                      self.socketGeneration == generation, socket === self.webSocket else { break }
                do {
                    let message = try await socket.receive()
                    // A message that arrived on a socket we have already replaced must not reach
                    // playback or start a turn.
                    guard self.socketGeneration == generation else { break }
                    await self.handleMessage(message)
                } catch {
                    // Only the CURRENT socket's death is a disconnect. Without this guard a
                    // superseded socket's error tore down its replacement and scheduled another
                    // reconnect — a self-sustaining leak of live sessions.
                    guard !Task.isCancelled, self.socketGeneration == generation else { break }
                    print("[OpenAIRealtime] Receive error on socket #\(generation): \(error)")
                    await self.handleDisconnect(error: error)
                    break
                }
            }
        }
    }

    /// Keepalive — Cloudflare drops a socket that has been quiet, and a live session is silent
    /// whenever nobody is talking.
    private func startPinging() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Constants.RealtimeAudio.pingInterval * 1_000_000_000))
                guard let self, let socket = self.webSocket else { return }
                socket.sendPing { _ in }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        guard let data = extractData(from: message),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "session.created":
            if let session = json["session"] as? [String: Any], let id = session["id"] as? String {
                sessionId = id
            }
            // Push our config, then consider the session ready to stream.
            do {
                try await sendSessionUpdate()
                isSessionReady = true
            } catch {
                print("[OpenAIRealtime] session.update failed: \(error)")
            }

        case "session.updated":
            isSessionReady = true

        // ── AUR-724 barge-in stage 1: the wearer started talking ──────────────────────────────
        case "input_audio_buffer.speech_started":
            onsetAt = Date()
            // Pause immediately and KEEP the buffer: the server has up to ~400 ms to confirm
            // this was speech and not the echo of the reply. A false alarm resumes below.
            playback?.pausePlayback()
            playback?.duck(true)
            isProcessing = true
            if let itemId = json["item_id"] as? String, currentItemId == nil { currentItemId = itemId }
            print("[OpenAIRealtime] ⏸ speech_started → playback paused")

        // ── stage 2a: confirmed → drop everything buffered and tell her what was heard ────────
        case "output_audio_buffer.cleared":
            let itemId = (json["item_id"] as? String) ?? currentItemId
            flushAndTruncate(itemId: itemId, trigger: "output_audio_buffer.cleared")

        // ── stage 2b: false alarm (echo/noise) → continue from where we paused ────────────────
        case "aurelia.playback.resume":
            playback?.resumePlayback()
            let waited = onsetAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            onsetAt = nil
            print("[OpenAIRealtime] ▶︎ playback.resume (false alarm after \(waited) ms)")

        // ── AUR-728: the pod is going away — reconnect on the hint, keep the session ──────────
        case "aurelia.server.draining":
            if let id = json["session_id"] as? String { sessionId = id }
            let resumeInMs = (json["resume_in_ms"] as? Double) ?? 1500
            print("[OpenAIRealtime] Server draining — resuming session \(sessionId ?? "?") in \(Int(resumeInMs)) ms")
            scheduleReconnect(afterMs: resumeInMs, reason: "draining")

        case "response.created":
            isProcessing = true
            truncatedItems.removeAll()

        case "response.output_item.added":
            if let item = json["item"] as? [String: Any], let id = item["id"] as? String {
                currentItemId = id
            }

        case "response.output_audio.delta":
            if let b64 = json["delta"] as? String, let audio = Data(base64Encoded: b64) {
                isModelSpeaking = true
                isProcessing = true
                let itemId = (json["item_id"] as? String) ?? currentItemId ?? "item_live"
                currentItemId = itemId
                if let playback {
                    playback.enqueue(pcm16: audio, itemId: itemId)
                } else {
                    onAudioReceived?(audio)
                }
            }

        case "response.output_audio_transcript.delta":
            if let text = json["delta"] as? String, !text.isEmpty {
                onOutputTranscription?(text)
            }

        case "conversation.item.input_audio_transcription.completed",
             "conversation.item.input_audio_transcription.delta":
            // The user's speech, transcribed. `transcript` on completed, `delta` while streaming.
            let text = (json["transcript"] as? String) ?? (json["delta"] as? String) ?? ""
            if !text.isEmpty { onInputTranscription?(text) }

        case "response.output_audio.done":
            // No more audio for this item — it completes once the ring plays it out, and THEN we
            // send `aurelia.playback.done` (which releases the server's play-out hold).
            let itemId = (json["item_id"] as? String) ?? currentItemId
            if let itemId { playback?.closeItem(itemId) }
            isModelSpeaking = false

        case "response.done":
            let response = json["response"] as? [String: Any]
            let status = (response?["status"] as? String) ?? "completed"
            if status == "cancelled" {
                // Idempotent with `output_audio_buffer.cleared` — whichever arrives first cuts.
                flushAndTruncate(itemId: currentItemId, trigger: "response.done cancelled")
            }
            isModelSpeaking = false
            isProcessing = false
            currentItemId = nil
            onTurnComplete?()

        case "conversation.item.truncated":
            let heard = (json["heard_prefix"] as? String) ?? ""
            print("[OpenAIRealtime] Truncate acknowledged (heard \(heard.count) chars)")

        case "error":
            let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            print("[OpenAIRealtime] Server error: \(detail)")
            lastError = detail
            // AUR-729 client half: never leave the UI stuck "thinking" on a server error.
            isProcessing = false

        default:
            break
        }
    }

    // MARK: - Barge-in execution

    /// Drop everything buffered and tell the brain how much of `itemId` actually reached the ear.
    /// The measured onset→flush latency is logged — this is the client half of the ≤300 ms number.
    private func flushAndTruncate(itemId: String?, trigger: String) {
        let flushed = playback?.flushPlayback()
        let target = itemId ?? flushed?.itemId
        let playedMs = flushed?.playedMs ?? 0
        let latency = onsetAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        onsetAt = nil
        isModelSpeaking = false

        print("[OpenAIRealtime] ✂︎ flush on \(trigger) — ear silent \(latency) ms after onset, played \(Int(playedMs)) ms")

        guard let target, !truncatedItems.contains(target) else { return }
        truncatedItems.insert(target)
        send([
            "type": "conversation.item.truncate",
            "item_id": target,
            "content_index": 0,
            "audio_end_ms": Int(playedMs.rounded())
        ])
    }

    /// An item finished playing out → release the server's play-out hold with the exact ms played.
    private func wirePlaybackCallbacks() {
        playback?.onItemPlayed = { [weak self] itemId, playedMs in
            guard let self else { return }
            guard self.connectionState.isUsable else { return }
            self.send([
                "type": "aurelia.playback.done",
                "item_id": itemId,
                "played_ms": Int(playedMs.rounded())
            ])
        }
    }

    // MARK: - Reconnect (AUR-728 client half)

    private func extractData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: return nil
        }
    }

    /// A socket died. Unless we closed it on purpose, reconnect with `?resume=<session_id>` on an
    /// exponential backoff and keep capturing into the offline ring meanwhile.
    private func handleDisconnect(error: Error?) async {
        guard !intentionalClose else { return }
        closeWebSocket()
        guard sessionId != nil else {
            // Never got a session — nothing to resume, report the drop.
            connectionState = .disconnected
            onConnectionStateChanged?(connectionState)
            onDisconnected?()
            return
        }
        scheduleReconnect(afterMs: nil, reason: error.map { "\($0)" } ?? "socket closed")
    }

    /// `afterMs` = the server's own hint (draining); nil = exponential backoff.
    private func scheduleReconnect(afterMs: Double?, reason: String) {
        guard !intentionalClose else { return }
        guard reconnectTask == nil else { return }
        guard reconnectAttempt < Constants.RealtimeAudio.reconnectMaxAttempts else {
            print("[OpenAIRealtime] Giving up after \(reconnectAttempt) reconnect attempts")
            connectionState = .failed("connection lost")
            onConnectionStateChanged?(connectionState)
            onDisconnected?()
            return
        }
        reconnectAttempt += 1
        let backoff = min(Constants.RealtimeAudio.reconnectMaxDelay,
                          Constants.RealtimeAudio.reconnectInitialDelay * pow(2, Double(reconnectAttempt - 1)))
        let delay = (afterMs.map { $0 / 1000 } ?? backoff)
        connectionState = .reconnecting(attempt: reconnectAttempt)
        onConnectionStateChanged?(connectionState)
        print("[OpenAIRealtime] Reconnect #\(reconnectAttempt) in \(String(format: "%.2f", delay))s (\(reason))")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        reconnectTask = nil
        guard !intentionalClose else { return }
        // `openSocket` closes whatever is still open first; the session id is what carries the
        // conversation across the swap.
        do {
            try await openSocket(resuming: true)
            reconnectAttempt = 0
            print("[OpenAIRealtime] ✓ Session resumed (\(sessionId ?? "?"))")
        } catch {
            print("[OpenAIRealtime] Reconnect failed: \(error)")
            scheduleReconnect(afterMs: nil, reason: "retry")
        }
    }
}

// MARK: - GeminiLiveService conformance

/// GeminiLiveService already implements the whole surface; expose its sample rates so it satisfies
/// `LiveVideoService` and can be selected interchangeably with the OpenAI backend.
extension GeminiLiveService: LiveVideoService {
    var inputSampleRate: Int { Constants.GeminiLive.inputSampleRate }
    var outputSampleRate: Int { Constants.GeminiLive.outputSampleRate }
}
