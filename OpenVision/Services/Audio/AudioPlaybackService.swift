// OpenVision - AudioPlaybackService.swift
// Ring-buffer PCM player for the full-duplex realtime session (AUR-723).
//
// The old implementation scheduled one AVAudioPlayerNode buffer per received delta. Two defects
// made barge-in impossible (plan fault B2):
//   1. `stop()` on the player node killed the node but the already-scheduled buffers still had to
//      be re-created, and there was no way to know how much of the reply had actually LEFT the
//      speaker — the server got no `conversation.item.truncate`.
//   2. The server emits audio FASTER than real time (whole sentences at once), so several seconds
//      of speech sit in the player when a barge-in lands.
//
// This version feeds an `AVAudioSourceNode` from a pre-allocated ring buffer:
//   • pause  — the render block returns silence, the buffer is KEPT (server may say "false alarm")
//   • flush  — the buffer is dropped instantly (one render quantum, ~5 ms)
//   • duck   — mixer gain drop for the local "someone is talking" hint
//   • resume — playback continues from where it paused
//   • played-ms — counted from frames the render block ACTUALLY rendered, per item id, so the
//     truncate we send the server describes what the wearer heard, not what we received.

import AVFoundation
import os

// MARK: - Pure ring buffer (unit-testable, no AVFoundation)

/// One conversation item's worth of audio inside the ring. Plain `Int32` fields only: the render
/// block touches this on the real-time audio thread, where ARC traffic (Strings, arrays) is not
/// allowed. Item ids are mapped to handles by `AudioPlaybackService`.
struct PlaybackSegment {
    var handle: Int32 = 0
    /// Frames written into the ring for this item.
    var frames: Int32 = 0
    /// Frames the render block has consumed for this item.
    var rendered: Int32 = 0
    /// The item is complete — no more audio will arrive (server sent `response.output_audio.done`).
    var closed: Bool = false
}

/// A finished item, handed to the main thread by `takeCompleted()`.
struct PlaybackCompletion {
    var handle: Int32 = 0
    var renderedFrames: Int32 = 0
}

/// Fixed-capacity float ring with per-item play-out accounting.
///
/// Thread model: `append`/`flush`/`pause`/`resume`/`takeCompleted` run on the main actor,
/// `render` runs on the audio render thread. Everything is guarded by one `os_unfair_lock`
/// and nothing inside the lock allocates.
final class PlaybackRingBuffer {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private var writeIndex = 0
    private(set) var count = 0

    private let maxSegments: Int
    private let segments: UnsafeMutablePointer<PlaybackSegment>
    private var segHead = 0
    private var segCount = 0

    private let maxCompletions: Int
    private let completions: UnsafeMutablePointer<PlaybackCompletion>
    private var compHead = 0
    private var compCount = 0

    private var lock = os_unfair_lock_s()

    private(set) var paused = false
    /// Frames dropped because the ring overflowed (diagnostics).
    private(set) var overflowFrames = 0
    /// Frames the render block asked for while the ring was empty (jitter/starvation diagnostics).
    private(set) var starvedFrames = 0
    /// Every frame ever handed to the speaker. The playback watchdog asserts this ADVANCES while
    /// audio is buffered and the ring is not paused — a graph that looks healthy but renders
    /// nothing is exactly how "I see the text but hear nothing" happens.
    private(set) var totalRendered: Int = 0

