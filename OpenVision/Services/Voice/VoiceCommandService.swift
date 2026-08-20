// OpenVision - VoiceCommandService.swift
// Wake word detection and voice command capture using Apple Speech Recognition

import Foundation
import Speech
import AVFoundation

/// Voice command service — the wake-word DOOR to the conversation (AUR-742).
///
/// In one-conversation mode (the default) this service does exactly one thing: listen for the
/// wake word while the app is idle and fire `onWakeWordDetected`. The realtime session then owns
/// the mic (`AudioCaptureService` → `/v1/realtime`), and NOTHING is scanned for phrases here —
/// mode/action words are the SERVER's (`aurelia.action`), talking is the interrupt.
///
/// The push-to-ask machinery (command capture after the wake word, silence detection,
/// conversation mode for follow-ups, the «Аурелия, …» barge-in over Apple TTS) is BANKED behind
/// `AppSettings.pushToAskEnabled` (AUR-744) — it keeps compiling and comes back when the flag is
/// flipped, for a rig that cannot do full duplex.
@MainActor
final class VoiceCommandService: ObservableObject {
    // MARK: - Singleton

    static let shared = VoiceCommandService()

    // MARK: - Published State

    @Published var state: ListeningState = .idle
    @Published var isListening: Bool = false
    @Published var currentTranscription: String = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    // MARK: - Listening State

    enum ListeningState: Equatable {
        /// Waiting for wake word
        case idle

        /// Wake word detected, capturing command
        case listening

        /// In conversation mode, waiting for follow-up
        case conversationMode

        /// Processing captured command
        case processing
    }

    // MARK: - Configuration

    var wakeWord: String {
        SettingsManager.shared.settings.wakeWord
    }

    var isWakeWordEnabled: Bool {
        SettingsManager.shared.settings.wakeWordEnabled
    }

    var playActivationSound: Bool {
        SettingsManager.shared.settings.playActivationSound
    }

    /// AUR-744: the banked push-to-ask path. Off (default) = this service is the wake-word door
    /// only; on = command capture + conversation mode come back.
    private var pushToAskEnabled: Bool {
        SettingsManager.shared.settings.pushToAskEnabled
    }

    // MARK: - Callbacks

    /// Called when wake word is detected
    var onWakeWordDetected: (() -> Void)?

    /// Called when a command is captured (push-to-ask only, AUR-744)
    var onCommandCaptured: ((String) -> Void)?

    /// Called when conversation mode times out (no speech detected) (push-to-ask only, AUR-744)
    var onConversationTimeout: (() -> Void)?

    // MARK: - Barge-in Control (push-to-ask only, AUR-744)

    /// Returns true if TTS is currently playing (allows wake word + command to interrupt)
    var shouldAllowInterrupt: (() -> Bool)?

    // MARK: - Speech Recognition

    /// Recognizer for the language the user selected (Settings → Voice Control → Language).
    ///
    /// Was hard-coded to en-US, which silently made the app monolingual: a Russian speaker's
    /// "покажи, что ты видишь" came back as English-phoneme mush and no command ever matched.
    /// `SFSpeechRecognizer`'s locale is fixed at init, so a language change means building a new
    /// instance — hence the cached-by-identifier accessor rather than a stored `let`.
    private var cachedRecognizer: SFSpeechRecognizer?
    private var cachedRecognizerLocaleID: String?

    private var speechRecognizer: SFSpeechRecognizer? {
        let locale = SpeechLocale.recognizerLocale
        if let cachedRecognizer, cachedRecognizerLocaleID == locale.identifier {
            return cachedRecognizer
        }
        let recognizer = SFSpeechRecognizer(locale: locale)
        cachedRecognizer = recognizer
        cachedRecognizerLocaleID = locale.identifier
        print("[VoiceCommand] Recognizer locale: \(locale.identifier) (available: \(recognizer?.isAvailable ?? false))")
        return recognizer
    }

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Identity of the CURRENT recognition task. A canceled SFSpeechRecognitionTask still delivers
    /// dying callbacks (stale partials, an empty final, a "canceled" error). Without this guard
    /// those zombie callbacks are indistinguishable from the live recognizer ending — each
    /// restart's own corpse then scheduled the next restart, tearing the recognizer down every
    /// second and chopping user speech into unrecognizable fragments (commands never transcribed).
    /// Every (re)start bumps the generation; callbacks from older generations are dropped.
    private var recognitionGeneration = 0

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?

