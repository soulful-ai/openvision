// OpenVision - VoiceActionService.swift
// AUR-776: the client half of "fast voice actions, Meta-AI style" — «сфоткай» / "take a photo",
// "record a video", "listen" — executed the moment the brain says so, with a short earcon FIRST.
//
// Wire (over the realtime WebSocket, see OpenAIRealtimeService):
//   server → client  { type:"aurelia.action", id, action, mode }
//   client → server  { type:"aurelia.action.ack", id, action, ok, detail, artifact }
//   client → server  { type:"aurelia.action.request", action, source:"button" }  (UI taps; the
//                    server echoes `aurelia.action` so the state is single-sourced)
//
// Actions and what they do on the phone:
//   photo              earcon → NATIVE glasses capture first (AUR-783: the glasses' own photo
//                      pipeline via captureNativePhoto — the AUR-776 "timeout" was a request sent
//                      before the stream was really live, silently dropped by the SDK), falling
//                      back to a fresh 720p frame off the POV stream → Photos +
//                      Documents/Captures/*.jpg. The ack detail names the path + pixel size.
//                      Glasses not there → the phone camera frame IF the eye is open, else ok:false.
//   video.start        earcon → SessionRecorder (glasses POV via AVAssetWriter + mic, + the
//                      assistant's voice in assist mode) → Photos on stop. mode:
//                        silent → assistant muted locally (+ server-side), NO eye (no frames to
//                                 the model), "not talking to her"
//                        assist → eye opened (the AUR-757 frame feed, same as «открой камеру»),
//                                 normal conversation, eye STAYS on after video.stop
//                      "video.start_assist" is accepted as an alias for video.start/assist.
//   video.stop         earcon → stop + save; ack carries the file URL + duration.
//   audio.start        earcon → listen indicator + local .m4a backup of the mic (the SERVER is the
//                      source of truth for the transcript — it already gets the mic stream) +
//                      assistant muted locally.
//   audio.stop         earcon → backup finalised; ack carries the file URL + duration.
//
// The service owns the recording STATE (what is running, since when) and the ack; the device
// work (which camera, the recorder, the playback mute) goes through `VoiceActionHost` — the
// ViewModel — so this file stays free of session orchestration and is testable.

import AVFoundation
import Foundation
import Photos
import UIKit

// MARK: - Wire model

enum VoiceActionKind: String, CaseIterable {
    case photo
    case videoStart = "video.start"
    case videoStop = "video.stop"
    case audioStart = "audio.start"
    case audioStop = "audio.stop"
    /// AUR-776b: the eye (AUR-757 frame feed) by voice — «смотри» / «не смотри».
    case eyeOn = "eye.on"
    case eyeOff = "eye.off"

    /// Parse the wire value. `video.start_assist` (an early draft of the contract) maps onto
    /// video.start with mode assist — see `VoiceAction.init(json:)`.
    static func parse(_ raw: String) -> (kind: VoiceActionKind, impliedMode: VoiceActionMode?)? {
        if raw == "video.start_assist" { return (.videoStart, .assist) }
        guard let k = VoiceActionKind(rawValue: raw) else { return nil }
        return (k, nil)
    }

    var earcon: CallEarconService.Cue {
        switch self {
        case .photo: return .photo
        case .videoStart: return .videoStart
        case .videoStop: return .videoStop
        case .audioStart: return .audioStart
        case .audioStop: return .audioStop
        case .eyeOn: return .eyeOn
        case .eyeOff: return .eyeOff
        }
    }
}

enum VoiceActionMode: String {
    case silent
    case assist
}

struct VoiceAction: Equatable {
    let id: String
    let kind: VoiceActionKind
    /// As sent by the server (nil when the action has no mode, e.g. photo / stop).
    let mode: VoiceActionMode?

    init(id: String, kind: VoiceActionKind, mode: VoiceActionMode?) {
        self.id = id
        self.kind = kind
        self.mode = mode
    }