    init(capacityFrames: Int, maxSegments: Int = 256, maxCompletions: Int = 64) {
        self.capacity = max(1024, capacityFrames)
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: self.capacity)
        self.storage.initialize(repeating: 0, count: self.capacity)
        self.maxSegments = max(8, maxSegments)
        self.segments = UnsafeMutablePointer<PlaybackSegment>.allocate(capacity: self.maxSegments)
        self.segments.initialize(repeating: PlaybackSegment(), count: self.maxSegments)
        self.maxCompletions = max(8, maxCompletions)
        self.completions = UnsafeMutablePointer<PlaybackCompletion>.allocate(capacity: self.maxCompletions)
        self.completions.initialize(repeating: PlaybackCompletion(), count: self.maxCompletions)
    }

    deinit {
        storage.deinitialize(count: capacity); storage.deallocate()
        segments.deinitialize(count: maxSegments); segments.deallocate()
        completions.deinitialize(count: maxCompletions); completions.deallocate()
    }

    // MARK: Producer (main actor)

    /// Append `samples` belonging to `handle`. Consecutive appends for the same item extend the
    /// same segment, so one item = one segment and the play-out accounting stays exact.
    /// Returns the number of frames accepted (< count only on overflow).
    @discardableResult
    func append(_ samples: [Float], handle: Int32) -> Int {
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return 0 }
            return append(base, count: buf.count, handle: handle)
        }
    }

    @discardableResult
    func append(_ samples: UnsafePointer<Float>, count n: Int, handle: Int32) -> Int {
        guard n > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let room = capacity - count
        let accepted = min(n, room)
        if accepted < n { overflowFrames += (n - accepted) }
        guard accepted > 0 else { return 0 }

        // Copy in up to two runs (wrap-around).
        let firstRun = min(accepted, capacity - writeIndex)
        storage.advanced(by: writeIndex).update(from: samples, count: firstRun)
        if accepted > firstRun {
            storage.update(from: samples.advanced(by: firstRun), count: accepted - firstRun)
        }
        writeIndex = (writeIndex + accepted) % capacity
        count += accepted

        // Extend the tail segment when it belongs to the same item, else open a new one.
        let tailIdx = (segHead + segCount - 1) % maxSegments
        if segCount > 0 && segments[tailIdx].handle == handle && !segments[tailIdx].closed {
            segments[tailIdx].frames += Int32(accepted)
        } else if segCount < maxSegments {
            let idx = (segHead + segCount) % maxSegments
            segments[idx] = PlaybackSegment(handle: handle, frames: Int32(accepted), rendered: 0, closed: false)
            segCount += 1
        } else {
            // Segment table full (pathological) — attribute to the tail so no audio is lost.
            segments[tailIdx].frames += Int32(accepted)
        }
        return accepted
    }

    /// No more audio will arrive for `handle`; it completes once the ring plays it out.
    func closeItem(handle: Int32) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var i = 0
        while i < segCount {
            let idx = (segHead + i) % maxSegments
            if segments[idx].handle == handle { segments[idx].closed = true }
            i += 1
        }
        collectFinishedLocked()
    }

    // MARK: Consumer (audio render thread)

    /// Fill `out` with up to `frames` samples. Returns how many were written (the caller must
    /// zero the remainder). Returns 0 while paused — the buffer is kept.
    @discardableResult
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if paused { return 0 }

        let available = min(frames, count)
        if available < frames { starvedFrames += (frames - available) }
        guard available > 0 else { return 0 }

        let firstRun = min(available, capacity - readIndex)
        out.update(from: storage.advanced(by: readIndex), count: firstRun)
        if available > firstRun {
            out.advanced(by: firstRun).update(from: storage, count: available - firstRun)
        }
        readIndex = (readIndex + available) % capacity
        count -= available
        totalRendered += available

        // Attribute the rendered frames to the segments at the head, in order.
        var remaining = Int32(available)
        while remaining > 0 && segCount > 0 {
            let idx = segHead % maxSegments
            let room = segments[idx].frames - segments[idx].rendered
            let take = min(room, remaining)
            segments[idx].rendered += take
            remaining -= take
            if segments[idx].rendered >= segments[idx].frames && segments[idx].closed {
                pushCompletionLocked(handle: segments[idx].handle, rendered: segments[idx].rendered)
                segHead = (segHead + 1) % maxSegments
                segCount -= 1
            } else if take == 0 {
                break   // head segment has no room left but is not closed — wait for more audio
            }
        }
        return available
    }

    // MARK: Transport

    func pause() { os_unfair_lock_lock(&lock); paused = true; os_unfair_lock_unlock(&lock) }
    func resume() { os_unfair_lock_lock(&lock); paused = false; os_unfair_lock_unlock(&lock) }
    var isPaused: Bool { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return paused }

    /// Frames currently buffered (not yet rendered).
    var bufferedFrames: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return count }

    /// Handle + rendered frames of the item at the head of the queue (the one being heard).
    func head() -> (handle: Int32, rendered: Int)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard segCount > 0 else { return nil }
        let idx = segHead % maxSegments
        return (segments[idx].handle, Int(segments[idx].rendered))
    }

    /// Drop everything still buffered and forget the queued items. Returns the head item's
    /// rendered-frame count — exactly what the wearer heard before the flush.
    @discardableResult
    func flush() -> (handle: Int32, rendered: Int)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var result: (Int32, Int)?
        if segCount > 0 {
            let idx = segHead % maxSegments
            result = (segments[idx].handle, Int(segments[idx].rendered))
        }
        readIndex = 0; writeIndex = 0; count = 0
        segHead = 0; segCount = 0
        paused = false
        return result
    }

    /// Items that finished playing since the last call (main actor polls this).
    func takeCompleted() -> [PlaybackCompletion] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard compCount > 0 else { return [] }
        var out: [PlaybackCompletion] = []
        out.reserveCapacity(compCount)
        for i in 0..<compCount { out.append(completions[(compHead + i) % maxCompletions]) }
        compHead = 0; compCount = 0
        return out
    }

    // MARK: Private (lock already held)

    private func pushCompletionLocked(handle: Int32, rendered: Int32) {
        guard compCount < maxCompletions else { return }
        let idx = (compHead + compCount) % maxCompletions
        completions[idx] = PlaybackCompletion(handle: handle, renderedFrames: rendered)
        compCount += 1
    }

    /// A closed item that is already fully rendered (or empty) completes immediately.
    private func collectFinishedLocked() {
        while segCount > 0 {
            let idx = segHead % maxSegments
            guard segments[idx].closed, segments[idx].rendered >= segments[idx].frames else { return }
            pushCompletionLocked(handle: segments[idx].handle, rendered: segments[idx].rendered)
            segHead = (segHead + 1) % maxSegments
            segCount -= 1
        }
    }
}