    // MARK: - Wake-word pre-roll (AUR-743)

    /// The last `Constants.RealtimeAudio.wakePreRollSeconds` of mic audio at the realtime input
    /// rate, filled from the SAME tap the recognizer reads. On a wake the ViewModel takes the part
    /// after the wake phrase (`takePreRoll()`) and replays it into the conversation.
    private let preRollRing = WakePreRollRing(sampleRate: Constants.OpenAIRealtime.inputSampleRate,
                                              seconds: Constants.RealtimeAudio.wakePreRollSeconds)
    /// Native tap format → PCM16 mono at the realtime rate (same converter the live mic uses).
    private var preRollChunker: AudioCaptureChunker?
    /// Wall clock of the last wake detection, and how much audio AFTER the wake phrase the ring
    /// already held at that moment (recognizer-timeline math, see `noteWakeWordEnd`).
    private var wakeDetectedAt: Date?
    private var wakeTailSecondsAtDetection: Double = 0
    private var wakeTailTrimmed = false

    /// Build (or rebuild) the converter that feeds the pre-roll ring from the tap.
    private func preparePreRollChunker() {
        if preRollChunker == nil {
            preRollChunker = AudioCaptureChunker(targetSampleRate: Double(Constants.OpenAIRealtime.inputSampleRate),
                                                frameMs: Constants.RealtimeAudio.captureFrameMs)
            let ring = preRollRing
            preRollChunker?.onFrame = { frame in ring.append(frame) }
        } else {
            preRollChunker?.resetConverter()   // the route (and so the tap format) may have changed
        }
    }

    /// Place the END of the wake phrase on the recognizer's audio timeline (segments carry
    /// `timestamp + duration` in seconds since the recognition request started; the ring's epoch is
    /// marked at the same moment) and remember how much audio after it the ring already holds.
    /// Not locatable → 0 (only audio after the detection moment will be kept).
    private func noteWakeWordEnd(in result: SFSpeechRecognitionResult, transcription: String) {
        wakeDetectedAt = Date()
        let nowSec = preRollRing.secondsSinceEpoch
        let lower = transcription.lowercased()
        guard let variation = wakeVariations.first(where: { lower.contains($0) }),
              let lastWord = variation.split(separator: " ").last.map(String.init) else {
            wakeTailSecondsAtDetection = 0; wakeTailTrimmed = false
            return
        }
        let segments = result.bestTranscription.segments
        // Scan from the end: the wake phrase's last word is usually the latest segment.
        for seg in segments.reversed() {
            let s = seg.substring.lowercased()
            let matches = s.contains(lastWord) || (s.count >= 4 && lastWord.contains(s))
            if matches {
                let end = seg.timestamp + seg.duration
                wakeTailSecondsAtDetection = max(0, nowSec - end)
                wakeTailTrimmed = true
                print("[VoiceCommand] Wake phrase ends at \(String(format: "%.2f", end)) s, audio clock \(String(format: "%.2f", nowSec)) s → \(Int(wakeTailSecondsAtDetection * 1000)) ms already after it")
                return
            }
        }
        wakeTailSecondsAtDetection = 0; wakeTailTrimmed = false
        print("[VoiceCommand] Wake phrase end not found in \(segments.count) segments — pre-roll keeps post-detection audio only")
    }

