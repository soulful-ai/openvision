// OpenVision - VoiceAgentViewModel.swift
// MVVM: all voice-session orchestration for the main screen lives here — session lifecycle,
// command routing, live video, face intents, photo capture, TTS streaming, and history.
// VoiceAgentView renders this state and forwards user interactions; it holds no logic.
//
// The services are app-wide singletons; this ViewModel is their single orchestrator. Service
// callbacks capture self weakly — the services outlive any owner, so strong captures would pin
// the ViewModel forever.

import SwiftUI
import Speech
import Combine
import AVFoundation

@MainActor
final class VoiceAgentViewModel: ObservableObject {

    // MARK: - Dependencies

    let settingsManager = SettingsManager.shared
    let glassesManager = GlassesManager.shared
    let voiceCommandService = VoiceCommandService.shared
    let geminiVision = GeminiVisionService.shared
    let geminiLive = GeminiLiveService.shared
    let openAIRealtime = OpenAIRealtimeService.shared
    let ttsService = TTSService.shared
    let soundService = SoundService.shared
    let audioCapture = AudioCaptureService()
    let phoneCamera = PhoneCameraService.shared
    let audioPlayback = AudioPlaybackService()
    let sessionRecorder = SessionRecorder.shared
    /// AUR-776: fast voice actions (photo / video / listen) driven by the brain's `aurelia.action`.
    let voiceActions = VoiceActionService()

    // MARK: - Published UI state

    @Published var isSessionActive = false
    @Published var agentState: AgentState = .idle
    @Published var userTranscript = ""
    @Published var aiTranscript = ""
    @Published var currentToolName: String?
    @Published var errorMessage: String?
    /// Live Video Mode - uses Gemini Live or OpenAI Realtime for real-time audio + video
    @Published var isLiveVideoMode = false

    /// Audio rig in use while a live session runs ("a2dp+phone-mic", "hfp+bt-mic", …) — AUR-723.
    @Published var liveRoute: String = "unknown"

    /// AUR-759: the brain the server resolved for the running live session (registry id, e.g.
    /// "gemini-3-flash-preview") — the small chip next to LIVE. nil = not live / not the brain.
    @Published var liveModel: String?

    /// Which eye is feeding the live session (AUR-723b). Glasses first; the phone's own rear
    /// camera when none are paired — before this, a phone-only rig sent NO frames at all and
    /// "what do you see" had nothing to describe.
    enum LiveCameraSource: Equatable {
        case none
        case glasses
        case phone

        var label: String {
            switch self {
            case .none: return "Camera off"
            case .glasses: return "Glasses"
            case .phone: return "Phone camera"
            }
        }
        var symbol: String {
            switch self {
            case .none: return "eye.slash"
            case .glasses: return "eyeglasses"
            case .phone: return "camera.fill"
            }
        }
    }
    @Published var liveCameraSource: LiveCameraSource = .none

    /// The eye is opt-in, whichever eye it is. Tapping into the conversation (or waking her) is
    /// AUDIO-ONLY — the eye opens only on explicit intent inside the session («включи камеру» /
    /// "camera on" / the toggle in the live UI) and shuts on the off-commands or the toggle.
    /// AUR-742a (2026-08-17) made the PHONE camera opt-in but let registered glasses feed the
    /// session automatically "because that is the point of wearing them". AUR-757 (principal
    /// ruling 2026-08-18, first live session on the Ray-Ban Meta Headliner Gen 2 with DAT
    /// registered: "when I call her, she should just use audio; only when I specifically say so
    /// on the live call already, she can start recording") reversed that: the GLASSES camera is
    /// opt-in exactly like the phone camera. When the eye is asked for it is glasses-first
    /// (registered + connected → `startStreaming()`, LED on), phone camera otherwise; dismissing
    /// it stops the glasses stream (LED off) and/or the phone camera.
    @Published private(set) var cameraRequested = false
    /// True when voice recognition is ready (audio engine running)
    @Published var isVoiceReady = false
    /// True while a POV demo recording (glasses video + mic audio) is in progress.
    @Published var isRecording = false
    /// Transient status shown after a recording finishes ("Saved to Photos" / a failure). Auto-clears.
    @Published var recordingStatus: String?

    // MARK: - Internal state

    // De-dup: the last command we processed and when (drops duplicate recognizer emissions).
    private var lastProcessedCommand = ""
    private var lastProcessedAt = Date.distantPast
    private var hasRequestedSpeechAuth = false

    /// The live-video backend currently driving audio/video (Gemini or OpenAI Realtime).
    /// Set when live video mode starts; used by stop/callbacks so both backends route correctly.
    private var activeLiveService: (any LiveVideoService)?

    /// Sentence-streaming TTS (Apple only): how many characters of the streamed reply have
    /// already been handed to the speech queue, and whether a streamed utterance is open.
    private var ttsStreamSpokenChars = 0
    private var ttsStreaming = false

    /// History: true after a user command was recorded, until its reply is recorded. Keeps
    /// system utterances ("Live video mode active", error prompts) out of the History tab.
    private var historyAwaitingReply = false
    /// History (live modes): last streamed AI turn already recorded, to dedupe turn-complete events.
    private var historyLastLiveReply = ""

    /// Frame counter for logging
    private var videoFrameCount: Int = 0

    /// AUR-723b: watches glasses streaming/registration so the live eye switches between the
    /// glasses and the phone camera without restarting the conversation.
    private var cameraSourceWatch: Set<AnyCancellable> = []
    /// The camera refusal is stated once per session, not once per frame.
    private var phoneCameraDeniedAnnounced = false

    // MARK: - Agent State

    enum AgentState: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case toolRunning
        case liveVideo  // Live video mode - Gemini handles audio + video

        var displayText: String {
            switch self {
            case .idle: return "Tap to start"
            case .connecting: return "Connecting..."
            case .listening: return "Listening..."
            case .thinking: return "Thinking..."
            case .speaking: return "Speaking..."
            case .toolRunning: return "Running tool..."
            case .liveVideo: return "Live Video"
            }
        }