    /// `{ "type": "aurelia.action", "id": "...", "action": "...", "mode": "silent"|"assist"|null }`
    init?(json: [String: Any]) {
        guard let raw = json["action"] as? String, let parsed = VoiceActionKind.parse(raw) else { return nil }
        let id = (json["id"] as? String) ?? UUID().uuidString
        let explicit = (json["mode"] as? String).flatMap(VoiceActionMode.init(rawValue:))
        self.init(id: id, kind: parsed.kind, mode: explicit ?? parsed.impliedMode)
    }

    /// The mode the action runs in. video.start defaults to silent (Meta's "record a video" is
    /// a recording, not a conversation); the assist flavour has to be asked for.
    var effectiveMode: VoiceActionMode {
        mode ?? .silent
    }
}

struct VoiceActionArtifact: Equatable {
    enum Kind: String { case photo, video, audio }
    let kind: Kind
    let uri: URL?
    let durationMs: Int?

    var json: [String: Any] {
        [
            "kind": kind.rawValue,
            "uri": uri?.absoluteString as Any? ?? NSNull(),
            "durationMs": durationMs as Any? ?? NSNull()
        ]
    }
}

struct VoiceActionAck {
    let id: String
    let action: String
    let ok: Bool
    let detail: String?
    let artifact: VoiceActionArtifact?

    var json: [String: Any] {
        [
            "type": "aurelia.action.ack",
            "id": id,
            "action": action,
            "ok": ok,
            "detail": detail as Any? ?? NSNull(),
            "artifact": artifact?.json as Any? ?? NSNull()
        ]
    }
}

// MARK: - Host

/// What the service needs from the live session — implemented by VoiceAgentViewModel.
@MainActor
protocol VoiceActionHost: AnyObject {
    /// The live rig's engine, so the earcons ride the call's route (HFP in the glasses).
    var earconEngine: AVAudioEngine? { get }
    /// One still: glasses POV frame if the glasses can see, else the phone camera IF its eye is
    /// open. Returns the JPEG and a short source tag ("glasses" / "phone"), nil = no camera.
    func captureStill() async -> (jpeg: Data, source: String)?
    /// Start the POV recorder (glasses stream + mic [+ assistant voice]). Throws with a reason.
    func startPOVRecording() async throws
    /// Stop the POV recorder; resolves with the saved file (nil = nothing saved).
    func stopPOVRecording() async -> URL?
    /// Open / leave the eye (the AUR-757 frame feed to the model) for assist-video.
    func setEyeOpen(_ open: Bool) async
    /// Current eye intent + when it last changed (AUR-776b dedupe against the local phrase handler).
    var eyeState: (open: Bool, changedAt: Date) { get }
    /// Mute / unmute the assistant's audio locally (silent modes).
    func setAssistantPlaybackSilenced(_ silenced: Bool)
    /// Sample rate of the PCM16 mic frames handed to `appendMicAudio` (the live capture rate).
    var micSampleRate: Double { get }
}

// MARK: - Service

@MainActor
final class VoiceActionService: ObservableObject {

    /// A recording that is running right now (video or listen), for the UI badge + elapsed time.
    struct ActiveRecording: Equatable {
        enum Kind: String { case video, audio }
        let kind: Kind
        let mode: VoiceActionMode
        let startedAt: Date
        let actionId: String

        var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
    }

    @Published private(set) var videoRecording: ActiveRecording?
    @Published private(set) var audioRecording: ActiveRecording?
    /// The last action outcome, for a transient status line ("Photo saved", …). Auto-clears.
    @Published private(set) var lastStatus: String?

    weak var host: (any VoiceActionHost)?

    /// True while the assistant must stay quiet locally (video.silent or listen running).
    var isSilencing: Bool {
        (videoRecording?.mode == .silent) || audioRecording != nil
    }
    /// Any action recording running (the UI badge; also what makes "stop video" a recording
    /// stop instead of a hang-up in the transcript keyword check).
    var isRecordingAnything: Bool { videoRecording != nil || audioRecording != nil }