    /// AUR-743: the mic audio that FOLLOWED the wake phrase, up to now (≤ the ring length). Call
    /// right after `stopListening()` on a wake — the ring is cleared by the call. nil when no wake
    /// was detected (the conversation was opened by a tap).
    func takePreRoll() -> WakePreRoll? {
        defer { preRollRing.clear() }
        guard let detectedAt = wakeDetectedAt else { return nil }
        wakeDetectedAt = nil
        let sinceDetection = Date().timeIntervalSince(detectedAt)
        // A wake that did not open a conversation promptly (push-to-ask took it, the rig failed)
        // is stale — the ring now holds ambient audio, not the wearer's continuation.
        guard sinceDetection < 5 else { return nil }
        let keep = min(preRollRing.seconds, wakeTailSecondsAtDetection + sinceDetection)
        let pcm = preRollRing.snapshot(lastSeconds: keep)
        return WakePreRoll(pcm: pcm,
                           keptMs: WakePreRollRing.milliseconds(of: pcm, sampleRate: preRollRing.sampleRate),
                           trimmedWakeWord: wakeTailTrimmed,
                           sinceDetectionMs: Int(sinceDetection * 1000))
    }

    /// Throttle for the wake-word auto-restart. On some audio routes (notably the glasses'
    /// Bluetooth HFP mic) the recognizer finalizes immediately, and restarting with no delay
    /// spins a tight infinite loop that freezes the app. We coalesce restarts to at most one
    /// every `minRestartInterval`.
    private var lastRecognizerRestart = Date.distantPast
    private var wakeWordRestartScheduled = false
    private let minRestartInterval: TimeInterval = 0.6

    // MARK: - Timers

    private var silenceTimer: Timer?
    private var commandTimeoutTimer: Timer?
    private var conversationTimeoutTimer: Timer?
    private var wakeWordCooldownActive: Bool = false

    /// Tracks if user has started speaking in this turn
    private var hasSpokenThisTurn: Bool = false

    // MARK: - Audio Feedback

    private var activationSound: AVAudioPlayer?

    // MARK: - Initialization

    private init() {
        setupActivationSound()
    }

    // MARK: - Authorization

    /// Request speech recognition authorization
    func requestAuthorization() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    self.authorizationStatus = status
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    // MARK: - Start/Stop