        var accentColor: Color {
            switch self {
            case .idle: return .gray
            case .connecting: return .orange
            case .listening: return .blue
            case .thinking: return .purple
            case .speaking: return .green
            case .toolRunning: return .orange
            case .liveVideo: return .red  // Red for live video recording indicator
            }
        }
    }

    // MARK: - View lifecycle

    func onAppear() {
        setupVoiceCommandService()
        setupGlassesCallbacks()
        preloadLocalModelIfNeeded()
        // Resume wake-word listening when returning to this screen. onDisappear stops it
        // (e.g. when navigating to Settings), and the one-time .task doesn't re-run on return —
        // so without this, the wake word stayed dead until you tapped the mic button.
        if voiceCommandService.authorizationStatus == .authorized && !voiceCommandService.isListening {
            startWakeWordListening()
        }
    }

    func onDisappear() {
        voiceCommandService.stopListening()
    }

    // MARK: - Observed state changes (forwarded from the view's onChange hooks)

    func ttsSpeakingChanged(_ isSpeaking: Bool) {
        if isSpeaking {
            agentState = .speaking
            // Pause barge-in detection while TTS is playing
            // (prevents microphone picking up TTS and triggering interruption)
            voiceCommandService.isBargeInPaused = true
        } else {
            // Resume barge-in detection
            voiceCommandService.isBargeInPaused = false

            if isSessionActive {
                agentState = .listening
                resumeListeningAfterSpeaking()
            } else {
                agentState = .idle
            }
        }
    }

    // Kokoro drives the same speaking-state flow as Apple TTS: keep the recognizer running
    // (in .processing) with barge-in paused so it stays in the conversation loop, then enter
    // conversation mode when playback finishes. (Don't stopListening — that trips the .idle
    // session-teardown observer and ends the conversation after every reply.)
    func kokoroSpeakingChanged(_ speaking: Bool) {
        if speaking {
            agentState = .speaking
            voiceCommandService.isBargeInPaused = true
        } else {
            voiceCommandService.isBargeInPaused = false
            if isSessionActive {
                agentState = .listening
                resumeListeningAfterSpeaking()
            } else {
                agentState = .idle
            }
        }
    }

    /// Control thinking sound based on agent state.
    func agentStateChanged(_ newState: AgentState) {
        if newState == .thinking || newState == .toolRunning {
            soundService.startThinkingSound()
        } else {
            soundService.stopThinkingSound()
        }
    }

    func voiceStateChanged(_ newState: VoiceCommandService.ListeningState) {
        ovLog("[VoiceAgent] VoiceCommandService state changed to: \(newState)")
        switch newState {
        case .idle:
            // In live video mode, a silence timeout must NOT end the mode — the user expects
            // to keep asking questions (camera stays on) until they say "stop video". Re-arm
            // conversation mode so the next question is heard without a fresh wake word.
            if isLiveVideoMode {
                ovLog("[VoiceAgent] Idle during live video — re-arming conversation mode")
                voiceCommandService.enterConversationMode()
                agentState = .liveVideo
                return
            }
            // A real conversation end is the recognizer going idle *while we were listening*
            // for the user (silence timeout). An .idle in any other state (.connecting startup,
            // .thinking/.toolRunning command processing, .speaking a reply) is a transient from
            // our own stop/restart — e.g. the camera capture restarts the recognizer mid-command
            // — and must NOT tear the session down. (This is what left the wake word dead after a
            // face/camera command: the restart flipped to .idle during .thinking and killed the
            // session, so the post-reply audio rebuild never ran.)
            if isSessionActive && agentState == .listening {
                ovLog("[VoiceAgent] Voice service idle, stopping session")
                isSessionActive = false
                agentState = .idle
                // Disconnect AI backend
                Task {
                    switch settingsManager.settings.aiBackend {
                    case .openClaw:
                        await OpenClawService.shared.disconnect()
                    case .geminiLive:
                        await GeminiLiveService.shared.disconnect()
                    case .openAI:
                        break   // stateless HTTP — nothing to disconnect
                    case .appleFoundation:
                        break   // OS-managed — nothing to disconnect
                    case .localGemma:
                        // Keep the on-device model LOADED so the next "Ok Vision" is instant.
                        // Unloading + reloading the ~3.6GB model per conversation was the cause
                        // of the "connecting…" lag and hangs. It stays resident until the app
                        // backgrounds or the user switches backend.
                        break
                    }
                }
            }
        case .listening, .conversationMode:
            // Keep the live indicator up in live video mode (don't clobber it back to
            // plain .listening, which would let the next idle tear the session down).
            if isLiveVideoMode {
                agentState = .liveVideo
            } else if ttsService.isSpeaking || KokoroTTSService.shared.isSpeaking {
                // The recognizer restarts (→ conversation mode) mid-reply for barge-in; don't
                // let that flip the UI to "Listening" while the assistant is still speaking.
                agentState = .speaking
            } else if isSessionActive {
                agentState = .listening
            }
        case .processing:
            agentState = .thinking
        }
    }

    // MARK: - Session lifecycle

    func toggleSession() {
        if isSessionActive {
            stopSession()
        } else {
            startSession()
        }
    }

    func startSession() {
        // Check configuration
        guard settingsManager.settings.isCurrentBackendConfigured else {
            errorMessage = "Please configure \(settingsManager.settings.aiBackend.displayName) in Settings"
            return
        }

        isSessionActive = true
        agentState = .connecting

        // Model memory follows the History conversation window (5-min inactivity), NOT the wake
        // session — every "Ok Vision" starts a new session, so clearing here made "what were we
        // just talking about?" fail seconds after the previous answer. Only reset memory when
        // enough time has passed that History would start a new conversation anyway.
        if !ConversationManager.shared.isCurrentConversationFresh {
            ConversationContext.shared.clear()
            AppleFoundationService.shared.resetContext()
        }

        // Configure audio routing for glasses if registered
        configureAudioForGlasses()

        // Connect to AI backend
        Task {
            do {
                switch settingsManager.settings.aiBackend {
                case .openClaw:
                    try await OpenClawService.shared.connect()
                    // Note: Streaming NOT auto-started in OpenClaw mode
                    // User says "start video stream" → startLiveVideoMode()
                    // User says "take a photo" → captureAndSendPhoto() starts streaming on-demand

                case .openAI:
                    try await OpenAIService.shared.connect()
                    // Stateless HTTP — photos are captured on-demand like OpenClaw.

                case .appleFoundation:
                    try await AppleFoundationService.shared.connect()
                    // On-device Apple model — text only; camera commands guide to a cloud backend.

                case .geminiLive:
                    try await GeminiLiveService.shared.connect()
                    // Start glasses streaming for Gemini Live mode
                    if glassesManager.isRegistered && !glassesManager.isStreaming {
                        ovLog("[VoiceAgent] Starting glasses stream for Gemini Live...")
                        await glassesManager.startStreaming()
                    }

                case .localGemma:
                    // On-device Gemma: load the model (must be downloaded first).
                    // Text-only in Phase 1 — no glasses streaming needed.
                    try await GemmaLocalService.shared.connect(
                        modelId: settingsManager.settings.localGemmaModelId
                    )
                }

                agentState = .listening
                userTranscript = ""
                aiTranscript = ""

                // Start voice command listening for speech capture
                if voiceCommandService.authorizationStatus == .authorized {
                    if !voiceCommandService.isListening {
                        try? voiceCommandService.startListening()
                    }
                    // Put in listening mode (not waiting for wake word)
                    voiceCommandService.enterConversationMode()
                } else {
                    errorMessage = "Speech recognition not authorized"
                }

            } catch {
                errorMessage = "Failed to connect: \(error.localizedDescription)"
                isSessionActive = false
                agentState = .idle
            }
        }
    }

    /// Resume listening after a spoken response ends — camera and text commands end identically:
    /// the persistent audio engine keeps running through a capture (never torn down — a rebuild
    /// would force a fresh Bluetooth HFP negotiation the glasses can't service right after
    /// streaming, leaving the mic deaf). Conversation mode's silence timeout then returns to idle.
    private func resumeListeningAfterSpeaking() {
        voiceCommandService.enterConversationMode()
    }

    /// Apply the preferred audio route: the glasses' Bluetooth mic + speaker when the user wants it
    /// and they're the connected audio device, otherwise the phone's built-in mic + loud speaker.
    /// Attempting glasses is what makes iOS expose the HFP mic — so we try it directly rather than
    /// pre-checking availability (which can't see HFP until it's allowed). Returns true on glasses.
    @discardableResult
    private func applyPreferredAudioRoute() -> Bool {
        // Never pick the glasses HFP mic while the camera is streaming: video saturates the
        // Bluetooth link, so the SCO audio channel can't be serviced. configureForGlasses() can
        // still "succeed" in that state, but the mic is deaf — commands are never transcribed
        // (seen when recording starts the stream before a wake-word session). Phone mic instead.
        if settingsManager.settings.preferGlassesMic, glassesManager.isRegistered,
           !glassesManager.isStreaming,
           (try? AudioSessionManager.shared.configureForGlasses()) == true {
            return true
        }
        // Glasses mic off, glasses not connected as audio, or no HFP input available → phone.
        // Loud speaker so spoken replies are audible (not the quiet earpiece).
        ovLog("[VoiceAgent] Using iPhone mic + speaker (glasses mic off or unavailable)")
        try? AudioSessionManager.shared.configureForPhone()
        return false
    }

    private func configureAudioForGlasses() {
        // If we're already on the glasses' Bluetooth (HFP) route and still listening, do NOT tear
        // the audio session down and re-activate it. That re-activation renegotiates the HFP SCO
        // link, which the glasses render as a "Bluetooth connecting/closing" blip — heard on every
        // wake after the first (the route stays on HFP between sessions, so the re-config is pure
        // churn). Skipping it keeps SCO stable, so the wake chime plays cleanly each time.
        if settingsManager.settings.preferGlassesMic, glassesManager.isRegistered,
           !glassesManager.isStreaming,   // HFP is deaf while the camera streams — reconfigure to phone
           AudioSessionManager.shared.isBluetoothHFPActive, voiceCommandService.isListening {
            return
        }
        let wasListening = voiceCommandService.isListening
        if wasListening { voiceCommandService.stopListening() }
        applyPreferredAudioRoute()
        if wasListening {
            try? voiceCommandService.startListening()
        }
    }

    func stopSession() {
        // If in live video mode, stop it first
        if isLiveVideoMode {
            Task {
                await stopLiveVideoMode()
            }
        }

        Task {
            switch settingsManager.settings.aiBackend {
            case .openClaw:
                await OpenClawService.shared.disconnect()
            case .geminiLive:
                await GeminiLiveService.shared.disconnect()
            case .openAI:
                break   // stateless HTTP — nothing to disconnect
            case .appleFoundation:
                break   // OS-managed — nothing to disconnect
            case .localGemma:
                // Keep the on-device model loaded — see note in the .idle handler. Reloading it
                // per conversation was what made "Ok Vision" slow/flaky.
                break
            }

            // Stop glasses streaming (turns off LED)
            if glassesManager.isStreaming {
                ovLog("[VoiceAgent] Stopping glasses stream...")
                await glassesManager.stopStreaming()
            }
        }

        // Stop any ongoing TTS
        ttsService.stop()
        KokoroTTSService.shared.stop()

        // Set session inactive FIRST to prevent callbacks from processing
        isSessionActive = false
        agentState = .idle

        // Handle voice command service based on wake word setting
        if settingsManager.settings.wakeWordEnabled {
            // Exit conversation mode but keep listening for wake word
            voiceCommandService.exitConversationMode()
        } else {
            // Wake word disabled - stop listening entirely to prevent
            // processing speech after session ends
            voiceCommandService.stopListening()
        }
        userTranscript = ""
        aiTranscript = ""
        currentToolName = nil
        isLiveVideoMode = false
        liveModel = nil
    }

    /// AUR-760: the phone's own mic gets a modest boost (a normal voice from ~1 m came in around
    /// −40 dBFS — Anton had to shout across the room); the glasses mic is left alone.
    private func applyInputGain(for routeTag: String) {
        audioCapture.inputGain = routeTag.hasSuffix("phone-mic") ? AudioCaptureService.phoneMicGain : 1
    }

    /// Full stop for "Ok Vision stop": silence all output, cancel any in-flight generation, and go
    /// quiet back to wake-word listening. The recognizer buffer is already reset by
    /// VoiceCommandService (so the stale transcript can't re-fire); here we just halt + end the turn.
    private func performFullStop() {
        ttsService.stop()
        KokoroTTSService.shared.stop()
        audioPlayback.stop()
        ttsStreaming = false

        Task {
            switch settingsManager.settings.aiBackend {
            case .openClaw: await OpenClawService.shared.interrupt()
            case .geminiLive: await GeminiLiveService.shared.interrupt()
            case .openAI: break   // single request/response — nothing to interrupt
            case .appleFoundation: AppleFoundationService.shared.interrupt()
            case .localGemma: GemmaLocalService.shared.interrupt()
            }
        }

        if isLiveVideoMode {
            Task { await stopLiveVideoMode() }
        }

        // Go quiet: end the turn, return to wake-word idle. Say "Ok Vision" to start again.
        userTranscript = ""
        aiTranscript = ""
        currentToolName = nil
        isSessionActive = false
        agentState = .idle
    }

    // MARK: - Voice Command Setup

    /// Warm up the on-device model in the background so the FIRST "Ok Vision" is instant
    /// (no multi-second load on wake). Only when Local Gemma is the selected, downloaded backend.
    private func preloadLocalModelIfNeeded() {
        guard settingsManager.settings.aiBackend == .localGemma,
              settingsManager.settings.localGemmaModelReady else { return }
        Task {
            do {
                try await GemmaLocalService.shared.connect(modelId: settingsManager.settings.localGemmaModelId)
                ovLog("[VoiceAgent] Local model preloaded — wake word will be instant")
            } catch {
                ovLog("[VoiceAgent] Local model preload failed: \(error.localizedDescription)")
            }
        }
    }

    /// Request speech recognition authorization
    func requestSpeechAuthorization() async {
        guard !hasRequestedSpeechAuth else { return }
        hasRequestedSpeechAuth = true

        let authorized = await voiceCommandService.requestAuthorization()
        if authorized {
            ovLog("[VoiceAgent] Speech recognition authorized")
            startWakeWordListening()
        } else {
            ovLog("[VoiceAgent] Speech recognition not authorized")
            errorMessage = "Speech recognition not authorized. Please enable in Settings."
        }
    }

    /// Setup voice command service callbacks
    private func setupVoiceCommandService() {
        ovLog("[VoiceAgent] Setting up voice command callbacks")

        // Allow wake word to interrupt TTS (for "ok vision stop")
        voiceCommandService.shouldAllowInterrupt = { [weak self] in
            self?.ttsService.isSpeaking ?? false
        }

        // Wake word detected
        voiceCommandService.onWakeWordDetected = { [weak self] in
            guard let self else { return }
            ovLog("[VoiceAgent] Wake word detected!")
            HapticFeedback.medium()
            // AUR-773: when the wake word opens the realtime call, the START earcon (played in
            // the call's own route once the rig is up) IS the "I'm listening" beep — Meta-style,
            // ONE sound, not chime + tone. The chime stays for push-to-ask and when call sounds
            // are off.
            let opensCall = !self.isLiveVideoMode && !self.isSessionActive && self.canStartTalkMode
            if !(opensCall && self.settingsManager.settings.callSoundsEnabled) {
                self.soundService.playWakeWordSound()
            }

            // If TTS is speaking, stop it immediately (interrupt)
            if self.ttsService.isSpeaking {
                ovLog("[VoiceAgent] Stopping TTS due to wake word interrupt")
                self.ttsService.stop()
                self.ttsStreaming = false   // keep flag in sync with the cleared stream
                KokoroTTSService.shared.stop()
                self.audioPlayback.stop()
                // Cancel any in-flight on-device generation too — otherwise its next streamed
                // token would immediately restart speech we just stopped.
                GemmaLocalService.shared.interrupt()
                self.agentState = .listening
            }

            // AUR-742a: the wake word is the DOOR TO THE CONVERSATION, not to push-to-ask.
            // «Аурелия» now opens the same audio-only realtime session the orb tap opens (camera
            // off, no «включи видео» needed). Push-to-ask survives only behind the long-press and
            // its own button, and as the fallback when no realtime backend is configured.
            // Known gap, deliberate: speech in the SAME breath as the wake word is dropped —
            // the session needs ~1 s to come up. The 2 s pre-roll that fixes it is AUR-743.
            Task { @MainActor in
                if self.isLiveVideoMode || self.isSessionActive { return }
                if self.canStartTalkMode {
                    ovLog("[VoiceAgent] Wake word → opening the realtime conversation (audio-only)")
                    await self.startLiveVideoMode()
                } else if self.settingsManager.settings.isCurrentBackendConfigured {
                    ovLog("[VoiceAgent] Wake word → push-to-ask (no realtime backend configured)")
                    self.startSession()
                }
            }
        }

        // "Ok Vision stop" during a reply → full stop, go quiet (the recognizer is already reset
        // to wake-word idle by VoiceCommandService; here we just halt output + end the turn).
        voiceCommandService.onStopCommand = { [weak self] in
            ovLog("[VoiceAgent] Full stop requested")
            self?.performFullStop()
        }

        // Command captured
        voiceCommandService.onCommandCaptured = { [weak self] (command: String) in
            guard let self else { return }
            ovLog("[VoiceAgent] Command captured: \(command)")

            // IMPORTANT: Only process commands when session is active
            // This prevents processing stale commands after session ends
            guard self.isSessionActive else {
                ovLog("[VoiceAgent] Ignoring command - session not active")
                return
            }

            self.userTranscript = command

            // History: every captured command is a user message (Meta AI records all glasses
            // prompts to its History tab; same idea, on-device).
            ConversationManager.shared.addUserMessage(command)
            self.historyAwaitingReply = true

            // Send command to AI backend
            Task {
                await self.sendCommand(command)
            }
        }

        // Barge-in (user interrupts AI)
        voiceCommandService.onInterruption = { [weak self] in
            guard let self else { return }
            ovLog("[VoiceAgent] Barge-in detected")

            // Stop TTS immediately
            self.ttsService.stop()
            KokoroTTSService.shared.stop()

            // Stop current AI response
            Task {
                switch self.settingsManager.settings.aiBackend {
                case .openClaw:
                    await OpenClawService.shared.interrupt()
                case .geminiLive:
                    await GeminiLiveService.shared.interrupt()
                case .openAI:
                    break   // single request/response — nothing to interrupt
                case .appleFoundation:
                    AppleFoundationService.shared.interrupt()
                case .localGemma:
                    GemmaLocalService.shared.interrupt()
                }
            }
        }

        // Conversation timeout (user didn't speak after AI response)
        voiceCommandService.onConversationTimeout = { [weak self] in
            guard let self else { return }
            // In live video mode, silence must not end the session — the .idle state handler
            // re-arms conversation mode so the user can keep asking until they say "stop video".
            if self.isLiveVideoMode {
                ovLog("[VoiceAgent] Conversation timeout during live video — staying live")
                return
            }
            ovLog("[VoiceAgent] Conversation timeout - returning to idle")
            self.stopSession()
        }

        // Setup AI service callbacks for responses
        setupAIServiceCallbacks()

        ovLog("[VoiceAgent] Voice command callbacks setup complete")
    }

    /// Setup AI service callbacks for receiving responses
    private func setupAIServiceCallbacks() {
        // Shared reply/state wiring — every AIBackend reports through the same two callbacks,
        // so wire them once for all. (Gemini Live is a streaming session and delivers replies
        // via its own transcription callbacks below; its protocol callbacks are inert.)
        for backend in AIBackendRegistry.all {
            backend.onAgentMessage = { [weak self] (message: String) in
                guard let self else { return }
                // In local live video mode replies must flow even if the session timer lapsed
                // while the user was silently looking around.
                guard self.isSessionActive || self.isLiveVideoMode else { return }
                self.aiTranscript = message
                if self.ttsStreaming {
                    // A streamed utterance is open (local model + Apple TTS pipelining):
                    // flush the unspoken tail and close the session.
                    self.feedStreamingSpeech(message, isFinal: true)
                } else {
                    self.speakResponse(message)
                }
            }
            backend.onProcessingChanged = { [weak self] (isProcessing: Bool) in
                guard let self else { return }
                if isProcessing {
                    self.agentState = .thinking
                    // New reply: reset the sentence-streaming cursor for a clean start.
                    self.ttsStreaming = false
                    self.ttsStreamSpokenChars = 0
                } else {
                    // Generation ended (always fires via defer, even when interrupted/superseded).
                    // If a streamed utterance is still open, onAgentMessage never fired to close it —
                    // close it here so streamingActive/isSpeaking don't stick true and freeze the
                    // wake-word listener (queued sentences still drain and reset isSpeaking).
                    if self.ttsStreaming {
                        self.ttsService.endStreaming()
                        self.ttsStreaming = false
                    }
                    if self.agentState == .thinking && !self.ttsService.isSpeaking {
                        // Return to the live video indicator, not plain listening, while in live mode.
                        self.agentState = self.isLiveVideoMode ? .liveVideo
                            : (self.isSessionActive ? .listening : .idle)
                    }
                }
            }
        }

        // Local Gemma extra: token streaming (pipelines Apple TTS behind generation).
        GemmaLocalService.shared.onPartialResponse = { [weak self] (partial: String) in
            guard let self else { return }
            guard self.isSessionActive || self.isLiveVideoMode else { return }
            // Show tokens as they stream so it doesn't look stuck on "thinking".
            self.aiTranscript = partial
            // Apple TTS: start speaking completed sentences as they arrive (pipeline speech
            // behind generation) instead of waiting for the whole reply. Big perceived speedup,
            // and Apple TTS isn't on the GPU so it doesn't fight the on-device model.
            if self.usingAppleTTS { self.feedStreamingSpeech(partial, isFinal: false) }
        }

        // OpenAI extra: SSE token streaming, same contract as Gemma's (cumulative text). Lets the
        // cloud backend start speaking the first sentence while the rest is still generating.
        OpenAIService.shared.onPartialResponse = { [weak self] (partial: String) in
            guard let self else { return }
            guard self.isSessionActive || self.isLiveVideoMode else { return }
            self.aiTranscript = partial
            if self.usingAppleTTS { self.feedStreamingSpeech(partial, isFinal: false) }
        }

        // OpenClaw extras: tool status + device-side tool calls.
        OpenClawService.shared.onToolStatusChanged = { [weak self] (toolName: String?, isRunning: Bool) in
            guard let self else { return }
            ovLog("[VoiceAgent] Tool status: \(toolName ?? "none"), running: \(isRunning)")
            self.currentToolName = toolName
            if isRunning {
                self.agentState = .toolRunning
            }
        }

        // Handle tool calls (e.g., take_photo)
        OpenClawService.shared.onToolCall = { [weak self] (toolName: String, args: [String: Any], completion: @escaping (String) -> Void) in
            guard let self else { return }
            ovLog("[VoiceAgent] Tool call: \(toolName) with args: \(args)")

            switch toolName {
            case "take_photo", "capture_photo", "take_picture":
                // Capture photo from glasses
                Task { @MainActor in
                    await self.handleTakePhotoTool(completion: completion)
                }

            case "describe_scene", "what_do_you_see", "look":
                // Query Gemini Vision for scene description
                Task { @MainActor in
                    await self.handleDescribeSceneTool(args: args, completion: completion)
                }

            default:
                ovLog("[VoiceAgent] Unknown tool: \(toolName)")
                completion("Tool '\(toolName)' is not available on this device.")
            }
        }

        // Gemini Live callbacks (for Gemini Live mode, not hybrid)
        GeminiLiveService.shared.onOutputTranscription = { [weak self] (text: String) in
            self?.aiTranscript = text
        }

        GeminiLiveService.shared.onTurnComplete = { [weak self] in
            guard let self else { return }
            self.agentState = self.isSessionActive ? .listening : .idle
            self.voiceCommandService.enterConversationMode()
            // History: persist this Gemini Live exchange (transcript only, no frames).
            self.recordLiveTurn()
        }
    }

    /// Start listening for wake word
    private func startWakeWordListening() {
        guard settingsManager.settings.wakeWordEnabled else { return }
        guard voiceCommandService.authorizationStatus == .authorized else { return }

        // Configure audio for glasses before starting to listen
        configureAudioForGlasses()

        do {
            try voiceCommandService.startListening()
            isVoiceReady = true
            ovLog("[VoiceAgent] Started wake word listening - READY")
        } catch {
            ovLog("[VoiceAgent] Failed to start listening: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Command routing

    /// Send command to AI backend
    private func sendCommand(_ command: String) async {
        let lowerCommand = command.lowercased()

        // Check for "stop" command - stops TTS and waits for next command
        let stopKeywords = ["stop", "be quiet", "shut up", "silence", "quiet", "enough", "ok stop", "okay stop",
                            // ru-RU STT hears Cyrillic — Russian stop words (Margo, 2026-08-16)
                            "стоп", "хватит", "замолчи", "тихо", "остановись", "перестань", "прекрати", "молчи", "достаточно"]
        let isStopCommand = stopKeywords.contains { lowerCommand.contains($0) } &&
                           !lowerCommand.contains("video") && !lowerCommand.contains("stream")
                           && !lowerCommand.contains("видео") && !lowerCommand.contains("стрим")

        if isStopCommand {
            ovLog("[VoiceAgent] Stop command detected - full stop")
            performFullStop()
            return
        }

        // Check for live video mode commands
        let startLiveKeywords = ["start video stream", "start live video", "start video", "start streaming",
                                 "enable video", "live mode", "go live", "video mode",
                                 // ru-RU STT (Apple) transcribes Cyrillic — accept Russian equivalents.
                                 "начни видео", "включи видео", "запусти видео", "старт видео", "видео режим",
                                 "лайв режим", "живой режим", "видео стрим", "включи стрим", "начни стрим"]

        let isStartLiveCommand = startLiveKeywords.contains { lowerCommand.contains($0) }
        // Fuzzy stop match: any "video"/"stream" phrase with a stop-like word. Tolerates Apple STT
        // dropping the leading 's' ("stop video" → "top video"), which previously sailed past the
        // exact-keyword list and got sent to the model as a question instead of ending the mode.
        let mentionsVideo = lowerCommand.contains("video") || lowerCommand.contains("stream")
            || lowerCommand.contains("видео") || lowerCommand.contains("стрим")
        let stopWords = ["stop", "top ", "end ", "exit", "disable", "close", "quit", "turn off",
                         "стоп", "останови", "выключи", "заверши", "закрой", "хватит"]
        let isStopLiveCommand = mentionsVideo && stopWords.contains { lowerCommand.contains($0) }

        // Handle live video mode commands
        if isStartLiveCommand {
            ovLog("[VoiceAgent] Starting live video mode...")
            await startLiveVideoMode()
            return
        }

        if isStopLiveCommand {
            ovLog("[VoiceAgent] Stopping live video mode...")
            await stopLiveVideoMode()
            return
        }

        // If in live video mode, route by which live backend is driving it.
        if isLiveVideoMode {
            if activeLiveService == nil {
                // Local (SmolVLM2) live mode: STT is the input path, so every command lands here.
                // Answer it against the latest glasses frame.
                await handleLocalLiveVideoCommand(command)
            } else if activeLiveService === geminiLive {
                // Cloud modes stream audio directly, so this shouldn't be reached — but Gemini
                // can accept a text turn as a fallback. OpenAI Realtime is audio-only here.
                do {
                    try await geminiLive.sendText(command)
                } catch {
                    ovLog("[VoiceAgent] Failed to send to Gemini Live: \(error)")
                }
            }
            return
        }

        // Drop only EXACT-duplicate commands fired within a few seconds. The speech
        // recognizer can emit the same phrase twice (partial + final), which double-fired
        // photo capture. A *different* follow-up question must still go through, even while
        // the previous answer is generating/speaking.
        let now = Date()
        if command == lastProcessedCommand, now.timeIntervalSince(lastProcessedAt) < 4 {
            ovLog("[VoiceAgent] Ignoring duplicate command within 4s: \(command)")
            return
        }
        lastProcessedCommand = command
        lastProcessedAt = now

        // Face recognition on CLOUD backends: classify via the on-device model (if loaded) up front.
        // On the Local backend we DON'T do this — routing is merged into the single generation below
        // so we never run two Gemma generations per command (memory/jetsam).
        if settingsManager.settings.aiBackend != .localGemma {
            if await handleFaceCommandIfNeeded(command) {
                agentState = isSessionActive ? .listening : .idle
                return
            }
        }

        agentState = .thinking

        // Check if this is a vision-related command
        // Keywords for "take a photo" - capture and send to OpenClaw
        let photoKeywords = ["take a photo", "take a picture", "take photo", "take picture",
                            "capture a photo", "capture photo", "snap a photo", "snap a picture",
                            "what do you see", "what are you looking at", "look at this",
                            "what's in front of me", "describe what you see", "what is this",
                            "what am i looking at", "can you see"]

        let isPhotoCommand = photoKeywords.contains { lowerCommand.contains($0) }

        // Drive whichever backend is selected through the AIBackend protocol — capabilities
        // (localLLM, supportsImageInput) decide the path, not concrete service types.
        let backend = AIBackendRegistry.backend(for: settingsManager.settings.aiBackend)
        do {
            if let llm = backend.localLLM {
                // On-device routing brain (Gemma / Apple Intelligence): one generation that
                // routes faces, web search, native tools, or answers.
                await handleLocalCommand(command, llm: llm, isPhotoCommand: isPhotoCommand)
            } else if isPhotoCommand && backend.supportsImageInput {
                ovLog("[VoiceAgent] Photo command on \(backend.backendType.displayName) — capturing...")
                await captureAndSendPhoto(withPrompt: command)
            } else {
                try await backend.sendMessage(command, imageData: nil)
            }
            // OpenAI is plain request/response with no session to keep "thinking" alive —
            // restore the listening state inline. The others restore via their callbacks.
            if backend.backendType == .openAI {
                agentState = isSessionActive ? .listening : .idle
            }
        } catch {
            errorMessage = "Failed to send command: \(error.localizedDescription)"
            agentState = isSessionActive ? .listening : .idle
        }
    }

    // MARK: - Live Video Mode

    /// Start live video mode - Gemini handles both audio and video
    private func startLiveVideoMode() async {
        guard !isLiveVideoMode else {
            ovLog("[VoiceAgent] Already in live video mode")
            return
        }

        // AUR-723: the realtime conversation is AUDIO-first — the camera is an optional add-on.
        // Requiring DAT-registered glasses here is what kept the full-duplex path from ever being
        // exercised (plan fault B10); the gate stays for the video-only backends below.
        let realtimeAudioPath = settingsManager.settings.aiBackend == .openAI
            && settingsManager.settings.isOpenAIConfigured
        guard glassesManager.isRegistered || realtimeAudioPath else {
            ttsService.speak("Please connect your glasses first")
            return
        }

        // Fully on-device live video: with SmolVLM2 loaded as the local backend, keep the glasses
        // camera streaming and answer each spoken question against the latest frame. No cloud,
        // no WebSocket — Apple STT keeps listening and the reply is spoken via the selected TTS.
        if settingsManager.settings.aiBackend == .localGemma && GemmaLocalService.shared.visionReady {
            await startLocalLiveVideoMode()
            return
        }

        // Pick the live backend: OpenAI Realtime when OpenAI is the selected + configured backend,
        // otherwise Gemini Live (the default video provider for every other backend).
        guard let (service, label) = resolveLiveService() else {
            ttsService.speak("Please configure your Gemini or OpenAI API key in settings")
            return
        }
        activeLiveService = service

        ovLog("[VoiceAgent] Starting live video mode via \(label)...")

        // AUR-772: say WHY when the mic is gone instead of failing silently three steps later
        // ("Audio input node unavailable" with no hint). iOS can revoke it behind our back.
        guard AudioSessionManager.shared.recordPermissionGranted else {
            errorMessage = "Microphone access is off for OpenVision — enable it in Settings › Privacy › Microphone"
            ttsService.speak("I can't hear you — microphone access is off. Enable it in Settings.")
            ovLog("[VoiceAgent] ✗ Record permission not granted — not starting live mode")
            return
        }

        // Stop VoiceCommandService - the live backend will handle audio directly
        voiceCommandService.stopListening()

        // Stop TTS if speaking
        ttsService.stop()
        KokoroTTSService.shared.stop()

        // Match the audio pipeline to the backend's sample rates (Gemini 16k in / 24k out,
        // OpenAI 24k in / 24k out) before starting capture/playback.
        audioCapture.targetSampleRate = Double(service.inputSampleRate)
        audioCapture.chunkDurationMs = Constants.RealtimeAudio.captureFrameMs
        audioCapture.applyFormatSettings()
        audioPlayback.inputSampleRate = Double(service.outputSampleRate)

        // AUR-723: ONE `.playAndRecord` + `.voiceChat` session with voice-processing IO, so the
        // mic can stay open for the whole conversation without the reply echoing back into it.
        // The "glasses mic" setting still decides whether HFP is allowed (classic BT then drops
        // playback to HFP — the known robotic-voice trade-off, plan §4).
        let wantsGlassesMic = settingsManager.settings.preferGlassesMic
            && glassesManager.isRegistered
            && !glassesManager.isStreaming
        do {
            try AudioSessionManager.shared.configureFullDuplex(preferGlassesMic: wantsGlassesMic)
        } catch {
            ovLog("[VoiceAgent] Full-duplex audio session failed: \(error)")
        }
        // Bring the shared engine up BEFORE connecting: whether voice-processing IO actually
        // engaged is only known once it is running, and the `?aec=` hint is decided at upgrade
        // time (AUR-724b). `startSharedEngine` is idempotent — the call further down reuses this.
        // AUR-772: right after a hang-up the previous VPIO unit may still be releasing; one retry
        // after a short settle covers that. If the engine still has no mic, stop HERE with a
        // clear error instead of connecting a session that can never hear.
        var engineError: Error?
        for attempt in 1...2 {
            do {
                _ = try AudioSessionManager.shared.startSharedEngine(voiceProcessing: true)
                engineError = nil
                break
            } catch {
                engineError = error
                ovLog("[VoiceAgent] Shared engine start failed (attempt \(attempt)): \(error)")
                AudioSessionManager.shared.stopSharedEngine()
                try? await Task.sleep(nanoseconds: 300_000_000)
                try? AudioSessionManager.shared.configureFullDuplex(preferGlassesMic: wantsGlassesMic)
            }
        }
        if let engineError {
            errorMessage = "Microphone unavailable: \(engineError.localizedDescription)"
            ttsService.speak("I can't open the microphone right now. Try again in a moment.")
            AudioSessionManager.shared.endRealtimeRig()
            activeLiveService = nil
            applyPreferredAudioRoute()
            if isSessionActive || settingsManager.settings.wakeWordEnabled {
                try? voiceCommandService.startListening()
                if isSessionActive { voiceCommandService.enterConversationMode() }
            }
            return
        }
        liveRoute = AudioSessionManager.shared.routeInfo.tag
        openAIRealtime.routeTag = liveRoute
        openAIRealtime.aecActive = AudioSessionManager.shared.clientAECActive
        applyInputGain(for: liveRoute)
        ovLog("[VoiceAgent] Live audio rig: \(liveRoute), client AEC: \(openAIRealtime.aecActive), input gain: \(audioCapture.inputGain)")

        // AUR-773: the START earcon — the rig is up on the call's route (HFP when the glasses are
        // on), so the cue rides the same stream the conversation will. Not awaited: it plays while
        // the socket connects, so it feels instant after «Аурелия» and the session is usually up
        // by the time it fades. Replaces the spoken "Live video mode active".
        Task { await CallEarconService.shared.play(.callStart, on: AudioSessionManager.shared.sharedEngine) }

        // AUR-757: the conversation starts AUDIO-ONLY even with DAT glasses registered and
        // connected — the glasses camera is NOT started here any more (it used to be, "only when
        // they're actually there"). The eye opens later, on explicit intent, via
        // `setLiveCamera(true)` → `updateLiveCameraSource()`, glasses-first. A stream that is
        // already running for some other reason is left alone here (a POV recording owns it);
        // frames only reach the backend once the eye is asked for (see `onVideoFrame` below).

        // Connect to the live backend
        do {
            try await service.connect()
        } catch {
            errorMessage = "Failed to connect to \(label): \(error.localizedDescription)"
            activeLiveService = nil
            // Cleanup: stop streaming and restart voice commands
            if glassesManager.isStreaming {
                await glassesManager.stopStreaming()
            }
            do {
                try voiceCommandService.startListening()
                voiceCommandService.enterConversationMode()
            } catch {
                ovLog("[VoiceAgent] Failed to restart voice commands: \(error)")
            }
            return
        }

        // Setup live backend callbacks
        setupLiveVideoCallbacks(service)
        // AUR-759: `connect()` returned after `session.created`, so the resolved model is known.
        liveModel = (service as? OpenAIRealtimeService)?.activeModel

        // Setup audio capture → live backend (continuous: no isModelSpeaking gate any more).
        // AUR-776: the same frames are tee'd to the listen-mode backup writer (no-op otherwise).
        audioCapture.onAudioCaptured = { [weak service, weak self] data in
            service?.sendAudio(data: data)
            self?.voiceActions.appendMicAudio(data)
        }

        // ONE engine for capture + playback (AUR-723); route churn reinstalls the tap in place.
        let sharedEngine = try? AudioSessionManager.shared.startSharedEngine(voiceProcessing: true)
        AudioSessionManager.shared.onEngineConfigurationChange = { [weak self] in
            guard let self, self.isLiveVideoMode else { return }
            let engine = AudioSessionManager.shared.sharedEngine
            self.audioCapture.reconfigure(engine: engine)
            self.audioPlayback.reattachIfNeeded(engine: engine)
        }
        AudioSessionManager.shared.onRouteChange = { [weak self] info in
            guard let self else { return }
            self.liveRoute = info.tag
            self.openAIRealtime.routeTag = info.tag
            // A route that moves the mic to the glasses withdraws the AEC claim (and back again).
            self.openAIRealtime.aecActive = AudioSessionManager.shared.clientAECActive
            self.applyInputGain(for: info.tag)
        }

        // Setup audio playback (ring buffer with pause / flush / played-ms accounting)
        do {
            try audioPlayback.setup(engine: sharedEngine)
        } catch {
            ovLog("[VoiceAgent] Failed to setup audio playback: \(error)")
        }

        // The realtime service drives playback directly (item ids + barge-in flush); the legacy
        // backends keep going through `onAudioReceived`.
        if let realtime = service as? OpenAIRealtimeService {
            realtime.playback = audioPlayback
            // AUR-776: fast voice actions — the brain recognised «сфоткай» / "record a video" /
            // "listen": earcon first, then the device work, then the ack on the socket.
            voiceActions.host = self
            realtime.onAction = { [weak self, weak realtime] action in
                Task { @MainActor in
                    guard let self else { return }
                    let ack = await self.voiceActions.perform(action)
                    realtime?.sendActionAck(ack)
                }
            }
        }

        // Start audio capture
        do {
            try audioCapture.startCapture(engine: sharedEngine)
        } catch {
            errorMessage = "Failed to start audio capture: \(error.localizedDescription)"
            await service.disconnect()
            activeLiveService = nil
            voiceCommandService.enterConversationMode()
            return
        }

        // Setup video frame routing to the live backend. AUR-757: gated on `cameraRequested`, so
        // a glasses stream that runs for another reason (a POV recording) never feeds the brain
        // while she is supposed to be audio-only.
        glassesManager.onVideoFrame = { [weak self, weak service] image in
            guard let self, self.cameraRequested else { return }
            if let jpegData = image.jpegData(compressionQuality: 0.6) {
                service?.sendVideoFrame(imageData: jpegData)
            }
        }

        isLiveVideoMode = true
        agentState = .liveVideo

        // AUR-723b/AUR-757: glasses first, phone camera otherwise — and keep following that as
        // the glasses come and go mid-session. MUST run AFTER `isLiveVideoMode = true`:
        // `updateLiveCameraSource` guards on it, so touching the eye any earlier silently did
        // nothing (measured on the phone rig 2026-08-17 — `/admin/rt-sessions` showed the live
        // ru-RU session answering with 0 `vision:` lines).
        phoneCameraDeniedAnnounced = false
        // AUDIO-ONLY entry (principal rulings 2026-08-17 phone / 2026-08-18 glasses, AUR-757):
        // BOTH eyes stay shut until asked for.
        cameraRequested = false
        await updateLiveCameraSource()
        watchCameraSource()

        ovLog("[VoiceAgent] ✓ Live video mode active - \(label) handling audio + video")
        // AUR-773: no spoken announcement — the START earcon above is the cue.
    }

    /// Resolve which live-video backend to use, or nil if none is configured.
    /// - OpenAI selected + configured → OpenAI Realtime
    /// - otherwise Gemini if configured (default video provider), else OpenAI if configured.
    private func resolveLiveService() -> (service: any LiveVideoService, label: String)? {
        let settings = settingsManager.settings
        if settings.aiBackend == .openAI && settings.isOpenAIConfigured {
            return (openAIRealtime, "OpenAI Realtime")
        }
        if settings.isGeminiConfigured {
            return (geminiLive, "Gemini Live")
        }
        if settings.isOpenAIConfigured {
            return (openAIRealtime, "OpenAI Realtime")
        }
        return nil
    }

    /// Fully on-device live video (SmolVLM2). Unlike the cloud modes, audio stays on the normal
    /// Apple STT path — we just keep the glasses camera streaming and mark the mode active, so
    /// each spoken question is answered against the latest frame (see sendCommand). Replies
    /// speak through the selected TTS engine as usual.
    private func startLocalLiveVideoMode() async {
        ovLog("[VoiceAgent] Starting local live video mode (SmolVLM2)...")

        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        guard glassesManager.isStreaming else {
            ttsService.speak("I couldn't start the glasses camera")
            return
        }

        // The glasses' Bluetooth HFP mic can't run while their camera streams (it goes deaf —
        // the PR #15 lesson; photo mode survives because its stream is momentary). Live mode
        // streams continuously, so force the phone mic + speaker for the whole session and
        // rebuild recognition on that route. The preferred route is restored on stop.
        voiceCommandService.stopListening()
        try? AudioSessionManager.shared.configureForPhone()
        do {
            try voiceCommandService.startListening()
        } catch {
            ovLog("[VoiceAgent] Failed to restart STT on phone mic: \(error)")
        }

        // Stay in conversation mode so follow-ups don't need the wake word.
        voiceCommandService.enterConversationMode()

        isLiveVideoMode = true
        agentState = .liveVideo

        ovLog("[VoiceAgent] ✓ Local live video mode active - SmolVLM2 answering on latest frame")
        // AUR-773: same start cue as the realtime call (no shared rig here → private engine).
        Task { await CallEarconService.shared.play(.callStart, on: nil) }
    }

    /// Answer a spoken question in local live video mode using a fresh, settled glasses frame.
    private func handleLocalLiveVideoCommand(_ command: String) async {
        agentState = .thinking
        // Let head motion settle and grab the freshest frame, so we describe the CURRENT view
        // rather than a stale/motion-blurred one the Bluetooth stream delivered a beat ago.
        guard let frame = await freshestGlassesFrame(settle: 0.3, maxWait: 1.0),
              let jpeg = frame.jpegData(compressionQuality: 0.6) else {
            speakResponse("I couldn't get a clear view just now — hold still a second and ask again.")
            agentState = .liveVideo
            return
        }
        do {
            // Strip "take a photo"-style wording; the frame is already attached.
            let prompt = visionPromptFromCommand(command)
            try await GemmaLocalService.shared.sendMessage(prompt, imageData: jpeg)
        } catch {
            ovLog("[VoiceAgent] Local live video inference failed: \(error)")
            speakResponse("Sorry, that didn't work. \(error.localizedDescription)")
        }
        if isLiveVideoMode { agentState = .liveVideo }
    }

    /// Wait a brief `settle` for head motion to stop, then return the freshest camera frame that's
    /// genuinely recent (stream not stalled). Falls back to whatever frame we have after `maxWait`.
    /// This is the "current view, not a stale glimpse" grab for live video.
    private func freshestGlassesFrame(settle: TimeInterval, maxWait: TimeInterval) async -> UIImage? {
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            // Accept only a frame received within the last 500ms — under heavy motion the BT stream
            // throttles and lastFrame goes stale; wait for a fresh one instead of describing it.
            if Date().timeIntervalSince(glassesManager.lastFrameTime) < 0.5,
               let f = glassesManager.lastFrame {
                return f
            }
            try? await Task.sleep(nanoseconds: 80_000_000)   // 80ms poll
        }
        return glassesManager.lastFrame   // fallback: better an old frame than nothing
    }

    /// Stop live video mode
    private func stopLiveVideoMode() async {
        guard isLiveVideoMode else {
            ovLog("[VoiceAgent] Not in live video mode")
            return
        }

        ovLog("[VoiceAgent] Stopping live video mode...")

        // AUR-772: did the SERVER end this call after speaking its goodbye? Then the wearer has
        // already heard the conversation end, in the call's own route — no second announcement.
        let serverSaidGoodbye = (activeLiveService as? OpenAIRealtimeService)?.endedAfterFarewell == true

        // AUR-776: a voice-action recording (video / listen) ends with the call — finalise + save
        // BEFORE the glasses stream and the mic go down, then lift the local mute.
        await voiceActions.sessionEnded()
        openAIRealtime.onAction = nil
        audioPlayback.silenced = false

        // Stop audio capture
        audioCapture.stopCapture()
        audioCapture.onAudioCaptured = nil

        // Stop the phone camera + its watchers (AUR-723b)
        cameraSourceWatch.removeAll()
        phoneCamera.stop()
        cameraRequested = false
        liveCameraSource = .none

        // Stop audio playback (AUR-723). On the End pill this cuts a reply mid-word, by design;
        // on the server-close path the farewell has already drained (+ its playout tail).
        openAIRealtime.playback = nil
        audioPlayback.teardown()
        AudioSessionManager.shared.onEngineConfigurationChange = nil
        AudioSessionManager.shared.onRouteChange = nil

        // AUR-773: the END earcon — played through the rig that is STILL up, so it is heard in the
        // glasses, then the output-latency tail is drained before the route drops (the same lesson
        // as the AUR-772 farewell tail: rendered ≠ heard on HFP). Order on every exit path:
        //   server close: farewell → tail → END cue → tail → rig down
        //   End pill / stop phrase: (reply cut) → END cue → tail → rig down
        // Replaces the spoken "Live video mode ended" on all of them.
        if settingsManager.settings.callSoundsEnabled {
            await CallEarconService.shared.play(.callEnd, on: AudioSessionManager.shared.sharedEngine)
            let tail = AudioSessionManager.shared.playoutTailSeconds + 0.1
            try? await Task.sleep(nanoseconds: UInt64(tail * 1_000_000_000))
        }

        // Local live mode forced the phone mic (HFP dies during camera streaming) and its STT
        // may still be running — stop it BEFORE the session is deactivated, so nothing holds IO.
        if voiceCommandService.isListening { voiceCommandService.stopListening() }
        // AUR-772: engine off (VPIO disabled, reset) AND the session deactivated — a clean end
        // of the rig, so the next Talk reconfigures from scratch instead of inheriting a
        // half-released HFP/VPIO IO (the "no mic until relaunch" symptom).
        AudioSessionManager.shared.endRealtimeRig()

        // Disconnect the active live backend (Gemini or OpenAI Realtime)
        await activeLiveService?.disconnect()
        activeLiveService = nil

        // Stop glasses streaming
        if glassesManager.isStreaming {
            await glassesManager.stopStreaming()
        }

        // Restore video frame callback to Gemini Vision
        glassesManager.onVideoFrame = { [weak self] image in
            self?.geminiVision.sendVideoFrame(image)
        }

        isLiveVideoMode = false
        agentState = isSessionActive ? .listening : .idle

        // AUR-772: the mic is re-armed only when something still wants it — a live session or the
        // wake word. With both off the capture really stops (and the orange dot goes away); the
        // old unconditional restart kept the mic open after every call for nothing.
        let wantsMic = isSessionActive || settingsManager.settings.wakeWordEnabled
        if wantsMic {
            applyPreferredAudioRoute()
            do {
                try voiceCommandService.startListening()
                if isSessionActive {
                    // Continue conversation mode if session was active
                    voiceCommandService.enterConversationMode()
                    ovLog("[VoiceAgent] Restarted voice commands in conversation mode")
                } else {
                    // Just listen for wake word
                    ovLog("[VoiceAgent] Restarted voice commands for wake word detection")
                }
            } catch {
                ovLog("[VoiceAgent] Failed to restart voice commands: \(error)")
            }
        } else {
            ovLog("[VoiceAgent] Mic released after live mode (no session, wake word off)")
        }

        ovLog("[VoiceAgent] Live video mode stopped (server said goodbye: \(serverSaidGoodbye))")
        // AUR-773: no spoken "ended" on any path — the END earcon above (played before the rig
        // went down, in the call's route) is the cue. The brain's own goodbye precedes it on the
        // server-close path.
    }

    // MARK: - Talk mode entry (AUR-742a)

    /// ONE TAP into the realtime conversation — the same audio-first path «включи видео» takes,
    /// without the phrase. The camera stays an optional add-on inside the session (AUR-723b), so
    /// this is an AUDIO entry: no glasses required, no video wording.
    func toggleTalkMode() {
        Task { @MainActor in
            if isLiveVideoMode {
                await stopLiveVideoMode()
            } else {
                await startLiveVideoMode()
            }
        }
    }

    /// True when a one-tap Talk session can be opened (the realtime backend is configured).
    var canStartTalkMode: Bool {
        let s = settingsManager.settings
        return (s.aiBackend == .openAI && s.isOpenAIConfigured) || s.isGeminiConfigured || s.isOpenAIConfigured
    }

    // MARK: - Live camera source (AUR-723b / AUR-742a / AUR-757)

    /// The glasses can serve as the eye right now: DAT-registered AND a device is connected
    /// (`startStreaming()` refuses without both). Registration alone is not enough — the Gen 2
    /// pair is often registered but in its case.
    var glassesEyeAvailable: Bool {
        glassesManager.isRegistered && glassesManager.connectedDevice != nil
    }

    /// Reconcile the eye with the wearer's intent. Nothing is requested → NO eye: the phone
    /// camera is stopped and a glasses stream we opened is stopped (LED off). Requested → the
    /// glasses when they are available (start their stream if needed), the iPhone's rear camera
    /// otherwise. Frames go down the SAME path either way (`sendVideoFrame` → `input_image`
    /// item), so the brain sees no difference. Re-entrant-safe: it is re-run from the
    /// `$isStreaming` / `$isRegistered` watchers and after every await it re-reads the intent.
    private func updateLiveCameraSource() async {
        guard isLiveVideoMode, activeLiveService != nil else { return }

        // The pure decision lives in `LiveEyePlan` (unit-tested); this is the side-effect half.
        switch LiveEyePlan.decide(requested: cameraRequested,
                                  glassesAvailable: glassesEyeAvailable,
                                  glassesStreaming: glassesManager.isStreaming) {
        case .off:
            // No explicit request → no eye. A session that opened audio-only stays audio-only
            // (AUR-742a phone, AUR-757 glasses).
            if phoneCamera.isRunning { phoneCamera.stop() }
            if glassesManager.isStreaming, !isRecording {
                await glassesManager.stopStreaming()   // LED off; the server stops receiving frames
            }
            if liveCameraSource != .none {
                liveCameraSource = .none
                ovLog("[VoiceAgent] Live eye: off (audio-only)")
            }
            return

        case .glasses(let startStream):
            if startStream {
                await glassesManager.startStreaming()
                // The wearer may have dismissed the eye while the stream was coming up.
                guard cameraRequested, isLiveVideoMode else {
                    if glassesManager.isStreaming, !isRecording { await glassesManager.stopStreaming() }
                    return
                }
            }
            if glassesManager.isStreaming {
                if phoneCamera.isRunning { phoneCamera.stop() }
                if liveCameraSource != .glasses {
                    liveCameraSource = .glasses
                    ovLog("[VoiceAgent] Live eye: glasses")
                }
                return
            }
            ovLog("[VoiceAgent] Glasses eye requested but the stream did not start — falling back to the phone camera")
            await startPhoneEye()

        case .phone:
            await startPhoneEye()
        }
    }

    /// The phone half of the eye (AUR-723b). Only ever called with `cameraRequested == true`.
    private func startPhoneEye() async {
        guard let service = activeLiveService else { return }
        if phoneCamera.isRunning {
            liveCameraSource = .phone
            return
        }

        // Same 1 fps preference the glasses path uses.
        phoneCamera.framesPerSecond = Double(max(1, settingsManager.settings.geminiVideoFPS))
        phoneCamera.onFrame = { [weak service] image in
            if let jpegData = image.jpegData(compressionQuality: 0.6) {
                service?.sendVideoFrame(imageData: jpegData)
            }
        }
        switch await phoneCamera.start() {
        case .started:
            guard cameraRequested, isLiveVideoMode else { phoneCamera.stop(); return }
            liveCameraSource = .phone
            ovLog("[VoiceAgent] Live eye: phone camera (no glasses available)")
        case .denied:
            liveCameraSource = .none
            announcePhoneCameraUnavailable("I can't see anything right now — camera access is off for OpenVision. Turn it on in Settings › OpenVision › Camera.")
        case .unavailable(let why):
            liveCameraSource = .none
            announcePhoneCameraUnavailable("I can't open the camera right now (\(why)), so I'm listening only.")
        }
    }

    /// State it once per live session, as assistant text — never per frame, never a crash.
    private func announcePhoneCameraUnavailable(_ message: String) {
        guard !phoneCameraDeniedAnnounced else { return }
        phoneCameraDeniedAnnounced = true
        aiTranscript = message
        errorMessage = message
        ovLog("[VoiceAgent] Phone camera unavailable: \(message)")
    }

    /// Explicit camera intent — the live UI's toggle and the in-session voice commands. Source-
    /// agnostic: "open the eye" means the glasses when they are there, the phone otherwise
    /// (AUR-757); "shut the eye" stops whichever one is running.
    func setLiveCamera(_ on: Bool) {
        guard isLiveVideoMode else { return }
        guard cameraRequested != on else { return }
        cameraRequested = on
        ovLog("[VoiceAgent] Camera \(on ? "requested" : "dismissed") by the wearer (glasses available: \(glassesEyeAvailable))")
        Task { @MainActor in await updateLiveCameraSource() }
    }

    func toggleLiveCamera() { setLiveCamera(!cameraRequested) }

    /// Inside a session «включи камеру/видео» and «выключи камеру/видео» toggle the EYE, they no
    /// longer switch modes — the conversation itself is entered by tap or wake word (AUR-742a).
    /// Returns true when the utterance was a camera command (so it is not treated as a question).
    @discardableResult
    private func handleCameraCommand(_ text: String) -> Bool {
        let t = text.lowercased()
        // AUR-776: CAMERA words only. "video" words («включи видео» / "start video" / "stop
        // video") now mean RECORDING and are the brain's call (`aurelia.action video.start/stop`),
        // so they are no longer interpreted here — three camera modes: eye-only (these phrases),
        // video.silent, video.assist (recording + this same eye).
        let off = ["выключи камеру", "останови камеру", "стоп камера", "стоп камеру", "убери камеру",
                   "закрой камеру", "camera off", "turn off camera", "stop camera", "stop the camera",
                   "close camera", "close the camera"]
        let on = ["включи камеру", "покажи камеру", "открой камеру",
                  "camera on", "turn on camera", "start camera", "show camera", "open camera",
                  "open the camera"]
        if off.contains(where: { t.contains($0) }) { setLiveCamera(false); return true }
        if on.contains(where: { t.contains($0) }) { setLiveCamera(true); return true }
        return false
    }

    /// Follow glasses registration/connection/streaming while live so a REQUESTED eye switches
    /// without a restart (glasses drop → phone; glasses arrive → glasses). While the eye is not
    /// requested the watchers stay hands-off (AUR-757): a stream some other feature opened (a POV
    /// recording) is neither adopted as the eye nor shut down by them.
    private func watchCameraSource() {
        cameraSourceWatch.removeAll()
        let react: (Any) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.cameraRequested || self.liveCameraSource != .none else { return }
                await self.updateLiveCameraSource()
            }
        }
        glassesManager.$isStreaming.removeDuplicates().dropFirst()
            .sink(receiveValue: react).store(in: &cameraSourceWatch)
        glassesManager.$isRegistered.removeDuplicates().dropFirst()
            .sink(receiveValue: react).store(in: &cameraSourceWatch)
        glassesManager.$connectedDevice.map { $0 != nil }.removeDuplicates().dropFirst()
            .sink(receiveValue: react).store(in: &cameraSourceWatch)
    }

    /// Setup live backend callbacks for audio/transcription (Gemini Live or OpenAI Realtime)
    private func setupLiveVideoCallbacks(_ service: any LiveVideoService) {
        // Audio from the model → playback
        service.onAudioReceived = { [weak self] data in
            self?.audioPlayback.playAudio(data: data)
        }

        // Transcription updates - also check for stop commands
        service.onInputTranscription = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.userTranscript = text

                // AUR-742a: inside a live session these phrases toggle the CAMERA, not the mode.
                if self.isLiveVideoMode, self.handleCameraCommand(text) { return }

                // Check for stop video commands in what the user said
                let lowerText = text.lowercased()
                // AUR-776: "stop video" / «стоп видео» are NOT hang-ups any more — the brain maps
                // them to `aurelia.action video.stop` (a recording stop); hang-up by voice is the
                // brain's `aurelia.session.close` (AUR-746). Only the explicit "live/stream" words
                // stay as a local fallback.
                let stopKeywords = ["stop streaming", "stop live", "end live", "exit live",
                                   "стоп стрим", "выключи стрим", "заверши стрим",
                                   // Hindi fallbacks (models sometimes transcribe English as Hindi)
                                   "स्टॉप", "बंद करो", "रुको"]

                let isStopCommand = stopKeywords.contains { lowerText.contains($0) }

                if isStopCommand && self.isLiveVideoMode {
                    ovLog("[VoiceAgent] Stop command detected in transcription: \(text)")
                    await self.stopLiveVideoMode()
                }
            }
        }

        service.onOutputTranscription = { [weak self] text in
            Task { @MainActor in
                self?.aiTranscript = text
            }
        }

        // Turn complete
        service.onTurnComplete = { [weak self] in
            Task { @MainActor in
                // History: persist this live-video exchange (transcript only, no frames).
                self?.recordLiveTurn()
            }
        }

        // Disconnection - handle reconnection or mode exit
        service.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isLiveVideoMode {
                    ovLog("[VoiceAgent] Live backend disconnected unexpectedly")
                    await self.stopLiveVideoMode()
                }
            }
        }
    }

    /// Turn a spoken photo command into a clean vision question for a model that already has
    /// the image attached. Removes "take a picture / photo" trigger wording so the model
    /// describes the image instead of protesting that it can't take photos.
    private func visionPromptFromCommand(_ command: String) -> String {
        var s = command.lowercased()
        // Only strip explicit photo-capture wording — that's what makes a VLM refuse ("I can't
        // take photos"). Do NOT strip politeness/filler ("would you", "right now", "of this"):
        // removing those mid-sentence mangled real questions ("what am I looking at right now"
        // → "what am I looking at"; "would you tell me which plant" → "tell me which plant").
        let triggers = [
            "take a picture of this", "take a photo of this", "take a picture", "take a photo",
            "take photo", "take picture", "capture a photo", "capture photo", "snap a photo",
            "snap a picture", "go ahead and take"
        ]
        for t in triggers { s = s.replacingOccurrences(of: t, with: " ") }
        s = s.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Trim leftover connective prefixes left after removing the trigger ("...and tell me…").
        for prefix in ["and ", "of this ", "of ", "please "] {
            while s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!"))
        if s.count < 3 {
            return "What is the main object in this image? Name it specifically and describe its key visible details in 2–3 sentences."
        }
        return "Look closely at the image and answer specifically and concretely: \(s)"
    }

    // MARK: - POV Recording

    /// Toggle a demo recording of the glasses point-of-view (video) plus the phone mic (audio,
    /// which captures the scene sound and the assistant's spoken reply played out the speaker).
    /// The result is saved to Photos for sharing.
    func toggleRecording() {
        if isRecording {
            sessionRecorder.stop()   // finishes async; `onFinished` resets state + reports the save
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        do {
            try await startPOVRecordingCore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    enum POVRecordingError: LocalizedError {
        case noGlasses
        case streamDidNotStart
        case recorder(String)
        var errorDescription: String? {
            switch self {
            case .noGlasses: return "Connect your glasses first to record."
            case .streamDidNotStart: return "Couldn't start the glasses camera to record."
            case .recorder(let reason): return "Recording failed to start: \(reason)"
            }
        }
    }

    /// The one POV-recording start, shared by the record button and the AUR-776 `video.start`
    /// action: glasses stream up (LED on), raw frames → SessionRecorder, mic (+ assistant voice
    /// via the playback tap) muxed by the recorder, saved to Photos on stop.
    private func startPOVRecordingCore() async throws {
        guard !isRecording else { return }
        guard glassesManager.isRegistered, glassesManager.connectedDevice != nil else {
            throw POVRecordingError.noGlasses
        }
        // Recording needs a live frame stream; start it if the user isn't already in live video.
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        guard glassesManager.isStreaming else {
            throw POVRecordingError.streamDidNotStart
        }

        // Route the raw glasses frames into the recorder. This is separate from `onVideoFrame`
        // (which feeds the AI in live mode), so recording and live vision can run together.
        glassesManager.onVideoSampleBuffer = { [weak self] sampleBuffer in
            self?.sessionRecorder.appendVideoSampleBuffer(sampleBuffer)
        }

        sessionRecorder.onFinished = { [weak self] url in
            guard let self else { return }
            self.isRecording = false
            self.glassesManager.onVideoSampleBuffer = nil
            self.showRecordingStatus(url != nil ? "Saved to Photos" : "Couldn't save recording")
        }

        do {
            try sessionRecorder.start()
            isRecording = true
        } catch {
            glassesManager.onVideoSampleBuffer = nil
            throw POVRecordingError.recorder(error.localizedDescription)
        }
    }

    /// Stop the POV recorder and wait for the saved file (nil = nothing saved / not recording).
    /// The glasses stream is left to `updateLiveCameraSource` (it is closed when no eye wants it)
    /// or stays up for the live eye.
    private func stopPOVRecordingAwaiting() async -> URL? {
        guard isRecording else { return nil }
        let saved: URL? = await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            var resumed = false
            sessionRecorder.onFinished = { [weak self] url in
                guard let self else { if !resumed { resumed = true; cont.resume(returning: url) }; return }
                self.isRecording = false
                self.glassesManager.onVideoSampleBuffer = nil
                self.showRecordingStatus(url != nil ? "Saved to Photos" : "Couldn't save recording")
                if !resumed { resumed = true; cont.resume(returning: url) }
            }
            sessionRecorder.stop()
        }
        // Outside a live session the stream was opened only for this recording — LED off.
        if !isLiveVideoMode, glassesManager.isStreaming { await glassesManager.stopStreaming() }
        else if isLiveVideoMode { await updateLiveCameraSource() }
        return saved
    }

    /// Show a brief status message after a recording finishes, then clear it.
    private func showRecordingStatus(_ text: String) {
        recordingStatus = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.recordingStatus == text { self?.recordingStatus = nil }
        }
    }

    // MARK: - Face recognition

    /// Route face-recognition commands using the on-device model as an intent classifier
    /// (agentic — no keyword matching, like OpenGlasses' face_recognition tool). Returns true
    /// if the command was a face command and was handled.
    private func handleFaceCommandIfNeeded(_ command: String) async -> Bool {
        guard let intent = await GemmaLocalService.shared.classifyFaceIntent(command) else {
            return false   // model not loaded, or not a face command
        }
        await handleFaceIntent(intent)
        return true
    }

    /// Shared handling for the on-device text models (Gemma / Apple Foundation): one agentic
    /// generation that routes a face action, a web search, or a direct spoken answer.
    private func handleLocalCommand(_ command: String, llm: LocalTextLLM, isPhotoCommand: Bool) async {
        if isPhotoCommand {
            // SmolVLM2 handles photos fully on-device; other local models are text-only
            // (Gemma E2B's vision hit the jetsam limit — see GemmaLocalModel.supportsOnDeviceVision).
            if settingsManager.settings.aiBackend == .localGemma && GemmaLocalService.shared.visionReady {
                ovLog("[VoiceAgent] Photo command on local SmolVLM2 — capturing...")
                await captureAndSendPhoto(withPrompt: command)
                return
            }
            agentState = isSessionActive ? .listening : .idle
            speakResponse("This on-device model is text only. For camera questions, select SmolVLM2 as your local model, or switch to Gemini or OpenClaw in Settings.")
            return
        }
        // Route the command. With Apple TTS, stream the answer: speak sentences as they generate.
        // Backends that can't stream (Apple FM) fall back to a plain route via the protocol's
        // default implementation — onPartial simply never fires. Face/tool routes emit JSON
        // starting with "{", so we only begin speaking once the streamed output's first non-space
        // char proves it's a plain answer — never for a structured route.
        let result: LocalAgent.RouteResult
        if usingAppleTTS {
            ttsStreaming = false
            ttsStreamSpokenChars = 0
            result = await llm.routeCommandStreaming(command) { [weak self] cumulative in
                guard let self else { return }
                let lead = cumulative.trimmingCharacters(in: .whitespacesAndNewlines).first
                guard let lead, lead != "{" else { return }   // JSON route → don't speak
                self.feedStreamingSpeech(cumulative, isFinal: false)
            }
        } else {
            result = await llm.routeCommand(command)
        }

        switch result {
        case .face(let intent):
            // Safety: if we mis-started streaming (answer contained a stray "{"), cancel it.
            if ttsStreaming { ttsService.stop(); ttsStreaming = false }
            await handleFaceIntent(intent)
        case .webSearch(let query):
            if ttsStreaming { ttsService.stop(); ttsStreaming = false }
            NSLog("[OV] web search: \"%@\"", query)
            var result = await WebSearchService.search(query)
            // Agentic retry: if the first query found nothing, let the model reformulate once.
            if result.isEmpty, let better = await llm.reformulateSearchQuery(question: command, triedQuery: query) {
                NSLog("[OV] web search retry: \"%@\"", better)
                result = await WebSearchService.search(better)
            }
            let answer = await llm.answerWithSearchResult(question: command, result: result)
            speakResponse(answer)   // separate generation — not streamed here
            ConversationContext.shared.record(user: command, assistant: answer)
        case .answer(let text):
            if ttsStreaming {
                feedStreamingSpeech(text, isFinal: true)   // flush the tail, close the session
            } else {
                speakResponse(text)   // Kokoro, or non-streaming backend
            }
            ConversationContext.shared.record(user: command, assistant: text)
        }
        // Generation finishes well before the voice does (several sentences stay queued in TTS).
        // Don't stomp the state back to .listening while the reply is still being spoken — the
        // TTS-finished observers handle that transition at the right moment.
        if !ttsService.isSpeaking && !KokoroTTSService.shared.isSpeaking {
            agentState = isSessionActive ? .listening : .idle
        }
    }

    /// Carry out a face action (camera capture + Apple Vision), shared by the cloud-backend
    /// classifier path and the Local-backend single-pass router.
    private func handleFaceIntent(_ intent: GemmaLocalService.FaceIntent) async {
        let face = FaceRecognitionService.shared
        switch intent.action {
        case "identify":
            agentState = .thinking
            guard let image = await currentGlassesImage() else {
                speakResponse("I couldn't get a picture from the glasses. Make sure they're connected.")
                return
            }
            speakResponse(await face.identify(in: image))
        case "remember":
            agentState = .thinking
            guard !intent.name.isEmpty else {
                speakResponse("Sure — what's their name?")
                return
            }
            guard let image = await currentGlassesImage() else {
                speakResponse("I couldn't get a picture from the glasses. Make sure they're connected.")
                return
            }
            speakResponse(await face.rememberFace(name: intent.name, from: image))
        case "forget":
            speakResponse(face.forgetFace(name: intent.name))
        case "list":
            speakResponse(face.listKnownFaces())
        default:
            break
        }
    }

    // MARK: - Photo capture

    /// Get a fresh UIImage frame from the glasses camera, then turn the camera off
    /// ("click and go") — unless we're in live video mode.
    private func currentGlassesImage() async -> UIImage? {
        guard glassesManager.isRegistered else { return nil }
        if !glassesManager.isStreaming { await glassesManager.startStreaming() }
        var frame: UIImage?
        for _ in 0..<40 {   // up to ~4s for a fresh frame
            if let f = glassesManager.lastFrame { frame = f; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if frame == nil { frame = glassesManager.lastFrame }
        if glassesManager.isStreaming && !isLiveVideoMode {
            await glassesManager.stopStreaming()
        }
        // Do NOT touch the audio stack here. Tearing down / rebuilding the recognizer around the
        // camera is what broke the HFP mic: every rebuild forces a fresh Bluetooth SCO negotiation,
        // which the glasses can't service right after streaming (mic stays deaf for tens of seconds,
        // with an audible reconnect chirp per attempt). OpenGlasses keeps its wake-word engine + mic
        // tap alive straight through photo capture — audio just gaps during the stream and resumes
        // into the same running engine. We now do the same; see restartRecognition()'s engine check.
        return frame
    }

    /// Send a prompt (optionally with a photo) to whichever backend is currently selected.
    private func sendPromptToActiveBackend(_ prompt: String, imageData: Data?) async throws {
        let backend = AIBackendRegistry.backend(for: settingsManager.settings.aiBackend)
        // Backends that can't take an image (Apple FM text-only, Gemini streams video live)
        // receive just the prompt.
        try await backend.sendMessage(prompt, imageData: backend.supportsImageInput ? imageData : nil)
    }

    private func captureAndSendPhoto(withPrompt prompt: String) async {
        // Try to get an image from various sources
        var imageData: Data?
        var startedStreamingForPhoto = false

        // Start streaming if glasses are registered but not streaming. `startStreaming()` only
        // returns after `session.start()` completes (isStreaming is already true here), so the
        // old "poll up to 3s for isStreaming" loop + fixed 500ms sleep were dead weight that just
        // kept the LED on longer. freshLiveFrame() below already waits for the first real frame,
        // so drop the artificial delay entirely.
        if glassesManager.isRegistered && !glassesManager.isStreaming {
            ovLog("[VoiceAgent] Starting glasses camera stream for photo...")
            await glassesManager.startStreaming()
            startedStreamingForPhoto = true
        }

        // Capture straight from the live video stream. The glasses' one-shot photo API
        // (session.capturePhoto) doesn't reliably deliver on this model/SDK — it times out
        // after 5s — whereas a live frame is available immediately. freshLiveFrame() ensures
        // the stream is running, waits for a fresh frame, and restarts a stalled stream.
        imageData = await freshLiveFrame()

        NSLog("[OV] captureAndSendPhoto result: %@ (streaming=%@, registered=%@)",
              imageData == nil ? "NO IMAGE" : "\(imageData!.count) bytes",
              glassesManager.isStreaming ? "yes" : "no",
              glassesManager.isRegistered ? "yes" : "no")

        // "Click and go": now that we have the photo, turn the glasses camera off immediately —
        // before the (multi-second) model inference — so the LED doesn't stay on. Repeat photo
        // commands restart the camera reliably via freshLiveFrame(). Skip in live video mode.
        if imageData != nil && glassesManager.isStreaming && !isLiveVideoMode {
            NSLog("[OV] photo captured — stopping camera (click and go)")
            await glassesManager.stopStreaming()
        }

        // Send with or without image
        do {
            if let imageData = imageData {
                // The image is attached, so strip the "take a picture" wording — otherwise the
                // VLM replies "I can't take photos / please provide an image" before describing.
                let visionPrompt = visionPromptFromCommand(prompt)
                NSLog("[OV] Sending message with photo (%d bytes), prompt: \"%@\"", imageData.count, visionPrompt)
                try await sendPromptToActiveBackend(visionPrompt, imageData: imageData)
            } else {
                NSLog("[OV] No image available — capture returned nil; NOT sending to model")
                // Don't send a degraded text-only prompt to the model — that's what makes it
                // reply "please provide an image". Tell the user directly and stop.
                errorMessage = "Couldn't capture a photo (streaming: \(glassesManager.isStreaming ? "on" : "off"), registered: \(glassesManager.isRegistered ? "yes" : "no")). Try again."
                speakResponse("I couldn't get a photo from the glasses. Please try again.")
            }
        } catch {
            ovLog("[VoiceAgent] Failed to send: \(error)")
            errorMessage = "Failed to send: \(error.localizedDescription)"
            agentState = isSessionActive ? .listening : .idle

            // Stop streaming on error if we started it for this photo
            if startedStreamingForPhoto && glassesManager.isStreaming {
                await glassesManager.stopStreaming()
            }
        }
    }

    /// Capture photo from glasses and return the data
    private func capturePhotoFromGlasses() async -> Data? {
        // Clear any stale photo before requesting a fresh capture.
        glassesManager.lastPhotoData = nil
        NSLog("[OV] capturePhotoFromGlasses: requesting capture (streaming=%@)", glassesManager.isStreaming ? "yes" : "no")
        await glassesManager.capturePhoto()

        // Wait for photo data to appear (poll for up to 5 seconds)
        for _ in 0..<50 {
            if let photoData = glassesManager.lastPhotoData {
                glassesManager.lastPhotoData = nil
                NSLog("[OV] Photo captured: %d bytes", photoData.count)
                return photoData
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        NSLog("[OV] Photo capture TIMED OUT after 5s")
        return nil
    }

    /// Force a fresh live video frame, restarting the stream if it has stalled.
    /// More reliable than the one-shot photo capture for repeated requests in a session.
    private func freshLiveFrame() async -> Data? {
        guard glassesManager.isRegistered else { return nil }
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        // Wait for a NEW frame (clear first so we don't reuse a stale one).
        glassesManager.lastFrame = nil
        for _ in 0..<25 { // up to ~2.5s
            if let f = glassesManager.lastFrame {
                NSLog("[OV] fresh live frame acquired")
                return f.jpegData(compressionQuality: 0.8)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Stream appears stalled — restart it once and retry.
        NSLog("[OV] live frame stalled — restarting stream")
        await glassesManager.stopStreaming()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await glassesManager.startStreaming()
        glassesManager.lastFrame = nil
        for _ in 0..<30 { // up to ~3s
            if let f = glassesManager.lastFrame {
                NSLog("[OV] fresh live frame acquired after restart")
                return f.jpegData(compressionQuality: 0.8)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("[OV] freshLiveFrame: STILL no frame after restart")
        return nil
    }

    // MARK: - Glasses Video Integration

    /// Setup glasses callbacks to stream video to Gemini Vision
    private func setupGlassesCallbacks() {
        ovLog("[VoiceAgent] Setting up glasses video callbacks...")

        // Connect video frames from glasses to Gemini Vision (for live feed)
        // Note: GeminiVisionService.sendVideoFrame already throttles to 1fps
        glassesManager.onVideoFrame = { [weak self] image in
            guard let self else { return }
            // Send frame to Gemini Vision for live analysis
            self.geminiVision.sendVideoFrame(image)

            // Log periodically (every 30 frames = ~1 second at 30fps)
            Task { @MainActor in
                self.videoFrameCount += 1
                if self.videoFrameCount % 30 == 0 {
                    ovLog("[VoiceAgent] Video frames processed: \(self.videoFrameCount)")
                }
            }
        }

        // Photo captured callback (for OpenClaw photo analysis)
        glassesManager.onPhotoCaptured = { data in
            ovLog("[VoiceAgent] Photo captured: \(data.count) bytes")
            // Photos are handled via OpenClaw's attachment system
        }

        ovLog("[VoiceAgent] Glasses callbacks configured")
    }

    // MARK: - TTS Integration

    /// True when the active speech engine is Apple's system voice (not Kokoro). Apple TTS runs on
    /// a system audio service — not the Metal GPU — so it can pipeline speech while the on-device
    /// model is still generating, with no resource contention.
    private var usingAppleTTS: Bool { !usingKokoroTTS }

    /// Kokoro speaks only when it is selected, downloaded, AND can pronounce the app's language —
    /// it is English-only (see `KokoroTTSService.supportedLanguageCodes`). Without the language
    /// check a Russian reply would be handed to an English phonemizer and come out as noise.
    private var usingKokoroTTS: Bool {
        settingsManager.settings.ttsEngine == .kokoro
            && KokoroTTSService.shared.isModelReady
            && KokoroTTSService.supportsCurrentLanguage
    }

    /// Feed the streamed reply to Apple TTS sentence-by-sentence. `cumulative` is the full text so
    /// far (the local model emits a growing snapshot each token). On non-final calls we speak only
    /// the sentences that have fully completed; on the final call we flush whatever remains.
    private func feedStreamingSpeech(_ cumulative: String, isFinal: Bool) {
        // Open a streamed utterance session on first content.
        if !ttsStreaming {
            guard !cumulative.isEmpty else { return }
            ttsStreaming = true
            ttsStreamSpokenChars = 0
            ttsService.beginStreaming()
        }

        // The portion not yet handed to the speech queue.
        let spokenClamped = min(ttsStreamSpokenChars, cumulative.count)
        let start = cumulative.index(cumulative.startIndex, offsetBy: spokenClamped)
        let pending = cumulative[start...]

        if isFinal {
            let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { ttsService.speakChunk(tail) }
            ttsStreamSpokenChars = cumulative.count
            ttsService.endStreaming()
            ttsStreaming = false
            recordAssistantReply(cumulative)   // history: streamed reply is complete
            return
        }

        // Speak everything up to the last completed sentence boundary in the pending text.
        guard let boundary = TextChunking.lastSentenceBoundary(in: String(pending)) else { return }
        let pendingStr = String(pending)
        let sentence = String(pendingStr[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentence.count >= 2 else { return }   // don't voice a stray "." or "?"
        ttsService.speakChunk(sentence)
        ttsStreamSpokenChars += pendingStr.distance(from: pendingStr.startIndex, to: boundary)
    }

    /// Speak AI response via TTS
    private func speakResponse(_ text: String) {
        guard !text.isEmpty else { return }
        recordAssistantReply(text)
        // Kokoro (on-device neural) when selected, ready, and able to speak the language;
        // otherwise the Apple system voice, which covers every language in the picker.
        if usingKokoroTTS {
            Task { await KokoroTTSService.shared.speak(text, voice: settingsManager.settings.kokoroVoice) }
        } else {
            ttsService.speak(text)
        }
    }

    // MARK: - History

    /// History: persist the assistant's reply, but only when it answers a recorded user command —
    /// system utterances ("Live video mode active", connection errors) stay out of History.
    private func recordAssistantReply(_ text: String) {
        guard historyAwaitingReply else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        ConversationManager.shared.addAssistantMessage(clean)
        historyAwaitingReply = false
    }

    /// History (live video / realtime modes): commands don't pass through onCommandCaptured there,
    /// so record the user+assistant pair at each turn boundary. Transcript only — video frames are
    /// never stored (same policy as Meta's live AI history).
    private func recordLiveTurn() {
        let user = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = aiTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, reply != historyLastLiveReply else { return }
        if !user.isEmpty { ConversationManager.shared.addUserMessage(user) }
        ConversationManager.shared.addAssistantMessage(reply)
        historyLastLiveReply = reply
        historyAwaitingReply = false
    }

    // MARK: - Tool Handlers (OpenClaw device-side tools)

    /// Handle take_photo tool call
    private func handleTakePhotoTool(completion: @escaping (String) -> Void) async {
        ovLog("[VoiceAgent] Handling take_photo tool")

        if glassesManager.isStreaming {
            // Capture from glasses
            await glassesManager.capturePhoto()

            // Wait for photo to be captured (via callback)
            // Set up one-time handler for the photo
            let originalHandler = glassesManager.onPhotoCaptured
            glassesManager.onPhotoCaptured = { [weak self] data in
                // Restore original handler
                self?.glassesManager.onPhotoCaptured = originalHandler

                // Send photo to OpenClaw as attachment in next message
                Task {
                    do {
                        try await OpenClawService.shared.sendMessage("Here's the photo I just captured.", imageData: data)
                        completion("Photo captured and sent for analysis.")
                    } catch {
                        completion("Photo captured but failed to send: \(error.localizedDescription)")
                    }
                }
            }

            // Timeout after 5 seconds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if self.glassesManager.onPhotoCaptured != nil {
                    self.glassesManager.onPhotoCaptured = originalHandler
                    completion("Photo capture timed out.")
                }
            }
        } else if let lastFrame = glassesManager.lastFrame,
                  let jpegData = lastFrame.jpegData(compressionQuality: 0.8) {
            // Use last frame if available
            do {
                try await OpenClawService.shared.sendMessage("Here's what I can see.", imageData: jpegData)
                completion("Captured current view and sent for analysis.")
            } catch {
                completion("Failed to send image: \(error.localizedDescription)")
            }
        } else {
            completion("Camera is not available. Please connect glasses and start streaming first.")
        }
    }

    /// Handle describe_scene tool call (uses Gemini Vision)
    private func handleDescribeSceneTool(args: [String: Any], completion: @escaping (String) -> Void) async {
        ovLog("[VoiceAgent] Handling describe_scene tool")

        let prompt = args["prompt"] as? String ?? "Please describe what you see in this image."

        // Capture photo and send to OpenClaw for analysis
        if let lastFrame = glassesManager.lastFrame,
           let jpegData = lastFrame.jpegData(compressionQuality: 0.8) {
            do {
                try await OpenClawService.shared.sendMessage(prompt, imageData: jpegData)
                completion("Image captured and sent for analysis.")
            } catch {
                completion("Failed to analyze scene: \(error.localizedDescription)")
            }
        } else if glassesManager.isStreaming {
            // Try to capture a photo
            await glassesManager.capturePhoto()
            // Wait briefly for photo
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let photoData = glassesManager.lastPhotoData {
                glassesManager.lastPhotoData = nil
                do {
                    try await OpenClawService.shared.sendMessage(prompt, imageData: photoData)
                    completion("Photo captured and sent for analysis.")
                } catch {
                    completion("Failed to send photo: \(error.localizedDescription)")
                }
            } else {
                completion("Failed to capture photo.")
            }
        } else {
            completion("Camera is not available. Please connect glasses and start streaming first, or say 'start video stream' for live mode.")
        }
    }
}

// MARK: - Text chunking (pure, unit-testable)

/// Pure text helpers for sentence-streamed TTS.
enum TextChunking {
    /// Index just past the last sentence terminator (. ! ? or newline) in `s`, or nil if none.
    /// A `.`/`!`/`?` only counts when followed by whitespace or end-of-text, so decimals like
    /// "2.5" and abbreviations don't get split mid-number.
    static func lastSentenceBoundary(in s: String) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?"]
        var boundary: String.Index? = nil
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if c == "\n" {
                boundary = next
            } else if terminators.contains(c) {
                let followedByBreak = next == s.endIndex || s[next] == " " || s[next] == "\n"
                if followedByBreak { boundary = next }
            }
            i = next
        }
        return boundary
    }

    /// Split `s` into speakable sentence chunks using the same boundary rules as
    /// `lastSentenceBoundary` (terminator followed by a break, or newline). Chunks are trimmed;
    /// empties dropped; text after the last terminator is included as a final chunk.
    /// Used by Kokoro TTS to synthesize per-sentence — one long reply in a single MLX pass
    /// spikes memory proportional to its length (jetsam risk next to SmolVLM2).
    static func sentences(_ s: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?"]
        var result: [String] = []
        var current = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            current.append(c)
            let next = s.index(after: i)
            let isBoundary = c == "\n"
                || (terminators.contains(c) && (next == s.endIndex || s[next] == " " || s[next] == "\n"))
            if isBoundary {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
            i = next
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}


// MARK: - AUR-776 fast voice actions (UI entry + device work)

extension VoiceAgentViewModel {

    /// The action row is shown only when the brain can echo `aurelia.action` (realtime socket).
    var voiceActionsAvailable: Bool {
        isLiveVideoMode && activeLiveService is OpenAIRealtimeService
    }

    /// A button tap: the server echoes `aurelia.action`, the action runs on that echo — voice
    /// and buttons share one path, the state is single-sourced.
    func requestVoiceAction(_ kind: VoiceActionKind, mode: VoiceActionMode? = nil) {
        guard openAIRealtime.connectionState.isUsable else {
            errorMessage = "Not connected to the brain"
            return
        }
        openAIRealtime.requestAction(kind, mode: mode, source: "button")
    }

    /// Photo button.
    func tapPhoto() { requestVoiceAction(.photo) }

    /// Video button: toggles silent video; long-press offers assist (see the view).
    func tapVideo(mode: VoiceActionMode = .silent) {
        if voiceActions.videoRecording != nil { requestVoiceAction(.videoStop) }
        else { requestVoiceAction(.videoStart, mode: mode) }
    }

    /// Listen button.
    func tapListen() {
        if voiceActions.audioRecording != nil { requestVoiceAction(.audioStop) }
        else { requestVoiceAction(.audioStart) }
    }
}

extension VoiceAgentViewModel: VoiceActionHost {

    var earconEngine: AVAudioEngine? { AudioSessionManager.shared.sharedEngine }

    var micSampleRate: Double { audioCapture.targetSampleRate }

    /// One still for `photo`. Glasses POV first (a FRESH frame off the DAT stream — the SDK's
    /// one-shot `capturePhoto` times out on this model, the stream frame is immediate); the
    /// phone camera's last frame when its eye is open; nil otherwise. Click-and-go: a stream
    /// opened only for the photo is closed again (LED off) unless the eye or a recording wants it.
    func captureStill() async -> (jpeg: Data, source: String)? {
        if glassesEyeAvailable {
            let wasStreaming = glassesManager.isStreaming
            if let jpeg = await freshLiveFrame() {
                if !wasStreaming, !cameraRequested, !isRecording, glassesManager.isStreaming {
                    await glassesManager.stopStreaming()
                }
                return (jpeg, "glasses")
            }
            if !wasStreaming, !cameraRequested, !isRecording, glassesManager.isStreaming {
                await glassesManager.stopStreaming()
            }
        }
        if phoneCamera.isRunning, let frame = phoneCamera.lastFrame,
           let jpeg = frame.jpegData(compressionQuality: 0.85) {
            return (jpeg, "phone")
        }
        return nil
    }

    func startPOVRecording() async throws {
        try await startPOVRecordingCore()
    }

    func stopPOVRecording() async -> URL? {
        await stopPOVRecordingAwaiting()
    }

    func setEyeOpen(_ open: Bool) async {
        guard isLiveVideoMode else { return }
        if cameraRequested != open {
            cameraRequested = open
            ovLog("[VoiceAgent] Camera \(open ? "requested" : "dismissed") by a voice action (glasses available: \(glassesEyeAvailable))")
        }
        await updateLiveCameraSource()
    }

    func setAssistantPlaybackSilenced(_ silenced: Bool) {
        audioPlayback.silenced = silenced
    }
}