// MARK: - Playback sink used by the realtime service

/// What `OpenAIRealtimeService` needs from the player to run barge-in (AUR-723).
@MainActor
protocol RealtimePlaybackSink: AnyObject {
    /// Queue PCM16 mono audio belonging to `itemId`.
    func enqueue(pcm16: Data, itemId: String)
    /// No more audio for this item; it completes when the ring plays it out.
    func closeItem(_ itemId: String)
    /// Stop feeding the speaker immediately, KEEP the buffer (server may say "false alarm").
    /// Returns true only if there was actually something in the ear to pause.
    @discardableResult func pausePlayback() -> Bool
    /// Continue after a paused onset that did not confirm.
    func resumePlayback()
    /// Drop everything buffered. Returns (itemId, playedMs) of what was being heard.
    @discardableResult func flushPlayback() -> (itemId: String, playedMs: Double)?
    /// Lower the local volume while we wait for the server verdict (optional soft cue).
    func duck(_ ducked: Bool)
    /// Played ms of the item currently at the head of the queue.
    func headPlayedMs() -> (itemId: String, playedMs: Double)?
    /// Fired on the main actor when an item has fully left the speaker.
    var onItemPlayed: ((String, Double) -> Void)? { get set }
}

// MARK: - Service

/// Plays audio data received from AI backends through ONE shared `AVAudioEngine`.
@MainActor
final class AudioPlaybackService: ObservableObject, RealtimePlaybackSink {
    // MARK: - Published State

    @Published var isPlaying: Bool = false

    // MARK: - Callbacks

