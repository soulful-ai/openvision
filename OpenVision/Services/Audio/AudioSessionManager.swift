// OpenVision - AudioSessionManager.swift
// Owns the AVAudioSession configuration AND the ONE shared AVAudioEngine (AUR-723).
//
// Before AUR-723 the app ran three separate engines (STT tap, mic capture, playback) plus Kokoro's,
// with `mode: .default` and no echo cancellation anywhere (plan fault A7/B11). Full duplex needs
// the opposite: a single `.playAndRecord` + `.voiceChat` engine with voice-processing IO (Apple's
// AEC/AGC/NS) on the input node, so the mic can stay open while the assistant speaks without the
// server barging in on its own voice.
//
// Route changes (A2DP <-> HFP when the glasses mic opens, LE Audio, phone mic, AirPods) are
// observed and reported instead of tearing the session down: the capture tap is reinstalled on the
// new input format and the session survives.

import AVFoundation

/// Manages audio session configuration
@MainActor
final class AudioSessionManager {
    // MARK: - Singleton

    static let shared = AudioSessionManager()

    // MARK: - Properties

    private let audioSession = AVAudioSession.sharedInstance()

    /// Current audio mode
    private(set) var currentMode: AudioMode = .inactive

    // MARK: - Audio Modes

    enum AudioMode {
        /// No audio session active
        case inactive

        /// Voice chat mode (aggressive echo cancellation for iPhone mic)
        case voiceChat

        /// Video chat mode (mild echo cancellation for glasses mic)
        case videoChat

        /// Measurement mode (for wake word detection)
        case measurement
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Configuration

    /// Configure audio session for specified mode
    func configure(for mode: AudioMode) throws {
        guard mode != currentMode else { return }

        switch mode {
        case .inactive:
            try deactivate()

        case .voiceChat:
            try configureVoiceChat()

        case .videoChat:
            try configureVideoChat()

        case .measurement:
            try configureMeasurement()
        }

        currentMode = mode
        ovLog("[AudioSession] Configured for \(mode)")
    }

    /// Deactivate audio session
    func deactivate() throws {
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        currentMode = .inactive
    }

    // MARK: - Mode Configurations

