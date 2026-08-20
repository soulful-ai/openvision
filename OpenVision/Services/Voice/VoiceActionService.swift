// OpenVision - VoiceActionService.swift
// AUR-776: the client half of "fast voice actions, Meta-AI style" — «сфоткай» / "take a photo",
// "record a video", "listen" — executed the moment the brain says so, with a short earcon FIRST.
//
// Wire (over the realtime WebSocket, see OpenAIRealtimeService):
//   server → client  { type:"aurelia.action", id, action, mode }
//   client → server  { type:"aurelia.action.ack", id, action, ok, detail, artifact }
//   client → server  { type:"aurelia.action.request", action, source:"button" }  (UI taps; the
//                    server echoes `aurelia.action` so the state is single-sourced)
//   client → server  { type:"aurelia.photo", id, mimeType, data }  (AUR-787: after a photo ack the
//                    ViewModel uploads the captured JPEG itself — downscaled — for grounding; see
//                    OpenAIRealtimeService.sendCapturedPhoto)
//
// Actions and what they do on the phone:
//   photo              ONE shutter, Meta-style (AUR-785): the NATIVE capture's hardware shutter
//                      when that path wins, our tick only when it does not (stream-frame / phone
//                      fallback). NATIVE glasses capture first (AUR-783: the glasses' own photo
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
import CoreImage
import Foundation
import ImageIO
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
    /// AUR-785: the server's tag on TEMPORARY eye events around a photo — `tail: "for this turn"`
    /// on the eye.on, `"end of the photo turn"` on the eye.off. nil on everything else.
    let tail: String?

    init(id: String, kind: VoiceActionKind, mode: VoiceActionMode?, tail: String? = nil) {
        self.id = id
        self.kind = kind
        self.mode = mode
        self.tail = tail
    }

    /// `{ "type": "aurelia.action", "id": "...", "action": "...", "mode": "silent"|"assist"|null,
    ///    "tail": "for this turn"|"end of the photo turn"|absent }`
    init?(json: [String: Any]) {
        guard let raw = json["action"] as? String, let parsed = VoiceActionKind.parse(raw) else { return nil }
        let id = (json["id"] as? String) ?? UUID().uuidString
        let explicit = (json["mode"] as? String).flatMap(VoiceActionMode.init(rawValue:))
        self.init(id: id, kind: parsed.kind, mode: explicit ?? parsed.impliedMode,
                  tail: json["tail"] as? String)
    }

    /// True when this eye event is the server's TEMPORARY eye around a photo turn (the tail
    /// markers above — matched loosely on "turn" so a rewording server-side still lands).
    var hasPhotoTurnTail: Bool {
        guard kind == .eyeOn || kind == .eyeOff, let tail else { return false }
        return tail.lowercased().contains("turn")
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
    /// open. Returns the JPEG, a short source tag ("glasses" / "phone"), and — AUR-789 — an
    /// optional upright REFERENCE frame (a fresh live-stream frame of the same scene) for the
    /// orientation normalizer's tie-break. nil = no camera.
    func captureStill() async -> (jpeg: Data, source: String, reference: UIImage?)?
    /// AUR-785: true when `captureStill` will try the glasses' NATIVE capture pipeline first —
    /// whose HARDWARE shutter is the audible feedback, so the service must not add its own tick.
    var nativeCaptureLikely: Bool { get }
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
    /// AUR-823: where a finished listen backup goes (file, startedAt, durationMs) — the uploader
    /// indexes it and auto-uploads ≥ 60 s backups for server re-transcription. Injectable so
    /// the service stays testable without a network.
    var listenBackupSink: (URL, Date, Int) -> Void = { url, startedAt, durationMs in
        ListenBackupUploader.shared.registerAndAutoUpload(fileURL: url, startedAt: startedAt, durationMs: durationMs)
    }
    /// Actions run strictly one after another — a "stop" that arrives while a "start" is still
    /// opening the glasses stream must see the started state, not race it.
    private var chain: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?

    // ── AUR-785 one-shutter photo ──────────────────────────────────────────────────────────────
    /// When the last `photo` action ARRIVED (perform-time, not run-time) — any eye event within
    /// `photoEyeWindow` of it is treated as the server's temp eye for that photo turn even if the
    /// `tail` tag is missing (the fallback the ticket asks for).
    private var lastPhotoActionAt: Date?
    private let photoEyeWindow: TimeInterval = 10.0
    /// Temp eye.on events accepted but not yet executed. While > 0, `captureStill` must NOT close
    /// the stream it opened for the photo — the temp eye is about to want it (no LED off/on churn,
    /// no double stream session for one photo).
    private var queuedTempEyeOn = 0
    var tempEyeOpenPending: Bool { queuedTempEyeOn > 0 }

    /// The server's temp eye around a photo: tagged by `tail`, or (fallback) any eye event that
    /// arrives within ~10 s of a photo action in this session.
    private func isTempPhotoEye(_ action: VoiceAction) -> Bool {
        guard action.kind == .eyeOn || action.kind == .eyeOff else { return false }
        if action.hasPhotoTurnTail { return true }
        if let t = lastPhotoActionAt, Date().timeIntervalSince(t) < photoEyeWindow { return true }
        return false
    }

    // MARK: Perform

    /// Play the cue (not awaited — feedback first), then do the work, then return the ack. The
    /// caller sends the ack on the socket. Serialized with any action still in flight.
    /// AUR-785: classification happens HERE, at arrival time — the chain may delay execution,
    /// and the photo's `captureStill` needs to see a queued temp eye.on before it runs.
    func perform(_ action: VoiceAction) async -> VoiceActionAck {
        if action.kind == .photo { lastPhotoActionAt = Date() }
        let tempEye = isTempPhotoEye(action)
        if tempEye, action.kind == .eyeOn { queuedTempEyeOn += 1 }
        let previous = chain
        let task = Task<VoiceActionAck, Never> { [weak self] in
            await previous?.value
            guard let self else {
                return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: false, detail: "service gone", artifact: nil)
            }
            let ack = await self.run(action, tempEye: tempEye)
            if tempEye, action.kind == .eyeOn { self.queuedTempEyeOn = max(0, self.queuedTempEyeOn - 1) }
            return ack
        }
        chain = Task { _ = await task.value }
        return await task.value
    }

    private func run(_ action: VoiceAction, tempEye: Bool = false) async -> VoiceActionAck {
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
        // AUR-785 exceptions (one shutter per photo, Meta-style): `photo` owns its cue inside
        // takePhoto (native capture ⇒ the glasses' hardware shutter IS the sound), and the
        // server's temp eye around a photo turn plays NOTHING — the shutter already told the
        // wearer everything.
        if action.kind != .photo, !tempEye {
            let engine = host?.earconEngine
            Task { await CallEarconService.shared.play(action.kind.earcon, on: engine) }
        }

        let ack: VoiceActionAck
        switch action.kind {
        case .photo:      ack = await takePhoto(action)
        case .videoStart: ack = await startVideo(action)
        case .videoStop:  ack = await stopVideo(action)
        case .audioStart: ack = await startAudio(action)
        case .audioStop:  ack = await stopAudio(action)
        case .eyeOn:      ack = await setEye(action, open: true, quiet: tempEye)
        case .eyeOff:     ack = await setEye(action, open: false, quiet: tempEye)
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        ovLog("[VoiceAction] \(ack.ok ? "✓" : "✗") \(action.kind.rawValue) in \(ms) ms — \(ack.detail ?? "ok")\(ack.artifact?.uri.map { " → \($0.lastPathComponent)" } ?? "")")
        return ack
    }

    // MARK: Photo

    private func takePhoto(_ action: VoiceAction) async -> VoiceActionAck {
        guard let host else { return fail(action, "no live session") }
        // AUR-785 one-shutter: on the native glasses pipeline the HARDWARE plays its own shutter —
        // our tick would be a second one. So: tick upfront only when no native capture can happen
        // (phone-camera path — instant feedback, no hardware sound); with glasses in play, tick
        // AFTER the capture and only if the silent fallback (stream frame / phone) won.
        let nativeLikely = host.nativeCaptureLikely
        if !nativeLikely {
            let engine = host.earconEngine
            Task { await CallEarconService.shared.play(.photo, on: engine) }
        }
        guard let still = await host.captureStill() else {
            showStatus("No camera for a photo")
            return fail(action, "no camera")
        }
        if nativeLikely, !still.source.hasPrefix("native") {
            let engine = host.earconEngine
            Task { await CallEarconService.shared.play(.photo, on: engine) }
        }
        // AUR-789: normalize orientation BEFORE the write — the Photos save AND the grounding
        // upload (sendCapturedPhoto reads this very file) both get the upright pixels.
        let upright = Self.normalizedUprightJPEG(still.jpeg, source: still.source,
                                                 reference: still.reference)
        let url = Self.capturesDirectory().appendingPathComponent("photo-\(Self.stamp()).jpg")
        do {
            try upright.write(to: url, options: .atomic)
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

    /// `quiet` = the server's TEMP eye around a photo turn (AUR-785): the stream still opens /
    /// closes exactly the same, but silently — no earcon (suppressed upstream), no status flip.
    /// The eye indicator in the action row still tracks the real state (the "subtle badge").
    private func setEye(_ action: VoiceAction, open: Bool, quiet: Bool = false) async -> VoiceActionAck {
        guard let host else { return fail(action, "no live session") }
        let was = host.eyeState.open
        await host.setEyeOpen(open)
        if !quiet { showStatus(open ? "Watching" : "Eye closed") }
        let base = was == open ? "already \(open ? "on" : "off")" : (open ? "eye opened" : "eye closed")
        return VoiceActionAck(id: action.id, action: action.kind.rawValue, ok: true,
                              detail: quiet ? "\(base) (photo turn, silent)" : base,
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
        // AUR-823: index the backup (+ auto-upload ≥ 60 s) — the server re-transcribes it.
        if let url { listenBackupSink(url, running.startedAt, durationMs) }
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
        if let running = audioRecording {
            // AUR-823: a call that drops mid-listen still leaves a complete backup — index it
            // and let the same ≥ 60 s auto-upload rule apply.
            let durationMs = Int(Date().timeIntervalSince(running.startedAt) * 1000)
            let url = await micBackup?.finish()
            micBackup = nil
            audioRecording = nil
            if let url { listenBackupSink(url, running.startedAt, durationMs) }
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

    /// Documents/Captures (created on first use). nonisolated: pure FileManager work, also the
    /// default for ListenBackupUploader's init (AUR-823).
    nonisolated static func capturesDirectory() -> URL {
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

    // MARK: - Photo orientation (AUR-789)

    /// AUR-789 manual override for NATIVE glasses photos, settable WITHOUT a rebuild via
    /// UserDefaults key "GlassesNativeRotation":
    ///   "auto" (default) — trust EXIF, with the stream-frame NCC tie-break (see the normalizer)
    ///   "cw" | "ccw" | "180" — FORCE that rotation of the stored pixels, ignore EXIF
    ///   "none" — force no rotation (stored pixels are upright), ignore EXIF
    /// Field data 2026-08-19 (10 shots off Anton's phone): the DAT native pipeline stamps
    /// EXIF orientation 6 on EVERY 1440×1080 native JPEG, but the stored pixels are
    /// INCONSISTENT — 6 of 8 were sensor-rotated (tag correct → upright portrait), 2 of 8
    /// (both landscape street scenes) were stored already upright, so honoring the tag turned
    /// them sideways in the gallery. No metadata differentiates the two cases — hence "auto".
    static var glassesNativeRotationOverride: CGImagePropertyOrientation? {
        switch UserDefaults.standard.string(forKey: "GlassesNativeRotation") {
        case "cw": return .right
        case "ccw": return .left
        case "180": return .down
        case "none": return .up
        default: return nil   // "auto"
        }
    }

    /// Shared CIContext for the orientation bake (context creation is the expensive part).
    private static let orientationBakeContext = CIContext()

    /// AUR-789: every captured photo passes through here BEFORE the Captures write (and thus
    /// before the Photos save and the aurelia.photo grounding upload, which re-reads that file).
    /// Decode → inspect EXIF/CGImagePropertyOrientation and the pixels → return an UPRIGHT JPEG
    /// with the rotation baked into the pixels and NO orientation tag left for a consumer to
    /// mis-handle. Decision, per the 2026-08-19 field data (see `glassesNativeRotationOverride`):
    ///   • native + override set → apply exactly the override to the stored pixels.
    ///   • native + EXIF says rotate + a fresh stream frame available → NCC tie-break: compare
    ///     32×32 grayscale center squares of (stored pixels) vs (EXIF-applied pixels) against
    ///     the upright stream frame of the same scene; a ≥0.10 correlation margin decides,
    ///     otherwise trust EXIF. (Validated 8/8 on the field photos, incl. FOV perturbation.)
    ///   • anything else → trust EXIF when present, else leave as stored.
    /// A wrong-tag photo that needs NO rotation is still re-encoded to STRIP the tag.
    /// Always logs one line: `photo orientation {exif, applied, size}`.
    static func normalizedUprightJPEG(_ jpeg: Data, source: String, reference: UIImage?) -> Data {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            ovLog("[VoiceAction] photo orientation {exif:undecodable, applied:none, size:?×? (\(source))}")
            return jpeg
        }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let exifRaw = props[kCGImagePropertyOrientation] as? UInt32
        let exif = exifRaw.flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
        let exifDesc = exifRaw.map { "\($0)" } ?? "none"
        let isNative = source.hasPrefix("native")

        var applied = exif
        var how = "exif"
        if isNative, let forced = glassesNativeRotationOverride {
            applied = forced
            how = "override"
        } else if isNative, exif != .up, let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let refCG = reference?.cgImage,
                  let refV = tinyGray(CIImage(cgImage: refCG)),
                  let tagV = tinyGray(CIImage(cgImage: cg).oriented(exif)),
                  let storedV = tinyGray(CIImage(cgImage: cg)) {
            let cTag = zip(refV, tagV).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            let cStored = zip(refV, storedV).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            if cStored > cTag + 0.10 {
                applied = .up      // stored pixels already upright — the tag lies
                how = String(format: "ncc stored %.2f>tag %.2f", cStored, cTag)
            } else {
                how = String(format: "ncc tag %.2f≥stored %.2f", cTag, cStored)
            }
        }

        let tagNeedsStrip = exifRaw != nil && exifRaw != 1
        if applied == .up && !tagNeedsStrip {
            ovLog("[VoiceAction] photo orientation {exif:\(exifDesc), applied:none [\(how)], size:\(w)×\(h) (\(source))}")
            return jpeg
        }
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            ovLog("[VoiceAction] photo orientation {exif:\(exifDesc), applied:FAILED-decode, size:\(w)×\(h) (\(source))}")
            return jpeg
        }
        let uprightImage = CIImage(cgImage: cg).oriented(applied)
        let colorSpace = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let baked = orientationBakeContext.jpegRepresentation(
            of: uprightImage, colorSpace: colorSpace, options: [quality: 0.9]) else {
            ovLog("[VoiceAction] photo orientation {exif:\(exifDesc), applied:FAILED(\(applied.logName)), size:\(w)×\(h) (\(source))}")
            return jpeg
        }
        let swapped = [CGImagePropertyOrientation.left, .right, .leftMirrored, .rightMirrored].contains(applied)
        let (ow, oh) = swapped ? (h, w) : (w, h)
        ovLog("[VoiceAction] photo orientation {exif:\(exifDesc), applied:\(applied.logName) [\(how)], size:\(w)×\(h)→\(ow)×\(oh) (\(source))}")
        return baked
    }

    /// 32×32 zero-mean unit-norm grayscale of the image's center square — the NCC feature.
    /// Everything goes through the same render path, so any common flip cancels out in the
    /// comparison. Returns nil when the render fails (→ caller falls back to EXIF).
    private static func tinyGray(_ image: CIImage, n: Int = 32) -> [Float]? {
        let ext = image.extent
        guard ext.width > 1, ext.height > 1 else { return nil }
        let side = min(ext.width, ext.height)
        let cropped = image.cropped(to: CGRect(x: ext.midX - side / 2, y: ext.midY - side / 2,
                                               width: side, height: side))
        let scale = CGFloat(n) / side
        var tiny = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        tiny = tiny.transformed(by: CGAffineTransform(translationX: -tiny.extent.origin.x,
                                                      y: -tiny.extent.origin.y))
        var px = [UInt8](repeating: 0, count: n * n * 4)
        orientationBakeContext.render(tiny, toBitmap: &px, rowBytes: n * 4,
                                      bounds: CGRect(x: 0, y: 0, width: n, height: n),
                                      format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var g = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            g[i] = 0.299 * Float(px[i * 4]) + 0.587 * Float(px[i * 4 + 1]) + 0.114 * Float(px[i * 4 + 2])
        }
        let mean = g.reduce(0, +) / Float(g.count)
        for i in g.indices { g[i] -= mean }
        let norm = g.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return g.map { $0 / norm }
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

// MARK: - AUR-789 orientation logging

extension CGImagePropertyOrientation {
    /// Human-readable name for the `photo orientation` log line.
    var logName: String {
        switch self {
        case .up: return "none"
        case .upMirrored: return "flipH"
        case .down: return "180"
        case .downMirrored: return "flipV"
        case .left: return "90CCW"
        case .leftMirrored: return "90CCW+flip"
        case .right: return "90CW"
        case .rightMirrored: return "90CW+flip"
        @unknown default: return "raw\(rawValue)"
        }
    }
}
