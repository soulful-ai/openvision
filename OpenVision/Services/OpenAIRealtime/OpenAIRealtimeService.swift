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
//   aurelia.action {id, action, mode}                AUR-776: photo / video / listen — earcon + do it
//   client → server: aurelia.action.ack {id, ok, artifact}, aurelia.action.request (UI buttons),
//                    aurelia.photo {id, mimeType, data}   AUR-787: the captured JPEG itself
//                    (≤1280 px, q0.7) so she describes THIS shot, not a later stream frame
//   aurelia.client_tools / aurelia.tool_call / aurelia.tool_result   AUR-792: the phone's native
//                    tools (timer, reminder, calendar, …) advertised after every (re)connect and
//                    executed on request — see ClientToolBridge.
//
// Any socket drop (pod swap, Cloudflare, phone sleep) reconnects with `?resume=<session_id>` on an
// exponential backoff, keeping the session id — the wearer hears a hiccup, not "Live mode ended"
// (fault B8 client half, server side AUR-728).

import Foundation
import AVFoundation
import ImageIO
import UIKit

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

    /// AUR-792: the phone's native tools on the wire. Advertised (`aurelia.client_tools`) right
    /// after each (re)connect's session.update, re-advertised when a permission state changes,
    /// and answers `aurelia.tool_call` → `aurelia.tool_result`. Shares `NativeToolRegistry` with
    /// the banked push-to-ask path; idle unless the session is open.
    let clientTools: ClientToolBridge

    /// AUR-724b: "this client cancels its own echo" (iOS VPIO). The brain drops its echo-level
    /// gate when this is true and leans on text-based self-echo rejection instead, which makes
    /// talk-over markedly more sensitive — so it must only be set when the PHONE really is the
    /// one cancelling (see `AudioSessionManager.clientAECActive`). A route change that hands the
    /// mic to the glasses flips it back off mid-session.
    var aecActive: Bool = false {
        didSet {
            guard aecActive != oldValue else { return }
            ovLog("[OpenAIRealtime] AEC hint changed → \(aecActive) (route \(routeTag))")
            sendClientMetadata()
        }
    }

    // MARK: - WebSocket

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var isSessionReady: Bool = false

    // MARK: - Session identity / reconnect (AUR-728 client half)

    /// Server session id (`session.created`) — replayed as `?resume=` on every reconnect.
    private(set) var sessionId: String?
    /// AUR-759: the model the server actually resolved for this session (`session.created`
    /// echoes the registry id, not our request) — what the live-screen chip shows.
    @Published private(set) var activeModel: String?
    /// AUR-742 / memo §1.6: heavy-lane tasks the brain reports for this session — `task_id` →
    /// spoken title, for every `aurelia.task.started` / `.queued` until its `.done`. The client's
    /// minimum viable handling: log them, show a "N running" pill; the SPOKEN channel carries the
    /// meaning (bridge phrase, hand-off, result), so nothing here gates the conversation.
    @Published private(set) var runningTasks: [String: String] = [:]
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
    /// pod swap costs a hiccup, not a lost question. AUR-743: ALSO fills while the first socket
    /// is still connecting, so the mic can start the moment the rig is up (before `connect()`)
    /// and nothing said during the handshake is lost.
    private var offlineAudio: [Data] = []
    private var offlineAudioBytes = 0
    private var offlineAudioLimitBytes: Int {
        Int(Double(inputSampleRate) * 2 * Constants.RealtimeAudio.offlineRingSeconds)
    }

    /// AUR-743: the wake-word pre-roll — mic audio that followed «Аурелия» on the idle tap,
    /// handed over by the ViewModel before `connect()` and sent as the session's FIRST
    /// `input_audio_buffer.append` (before the offline ring, before live frames).
    private var pendingPreRoll: WakePreRoll?

    // MARK: - Barge-in state

    /// Item id of the reply currently being spoken (target of `conversation.item.truncate`).
    private var currentItemId: String?
    /// When `input_audio_buffer.speech_started` landed — used for the flush-latency log line.
    private var onsetAt: Date?
    /// Item ids already truncated, so `cleared` + cancelled `response.done` do not double-send.
    private var truncatedItems: Set<String> = []
    /// False until the session's first reply has been prepared — the first one is the fragile one.
    private var hasPlayedAnyReply = false
    /// AUR-746: the brain said goodbye and is ending the conversation. Everything after this is
    /// expected — the socket closing is not a drop and must not start the `?resume=` backoff.
    private var sessionClosing = false
    /// AUR-772: true when the conversation was ended by the SERVER after its spoken farewell —
    /// the VM then skips its own "call ended" announcement (the goodbye was already heard, on
    /// the call's route; a second one would play on whatever route is left after teardown).
    private(set) var endedAfterFarewell = false

    // MARK: - Video Throttling

    private var lastFrameTime: Date = .distantPast
    private var frameInterval: TimeInterval { 1.0 / Double(videoFPS) }

    // MARK: - Initialization

    private init() {
        clientTools = ClientToolBridge(tools: NativeToolRegistry.shared.allTools)
        clientTools.send = { [weak self] payload in self?.send(payload) }
        // AUR-803b: the phone crossed a time zone (or DST flipped) mid-session → the brain's
        // session clock follows (`metadata.tz` / `utcOffsetMin`; server precedence metadata →
        // ?tz= → profile → Europe/Amsterdam). Idle unless a session is open.
        tzObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connectionState.isUsable else { return }
                ovLog("[OpenAIRealtime] system time zone changed → \(TimeZone.current.identifier); re-sending metadata")
                self.sendClientMetadata()
            }
        }
        // AUR-845, same AUR-803b rail: the phone left / came back to the foreground mid-call →
        // `metadata.appState` follows. The wearer pockets the phone during a glasses call and iOS
        // stops honouring pasteboard writes; the brain has to know that without inferring it from
        // the last tool result. Deduped — only a CHANGED state is re-declared. Idle unless a
        // session is open.
        for name in [UIApplication.didBecomeActiveNotification,
                     UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification] {
            appStateObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.connectionState.isUsable else { return }
                    let now = AppForegroundState.current()
                    guard now != self.lastSentAppState else { return }
                    ovLog("[OpenAIRealtime] app state \(self.lastSentAppState?.rawValue ?? "?") → \(now.rawValue); re-sending metadata")
                    self.sendClientMetadata()
                }
            })
        }
    }

    private var tzObserver: NSObjectProtocol?
    /// AUR-845: the four foreground-lifecycle observers behind `metadata.appState`.
    private var appStateObservers: [NSObjectProtocol] = []
    /// The last `appState` that actually crossed the wire — the dedup key for the re-declares.
    private var lastSentAppState: AppForegroundState?

    // MARK: - Connection

    func connect() async throws {
        guard !apiKey.isEmpty else { throw AIBackendError.notConfigured }
        guard !connectionState.isUsable, !connectionState.isAttempting, !isOpening else { return }
        intentionalClose = false
        hasPlayedAnyReply = false
        sessionClosing = false
        endedAfterFarewell = false
        // A fresh session starts with a clean ring: frames a FAILED previous attempt buffered
        // while connecting must not be replayed into this one.
        offlineAudio.removeAll(); offlineAudioBytes = 0
        do {
            try await openSocket(resuming: false)
        } catch {
            pendingPreRoll = nil
            offlineAudio.removeAll(); offlineAudioBytes = 0
            throw error
        }
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
            // AUR-792: the session.update went out on `session.created`; the tool manifest is
            // the next thing on the wire — before any audio, so the very first turn can already
            // set a timer. Re-sent on every resume (the server's session may have forgotten it).
            clientTools.sessionDidConnect()
            flushPreRoll()        // AUR-743: what followed the wake word, first
            flushOfflineAudio()   // then what the mic heard while we were connecting / down
            ovLog("[OpenAIRealtime] Connected socket #\(generation) (session \(sessionId ?? "?"), resumed: \(resuming), route \(routeTag))")

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
        ovLog("[OpenAIRealtime] Disconnecting")
        intentionalClose = true
        reconnectTask?.cancel(); reconnectTask = nil
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        closeWebSocket()
        sessionId = nil
        activeModel = nil
        runningTasks.removeAll()
        pendingPreRoll = nil
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
        // AUR-759: the wearer's pick (a registry id the server offers); empty = server default, so
        // the parameter is simply left off and the brain applies its REALTIME_MODEL.
        let model = settings.openAIRealtimeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: base + Constants.OpenAIRealtime.websocketPath)
        var items: [URLQueryItem] = []
        if !model.isEmpty { items.append(URLQueryItem(name: "model", value: model)) }
        // The brain uses `?lang=` as the STT/TTS language hint (ru-RU for Margo's rig).
        let locale = settings.speechLocaleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !locale.isEmpty { items.append(URLQueryItem(name: "lang", value: locale)) }
        // AUR-724b: declared at upgrade so the very first turn already runs without the echo gate.
        items.append(URLQueryItem(name: "aec", value: aecActive ? "1" : "0"))
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
        // AUR-792: nothing in flight can be answered on a closed socket.
        clientTools.sessionDidDisconnect()
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
                "metadata": currentClientMetadata(),
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

    /// The `session.update.metadata` dict — ONE builder for the connect-time update and every
    /// later re-declaration, so no path can forget a key. Pure (no socket, no singleton state) so
    /// the tests can pin the shape. AUR-803b: `tz` (IANA id) + `utcOffsetMin` (minutes east of
    /// UTC, DST included) are the phone's CURRENT zone; the brain sets the session clock from
    /// them (precedence metadata → `?tz=` → profile → Europe/Amsterdam) and echoes
    /// `session.updated.metadata.tz/tz_source`.
    /// AUR-845: `appState` ("active" | "inactive" | "background") is the phone's foreground state
    /// at send time, re-declared on every change while the session is open — the brain needs it to
    /// read a `deferred` clipboard result ("he is not in the app, the paste has NOT landed yet")
    /// without guessing from the last tool result.
    nonisolated static func clientMetadata(route: String, aec: Bool,
                                           timeZone: TimeZone = .current,
                                           appState: AppForegroundState) -> [String: Any] {
        [
            "client": Constants.RealtimeAudio.clientTag,
            "proto": Constants.RealtimeAudio.protocolTag,
            "route": route,
            "aec": aec,
            "tz": timeZone.identifier,
            "utcOffsetMin": timeZone.secondsFromGMT() / 60,
            "appState": appState.rawValue
        ]
    }

    /// The live metadata for THIS send, logged once per send (`🕒 tz Europe/Amsterdam (+120) app active`).
    private func currentClientMetadata() -> [String: Any] {
        let tz = TimeZone.current
        let offset = tz.secondsFromGMT() / 60
        let state = AppForegroundState.current()
        lastSentAppState = state
        ovLog("[OpenAIRealtime] 🕒 tz \(tz.identifier) (\(offset >= 0 ? "+" : "")\(offset)) app \(state.rawValue)")
        return Self.clientMetadata(route: routeTag, aec: aecActive, timeZone: tz, appState: state)
    }

    /// Re-declare the client hints mid-session (route change flipped AEC, mic moved to the
    /// glasses, the phone changed time zone, …). Metadata-only: the server applies just the
    /// keys present.
    private func sendClientMetadata() {
        guard connectionState.isUsable else { return }
        send([
            "type": "session.update",
            "session": [
                "metadata": currentClientMetadata()
            ]
        ])
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
        // A session we are resuming, OR the first socket still coming up (AUR-743: the mic runs
        // from rig-up, before `connect()` returns). Never after we hung up.
        guard !intentionalClose, sessionId != nil || connectionState.isAttempting else { return }
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
        let ms = frames.reduce(0) { $0 + $1.count } / 2 * 1000 / max(1, inputSampleRate)
        ovLog("[OpenAIRealtime] Replaying \(frames.count) mic frames (\(ms) ms) captured while the socket was connecting / down")
        for frame in frames {
            let message: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": frame.base64EncodedString()
            ]
            Task { try? await sendJSON(message) }
        }
    }

    // MARK: - Wake-word pre-roll (AUR-743)

    /// Hand over the audio that followed the wake phrase. Call BEFORE `connect()`; it goes out as
    /// the first append the moment the session is up. An empty tail is dropped (bare «Аурелия»
    /// opens the session and stays silent — nothing is fed that could make her answer).
    func primePreRoll(_ preRoll: WakePreRoll?) {
        guard let preRoll, !preRoll.pcm.isEmpty else { pendingPreRoll = nil; return }
        pendingPreRoll = preRoll
    }

    /// ONE message for the whole tail so nothing can interleave ahead of its end (live frames are
    /// separate sends that start after `connect()` returns). The send is fire-and-forget, like
    /// every mic frame: it adds no wait to the session coming up; what it costs the wire is
    /// logged (`sent in … ms`) — the AUR-743 ≤100 ms budget.
    private func flushPreRoll() {
        guard let preRoll = pendingPreRoll else { return }
        pendingPreRoll = nil
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": preRoll.pcm.base64EncodedString()
        ]
        let started = Date()
        Task {
            try? await sendJSON(message)
            ovLog("[OpenAIRealtime] ⏪ wake pre-roll: \(preRoll.keptMs) ms after the wake word (trimmed: \(preRoll.trimmedWakeWord), snapshot \(preRoll.sinceDetectionMs) ms after detection) sent as the first append in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
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
                    ovLog("[OpenAIRealtime] Receive error on socket #\(generation): \(error)")
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
                if let model = session["model"] as? String, !model.isEmpty { activeModel = model }
            }
            // Push our config, then consider the session ready to stream.
            do {
                try await sendSessionUpdate()
                isSessionReady = true
            } catch {
                ovLog("[OpenAIRealtime] session.update failed: \(error)")
            }

        case "session.updated":
            isSessionReady = true

        // ── AUR-724 barge-in stage 1: the wearer started talking ──────────────────────────────
        case "input_audio_buffer.speech_started":
            // NOTE: this fires on EVERY utterance onset, not only over a playing reply
            // (channel.ts `speechStarted` sends it before it even checks for a turn). When
            // nothing is playing there is no turn to false-alarm on, so no `aurelia.playback.
            // resume` will ever follow — pausing unconditionally wedged the player shut for the
            // rest of the session and the next reply went into a paused ring (field bug: correct
            // transcript on screen, silence in the ear). Pause only when there IS something in
            // the ear; the player releases the pause itself if no verdict lands in ~700 ms.
            isProcessing = true
            if let itemId = json["item_id"] as? String, currentItemId == nil { currentItemId = itemId }
            let paused = playback?.pausePlayback() ?? false
            if paused {
                onsetAt = Date()
                playback?.duck(true)
                ovLog("[OpenAIRealtime] ⏸ speech_started → playback paused (reply in the ear)")
            } else {
                onsetAt = nil
                ovLog("[OpenAIRealtime] speech_started with an idle player — utterance onset, nothing to pause")
            }

        // ── stage 2a: confirmed → drop everything buffered and tell her what was heard ────────
        case "output_audio_buffer.cleared":
            let itemId = (json["item_id"] as? String) ?? currentItemId
            flushAndTruncate(itemId: itemId, trigger: "output_audio_buffer.cleared")

        // ── stage 2b: false alarm (echo/noise) → continue from where we paused ────────────────
        case "aurelia.playback.resume":
            playback?.resumePlayback()
            let waited = onsetAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            onsetAt = nil
            ovLog("[OpenAIRealtime] ▶︎ playback.resume (false alarm after \(waited) ms)")

        // ── AUR-746: the wearer ended the conversation by voice; the farewell is already on
        //    its way to the ear. Let it finish, then tear down exactly like the End pill. ───────
        case "aurelia.session.close":
            let reason = (json["reason"] as? String) ?? "user_request"
            endAfterFarewell(reason: reason)

        // ── AUR-776: a fast voice action (photo / video / listen) the brain recognised ────────
        case "aurelia.action":
            if let action = VoiceAction(json: json) {
                onAction?(action)
            } else {
                let raw = (json["action"] as? String) ?? "?"
                let id = (json["id"] as? String) ?? UUID().uuidString
                ovLog("[OpenAIRealtime] Unknown aurelia.action \"\(raw)\" — nacking")
                sendActionAck(VoiceActionAck(id: id, action: raw, ok: false, detail: "unknown action", artifact: nil))
            }

        // ── AUR-792: the brain wants the phone to do something (timer / reminder / calendar…) ─
        case "aurelia.tool_call":
            clientTools.handleToolCall(json)

        // ── AUR-742 client half of the heavy lane (memo §1.6): log + count the tasks ──────────
        case "aurelia.task.started", "aurelia.task.queued":
            let id = (json["task_id"] as? String) ?? UUID().uuidString
            let title = (json["title"] as? String) ?? "task"
            runningTasks[id] = type.hasSuffix("queued") ? "\(title) (queued)" : title
            ovLog("[OpenAIRealtime] ⚙︎ \(type) \(id): \(title) on \((json["device"] as? String) ?? "brain") — \(runningTasks.count) in flight")

        case "aurelia.task.progress":
            let id = (json["task_id"] as? String) ?? "?"
            let stage = (json["stage"] as? String) ?? "?"
            let detail = (json["detail"] as? String) ?? ""
            let elapsed = (json["elapsed_ms"] as? Double).map { Int($0) } ?? -1
            ovLog("[OpenAIRealtime] ⚙︎ task.progress \(id): \(stage) \(detail) (\(elapsed) ms)")

        case "aurelia.task.done":
            let id = (json["task_id"] as? String) ?? "?"
            let status = (json["status"] as? String) ?? "done"
            let elapsed = (json["elapsed_ms"] as? Double).map { Int($0) } ?? -1
            let title = runningTasks.removeValue(forKey: id) ?? "?"
            ovLog("[OpenAIRealtime] ⚙︎ task.done \(id) \"\(title)\": \(status) in \(elapsed) ms — \(runningTasks.count) left")

        case "aurelia.task.list":
            // The answer to `aurelia.task.query`: the ledger replaces what we think is running.
            let tasks = (json["tasks"] as? [[String: Any]]) ?? []
            var next: [String: String] = [:]
            for t in tasks {
                guard let id = t["task_id"] as? String else { continue }
                let status = (t["status"] as? String) ?? "running"
                guard status == "running" || status == "queued" else { continue }
                let title = (t["title"] as? String) ?? "task"
                next[id] = status == "queued" ? "\(title) (queued)" : title
            }
            runningTasks = next
            ovLog("[OpenAIRealtime] ⚙︎ task.list: \(next.count) running/queued")

        // ── AUR-728: the pod is going away — reconnect on the hint, keep the session ──────────
        case "aurelia.server.draining":
            if let id = json["session_id"] as? String { sessionId = id }
            let resumeInMs = (json["resume_in_ms"] as? Double) ?? 1500
            ovLog("[OpenAIRealtime] Server draining — resuming session \(sessionId ?? "?") in \(Int(resumeInMs)) ms")
            scheduleReconnect(afterMs: resumeInMs, reason: "draining")

        case "response.created":
            isProcessing = true
            truncatedItems.removeAll()
            // A fresh reply always starts audible: any pause/duck left over from the onset that
            // triggered THIS turn belongs to the previous response, not to this one.
            playback?.resumePlayback()
            onsetAt = nil
            // First-turn guarantee: the deltas are ~1-3 s away, so this is the moment to prove the
            // speaker can render — the first reply of a session arrives while the `.playAndRecord`
            // route is still settling, and it was the one the wearer never heard.
            playback?.ensureReadyForPlayback(firstOfSession: !hasPlayedAnyReply)
            hasPlayedAnyReply = true

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
            ovLog("[OpenAIRealtime] Truncate acknowledged (heard \(heard.count) chars)")

        case "error":
            let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            ovLog("[OpenAIRealtime] Server error: \(detail)")
            lastError = detail
            // AUR-729 client half: never leave the UI stuck "thinking" on a server error.
            isProcessing = false

        default:
            break
        }
    }

    // MARK: - Fast voice actions (AUR-776 client half)

    /// The brain says "do it now": photo / video.start / video.stop / audio.start / audio.stop.
    /// The ViewModel performs it (earcon first) and answers with `sendActionAck`.
    var onAction: ((VoiceAction) -> Void)?

    /// `{ type:"aurelia.action.ack", id, action, ok, detail, artifact }`.
    func sendActionAck(_ ack: VoiceActionAck) {
        send(ack.json)
    }

    /// A UI control asked for an action. The server echoes `aurelia.action` so the state stays
    /// single-sourced (voice and buttons go through the same path).
    func requestAction(_ kind: VoiceActionKind, mode: VoiceActionMode? = nil, source: String = "button") {
        guard connectionState.isUsable else {
            ovLog("[OpenAIRealtime] action.request \(kind.rawValue) dropped — socket not usable")
            return
        }
        var payload: [String: Any] = ["type": "aurelia.action.request", "action": kind.rawValue, "source": source]
        if let mode { payload["mode"] = mode.rawValue }
        send(payload)
    }

    /// AUR-787: ground the model's photo description in the ACTUAL captured image. The server
    /// used to describe a later DAT stream frame — a different picture than the gallery shot.
    /// Right after the `aurelia.action.ack` the client now uploads the very JPEG it saved:
    ///   client → server  { type:"aurelia.photo", id, mimeType:"image/jpeg", data:<base64> }
    /// where `id` is the photo action's id (server-initiated and button-echoed alike). The copy
    /// is downscaled to ≤1280 px long edge at JPEG q0.7 — well under 2 MB even off the native
    /// 4032×3024 pipeline; the full-resolution save to Photos is untouched. File read, downscale
    /// and base64 all run OFF the main actor; a closed socket skips silently (logged).
    func sendCapturedPhoto(id: String, fileURL: URL) {
        guard connectionState.isUsable, webSocket != nil else {
            ovLog("[OpenAIRealtime] aurelia.photo \(id) skipped — socket not usable")
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let jpeg = try? Data(contentsOf: fileURL) else {
                ovLog("[OpenAIRealtime] aurelia.photo \(id) skipped — can't read \(fileURL.lastPathComponent)")
                return
            }
            guard let scaled = Self.downscaledJPEG(jpeg, maxLongEdge: 1280, quality: 0.7) else {
                ovLog("[OpenAIRealtime] aurelia.photo \(id) skipped — downscale failed")
                return
            }
            let payload: [String: Any] = [
                "type": "aurelia.photo",
                "id": id,
                "mimeType": "image/jpeg",
                "data": scaled.base64EncodedString()
            ]
            ovLog("[OpenAIRealtime] aurelia.photo \(id): \(jpeg.count / 1024) KB → \(scaled.count / 1024) KB upload")
            await self?.send(payload)
        }
    }

    /// Downscale a JPEG to ≤`maxLongEdge` px on the long side, EXIF orientation baked in.
    /// nonisolated static so the detached encode task never touches the main actor.
    private nonisolated static func downscaledJPEG(_ jpeg: Data, maxLongEdge: CGFloat, quality: CGFloat) -> Data? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
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

        ovLog("[OpenAIRealtime] ✂︎ flush on \(trigger) — ear silent \(latency) ms after onset, played \(Int(playedMs)) ms")

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

    // MARK: - Voice-ended session (AUR-746 client half)

    /// The brain has spoken its goodbye and asked to end the conversation. Do NOT cut playback —
    /// the farewell is already queued in the ring; wait for the ear to catch up, then close the
    /// session the same way the End pill does (`onDisconnected` → `stopLiveVideoMode`). The
    /// server also closes the socket ~3 s later; because `intentionalClose` is set, that close is
    /// swallowed as expected rather than treated as a drop that needs `?resume=`.
    private func endAfterFarewell(reason: String) {
        guard !sessionClosing else { return }
        sessionClosing = true
        intentionalClose = true
        reconnectTask?.cancel(); reconnectTask = nil
        let pending = playback?.pendingMs ?? 0
        ovLog("[OpenAIRealtime] Session close requested (\(reason)) — letting \(Int(pending)) ms of farewell finish")

        Task { @MainActor in
            // Drain, with a ceiling so a stalled ring can never strand the session open.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, (self.playback?.pendingMs ?? 0) > 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // AUR-772: the ring being empty means RENDERED, not HEARD. On Bluetooth HFP the last
            // few hundred ms of the goodbye are still in the output chain; tearing the engine and
            // the route down now cut them (and the tail then surfaced from the phone speaker).
            // Keep the session + route alive for the output latency plus a margin.
            let tailMs = (self.playback?.playoutTailMs ?? 0) + 250
            try? await Task.sleep(nanoseconds: UInt64(tailMs * 1_000_000))
            ovLog("[OpenAIRealtime] Farewell played out (+\(Int(tailMs)) ms tail) — ending the session (\(reason))")
            self.endedAfterFarewell = true
            self.closeWebSocket()
            self.connectionState = .disconnected
            self.onConnectionStateChanged?(self.connectionState)
            self.sessionId = nil
            self.runningTasks.removeAll()
            self.offlineAudio.removeAll(); self.offlineAudioBytes = 0
            // Same exit the End pill takes: the VM tears live mode down and returns to idle.
            self.onDisconnected?()
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
            ovLog("[OpenAIRealtime] Giving up after \(reconnectAttempt) reconnect attempts")
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
        ovLog("[OpenAIRealtime] Reconnect #\(reconnectAttempt) in \(String(format: "%.2f", delay))s (\(reason))")

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
            ovLog("[OpenAIRealtime] ✓ Session resumed (\(sessionId ?? "?"))")
        } catch {
            ovLog("[OpenAIRealtime] Reconnect failed: \(error)")
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