    /// Called when playback completes (legacy Gemini path).
    var onPlaybackComplete: (() -> Void)?
    /// AUR-723: an item finished playing → the service reports `aurelia.playback.done`.
    var onItemPlayed: ((String, Double) -> Void)?

    // MARK: - Audio graph

    /// The shared engine (owned by AudioSessionManager) this player is attached to.
    private weak var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var mixerNode: AVAudioMixerNode?
    private var ring: PlaybackRingBuffer?
    private var pollTimer: Timer?
    private var ownsEngine = false

    // MARK: - Format

    /// Expected input sample rate (from the backend).
    var inputSampleRate: Double = Double(Constants.GeminiLive.outputSampleRate)

    /// Seconds of audio the ring can hold (server bursts whole sentences).
    private let ringSeconds: Double = 30

    // MARK: - Item accounting

    /// When the ring was paused by an onset (nil = not paused by us).
    private var pausedAt: Date?
    /// How long a pause may be held without a server verdict before we resume anyway.
    private let pauseSafetySeconds: TimeInterval = 0.7
    /// Render-advance assertion state.
    private var lastRenderedSeen = 0
    private var lastAdvanceAt = Date()
    private var graphRebuilds = 0

    private var handles: [String: Int32] = [:]
    private var itemIds: [Int32: String] = [:]
    private var nextHandle: Int32 = 1
    private static let legacyItemId = "legacy"

    /// Frames that are rendered but not yet audible (engine + BT output latency), subtracted from
    /// played-ms so `conversation.item.truncate` describes what was HEARD.
    private var outputLatencySeconds: Double {
        let session = AVAudioSession.sharedInstance()
        return session.outputLatency + session.ioBufferDuration
    }

    // MARK: - Initialization

    init() {}

    // MARK: - Setup

    /// Attach to the shared engine (AUR-723: ONE engine for capture + playback). When no engine is
    /// supplied a private one is created, which keeps the legacy Gemini path working standalone.
    func setup(engine sharedEngine: AVAudioEngine? = nil) throws {
        teardown()

        let engine: AVAudioEngine
        if let sharedEngine {
            engine = sharedEngine
            ownsEngine = false
        } else {
            engine = AVAudioEngine()
            ownsEngine = true
        }
        self.engine = engine

        let rate = inputSampleRate > 0 ? inputSampleRate : 24_000
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw AudioPlaybackError.setupFailed
        }

        let ring = PlaybackRingBuffer(capacityFrames: Int(rate * ringSeconds))
        self.ring = ring

