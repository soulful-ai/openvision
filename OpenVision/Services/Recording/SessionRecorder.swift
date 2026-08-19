// OpenVision - SessionRecorder.swift
// Records the glasses point-of-view (video) plus the phone microphone (audio) into a single
// .mp4 and saves it to the Photos library — for demo clips of "what I'm looking at and the
// answer I'm getting back."
//
// Design notes:
//  • Video comes from the glasses stream as CMSampleBuffers (see GlassesManager.onVideoSampleBuffer),
//    muxed straight into an AVAssetWriter — no re-encode of the pixels beyond H.264.
//  • Audio comes from THIS service's OWN AVAudioEngine mic tap, deliberately independent of
//    AudioCaptureService / the realtime backends (in live-video mode those own the mic, so we
//    can't rely on them). Because the audio session is `.playAndRecord` + `.defaultToSpeaker`,
//    the AI's spoken (TTS) reply plays out the speaker and the mic picks it up — so the recording
//    contains the scene sound AND the assistant's answer, "as experienced".
//      Tradeoffs (acceptable for demo clips): speaker-captured audio is roomy, not studio-clean;
//      if TTS is routed to a Bluetooth headset it won't be captured; Bluetooth adds slight AV lag.
//  • Both tracks are timestamped on ONE host clock so they stay in sync.
//
// All AVAssetWriter mutation happens on a private serial queue; video frames arrive on the main
// actor and audio buffers on the audio render thread, so both are hopped onto that queue.

import Foundation
import AVFoundation
import Photos
import CoreMedia

enum RecorderError: LocalizedError {
    case inputUnavailable
    case tapFailed(String)

    var errorDescription: String? {
        switch self {
        case .inputUnavailable: return "Microphone input unavailable"
        case .tapFailed(let reason): return "Mic tap failed: \(reason)"
        }
    }
}

final class SessionRecorder: ObservableObject {

    static let shared = SessionRecorder()

    /// Whether a recording is currently in progress (published on the main thread for the UI).
    @Published private(set) var isRecording = false

    /// Called on the main thread after `stop()` finishes, with the saved asset URL (or nil on failure).
    var onFinished: ((URL?) -> Void)?

    // MARK: - Writer state (touched only on `writerQueue`)

    private let writerQueue = DispatchQueue(label: "com.openvision.session-recorder")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?

    // MARK: - Playback (AI voice) track state — touched only on `writerQueue`
    //
    // The assistant's spoken reply is captured DIGITALLY (taps on the playback engines' mixer
    // nodes forward their buffers here) into a second audio track, because the acoustic path
    // (speaker → room → mic) buries it under ambient noise. At stop, the tracks are merged with
    // the mic ducked while the assistant speaks.

    private var playbackInput: AVAssetWriterInput?
    /// End PTS of the last playback sample written. Playback audio is sparse (only while the
    /// assistant speaks) but an audio track's samples are laid out contiguously — gaps must be
    /// filled with silence or everything after a gap plays early and drifts out of sync.
    private var playbackCursor: CMTime = .zero
    /// Time ranges (writer timeline) where the assistant was speaking — drives mic ducking.
    private var speechIntervals: [CMTimeRange] = []
    private var didCapturePlayback = false
    /// Keeps the playback track continuously silence-filled to within ~1 s of "now". Without it
    /// the first audible buffer of a reply had to backfill the entire recording-so-far in one
    /// burst; the realtime input throttled mid-burst and the reply's first ~second was dropped —
    /// heard as the roomy mic version of the assistant's voice before the clean track "kicks in".
    private var silencePump: DispatchSourceTimer?

    private let hostClock = CMClockGetHostTimeClock()
    /// Host time of the first video frame; the writer session starts at .zero, everything else is
    /// stamped relative to this. `nil` until the first video frame creates the writer.
    private var sessionStart: CMTime?
    private var outputURL: URL?
    private var finished = false
    private var videoFrameCount = 0

    // MARK: - Audio capture (own engine)

    /// Recreated (not just restarted) on every mic re-arm: a stopped engine keeps reporting the
    /// pre-route-change input format, and installing a tap with that stale format fails forever.
    private var audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?