    /// Start listening for wake word or commands
    func startListening() throws {
        guard authorizationStatus == .authorized else {
            throw VoiceCommandError.notAuthorized
        }

        guard !isListening else { return }

        // Setup audio engine
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            throw VoiceCommandError.audioEngineUnavailable
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest else {
            throw VoiceCommandError.requestCreationFailed
        }

        configureRecognitionRequest(recognitionRequest)

        // Get input node
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0) // defensive: never install over an existing tap
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Guard against an invalid input format. This happens when the mic is unavailable —
        // most commonly while the user is on a phone/FaceTime call, where the input route
        // reports 0 Hz / 0 channels. Installing a tap with that format throws (SIGABRT),
        // so bail gracefully instead of crashing.
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            print("[VoiceCommand] Input unavailable (format \(recordingFormat.sampleRate)Hz/\(recordingFormat.channelCount)ch) — mic likely in use by a call. Skipping listen.")
            self.recognitionRequest = nil
            self.audioEngine = nil
            throw VoiceCommandError.audioEngineUnavailable
        }

        // AUR-743: the same tap feeds the wake-word pre-roll ring (converted to the realtime rate).
        preparePreRollChunker()
        preRollRing.clear()
        preRollRing.markEpoch()
        let preRoll = preRollChunker

        // Install tap — wrapped so an AVAudioEngine NSException (mic busy / bad route, e.g.
        // during a phone call) fails gracefully instead of aborting the process.
        if let reason = OVCatchException({
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
                preRoll?.process(buffer)
            }
        }) {
            print("[VoiceCommand] installTap failed: \(reason)")
            self.recognitionRequest = nil
            self.audioEngine = nil
            throw VoiceCommandError.audioEngineUnavailable
        }

        // Start audio engine first (before recognition task)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("[VoiceCommand] Failed to start audio engine: \(error)")
            // Clean up
            audioEngine.inputNode.removeTap(onBus: 0)
            self.recognitionRequest = nil
            self.audioEngine = nil
            throw VoiceCommandError.audioEngineUnavailable
        }

        // Start recognition task after audio engine is running
        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.recognitionGeneration else { return }  // zombie task
                self.handleRecognitionResult(result: result, error: error)
                self.restartIfRecognizerEnded(result: result, error: error)
            }
        }

        isListening = true
        state = isWakeWordEnabled ? .idle : .listening
        print("[VoiceCommand] Started listening - audio engine running")
    }

    /// Prime the recognizer for the wake phrase and short-phrase detection. `contextualStrings`
    /// biases recognition toward "Ok Vision", which is the single biggest factor in reliably
    /// hearing the wake word over the low-quality glasses Bluetooth-HFP mic (8 kHz). `.search`
    /// (short phrase) beats `.dictation` (long-form) for a quick wake word + command.
    private func configureRecognitionRequest(_ request: SFSpeechAudioBufferRecognitionRequest) {
        request.shouldReportPartialResults = true
        request.taskHint = .search
        // The English variants only help an English recognizer — feeding "Okay Vision" to a
        // Russian model just biases it toward transliterating noise. Outside English, bias on the
        // user's own wake phrase alone (they can set a Cyrillic one, e.g. "Окей Вижн").
        var phrases: [String] = SpeechLocale.isEnglish
            ? ["Ok Vision", "Okay Vision", "Hey Vision", "Vision"]
            : []
        if !wakeWord.isEmpty { phrases.insert(wakeWord, at: 0) }
        request.contextualStrings = phrases
    }

    /// Apply a language change from Settings. The recognizer's locale is immutable, so an active
    /// listening session has to be torn down and relaunched to start hearing the new language.
    func applyLocaleChange() {
        let newLocale = SpeechLocale.recognizerLocale
        guard cachedRecognizerLocaleID != newLocale.identifier else { return }
        cachedRecognizer = nil
        cachedRecognizerLocaleID = nil
        guard isListening else { return }
        print("[VoiceCommand] Language changed → restarting recognizer as \(newLocale.identifier)")
        restartRecognition()
    }

    /// SFSpeechRecognizer stops after ~1 minute or when it emits a final result / errors. While
    /// idling for the wake word that would silently kill listening ("responds once in a while"),
    /// so restart a fresh recognizer whenever the task ends and we're still meant to be listening.
    private func restartIfRecognizerEnded(result: SFSpeechRecognitionResult?, error: Error?) {
        let ended = (error != nil) || (result?.isFinal ?? false)
        // Idle (wake-word) AND conversation mode both rely on an always-running recognizer with no
        // other flow to revive it. Restricting this to `.idle` caused a deaf-mic race: an empty
        // final result arriving while still in conversationMode skipped the restart here, then the
        // conversation timeout returned to idle with a dead recognizer — and every "Ok Vision"
        // after that hit silence. (`.listening`/`.processing` are excluded on purpose: their
        // restarts are owned by handleCommandComplete / the TTS flow.)
        let needsAlwaysOnRecognizer = (state == .idle && isWakeWordEnabled) || state == .conversationMode
        guard ended, isListening, needsAlwaysOnRecognizer else { return }
        if let error { print("[VoiceCommand] Recognizer ended (\(error.localizedDescription)) — will relaunch listener") }
        scheduleWakeWordRestart()
    }

    /// Relaunch the wake-word recognizer, but never more than once per `minRestartInterval`.
    /// If the recognizer keeps ending immediately (e.g. a flaky Bluetooth HFP mic), this makes it
    /// retry ~1×/second instead of spinning thousands of times a second and freezing the app.
    private func scheduleWakeWordRestart() {
        guard !wakeWordRestartScheduled else { return }   // coalesce a burst of "ended" callbacks
        wakeWordRestartScheduled = true
        let delay = max(0, minRestartInterval - Date().timeIntervalSince(lastRecognizerRestart))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.wakeWordRestartScheduled = false
            // Same states as restartIfRecognizerEnded: idle wake-word listening or conversation
            // mode. The state may legitimately have flipped between scheduling and firing (e.g.
            // conversationMode → timeout → idle); both still need a live recognizer.
            let stillNeedsRecognizer = (self.state == .idle && self.isWakeWordEnabled)
                || self.state == .conversationMode
            guard self.isListening, stillNeedsRecognizer else { return }
            self.lastRecognizerRestart = Date()
            self.restartRecognition()
        }
    }

    /// Stop listening
    func stopListening() {
        recognitionGeneration += 1   // orphan any in-flight callbacks from the dying task
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        silenceTimer?.invalidate()
        silenceTimer = nil
        commandTimeoutTimer?.invalidate()
        commandTimeoutTimer = nil
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = nil

        isListening = false
        state = .idle
        currentTranscription = ""
        hasSpokenThisTurn = false
        // AUR-743: the pre-roll ring is deliberately NOT cleared here — on a wake the ViewModel
        // stops this listener and then takes the ring (`takePreRoll()`); `startListening` clears.
        print("[VoiceCommand] Stopped listening")
    }

    /// Enter conversation mode (no wake word needed for follow-ups). Push-to-ask only (AUR-744):
    /// in one-conversation mode follow-ups go to the realtime session, so this falls back to the
    /// plain wake-word door (recognizer relaunched, transcript cleared).
    func enterConversationMode() {
        guard pushToAskEnabled else {
            print("[VoiceCommand] enterConversationMode ignored — push-to-ask is off (wake-word door only)")
            exitConversationMode()
            return
        }
        // Restart recognition to clear accumulated transcription
        restartRecognition()

        state = .conversationMode
        hasSpokenThisTurn = false
        currentTranscription = ""

        // Start conversation timeout (exits if no speech for 4 seconds)
        startConversationTimeout()

        print("[VoiceCommand] Entered conversation mode")
    }

    /// Restart speech recognition to clear buffer
    private func restartRecognition() {
        guard isListening else { return }

        // Stop current recognition. Bump the generation FIRST so the canceled task's dying
        // callbacks (delivered async) are orphaned immediately, not just once the new task exists.
        recognitionGeneration += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Remove tap and stop engine briefly
        audioEngine?.inputNode.removeTap(onBus: 0)

        // Create new recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }

        configureRecognitionRequest(recognitionRequest)

        // Reinstall tap
        guard let audioEngine = audioEngine else { return }

        // The glasses camera's Bluetooth route change can silently STOP the running engine (the
        // recognizer then looks alive but hears nothing). Revive the same engine instead of tearing
        // it down — a rebuild would force a fresh HFP/SCO negotiation the glasses can't service
        // right after streaming, leaving the mic deaf. This mirrors OpenGlasses' persistent engine.
        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
                print("[VoiceCommand] Engine had stopped (route change) — restarted in place")
            } catch {
                print("[VoiceCommand] Engine restart failed: \(error)")
            }
        }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0) // defensive: never install over an existing tap
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Skip if the mic is unavailable (e.g. on a call) — installing a tap with a
        // 0 Hz / 0 channel format throws.
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            print("[VoiceCommand] Input unavailable on reinstall — skipping tap")
            self.recognitionRequest = nil
            return
        }

        // AUR-743: the ring keeps filling across restarts (the audio is continuous; only the
        // recognizer's timeline restarts — re-mark its epoch).
        preparePreRollChunker()
        preRollRing.markEpoch()
        let preRoll = preRollChunker

        if let reason = OVCatchException({
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
                preRoll?.process(buffer)
            }
        }) {
            print("[VoiceCommand] installTap (reinstall) failed: \(reason)")
            self.recognitionRequest = nil
            return
        }

        // Start new recognition task
        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.recognitionGeneration else { return }  // zombie task
                self.handleRecognitionResult(result: result, error: error)
                self.restartIfRecognizerEnded(result: result, error: error)
            }
        }

        print("[VoiceCommand] Restarted recognition (cleared buffer)")
    }

    /// Exit conversation mode
    func exitConversationMode() {
        state = isWakeWordEnabled ? .idle : .listening
        silenceTimer?.invalidate()
        silenceTimer = nil
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = nil
        hasSpokenThisTurn = false
        // Don't trust the recognizer to still be alive here: if it emitted its final result while
        // we were still in conversationMode, no restart fired and idle would sit deaf to the wake
        // word. Relaunch unconditionally — this also clears any stale transcript buffer.
        restartRecognition()
        print("[VoiceCommand] Exited conversation mode")
    }

    /// Start conversation timeout (auto-exit after silence)
    private func startConversationTimeout() {
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleConversationTimeout()
            }
        }
    }

    /// Handle conversation timeout - exit if user hasn't spoken
    private func handleConversationTimeout() {
        guard state == .conversationMode else { return }

        if hasSpokenThisTurn {
            // User spoke, wait for them to finish (silence timer handles this)
            print("[VoiceCommand] User is speaking, extending conversation")
        } else {
            // No speech detected, exit conversation mode
            print("[VoiceCommand] Conversation timeout - no speech detected")
            exitConversationMode()
            onConversationTimeout?()
        }
    }

    // MARK: - Recognition Handling

    /// Handle recognition result
    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        // Guard: must be actively listening
        guard isListening else {
            print("[VoiceCommand] Ignoring result - not listening")
            return
        }

        guard let result = result else {
            if let error = error {
                let errorMsg = error.localizedDescription
                // Ignore common non-critical errors
                if !errorMsg.contains("No speech detected") && !errorMsg.contains("canceled") {
                    print("[VoiceCommand] Recognition error: \(error)")
                }
            }
            return
        }

        let transcription = result.bestTranscription.formattedString
        print("[VoiceCommand] 🎤 heard(\(state)): \"\(transcription)\"")

        switch state {
        case .idle:
            currentTranscription = transcription
            // Check for wake word
            if detectWakeWord(in: transcription) {
                // AUR-743: place the end of the wake phrase on the audio clock BEFORE anything
                // restarts the recognizer (its segment timestamps belong to THIS request).
                noteWakeWordEnd(in: result, transcription: transcription)
                handleWakeWordDetected()
            }

        case .listening, .conversationMode:
            // Strip wake word from transcription (like xmeta does)
            var command = transcription
            for ww in wakeVariations {
                if let range = command.lowercased().range(of: ww) {
                    command = String(command[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            currentTranscription = command

            // Mark that user has started speaking
            if command.count > 3 {
                hasSpokenThisTurn = true
                // Cancel conversation timeout since user is speaking
                conversationTimeoutTimer?.invalidate()
            }

            // Reset silence timer on new speech
            resetSilenceTimer()

            // Check for command completion
            if result.isFinal && !command.isEmpty {
                handleCommandComplete(command)
            }

        case .processing:
            // Push-to-ask only (AUR-744): a reply is being spoken by the phone's TTS; the wake word
            // + a command interrupts it. (The old client-side stop-phrase matcher — "стоп",
            // "хватит", the tail-of-transcript lists — is GONE with AUR-742: inside the realtime
            // conversation talking IS the interrupt and stop words are the server's. It was also
            // the A5 defect: "how do I stop a nosebleed" was obeyed, not answered.)
            let allowInterrupt = shouldAllowInterrupt?() ?? false

            if allowInterrupt && detectWakeWord(in: transcription, bypassCooldown: true)
                && wakeWordAtStart(transcription) {
                // A BARE "Ok Vision" with nothing after it, mid-reply, is almost always the mic
                // hallucinating the wake word from the reply audio the speaker is playing (echo) —
                // NOT a deliberate interrupt. Real interrupts carry a follow-up ("Ok Vision, what
                // about Mars?"). Require that command; otherwise ignore and let the reply finish.
                // (To simply silence a reply, "Ok Vision stop" is handled by the stop-phrase branch
                // above.)
                let command = extractCommandAfterWakeWord(transcription)
                guard !command.isEmpty else { return }

                print("[VoiceCommand] Wake word + command during TTS - interrupting: '\(command)'")

                // Notify to stop TTS immediately
                onWakeWordDetected?()

                // Switch to listening mode - like xmeta's isCapturingCommand = true
                state = .listening
                currentTranscription = command
                hasSpokenThisTurn = true

                // Start silence timer to wait for user to finish speaking
                resetSilenceTimer()

                // If result is already final, process it
                if result.isFinal {
                    print("[VoiceCommand] Result is final, processing command immediately")
                    handleCommandComplete(command)
                }
                return
            }

            // NOTE: no naive "any speech" barge-in here — during the processing→speaking window it
            // fired on our OWN audio (the command echo and the reply the mic hears back), flipping
            // the UI to "Listening" mid-reply and tearing the session down. Deliberate interruption
            // is "Ok Vision …" (wake word at start + a command), above.
        }
    }

    /// Every phrase that counts as the wake word: the configured phrase, the stock "Ok Vision"
    /// family, and the "Aurelia" family in Latin + Cyrillic (Apple's ru-RU recognizer spells the
    /// name several ways: Аурелия / Аврелия / Орелия…). Shared by detection, barge-in and
    /// command extraction so a phrase that wakes the app is also stripped from the command.
    private var wakeVariations: [String] {
        [
            wakeWord.lowercased(),
            // OK Vision variants (most reliable)
            "ok vision", "okay vision", "o.k. vision", "o k vision",
            "hey vision", "hi vision",
            // Common misrecognitions
            "a vision", "heavy vision", "have vision", "obey vision", "oak vision",
            // Aurelia — en + ru spellings/misrecognitions
            "aurelia", "aurellia", "orelia", "aurelio", "hey aurelia", "ok aurelia",
            "аурелия", "аврелия", "аурэлия", "орелия", "аурели", "аурелие", "аврелие",
            "эй аурелия", "окей аурелия", "привет аурелия",
        ]
    }

    /// True when a wake-word variation sits at (or very near) the START of the transcript — i.e. a
    /// deliberate "Ok Vision …" barge-in. During TTS the mic also hears the reply itself, whose
    /// transcription can incidentally contain a "…vision…" buried mid-sentence; requiring the wake
    /// word up front rejects those phantoms while still catching a real interrupt.
    private func wakeWordAtStart(_ text: String) -> Bool {
        let lower = text.lowercased()
        for v in wakeVariations {
            if let r = lower.range(of: v) {
                // Characters of speech before the wake word. A little leeway ("uh, ok vision")
                // is fine; a whole sentence in front of it means it's echo, not a barge-in.
                if lower.distance(from: lower.startIndex, to: r.lowerBound) <= 12 { return true }
            }
        }
        return false
    }

    /// Detect wake word in transcription
    private func detectWakeWord(in text: String, bypassCooldown: Bool = false) -> Bool {
        guard bypassCooldown || !wakeWordCooldownActive else { return false }

        let lowercased = text.lowercased()
        let detected = wakeVariations.contains { lowercased.contains($0) }
        if detected {
            print("[VoiceCommand] Detected wake word in: '\(text)'")
        }
        return detected
    }

    /// Extract command text after wake word
    private func extractCommandAfterWakeWord(_ text: String) -> String {
        let lowercased = text.lowercased()
        for variation in wakeVariations {
            if let range = lowercased.range(of: variation) {
                let afterWakeWord = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                return afterWakeWord
            }
        }
        return ""
    }

    /// Handle wake word detection
    private func handleWakeWordDetected() {
        print("[VoiceCommand] Wake word detected!")

        // Activate cooldown
        wakeWordCooldownActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Voice.wakeWordCooldown) { [weak self] in
            self?.wakeWordCooldownActive = false
        }

        // Play activation sound
        if playActivationSound {
            playActivation()
        }

        guard pushToAskEnabled else {
            // AUR-742: the wake word is the DOOR, not a command prefix. Stay in `.idle` — the
            // conversation opens in the realtime session (the ViewModel stops this recognizer the
            // moment the rig comes up). The recognizer is relaunched so the cumulative transcript
            // (still holding «Аурелия») cannot re-fire the door after the cooldown when the
            // session fails to open (no backend, no mic).
            currentTranscription = ""
            restartRecognition()
            onWakeWordDetected?()
            return
        }

        // Push-to-ask (AUR-744): capture the command that follows the wake word.
        state = .listening
        currentTranscription = ""

        // Start command timeout
        startCommandTimeout()

        onWakeWordDetected?()
    }

    /// Handle command complete
    private func handleCommandComplete(_ text: String) {
        // Remove wake word from beginning
        var command = text
        let wakeWordLower = wakeWord.lowercased()

        for prefix in [wakeWordLower, "hey vision", "ok vision", "okay vision"] {
            if command.lowercased().hasPrefix(prefix) {
                command = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard !command.isEmpty else { return }

        print("[VoiceCommand] Command captured: \(command)")

        state = .processing
        silenceTimer?.invalidate()
        commandTimeoutTimer?.invalidate()

        // Clear transcription to prevent re-sending the same command
        currentTranscription = ""

        // Reset the recognizer's OWN buffer too. `currentTranscription = ""` only clears our copy;
        // the live SFSpeechRecognitionResult keeps accumulating the whole utterance. Without this,
        // the captured command ("…sun and the moon") lingers in the buffer during TTS, and a single
        // misheard "Okay Vision" (from the reply audio / ambient) tacks onto it and false-fires the
        // wake-word interrupt — cutting the reply off and flipping the UI back to "Listening".
        restartRecognition()

        onCommandCaptured?(command)
    }

    // MARK: - Timers (push-to-ask only, AUR-744)

    /// Reset silence timer
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: Constants.Voice.silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleSilenceTimeout()
            }
        }
    }

    /// Handle silence timeout
    private func handleSilenceTimeout() {
        guard state == .listening || state == .conversationMode else { return }

        if !currentTranscription.isEmpty {
            handleCommandComplete(currentTranscription)
        } else if state == .conversationMode {
            exitConversationMode()
        }
    }

    /// Start command timeout
    private func startCommandTimeout() {
        commandTimeoutTimer?.invalidate()
        commandTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Constants.Voice.commandTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleCommandTimeout()
            }
        }
    }

    /// Handle command timeout
    private func handleCommandTimeout() {
        guard state == .listening else { return }

        print("[VoiceCommand] Command timeout")

        if !currentTranscription.isEmpty {
            handleCommandComplete(currentTranscription)
        } else {
            state = .idle
            currentTranscription = ""
        }
    }

    // MARK: - Audio Feedback

    /// Setup activation sound
    private func setupActivationSound() {
        if let soundURL = Bundle.main.url(forResource: "activation_chime", withExtension: "wav") {
            activationSound = try? AVAudioPlayer(contentsOf: soundURL)
            activationSound?.prepareToPlay()
        }
    }

    /// Play activation sound
    private func playActivation() {
        activationSound?.currentTime = 0
        activationSound?.play()
    }
}

// MARK: - Errors

enum VoiceCommandError: LocalizedError {
    case notAuthorized
    case audioEngineUnavailable
    case requestCreationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition not authorized"
        case .audioEngineUnavailable: return "Audio engine unavailable"
        case .requestCreationFailed: return "Failed to create speech recognition request"
        }
    }
}