        // The render block runs on the real-time audio thread: no allocation, no ARC, no locks
        // other than the ring's own `os_unfair_lock`.
        let source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let want = Int(frameCount)
            guard let raw = abl[0].mData else { isSilence.pointee = true; return noErr }
            let out = raw.assumingMemoryBound(to: Float.self)
            let produced = ring.render(into: out, frames: want)
            if produced < want {
                // Zero-fill the remainder so a starved/paused ring is silence, not garbage.
                out.advanced(by: produced).update(repeating: 0, count: want - produced)
            }
            isSilence.pointee = ObjCBool(produced == 0)
            return noErr
        }
        self.sourceNode = source

        // A dedicated mixer gives us a local duck control that does not touch the main mixer
        // (the session recorder taps the main mixer).
        let mixer = AVAudioMixerNode()
        self.mixerNode = mixer

        engine.attach(source)
        engine.attach(mixer)
        engine.connect(source, to: mixer, format: format)
        // Downstream runs at the hardware rate; the mixer does the SRC so the ring can stay in
        // the server's 24 kHz frames (which is what played-ms is counted in). A nil/invalid
        // hardware format (engine not yet realized) falls back to the source format.
        let downstream = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(mixer, to: engine.mainMixerNode, format: downstream.sampleRate > 0 ? downstream : format)

        // Forward what we play to the session recorder (cheap no-op when not recording): the
        // assistant's voice is mixed into demo recordings digitally, since the mic path buries
        // it under ambient noise.
        let tapFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        if tapFormat.sampleRate > 0 {
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, when in
                SessionRecorder.shared.appendPlaybackAudio(buffer, at: when)
            }
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        lastRenderedSeen = 0
        lastAdvanceAt = Date()
        pausedAt = nil
        startPolling()
        ovLog("[AudioPlayback] Ring-buffer player started (rate \(Int(rate)) Hz, shared engine: \(!ownsEngine))")
    }

    /// Teardown the player. The shared engine keeps running (capture may still use it).
    func teardown() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let engine, let sourceNode {
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        if let engine, let mixerNode {
            engine.disconnectNodeOutput(mixerNode)
            engine.detach(mixerNode)
        }
        if ownsEngine { engine?.stop() }
        sourceNode = nil
        mixerNode = nil
        ring = nil
        engine = nil
        handles.removeAll()
        itemIds.removeAll()
        isPlaying = false
    }

    /// Re-attach after a route/configuration change tore the graph down (AUR-723 route observers).
    func reattachIfNeeded(engine sharedEngine: AVAudioEngine?) {
        guard let sharedEngine, sourceNode != nil else { return }
        // `AVAudioNode.engine` goes nil when a configuration change detaches the node — checking
        // only `isRunning` missed exactly that case (capture's own recovery restarts the engine
        // first, so the player looked healthy while its source node was gone and she went mute).
        let detached = sourceNode?.engine == nil || mixerNode?.engine == nil
        guard detached || sharedEngine !== engine || !sharedEngine.isRunning else { return }
        ovLog("[AudioPlayback] Rebuilding the player graph (detached: \(detached), running: \(sharedEngine.isRunning))")
        try? setup(engine: sharedEngine)
    }

    // MARK: - Playback (legacy Gemini path)

    /// Play PCM Int16 audio data.
    func playAudio(data: Data) {
        enqueue(pcm16: data, itemId: Self.legacyItemId)
    }

    /// Stop playback and drop what is buffered.
    func stop() {
        _ = flushPlayback()
        onPlaybackComplete?()
    }

    // MARK: - RealtimePlaybackSink

    func enqueue(pcm16: Data, itemId: String) {
        guard let ring else { return }
        let handle = handle(for: itemId)
        let samples = Self.floatSamples(fromPCM16: pcm16)
        guard !samples.isEmpty else { return }
        ring.append(samples, handle: handle)
        isPlaying = true
    }

    func closeItem(_ itemId: String) {
        guard let ring, let handle = handles[itemId] else { return }
        ring.closeItem(handle: handle)
        drainCompletions()
    }

    /// Pause ONLY when a reply is actually playing. `input_audio_buffer.speech_started` fires on
    /// every utterance onset, not just barge-ins (channel.ts `speechStarted`), and when nothing is
    /// playing the server has no turn to false-alarm on — so no `aurelia.playback.resume` ever
    /// follows. Pausing an idle ring therefore wedged it shut for the rest of the session and the
    /// NEXT reply was enqueued into a paused player: transcripts fine, silence in the ear.
    @discardableResult
    func pausePlayback() -> Bool {
        guard let ring, ring.bufferedFrames > 0 else { return false }
        ring.pause()
        pausedAt = Date()
        return true
    }

    /// Safety net: the server promises a verdict within its confirm window (~400 ms). If neither
    /// `output_audio_buffer.cleared` nor `aurelia.playback.resume` arrives, resume anyway rather
    /// than staying mute forever.
    private func releaseStalePause() {
        guard let ring, ring.isPaused, let since = pausedAt else { return }
        let held = Date().timeIntervalSince(since)
        guard held > pauseSafetySeconds else { return }
        ovLog("[AudioPlayback] ⚠︎ pause held \(String(format: "%.2f", held))s with no verdict — resuming (buffered \(Int(bufferedMs)) ms)")
        resumePlayback()
    }

    func resumePlayback() {
        ring?.resume()
        pausedAt = nil
        duck(false)
    }

    @discardableResult
    func flushPlayback() -> (itemId: String, playedMs: Double)? {
        guard let ring else { return nil }
        let head = ring.flush()
        pausedAt = nil
        duck(false)
        isPlaying = false
        guard let head, let itemId = itemIds[head.handle] else { return nil }
        return (itemId, playedMs(fromFrames: head.rendered))
    }

    func duck(_ ducked: Bool) {
        mixerNode?.outputVolume = ducked ? 0.15 : 1.0
    }

    func headPlayedMs() -> (itemId: String, playedMs: Double)? {
        guard let head = ring?.head(), let itemId = itemIds[head.handle] else { return nil }
        return (itemId, playedMs(fromFrames: head.rendered))
    }

    // MARK: - Diagnostics

    var bufferedMs: Double {
        guard let ring else { return 0 }
        return Double(ring.bufferedFrames) / max(1, inputSampleRate) * 1000
    }

    // MARK: - Private

    private func handle(for itemId: String) -> Int32 {
        if let existing = handles[itemId] { return existing }
        let h = nextHandle
        nextHandle &+= 1
        handles[itemId] = h
        itemIds[h] = itemId
        return h
    }

    /// Frames actually rendered → ms the wearer HEARD (minus what is still in the output chain).
    private func playedMs(fromFrames frames: Int) -> Double {
        let rate = inputSampleRate > 0 ? inputSampleRate : 24_000
        let raw = Double(frames) / rate
        return max(0, (raw - outputLatencySeconds)) * 1000
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // 40 ms — one output frame; fast enough that `aurelia.playback.done` lands with the ear.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.auditPlayback()
                self?.drainCompletions()
            }
        }
    }

    /// Runs on the 40 ms poll: release a stale pause, and prove the graph is actually rendering.
    private func auditPlayback() {
        releaseStalePause()
        guard let ring else { return }
        let rendered = ring.totalRendered
        if rendered != lastRenderedSeen {
            lastRenderedSeen = rendered
            lastAdvanceAt = Date()
            return
        }
        // Nothing rendered since the last poll. That is only a fault when audio is waiting and
        // the ring is not deliberately paused.
        guard ring.bufferedFrames > 0, !ring.isPaused else { lastAdvanceAt = Date(); return }
        guard Date().timeIntervalSince(lastAdvanceAt) > 0.5 else { return }
        let live = engine
        graphRebuilds += 1
        ovLog("[AudioPlayback] ⚠︎ \(Int(bufferedMs)) ms buffered but nothing rendered for 500 ms — rebuilding the graph (rebuild #\(graphRebuilds), engine running: \(live?.isRunning ?? false), source attached: \(sourceNode?.engine != nil))")
        lastAdvanceAt = Date()
        try? setup(engine: live)
    }

    private func drainCompletions() {
        guard let ring else { return }
        for done in ring.takeCompleted() {
            guard let itemId = itemIds[done.handle] else { continue }
            let ms = playedMs(fromFrames: Int(done.renderedFrames))
            if itemId == Self.legacyItemId {
                isPlaying = false
                onPlaybackComplete?()
            } else {
                onItemPlayed?(itemId, ms)
            }
            handles.removeValue(forKey: itemId)
            itemIds.removeValue(forKey: done.handle)
        }
        if ring.bufferedFrames == 0 { isPlaying = false }
    }

    // MARK: - Conversion

    /// Convert Int16 PCM data to Float32 samples. Pure — callable off the main actor (tests).
    nonisolated static func floatSamples(fromPCM16 data: Data) -> [Float] {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(Int16(littleEndian: int16Buffer[i])) / Float(Int16.max)
            }
        }
        return samples
    }
}

// MARK: - Errors

enum AudioPlaybackError: LocalizedError {
    case setupFailed

    var errorDescription: String? {
        switch self {
        case .setupFailed: return "Failed to setup audio playback"
        }
    }
}
