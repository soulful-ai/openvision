// OpenVision - AudioCaptureService.swift
// Continuous 40 ms PCM16 mic capture for the full-duplex realtime session (AUR-723).
//
// Changes vs the pre-AUR-723 version:
//   • attaches to the ONE shared AVAudioEngine (AudioSessionManager) instead of spinning up its
//     own — three parallel engines were what made VPIO/AEC impossible (plan fault B11);
//   • `AVAudioConverter` for the rate/format conversion instead of hand-rolled linear
//     interpolation (aliasing on the 48k → 24k step);
//   • 40 ms frames instead of 100 ms → ~30 ms less speech-onset latency;
//   • the tap is reinstalled on route/configuration changes instead of the session being torn down.

import AVFoundation

// MARK: - Audio-thread chunker (no actor isolation — the tap runs on the render thread)

/// Converts tap buffers to mono PCM16 at a target rate and emits FIXED-SIZE frames.
/// Pure audio-thread object: no main-actor hops per buffer, no allocation beyond the frame Data.
final class AudioCaptureChunker: @unchecked Sendable {
    let targetSampleRate: Double
    /// Bytes per emitted frame (PCM16 mono).
    let frameBytes: Int

    /// Called on the audio thread with exactly `frameBytes` of PCM16.
    var onFrame: ((Data) -> Void)?
    /// Called on the audio thread with the RMS of each converted buffer (0…1).
    var onLevel: ((Float) -> Void)?

    private var pending = Data()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private let targetFormat: AVAudioFormat

    init?(targetSampleRate: Double, frameMs: Int) {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: targetSampleRate,
                                      channels: 1,
                                      interleaved: true) else { return nil }
        self.targetFormat = fmt
        self.targetSampleRate = targetSampleRate
        self.frameBytes = max(2, Int(targetSampleRate) * frameMs / 1000 * 2)
    }

    /// Feed one tap buffer.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        let frameLength = Int(converted.frameLength)
        guard frameLength > 0, let int16 = converted.int16ChannelData else { return }

        var sumSquares: Double = 0
        for i in 0..<frameLength {
            let s = Double(int16[0][i]) / Double(Int16.max)
            sumSquares += s * s
        }
        onLevel?(Float((sumSquares / Double(frameLength)).squareRoot()))

        let pcm = Data(bytes: int16[0], count: frameLength * MemoryLayout<Int16>.size)

        lock.lock()
        pending.append(pcm)
        var frames: [Data] = []
        while pending.count >= frameBytes {
            frames.append(Data(pending.prefix(frameBytes)))
            pending.removeFirst(frameBytes)
        }
        lock.unlock()

        for frame in frames { onFrame?(frame) }
    }

    /// Emit whatever partial frame is left (session end).
    func flush() {
        lock.lock()
        let remaining = pending
        pending.removeAll()
        lock.unlock()
        if !remaining.isEmpty { onFrame?(remaining) }
    }

    /// Drop the cached converter (route change → new input format).
    func resetConverter() {
        converter = nil
        converterSource = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        if converter == nil || converterSource != source {
            guard let made = AVAudioConverter(from: source, to: targetFormat) else { return nil }
            made.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = made
            converterSource = source
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || out.frameLength == 0 {
            if let error { ovLog("[AudioCapture] Convert failed: \(error)") }
            return nil
        }
        return out
    }
}

// MARK: - Service

/// Captures audio from the microphone, continuously, while a session is live.
@MainActor
final class AudioCaptureService: ObservableObject {
    // MARK: - Published State

    @Published var isCapturing: Bool = false
    @Published var audioLevel: Float = 0

    // MARK: - Callbacks

    /// Called when audio data is captured (PCM Int16, mono, `targetSampleRate`).
    var onAudioCaptured: ((Data) -> Void)?

    // MARK: - Audio Engine

    private weak var engine: AVAudioEngine?
    private var ownsEngine = false
    private var tappedNode: AVAudioInputNode?
    private var chunker: AudioCaptureChunker?

    /// When the last mic frame reached the main actor. The realtime session is deaf the moment
    /// this stops advancing, and it stops silently: iOS can kill a running tap on a route or
    /// engine-configuration change (starting the phone camera is one such trigger) without
    /// throwing anything at us.
    private(set) var lastFrameAt: Date = .distantPast
    private var stallWatchdog: Timer?
    /// Seconds of no frames before the tap is reinstalled.
    private let stallTimeout: TimeInterval = 3.0
    private var stallRecoveries = 0

    // MARK: - Audio Format

    /// Target sample rate for output.
    var targetSampleRate: Double = Double(Constants.OpenAIRealtime.inputSampleRate)