    /// Converter for playback (AI voice) buffers. Sources differ (Kokoro: 24 kHz mono; realtime
    /// backends: device-rate stereo) and may interleave, so it's rebuilt when the format changes.
    /// Guarded by `playbackConvertLock` — tap callbacks arrive on each engine's render thread.
    private var playbackConverter: AVAudioConverter?
    private var playbackSourceFormat: AVAudioFormat?
    private let playbackConvertLock = NSLock()
    /// Canonical output format we feed to the writer: mono Int16, 44.1kHz — trivial to package as
    /// a CMSampleBuffer and fine for AAC transcode.
    private let audioOutFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 44_100,
                                               channels: 1,
                                               interleaved: true)!

    private init() {}

    // MARK: - Public API

    /// Begin recording. Video frames must then be forwarded via `appendVideoSampleBuffer(_:)`.
    /// The writer is created lazily on the first video frame (once we know the pixel dimensions).
    func start() throws {
        guard !isRecording else { return }

        let dir = FileManager.default.temporaryDirectory
        let name = "OpenVision-\(Int(CMClockGetTime(hostClock).seconds * 1000)).mp4"
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        writerQueue.sync {
            self.outputURL = url
            self.writer = nil
            self.videoInput = nil
            self.pixelAdaptor = nil
            self.audioInput = nil
            self.playbackInput = nil
            self.playbackCursor = .zero
            self.speechIntervals = []
            self.didCapturePlayback = false
            self.silencePump?.cancel()
            self.silencePump = nil
            self.sessionStart = nil
            self.finished = false
            self.videoFrameCount = 0
        }
        playbackConvertLock.lock()
        playbackConverter = nil
        playbackSourceFormat = nil
        playbackConvertLock.unlock()

        try startMic()

        DispatchQueue.main.async { self.isRecording = true }
        NSLog("[Recorder] Started → %@", url.lastPathComponent)
    }

    /// Stop recording, finalize the file, and save it to Photos. `onFinished` fires on the main
    /// thread with the saved URL (or nil on failure).
    func stop() {
        guard isRecording else { return }

        // Tear the mic down first so no more audio is enqueued.
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        DispatchQueue.main.async { self.isRecording = false }

        writerQueue.async {
            guard let writer = self.writer, !self.finished else {
                // Nothing was ever written (e.g. no frames arrived) — report failure cleanly.
                self.finish(url: nil)
                return
            }
            self.finished = true
            self.silencePump?.cancel()
            self.silencePump = nil
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.playbackInput?.markAsFinished()
            // Snapshot on the writer queue — the finishWriting completion runs elsewhere.
            let intervals = self.didCapturePlayback ? self.speechIntervals : []
            writer.finishWriting {
                if writer.status == .completed, let url = self.outputURL {
                    if intervals.isEmpty {
                        // No assistant speech captured — nothing to merge, ship the raw file.
                        self.saveToPhotos(url)
                    } else {
                        Task { await self.mergeAndSave(rawURL: url, speechIntervals: intervals) }
                    }
                } else {
                    NSLog("[Recorder] finishWriting failed: %@", String(describing: writer.error))
                    self.finish(url: nil)
                }
            }
        }
    }

    // MARK: - Merge (mic + AI voice → one track, mic ducked while the assistant speaks)

    /// Combine the raw file's three tracks (video, mic, assistant voice) into a single shareable
    /// .mp4. The export mixes both audio tracks into one; an AVAudioMix ducks the mic to 25%
    /// while the assistant speaks so its digitally-captured voice reads clearly over ambient
    /// noise (and over its own faint acoustic echo picked up by the mic). Falls back to the raw
    /// file on any failure — that still has the mic track, matching pre-merge behavior.
    private func mergeAndSave(rawURL: URL, speechIntervals: [CMTimeRange]) async {
        let asset = AVURLAsset(url: rawURL)
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            // Writer add-order: [0] mic, [1] assistant voice.
            guard let videoTrack = videoTracks.first, audioTracks.count >= 2 else {
                NSLog("[Recorder] Merge skipped — unexpected track layout")
                saveToPhotos(rawURL)
                return
            }
            let micTrack = audioTracks[0]
            let voiceTrack = audioTracks[1]

            let composition = AVMutableComposition()
            let fullRange = CMTimeRange(start: .zero, duration: duration)
            guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compMic = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compVoice = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
                saveToPhotos(rawURL)
                return
            }
            try compVideo.insertTimeRange(fullRange, of: videoTrack, at: .zero)
            try compMic.insertTimeRange(CMTimeRange(start: .zero,
                                                    duration: try await micTrack.load(.timeRange).duration),
                                        of: micTrack, at: .zero)
            try compVoice.insertTimeRange(CMTimeRange(start: .zero,
                                                      duration: try await voiceTrack.load(.timeRange).duration),
                                          of: voiceTrack, at: .zero)
            compVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

            // Duck the mic during assistant speech: quick 0.15 s ramps in and out.
            let micParams = AVMutableAudioMixInputParameters(track: compMic)
            let ramp = CMTime(seconds: 0.15, preferredTimescale: 600)
            for interval in speechIntervals {
                let rampInStart = CMTimeMaximum(.zero, CMTimeSubtract(interval.start, ramp))
                micParams.setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.25,
                                        timeRange: CMTimeRange(start: rampInStart, end: interval.start))
                micParams.setVolumeRamp(fromStartVolume: 0.25, toEndVolume: 1.0,
                                        timeRange: CMTimeRange(start: interval.end,
                                                               end: CMTimeAdd(interval.end, ramp)))
            }
            let voiceParams = AVMutableAudioMixInputParameters(track: compVoice)
            voiceParams.setVolume(1.0, at: .zero)
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [micParams, voiceParams]

            guard let export = AVAssetExportSession(asset: composition,
                                                    presetName: AVAssetExportPresetHighestQuality) else {
                saveToPhotos(rawURL)
                return
            }
            export.audioMix = audioMix
            let mergedURL = rawURL.deletingPathExtension().appendingPathExtension("merged.mp4")
            try? FileManager.default.removeItem(at: mergedURL)
            try await export.export(to: mergedURL, as: .mp4)
            NSLog("[Recorder] Merged %d speech interval(s) — mic ducked", speechIntervals.count)
            try? FileManager.default.removeItem(at: rawURL)
            saveToPhotos(mergedURL)
        } catch {
            NSLog("[Recorder] Merge failed (%@) — saving raw recording", error.localizedDescription)
            saveToPhotos(rawURL)
        }
    }

    // MARK: - Video

    /// Forward a glasses video frame into the recording. Safe to call from the main actor.
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CMClockGetTime(hostClock)
        writerQueue.async {
            self.handleVideo(pixelBuffer: pixelBuffer, now: now)
        }
    }

    private func handleVideo(pixelBuffer: CVPixelBuffer, now: CMTime) {
        if writer == nil {
            createWriter(firstPixelBuffer: pixelBuffer, firstFrameTime: now)
        }
        guard let adaptor = pixelAdaptor, let input = videoInput,
              let start = sessionStart, input.isReadyForMoreMediaData else { return }
        let pts = CMTimeSubtract(now, start)
        adaptor.append(pixelBuffer, withPresentationTime: pts)

        // Memory telemetry (~every 5 s at 30 fps): recording + live vision runs near the jetsam
        // ceiling, and a SIGKILL leaves no crash log — this trail in the console is the evidence.
        videoFrameCount += 1
        if videoFrameCount % 150 == 0 {
            let availableMB = os_proc_available_memory() / (1024 * 1024)
            NSLog("[Recorder] jetsam headroom: %d MB", availableMB)
        }
    }

    private func createWriter(firstPixelBuffer: CVPixelBuffer, firstFrameTime: CMTime) {
        guard let url = outputURL,
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            NSLog("[Recorder] Failed to create AVAssetWriter")
            return
        }

        let width = CVPixelBufferGetWidth(firstPixelBuffer)
        let height = CVPixelBufferGetHeight(firstPixelBuffer)

        // Video input (H.264).
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // Explicit bitrate: the default is stingy for a moving handheld/head-mounted POV.
            // Scaled by pixel count so the AUR-783 720×1280 stream gets ~8 Mbps where the old
            // 504×896 got ~4 — keeps encode artifacts out of the quality budget (the glasses
            // stream itself is the ceiling).
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, width * height * 9),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        let srcAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(firstPixelBuffer)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput,
                                                           sourcePixelBufferAttributes: srcAttrs)
        if writer.canAdd(vInput) { writer.add(vInput) }

        // Audio input (AAC).
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aInput) { writer.add(aInput) }

        // Second audio track: the assistant's voice, captured digitally from the playback engines.
        // Added unconditionally (an empty track is harmless and skipped at merge time). Track
        // order matters: mic is added first, playback second — the merge step relies on it.
        let pInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        pInput.expectsMediaDataInRealTime = true
        if writer.canAdd(pInput) { writer.add(pInput) }

        guard writer.startWriting() else {
            NSLog("[Recorder] startWriting failed: %@", String(describing: writer.error))
            return
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = vInput
        self.pixelAdaptor = adaptor
        self.audioInput = aInput
        self.playbackInput = pInput
        self.sessionStart = firstFrameTime
        startSilencePump()
        NSLog("[Recorder] Writer ready (%dx%d)", width, height)
    }

    // MARK: - Playback audio (AI voice, captured digitally)

    /// Forward a buffer the app is PLAYING (the assistant's voice) into the recording. Called from
    /// playback engines' mixer taps on their render threads; cheap no-op when not recording.
    /// `when` is the tap's timestamp — used for precise alignment when valid.
    func appendPlaybackAudio(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?) {
        guard isRecording, buffer.frameLength > 0 else { return }

        // Mixer taps run continuously while their engine runs, emitting silence between replies.
        // Only audible content counts — otherwise "assistant speaking" would span the whole
        // session and the mic would stay ducked. (~-54 dBFS threshold; gaps the gate creates are
        // silence-filled on append, and >0.5 s gaps split the ducking intervals — both desired.)
        guard peakLevel(of: buffer) > 0.002 else { return }

        // Prefer the render timestamp (mach host time, same timebase as our host clock).
        let time: CMTime
        if let when, when.isHostTimeValid {
            time = CMClockMakeHostTimeFromSystemUnits(when.hostTime)
        } else {
            time = CMClockGetTime(hostClock)
        }

        playbackConvertLock.lock()
        if playbackSourceFormat != buffer.format {
            playbackConverter = AVAudioConverter(from: buffer.format, to: audioOutFormat)
            playbackSourceFormat = buffer.format
        }
        guard let converter = playbackConverter else { playbackConvertLock.unlock(); return }

        let ratio = audioOutFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: audioOutFormat, frameCapacity: capacity) else {
            playbackConvertLock.unlock(); return
        }
        var supplied = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, statusPtr in
            if supplied { statusPtr.pointee = .noDataNow; return nil }
            supplied = true
            statusPtr.pointee = .haveData
            return buffer
        }
        playbackConvertLock.unlock()
        guard convError == nil, outBuffer.frameLength > 0 else { return }

        writerQueue.async {
            self.appendPlayback(outBuffer, at: time)
        }
    }

    /// Fill the playback track with silence from the cursor up to `pts`, in ≤1 s chunks.
    /// Audio samples are laid out contiguously in the track regardless of PTS gaps, so a sparse
    /// track (assistant speaks at 0:30 and 1:10) would compact and drift without this.
    /// Appending while !isReadyForMoreMediaData is an uncaught NSException → crash (hit in
    /// testing), so readiness is re-checked before EVERY append. Returns true when the gap is
    /// fully closed (≤60 ms remaining). Must run on `writerQueue`.
    @discardableResult
    private func fillSilence(upTo pts: CMTime, input: AVAssetWriterInput) -> Bool {
        var gap = CMTimeSubtract(pts, playbackCursor)
        while gap.seconds > 0.06 {
            guard input.isReadyForMoreMediaData else { return false }
            let chunkSeconds = min(gap.seconds, 1.0)
            let frames = AVAudioFrameCount(chunkSeconds * audioOutFormat.sampleRate)
            guard let silence = AVAudioPCMBuffer(pcmFormat: audioOutFormat, frameCapacity: frames) else { return false }
            silence.frameLength = frames   // buffer memory is zero-initialized → silence
            guard let sample = makeAudioSampleBuffer(silence, pts: playbackCursor) else { return false }
            input.append(sample)
            playbackCursor = CMTimeAdd(playbackCursor,
                                       CMTime(value: CMTimeValue(frames), timescale: 44_100))
            gap = CMTimeSubtract(pts, playbackCursor)
        }
        return true
    }

    /// Start the timer that keeps the playback track silence-filled to within ~1 s of "now".
    /// Runs on `writerQueue`; the 1 s lag stays safely behind in-flight audible buffers (tap
    /// latency is tens of ms) so real audio is never pre-empted by silence.
    private func startSilencePump() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, let input = self.playbackInput, let start = self.sessionStart,
                  !self.finished else { return }
            let elapsed = CMTimeSubtract(CMClockGetTime(self.hostClock), start)
            let target = CMTimeSubtract(elapsed, CMTime(seconds: 1.0, preferredTimescale: 600))
            if target > self.playbackCursor {
                self.fillSilence(upTo: target, input: input)
            }
        }
        timer.resume()
        silencePump = timer
    }

    /// Peak absolute sample value across channels (0 for unsupported formats — treated as silence).
    private func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            let data = channels[ch]
            for i in 0..<frames {
                let v = abs(data[i])
                if v > peak { peak = v }
            }
        }
        return peak
    }

    private func appendPlayback(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        guard let input = playbackInput, let start = sessionStart, !finished else { return }

        var pts = CMTimeSubtract(time, start)
        if pts < .zero { pts = .zero }
        // Never write backwards: overlapping/jittered arrivals snap to the cursor.
        if pts < playbackCursor { pts = playbackCursor }

        // Close any remaining gap since the last sample. The silence pump keeps this small
        // (~≤1.5 s), so a reply's onset appends immediately instead of stalling behind a large
        // backfill. If the writer momentarily throttles anyway, drop this buffer WITHOUT
        // advancing the cursor — the next callback re-fills, keeping the timeline aligned.
        guard fillSilence(upTo: pts, input: input),
              input.isReadyForMoreMediaData,
              let sample = makeAudioSampleBuffer(buffer, pts: playbackCursor) else { return }
        input.append(sample)
        let duration = CMTime(value: CMTimeValue(buffer.frameLength), timescale: 44_100)
        let end = CMTimeAdd(playbackCursor, duration)

        // Track when the assistant is speaking (merge adjacent buffers into one interval when the
        // gap is < 0.5 s) — this drives mic ducking at merge time.
        if var last = speechIntervals.last,
           CMTimeSubtract(playbackCursor, last.end).seconds < 0.5 {
            last.duration = CMTimeSubtract(end, last.start)
            speechIntervals[speechIntervals.count - 1] = last
        } else {
            speechIntervals.append(CMTimeRange(start: playbackCursor, end: end))
        }
        playbackCursor = end
        didCapturePlayback = true
    }

    // MARK: - Audio

    private func startMic() throws {
        try installMicTap()
        registerConfigObserver()
    }

    /// Observe configuration changes on the CURRENT engine instance. Must be re-registered every
    /// time the engine is recreated, since the notification is delivered per engine object.
    private func registerConfigObserver() {
        if let observer = configObserver { NotificationCenter.default.removeObserver(observer) }
        // When another audio consumer (e.g. a live-video backend) starts or the route changes, the
        // shared input is reconfigured and our engine silently stops delivering buffers. Re-arm the
        // tap on the new format so recording keeps capturing audio through that transition.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine, queue: .main) { [weak self] _ in
                self?.restartMicAfterConfigChange()
        }
    }

    private func installMicTap() throws {
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)   // defensive: never install over an existing tap
        let nativeFormat = input.outputFormat(forBus: 0)

        // During a route transition the input can briefly report a dead (0 Hz) or stale format.
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }
        audioConverter = AVAudioConverter(from: nativeFormat, to: audioOutFormat)

        // installTap throws an ObjC exception (uncatchable from Swift) on a format mismatch —
        // which DOES happen when a route change (e.g. TTS starting on the glasses' HFP route)
        // lands between reading `nativeFormat` and installing. Catch it like VoiceCommandService
        // does and surface it as a Swift error so the caller can retry after the route settles.
        if let reason = OVCatchException({ [weak self] in
            input.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { buffer, _ in
                self?.handleMic(buffer)
            }
        }) {
            throw RecorderError.tapFailed(reason)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func restartMicAfterConfigChange() {
        guard isRecording else { return }
        // The engine stops itself on a configuration change; rebuild the tap on the new input
        // format and restart. Don't re-arm immediately — installing a tap mid-transition is what
        // crashed with a format-mismatch exception. Wait for the route to settle, then retry a
        // few times. A short audio gap at the transition is expected and acceptable.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        scheduleMicRearm(attempt: 1)
    }

    private func scheduleMicRearm(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isRecording else { return }
            do {
                // Fresh engine: the stopped one reports the stale pre-change format (48 kHz vs the
                // route's real 16 kHz HFP), which made every install attempt mismatch. A new engine
                // reads the live route. Re-register the observer — it's bound per engine instance.
                self.audioEngine = AVAudioEngine()
                self.registerConfigObserver()
                try self.installMicTap()
                NSLog("[Recorder] Mic re-armed after audio config change (attempt %d)", attempt)
            } catch {
                NSLog("[Recorder] Mic re-arm attempt %d failed: %@", attempt, error.localizedDescription)
                if attempt < 3 {
                    self.scheduleMicRearm(attempt: attempt + 1)
                }
                // After 3 failures give up on audio: video keeps recording, and the next
                // configuration change will trigger a fresh re-arm cycle anyway.
            }
        }
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        // Stamp at arrival on the shared host clock so audio lines up with video.
        let now = CMClockGetTime(hostClock)
        guard let converter = audioConverter else { return }

        let ratio = audioOutFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: audioOutFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, statusPtr in
            if supplied {
                statusPtr.pointee = .noDataNow
                return nil
            }
            supplied = true
            statusPtr.pointee = .haveData
            return buffer
        }
        if let convError { NSLog("[Recorder] audio convert error: %@", convError); return }
        guard outBuffer.frameLength > 0 else { return }

        writerQueue.async {
            self.appendAudio(outBuffer, now: now)
        }
    }

    private func appendAudio(_ buffer: AVAudioPCMBuffer, now: CMTime) {
        // Drop audio that arrives before the first video frame has opened the session.
        guard let input = audioInput, let start = sessionStart, !finished,
              input.isReadyForMoreMediaData else { return }
        var pts = CMTimeSubtract(now, start)
        if pts < .zero { pts = .zero }
        guard let sample = makeAudioSampleBuffer(buffer, pts: pts) else { return }
        input.append(sample)
    }

    /// Package an interleaved mono Int16 PCM buffer as a CMSampleBuffer at the given PTS.
    private func makeAudioSampleBuffer(_ buffer: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.int16ChannelData else { return nil }
        let byteCount = frames * MemoryLayout<Int16>.size

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let block = blockBuffer else { return nil }

        let status = channel[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        let format = audioOutFormat.formatDescription
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [MemoryLayout<Int16>.size],
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    // MARK: - Save

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                NSLog("[Recorder] Photos permission denied")
                self.finish(url: nil)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if success {
                    NSLog("[Recorder] Saved to Photos")
                    self.finish(url: url)
                } else {
                    NSLog("[Recorder] Save failed: %@", String(describing: error))
                    self.finish(url: nil)
                }
            }
        }
    }

    private func finish(url: URL?) {
        DispatchQueue.main.async { self.onFinished?(url) }
    }
}