    private var micBackup: MicBackupWriter?
    /// Actions run strictly one after another — a "stop" that arrives while a "start" is still
    /// opening the glasses stream must see the started state, not race it.
    private var chain: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?

    // MARK: Perform

    /// Play the cue (not awaited — feedback first), then do the work, then return the ack. The
    /// caller sends the ack on the socket. Serialized with any action still in flight.
    func perform(_ action: VoiceAction) async -> VoiceActionAck {
        let previous = chain
        let task = Task<VoiceActionAck, Never> { [weak self] in
            await previous?.value
            guard let self else {
                return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: false, detail: "service gone", artifact: nil)
            }
            return await self.run(action)
        }
        chain = Task { _ = await task.value }
        return await task.value
    }

    private func run(_ action: VoiceAction) async -> VoiceActionAck {
        let t0 = Date()
        ovLog("[VoiceAction] ▶ \(action.kind.rawValue) mode=\(action.mode?.rawValue ?? "-") id=\(action.id)")
        // AUR-776b: the local phrase handler («открой камеру») may have toggled the eye a moment
        // ago for the same utterance — then this is a duplicate: no cue, no work, a plain ack.
        if let host, action.kind == .eyeOn || action.kind == .eyeOff {
            let want = action.kind == .eyeOn
            let st = host.eyeState
            let ago = Date().timeIntervalSince(st.changedAt)
            if st.open == want, ago < 1.0 {
                ovLog("[VoiceAction] \(action.kind.rawValue) deduped — local toggle \(Int(ago * 1000)) ms ago")
                return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: true,
                                      detail: "already \(want ? "on" : "off") (local toggle \(Int(ago * 1000)) ms ago)", artifact: nil)
            }
        }
        // Earcon FIRST — the whole point is Meta-speed feedback; the capture follows.
        let engine = host?.earconEngine
        Task { await CallEarconService.shared.play(action.kind.earcon, on: engine) }

        let ack: VoiceActionAck
        switch action.kind {
        case .photo:      ack = await takePhoto(action)
        case .videoStart: ack = await startVideo(action)
        case .videoStop:  ack = await stopVideo(action)
        case .audioStart: ack = await startAudio(action)
        case .audioStop:  ack = await stopAudio(action)
        case .eyeOn:      ack = await setEye(action, open: true)
        case .eyeOff:     ack = await setEye(action, open: false)
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        ovLog("[VoiceAction] \(ack.ok ? "✓" : "✗") \(action.kind.rawValue) in \(ms) ms — \(ack.detail ?? "ok")\(ack.artifact?.uri.map { " → \($0.lastPathComponent)" } ?? "")")
        return ack
    }

    // MARK: Photo

    private func takePhoto(_ action: VoiceAction) async -> VoiceActionAck {
        guard let host else { return fail(action, "no live session") }
        guard let still = await host.captureStill() else {
            showStatus("No camera for a photo")
            return fail(action, "no camera")
        }
        let url = Self.capturesDirectory().appendingPathComponent("photo-\(Self.stamp()).jpg")
        do {
            try still.jpeg.write(to: url, options: .atomic)
        } catch {
            return fail(action, "write failed: \(error.localizedDescription)")
        }
        let saved = await Self.saveToPhotos(url, isVideo: false)
        showStatus(saved ? "Photo saved" : "Photo kept in the app (Photos access off)")
        // AUR-783: `source` says which path won — "native 4032×3024" (the glasses' own photo
        // pipeline) vs "stream frame 720×1280" (the fallback grab) vs "phone".
        return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: true,
                              detail: "\(still.source)\(saved ? ", saved to Photos" : ", app docs only")",
                              artifact: VoiceActionArtifact(kind: .photo, uri: url, durationMs: nil))
    }

    // MARK: Video

    private func startVideo(_ action: VoiceAction) async -> VoiceActionAck {
        guard let host else { return fail(action, "no live session") }
        let mode = action.effectiveMode
        if let running = videoRecording {
            // Already rolling: switching silent ↔ assist is just the mute + the eye.
            videoRecording = ActiveRecording(kind: .video, mode: mode, startedAt: running.startedAt, actionId: action.id)
            applySilence()
            await host.setEyeOpen(mode == .assist)
            return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: true,
                                  detail: "already recording, mode → \(mode.rawValue)", artifact: nil)
        }
        do {
            try await host.startPOVRecording()
        } catch {
            showStatus("Couldn't start video")
            return fail(action, error.localizedDescription)
        }
        videoRecording = ActiveRecording(kind: .video, mode: mode, startedAt: Date(), actionId: action.id)
        applySilence()
        // Assist = recording + her eye on what is recorded (the same path as «открой камеру»).
        // Silent = a recording, not a conversation: no frames to the model (an open eye is
        // closed; the glasses stream itself stays up for the recorder).
        await host.setEyeOpen(mode == .assist)
        showStatus(mode == .silent ? "Recording video" : "Recording video, assistant watching")
        return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: true,
                              detail: "recording glasses POV (\(mode.rawValue))", artifact: nil)
    }

    private func stopVideo(_ action: VoiceAction) async -> VoiceActionAck {
        guard let host else { return fail(action, "no live session") }
        guard let running = videoRecording else {
            return fail(action, "no video recording running")
        }
        let url = await host.stopPOVRecording()
        let durationMs = Int(Date().timeIntervalSince(running.startedAt) * 1000)
        videoRecording = nil
        applySilence()
        // The eye stays as it is (assist leaves it open unless the wearer closes it).
        showStatus(url != nil ? "Video saved to Photos" : "Couldn't save the video")
        return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: url != nil,
                              detail: url != nil ? "saved to Photos" : "recorder produced no file",
                              artifact: VoiceActionArtifact(kind: .video, uri: url, durationMs: durationMs))
    }

    // MARK: Eye (AUR-776b)

    private func setEye(_ action: VoiceAction, open: Bool) async -> VoiceActionAck {
        guard let host else { return fail(action, "no live session") }
        let was = host.eyeState.open
        await host.setEyeOpen(open)
        showStatus(open ? "Watching" : "Eye closed")
        return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: true,
                              detail: was == open ? "already \(open ? "on" : "off")" : (open ? "eye opened" : "eye closed"),
                              artifact: nil)
    }

    // MARK: Audio / listen

    private func startAudio(_ action: VoiceAction) async -> VoiceActionAck {
        guard let host else { return fail(action, "no live session") }
        if audioRecording != nil {
            return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: true,
                                  detail: "already listening", artifact: nil)
        }
        let url = Self.capturesDirectory().appendingPathComponent("listen-\(Self.stamp()).m4a")
        let writer = MicBackupWriter(url: url, sampleRate: host.micSampleRate)
        micBackup = writer
        audioRecording = ActiveRecording(kind: .audio, mode: .silent, startedAt: Date(), actionId: action.id)
        applySilence()
        showStatus("Listening (recording)")
        return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: true,
                              detail: "mic streaming to the server; local backup \(url.lastPathComponent)",
                              artifact: nil)
    }

    private func stopAudio(_ action: VoiceAction) async -> VoiceActionAck {
        guard let running = audioRecording else {
            return fail(action, "no listen session running")
        }
        let durationMs = Int(Date().timeIntervalSince(running.startedAt) * 1000)
        let url = await micBackup?.finish()
        micBackup = nil
        audioRecording = nil
        applySilence()
        showStatus("Listening stopped")
        return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: true,
                              detail: url != nil ? "backup saved" : "no local backup (no mic frames)",
                              artifact: VoiceActionArtifact(kind: .audio, uri: url, durationMs: durationMs))
    }

    /// Mic frames (PCM16 mono at `host.micSampleRate`) — tee'd from the live capture by the
    /// ViewModel. No-op unless a listen backup is running.
    func appendMicAudio(_ pcm16: Data) {
        micBackup?.append(pcm16)
    }

    // MARK: Session end

    /// The live session is going down: finish whatever is recording (the glasses stream stops
    /// with it), unmute, clear the badges. Called from stopLiveVideoMode.
    func sessionEnded() async {
        if videoRecording != nil {
            _ = await host?.stopPOVRecording()
            videoRecording = nil
        }
        if audioRecording != nil {
            _ = await micBackup?.finish()
            micBackup = nil
            audioRecording = nil
        }
        applySilence()
    }

    // MARK: Helpers

    private func applySilence() {
        host?.setAssistantPlaybackSilenced(isSilencing)
    }

    private func fail(_ action: VoiceAction, _ detail: String) -> VoiceActionAck {
        VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: false, detail: detail, artifact: nil)
    }

    private func showStatus(_ text: String) {
        lastStatus = text
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            if self?.lastStatus == text { self?.lastStatus = nil }
        }
    }

    static func capturesDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// Add a file to the Photos library (add-only access). False = not added (permission off or
    /// failure) — the file still lives in the app's Captures folder.
    static func saveToPhotos(_ url: URL, isVideo: Bool) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            return true
        } catch {
            ovLog("[VoiceAction] Photos save failed: \(error)")
            return false
        }
    }
}