    /// Frame duration in milliseconds (AUR-723: 40 ms).
    var chunkDurationMs: Int = Constants.RealtimeAudio.captureFrameMs

    // MARK: - Start/Stop

    /// Start capturing audio. Pass the shared engine to run capture and playback on ONE engine
    /// (required for voice-processing IO / AEC); omit it to keep the legacy standalone behaviour.
    func startCapture(engine sharedEngine: AVAudioEngine? = nil) throws {
        guard !isCapturing else { return }

        let engine: AVAudioEngine
        if let sharedEngine {
            engine = sharedEngine
            ownsEngine = false
        } else {
            engine = AVAudioEngine()
            ownsEngine = true
        }
        self.engine = engine

        try installTap(on: engine)

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        isCapturing = true
        lastFrameAt = Date()
        startStallWatchdog()
        ovLog("[AudioCapture] Started (frame \(chunkDurationMs) ms → \(Int(targetSampleRate)) Hz PCM16, shared engine: \(!ownsEngine))")
    }

    /// Stop capturing audio.
    func stopCapture() {
        guard isCapturing else { return }

        stallWatchdog?.invalidate()
        stallWatchdog = nil
        tappedNode?.removeTap(onBus: 0)
        tappedNode = nil
        if ownsEngine { engine?.stop() }
        engine = nil

        chunker?.flush()
        chunker = nil
        isCapturing = false
        ovLog("[AudioCapture] Stopped capturing")
    }

    /// Reinstall the tap after a route / engine-configuration change WITHOUT tearing the session
    /// down (AUR-723: A2DP ⇄ HFP ⇄ LE Audio switches change the input format underneath us).
    func reconfigure(engine sharedEngine: AVAudioEngine?) {
        guard isCapturing else { return }
        guard let target = sharedEngine ?? engine else { return }
        tappedNode?.removeTap(onBus: 0)
        tappedNode = nil
        chunker?.resetConverter()
        self.engine = target
        do {
            try installTap(on: target)
            if !target.isRunning {
                target.prepare()
                try target.start()
            }
            lastFrameAt = Date()
            ovLog("[AudioCapture] Tap reinstalled — input now \(target.inputNode.outputFormat(forBus: 0).sampleRate) Hz")
        } catch {
            ovLog("[AudioCapture] Failed to reinstall tap: \(error)")
        }
    }

    // MARK: - Tap

    private func installTap(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0 else { throw AudioCaptureError.inputNodeUnavailable }
        ovLog("[AudioCapture] Native input format: \(nativeFormat)")

        let chunker = self.chunker ?? AudioCaptureChunker(targetSampleRate: targetSampleRate, frameMs: chunkDurationMs)
        guard let chunker else { throw AudioCaptureError.engineCreationFailed }
        chunker.onFrame = { [weak self] frame in
            Task { @MainActor in
                guard let self else { return }
                self.lastFrameAt = Date()
                self.onAudioCaptured?(frame)
            }
        }
        chunker.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        self.chunker = chunker

        // One target frame's worth of native samples keeps the pipeline at ~40 ms granularity.
        let bufferSize = AVAudioFrameCount(max(256, Int(nativeFormat.sampleRate) * chunkDurationMs / 1000))
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nativeFormat) { buffer, _ in
            chunker.process(buffer)
        }
        tappedNode = inputNode
    }

    /// A live session that stops hearing the wearer is the worst failure this app has (she
    /// answers once, then never again). Nothing throws when it happens, so poll: no frames for
    /// `stallTimeout` while capturing → reinstall the tap and restart the engine.
    private func startStallWatchdog() {
        stallWatchdog?.invalidate()
        stallWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCapturing else { return }
                let silence = Date().timeIntervalSince(self.lastFrameAt)
                guard silence > self.stallTimeout else { return }
                self.stallRecoveries += 1
                ovLog("[AudioCapture] ⚠︎ mic stalled \(String(format: "%.1f", silence))s — reinstalling tap (recovery #\(self.stallRecoveries))")
                self.lastFrameAt = Date()   // give the reinstall a full window before retrying
                self.reconfigure(engine: self.engine)
            }
        }
    }

    /// Rebuild the chunker for a new target rate / frame size. Call before `startCapture`.
    func applyFormatSettings() {
        chunker = AudioCaptureChunker(targetSampleRate: targetSampleRate, frameMs: chunkDurationMs)
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case engineCreationFailed
    case inputNodeUnavailable

    var errorDescription: String? {
        switch self {
        case .engineCreationFailed: return "Failed to create audio engine"
        case .inputNodeUnavailable: return "Audio input node unavailable"
        }
    }
}