    /// Configure for voice chat (iPhone mic, aggressive AEC)
    private func configureVoiceChat() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .mixWithOthers,
                .duckOthers
            ]
        )
        try audioSession.setActive(true)
    }

    /// Configure for video chat (glasses mic, mild AEC)
    private func configureVideoChat() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .mixWithOthers
            ]
        )
        try audioSession.setActive(true)
    }

    /// Configure for measurement (wake word detection)
    private func configureMeasurement() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .duckOthers
            ]
        )
        try audioSession.setActive(true)
    }

    // MARK: - Bluetooth HFP Routing

    /// Configure the audio session for the glasses' Bluetooth HFP mic + speaker.
    /// Returns `true` only if an HFP input was actually found and selected (i.e. the glasses are
    /// connected as an audio device); `false` means no glasses audio is present and the caller
    /// should fall back to the phone. NOTE: we must set the category with `.allowBluetoothHFP` and
    /// activate the session *first* — only then does iOS expose the HFP input in `availableInputs`
    /// (this is what previously made the glasses mic undetectable: the phone route disallows HFP).
    @discardableResult
    func configureForGlasses() throws -> Bool {
        // Match OpenGlasses: `.default` mode + `.mixWithOthers` so the recognizer's session COEXISTS
        // with the glasses camera's Bluetooth stream instead of taking exclusive HFP control. With
        // `.voiceChat` + `.duckOthers` the camera stream killed the HFP mic (and iOS wouldn't revive
        // it); `.mixWithOthers` keeps the glasses mic alive through photo capture.
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Now that HFP is allowed + the session is active, the glasses mic should be listed.
        guard let hfpInput = findBluetoothHFPInput() else {
            ovLog("[AudioSession] No Bluetooth HFP input — glasses not connected as an audio device. Inputs: \(availableInputsDescription)")
            return false
        }
        try audioSession.setPreferredInput(hfpInput)
        currentMode = .voiceChat
        ovLog("[AudioSession] ✓ Configured for glasses (Bluetooth HFP): \(hfpInput.portName) — route: \(currentRouteDescription)")
        return true
    }

    /// Names + types of every input iOS currently reports — for diagnosing mic routing.
    var availableInputsDescription: String {
        (audioSession.availableInputs ?? []).map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ", ")
    }

    /// Configure audio for phone-only use (no glasses): record from the built-in mic and play
    /// spoken responses out of the LOUD speaker. Without `.defaultToSpeaker`, `.playAndRecord`
    /// routes output to the quiet earpiece — which is why phone-only audio was inaudible.
    /// `.allowBluetoothA2DP` still lets AirPods / other Bluetooth audio work when present.
    func configureForPhone() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothA2DP]
        )
        try audioSession.setActive(true)
        // If still routed to the quiet earpiece (carried over from a glasses/voiceChat config),
        // force the loud speaker — but leave AirPods / headphones alone if they're connected.
        if audioSession.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
            try? audioSession.overrideOutputAudioPort(.speaker)
        }
        currentMode = .voiceChat
        ovLog("[AudioSession] Configured for phone (built-in mic + loud speaker)")
    }

    /// Find Bluetooth HFP input port
    private func findBluetoothHFPInput() -> AVAudioSessionPortDescription? {
        for input in audioSession.availableInputs ?? [] {
            if input.portType == .bluetoothHFP {
                return input
            }
        }
        return nil
    }

    /// Check if Bluetooth HFP is currently active
    var isBluetoothHFPActive: Bool {
        let inputs = audioSession.currentRoute.inputs
        let outputs = audioSession.currentRoute.outputs

        let hasHFPInput = inputs.contains { $0.portType == .bluetoothHFP }
        let hasHFPOutput = outputs.contains { $0.portType == .bluetoothHFP }

        return hasHFPInput || hasHFPOutput
    }

    /// Get current audio route description
    var currentRouteDescription: String {
        let inputs = audioSession.currentRoute.inputs.map { $0.portName }.joined(separator: ", ")
        let outputs = audioSession.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        return "Input: \(inputs.isEmpty ? "none" : inputs), Output: \(outputs.isEmpty ? "none" : outputs)"
    }

    // MARK: - AUR-723: the ONE shared engine + full-duplex configuration

    /// The single AVAudioEngine shared by capture and playback while a realtime session is live.
    private(set) var sharedEngine: AVAudioEngine?

    /// True when voice-processing IO (AEC/AGC/NS) is active on the shared engine's input node.
    private(set) var voiceProcessingEnabled = false

    /// Fired (main actor) when the audio route changes while the shared engine is up.
    var onRouteChange: ((RouteInfo) -> Void)?
    /// Fired when AVAudioEngine reports a configuration change (format/route churn): the capture
    /// tap must be reinstalled and the engine restarted.
    var onEngineConfigurationChange: (() -> Void)?

    private var routeObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    /// What the client reports to the brain as `metadata.route` — the rig actually in use.
    struct RouteInfo {
        let inputPort: String
        let inputType: String
        let outputPort: String
        let outputType: String
        let sampleRate: Double
        let reason: String

        /// Compact tag for the session metadata / logs, e.g. "a2dp+phone-mic".
        var tag: String {
            let mic: String
            switch inputType {
            case AVAudioSession.Port.bluetoothHFP.rawValue: mic = "bt-mic"
            case AVAudioSession.Port.builtInMic.rawValue: mic = "phone-mic"
            case AVAudioSession.Port.headsetMic.rawValue: mic = "headset-mic"
            default: mic = inputType.isEmpty ? "no-mic" : inputType
            }
            let out: String
            switch outputType {
            case AVAudioSession.Port.bluetoothA2DP.rawValue: out = "a2dp"
            case AVAudioSession.Port.bluetoothHFP.rawValue: out = "hfp"
            case AVAudioSession.Port.bluetoothLE.rawValue: out = "le-audio"
            case AVAudioSession.Port.builtInSpeaker.rawValue: out = "speaker"
            case AVAudioSession.Port.builtInReceiver.rawValue: out = "earpiece"
            case AVAudioSession.Port.headphones.rawValue: out = "headphones"
            default: out = outputType.isEmpty ? "no-out" : outputType
            }
            return "\(out)+\(mic)"
        }

        var description: String {
            "\(tag) [in: \(inputPort) (\(inputType)), out: \(outputPort) (\(outputType)), \(Int(sampleRate)) Hz]"
        }
    }

    /// AUR-724b — may we tell the brain "this client cancels its own echo"?
    ///
    /// Only when the PHONE is doing the cancelling: voice-processing IO is on AND the mic is one
    /// the VPIO unit actually owns (the built-in mic, or a wired headset mic on the same IO).
    /// A Bluetooth mic is NOT covered — with the glasses' mic the echo path is their speaker into
    /// their own mic, which the phone's VPIO never sees. Claiming AEC there would make the server
    /// drop its echo-level gate and start barging in on its own voice, so the honest answer is no.
    var clientAECActive: Bool {
        guard voiceProcessingEnabled else { return false }
        guard let input = audioSession.currentRoute.inputs.first else { return false }
        switch input.portType {
        case .builtInMic, .headsetMic: return true
        default: return false   // bluetoothHFP / bluetoothLE / anything else: not ours to claim
        }
    }

    /// Snapshot of the live route.
    var routeInfo: RouteInfo {
        let route = audioSession.currentRoute
        let input = route.inputs.first
        let output = route.outputs.first
        return RouteInfo(inputPort: input?.portName ?? "",
                         inputType: input?.portType.rawValue ?? "",
                         outputPort: output?.portName ?? "",
                         outputType: output?.portType.rawValue ?? "",
                         sampleRate: audioSession.sampleRate,
                         reason: "snapshot")
    }

    /// Configure the session for a continuous full-duplex conversation.
    ///
    /// `preferGlassesMic` keeps the existing "glasses mic ON" setting working: HFP is allowed and
    /// the glasses' HFP input is pinned when present (classic BT then downgrades playback to HFP —
    /// the known "robotic voice" trade-off). With it off we stay on A2DP output + the phone mic,
    /// which is the recommended default on classic BT (plan §4.2).
    ///
    /// Returns true when the glasses mic was actually selected.
    @discardableResult
    func configureFullDuplex(preferGlassesMic: Bool) throws -> Bool {
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers]
        if preferGlassesMic { options.insert(.allowBluetoothHFP) }

        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        // A short IO buffer keeps the flush-to-silence inside one render quantum (~5 ms at 24 kHz).
        try? audioSession.setPreferredIOBufferDuration(0.005)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        var usingGlasses = false
        if preferGlassesMic, let hfp = findBluetoothHFPInput() {
            try? audioSession.setPreferredInput(hfp)
            usingGlasses = true
            ovLog("[AudioSession] Full duplex on the glasses mic (HFP): \(hfp.portName)")
        } else {
            // Explicitly release any pinned input so iOS picks the built-in mic and playback can
            // stay on A2DP.
            try? audioSession.setPreferredInput(nil)
            if audioSession.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
                try? audioSession.overrideOutputAudioPort(.speaker)
            }
        }
        currentMode = .voiceChat
        ovLog("[AudioSession] Full duplex configured — route: \(routeInfo.description)")
        return usingGlasses
    }

    /// Create (or return) the ONE engine used by capture + playback, with voice-processing IO
    /// enabled on the input node so the assistant's own voice is cancelled out of the mic.
    @discardableResult
    func startSharedEngine(voiceProcessing: Bool = true) throws -> AVAudioEngine {
        if let engine = sharedEngine {
            if !engine.isRunning { engine.prepare(); try engine.start() }
            return engine
        }
        let engine = AVAudioEngine()
        // Touching inputNode instantiates the IO unit; VPIO must be enabled before the engine runs.
        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
                ovLog("[AudioSession] Voice-processing IO (AEC/AGC/NS) enabled on the input node")
            } catch {
                voiceProcessingEnabled = false
                ovLog("[AudioSession] Voice processing unavailable on this route: \(error)")
            }
        } else {
            voiceProcessingEnabled = false
        }
        // AUR-772: a 0 Hz input format here means the IO unit has no mic — the previous session's
        // VPIO unit is still being torn down, or the mic was lost with the route. An engine started
        // in that state "runs" but the capture tap can never be installed (the second call of the
        // evening was exactly this: hang up → Talk → deaf). Fall back to plain IO once, then fail
        // loudly so the caller can retry instead of guessing.
        if input.outputFormat(forBus: 0).sampleRate <= 0, voiceProcessingEnabled {
            ovLog("[AudioSession] Input format is 0 Hz with VPIO on — retrying without voice processing")
            try? input.setVoiceProcessingEnabled(false)
            voiceProcessingEnabled = false
        }
        guard input.outputFormat(forBus: 0).sampleRate > 0 else {
            ovLog("[AudioSession] ✗ No usable mic input (0 Hz) — route \(routeInfo.description), inputs: \(availableInputsDescription)")
            throw AudioCaptureError.inputNodeUnavailable
        }
        // Realize the main mixer before the first attach so the graph has a valid output format.
        _ = engine.mainMixerNode
        engine.prepare()
        try engine.start()
        sharedEngine = engine
        installRouteObservers()
        ovLog("[AudioSession] Shared engine started — input \(input.outputFormat(forBus: 0).sampleRate) Hz, route \(routeInfo.description)")
        return engine
    }

    /// Tear the shared engine down (end of a realtime session).
    ///
    /// AUR-772: the teardown is explicit, not left to ARC. The voice-processing IO unit is
    /// switched off and the engine reset BEFORE the reference is dropped — a VPIO unit that is
    /// still alive when the next session creates its engine is what left the next call without a
    /// mic (0 Hz input, "Audio input node unavailable") until the app was relaunched.
    func stopSharedEngine() {
        removeRouteObservers()
        if let engine = sharedEngine {
            if engine.isRunning { engine.stop() }
            if voiceProcessingEnabled {
                do { try engine.inputNode.setVoiceProcessingEnabled(false) }
                catch { ovLog("[AudioSession] Could not disable voice processing on teardown: \(error)") }
            }
            engine.reset()
            ovLog("[AudioSession] Shared engine stopped and released")
        }
        sharedEngine = nil
        voiceProcessingEnabled = false
    }

    /// AUR-772: end the realtime rig completely — engine down, then the session deactivated with
    /// `.notifyOthersOnDeactivation` so the HFP/VPIO IO is actually released. The next
    /// `configure*` call reactivates with a full category/mode/options set, so stop → start is
    /// a clean cycle rather than a reconfigure on top of a half-torn-down session.
    func endRealtimeRig() {
        stopSharedEngine()
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            currentMode = .inactive
            ovLog("[AudioSession] Session deactivated after the realtime rig")
        } catch {
            // 560030580 (!act) = some IO still running (a TTS player, another engine). Not fatal:
            // the next configure* reactivates regardless; just say so.
            ovLog("[AudioSession] Deactivate after the realtime rig failed (IO still busy?): \(error)")
        }
    }

    /// Microphone permission as iOS sees it right now (`AVAudioApplication`, iOS 17+).
    var recordPermissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Seconds between "rendered by the engine" and "heard": output latency + one IO buffer.
    /// On Bluetooth HFP this is a few hundred ms — a farewell whose ring just drained is STILL in
    /// this tail, and stopping the engine now cuts it (AUR-772).
    var playoutTailSeconds: TimeInterval {
        audioSession.outputLatency + audioSession.ioBufferDuration
    }

    // MARK: - AUR-793b: the music-capture window (`phone.shazam`)

    /// What `beginMusicWindow()` took away, so `endMusicWindow(_:)` can put it back exactly.
    struct MusicWindow {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let preferredInput: AVAudioSessionPortDescription?
        let sampleRate: Double
        /// The live call's shared engine was running and got paused for the window.
        let enginePaused: Bool
        /// Voice processing was on before the window (it goes back on at the end).
        let voiceProcessingWas: Bool
    }

    /// True while a `phone.shazam` listen owns the mic. Route / configuration churn caused by the
    /// window ITSELF is not a mic change and must not be reported to the live call — otherwise
    /// every listen restarts the STT stream and re-hydrates the memory budget twice (visible in the
    /// 2026-08-21 12:03Z pod log, once per listen, in each direction).
    private(set) var musicWindowActive = false

    /// The mic label the tool reports: which port actually carries the audio right now.
    var micLabel: String {
        switch audioSession.currentRoute.inputs.first?.portType {
        case .some(.builtInMic): return "phone"
        case .some(.bluetoothHFP), .some(.bluetoothLE): return "glasses"
        case .some(.headsetMic), .some(.headphones): return "headset"
        case .some(let other): return other.rawValue
        case .none: return "none"
        }
    }

    /// The capture conditions read-out for a `phone.shazam` result (AUR-793b). `sampleRate` and
    /// `voiceProcessing` come from the LISTEN's own engine — the session's preferred values are a
    /// request, the tap's format is the truth.
    func musicCaptureConditions(sampleRate: Double, voiceProcessing: Bool, callPaused: Bool) -> MusicCaptureConditions {
        MusicCaptureConditions(mic: micLabel,
                               category: audioSession.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""),
                               mode: audioSession.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""),
                               voiceProcessing: voiceProcessing,
                               sampleRate: sampleRate > 0 ? sampleRate : audioSession.sampleRate,
                               peakDbfs: -120,
                               route: routeInfo.tag,
                               callPaused: callPaused)
    }

    /// Open a listen window. This first cut only SNAPSHOTS the rig and reports it — the
    /// reconfiguration lands in the next commit; the observability has to come first so the next
    /// field attempt says what it ran on either way.
    @discardableResult
    func beginMusicWindow() -> MusicWindow {
        musicWindowActive = true
        let window = MusicWindow(category: audioSession.category,
                                 mode: audioSession.mode,
                                 options: audioSession.categoryOptions,
                                 preferredInput: audioSession.preferredInput,
                                 sampleRate: audioSession.sampleRate,
                                 enginePaused: false,
                                 voiceProcessingWas: voiceProcessingEnabled)
        ovLog("[AudioSession] 🎵 music window open — \(routeInfo.description), mode \(audioSession.mode.rawValue), vp \(voiceProcessingEnabled ? "on" : "off")")
        return window
    }

    /// Close the listen window and put the rig back.
    func endMusicWindow(_ window: MusicWindow) {
        musicWindowActive = false
        ovLog("[AudioSession] 🎵 music window closed — \(routeInfo.description)")
    }

    // MARK: - Route observers

    private func installRouteObservers() {
        removeRouteObservers()
        let center = NotificationCenter.default
        routeObserver = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            Task { @MainActor in self?.handleRouteChange(reason) }
        }
        configObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: sharedEngine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleEngineConfigurationChange() }
        }
        interruptionObserver = center.addObserver(forName: AVAudioSession.interruptionNotification, object: audioSession, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            Task { @MainActor in self?.handleInterruption(AVAudioSession.InterruptionType(rawValue: raw)) }
        }
    }

    private func removeRouteObservers() {
        let center = NotificationCenter.default
        if let routeObserver { center.removeObserver(routeObserver) }
        if let configObserver { center.removeObserver(configObserver) }
        if let interruptionObserver { center.removeObserver(interruptionObserver) }
        routeObserver = nil; configObserver = nil; interruptionObserver = nil
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        // AUR-793b: the churn a music window causes is the window's own doing, not a mic change.
        guard !musicWindowActive else {
            ovLog("[AudioSession] Route change (\(reason)) inside the music window — not reported")
            return
        }
        let info = RouteInfo(inputPort: routeInfo.inputPort, inputType: routeInfo.inputType,
                             outputPort: routeInfo.outputPort, outputType: routeInfo.outputType,
                             sampleRate: routeInfo.sampleRate, reason: String(describing: reason))
        ovLog("[AudioSession] Route change (\(info.reason)) → \(info.description)")
        // The route moved (BT connected/lost, HFP<->A2DP): the engine keeps running, but the input
        // format may have changed — the capture tap is reinstalled by the callback.
        onRouteChange?(info)
        onEngineConfigurationChange?()
    }

    private func handleEngineConfigurationChange() {
        guard !musicWindowActive else {
            ovLog("[AudioSession] Engine configuration change inside the music window — deferred to its close")
            return
        }
        ovLog("[AudioSession] AVAudioEngine configuration change — rebuilding taps")
        onEngineConfigurationChange?()
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard let type else { return }
        switch type {
        case .began:
            ovLog("[AudioSession] Interruption began (call/Siri)")
        case .ended:
            ovLog("[AudioSession] Interruption ended — reactivating")
            try? audioSession.setActive(true)
            onEngineConfigurationChange?()
        @unknown default:
            break
        }
    }

    // MARK: - Utilities

    /// Get current input sample rate
    var inputSampleRate: Double {
        audioSession.sampleRate
    }

    /// Get current output sample rate
    var outputSampleRate: Double {
        audioSession.sampleRate
    }

    /// Check if Bluetooth audio is available
    var isBluetoothAvailable: Bool {
        audioSession.availableInputs?.contains { port in
            port.portType == .bluetoothHFP || port.portType == .bluetoothA2DP
        } ?? false
    }

    /// Check if using built-in mic
    var isUsingBuiltInMic: Bool {
        audioSession.currentRoute.inputs.contains { port in
            port.portType == .builtInMic
        }
    }
}