// MARK: - Mic backup writer (.m4a)

/// Writes PCM16 mono frames into an AAC .m4a with AVAssetWriter. A local safety copy of what
/// the server is transcribing during listen mode — not the transcript source of truth.
final class MicBackupWriter: @unchecked Sendable {
    private let url: URL
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "com.openvision.mic-backup")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var frames: Int64 = 0
    private var failed = false
    private let format: AVAudioFormat

    init(url: URL, sampleRate: Double) {
        self.url = url
        self.sampleRate = sampleRate > 0 ? sampleRate : 24_000
        self.format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: self.sampleRate,
                                    channels: 1, interleaved: true)!
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        queue.async { [self] in
            guard !failed else { return }
            if writer == nil { open() }
            guard let input, input.isReadyForMoreMediaData,
                  let sample = makeSampleBuffer(pcm16) else { return }
            if !input.append(sample) {
                failed = true
                ovLog("[MicBackup] append failed: \(String(describing: writer?.error))")
            }
        }
    }

    /// Finalize; nil when nothing was ever written.
    func finish() async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            queue.async { [self] in
                guard let writer, let input, writer.status == .writing else {
                    cont.resume(returning: nil)
                    return
                }
                input.markAsFinished()
                writer.finishWriting {
                    cont.resume(returning: writer.status == .completed ? self.url : nil)
                }
            }
        }
    }

    private func open() {
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000
            ]
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            i.expectsMediaDataInRealTime = true
            guard w.canAdd(i) else { failed = true; return }
            w.add(i)
            guard w.startWriting() else { failed = true; return }
            w.startSession(atSourceTime: .zero)
            writer = w
            input = i
        } catch {
            failed = true
            ovLog("[MicBackup] open failed: \(error)")
        }
    }

    private func makeSampleBuffer(_ pcm16: Data) -> CMSampleBuffer? {
        let frameCount = pcm16.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: pcm16.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: pcm16.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = pcm16.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: pcm16.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        let scale = CMTimeScale(sampleRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: scale),
                                        presentationTimeStamp: CMTime(value: frames, timescale: scale),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format.formatDescription,
                                        sampleCount: frameCount, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: [MemoryLayout<Int16>.size],
                                        sampleBufferOut: &sample) == noErr else { return nil }
        frames += Int64(frameCount)
        return sample
    }
}
