// OpenVision - ShazamTool.swift
// AUR-793a: «Аурелия, что за песня?» — ShazamKit on the PHONE mic.
//
// Why the phone mic and not the glasses: the glasses ride HFP when their mic is open (see the
// BT-HFP note in the runbook) — 8 kHz narrowband, speech-shaped, with the far end's AGC on top.
// Shazam matches a spectral fingerprint of the ORIGINAL recording; narrowband voice audio does not
// carry it and the match fails, reliably. So the listen switches the audio session's preferred
// input to the built-in mic for the duration and puts it back afterwards. If there is no built-in
// mic to switch to (or the switch fails), it listens on whatever input is current — the glasses —
// and SAYS SO in the result (`mic: glasses`), because a no-match on a narrowband mic is a fact the
// wearer should be able to act on ("hold the phone closer"), not a mystery.
//
// AUR-793b — the field failure (2026-08-21 12:03Z, rt_2/rt_3) and what it proved. The pod log
// showed `phone.shazam` flipping the route to `hfp+phone-mic` with `aec:true` for exactly the
// length of each listen and back afterwards. So the mic switch WORKED — and `aec:true` is
// `AudioSessionManager.clientAECActive`, which is only true when voice-processing IO (AEC/AGC/NS)
// is live on the built-in mic. The listen was therefore running INSIDE the call's own rig:
// `.playAndRecord` + `.voiceChat`, VPIO on the input node, HFP still on the output. All three are
// speech isolators — AGC rides the level, the noise suppressor treats sustained non-speech as
// noise, and the SCO link pins the input band. That is a fingerprint of a speech stream, not of the
// record. `preferPhoneMic()` moved the PORT and nothing else.
//
// So two things changed here: the listen now MEASURES and REPORTS its own conditions (mic, category
// + mode, voice processing, real sample rate, peak level, route) on the result AND on the failure
// code, and it takes a music-capable capture window for its duration (see
// `AudioSessionManager.beginMusicWindow`). `SHManagedSession` is gone with it: it records on
// whatever the app's session happens to be and reports neither level nor format, so it could
// neither be fixed nor explained. `SHSession.matchStreamingBuffer` on an engine we own can be both.
//
// No account, no login, no network keys of our own: ShazamKit matches against Apple's catalog with
// the app's own entitlement. One human step is required ONCE, and it is not in this repo:
// developer.apple.com → Identifiers → app.soulless.openvision → App Services → **ShazamKit** → Save.
// Until then a match attempt comes back as an SHError and the tool reports it honestly
// (`shazam_failed:202`) instead of pretending it heard nothing. The entitlement key itself is
// deliberately NOT committed: adding an entitlement the wildcard "iOS Team Provisioning Profile: *"
// does not carry fails the device build outright (verified for the Wi-Fi-info key on this branch,
// 2026-08-21) — so it goes in the same commit as the portal toggle, not before it.

import Foundation
import AVFoundation
import ShazamKit

// MARK: - The match

/// One recognised track. Everything is optional at the source (SHMediaItem), so the tool only
/// claims a match when it has at least a title.
struct ShazamMatch: Equatable, Codable {
    let title: String
    let artist: String?
    let appleMusicID: String?
    let artworkURL: String?
    let isrc: String?
    var at = Date()

    /// The Spotify search string for «включи её в спотифай» — artist + title, nothing else.
    var searchQuery: String {
        [artist, title].compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: - The conditions one listen ran under (AUR-793b observability)

/// What the microphone ACTUALLY was while Shazam listened. Every field rides the tool result and,
/// on a failure, the wire code — so the brain log answers "why did it not match" without anyone
/// reading a device console. Before this the only thing that crossed the wire was a bare
/// `no_match`, and the one fact that explained it (voice processing) lived in `ovLog`.
struct MusicCaptureConditions: Equatable {
    /// "phone" | "glasses" | "headset" | "none" — the port that actually carried the audio.
    var mic = "unknown"
    /// The audio-session category in force during the listen ("playAndRecord").
    var category = ""
    /// The MODE in force ("measurement" = music-capable, "voiceChat" = a speech isolator).
    var mode = ""
    /// Voice-processing IO (Apple's AEC/AGC/NS) live on the capture. The thing that ate the music.
    var voiceProcessing = false
    /// The tap's REAL sample rate in Hz — not the preferred one, the one we got.
    var sampleRate: Double = 0
    /// Peak level measured across the whole listen, dBFS. -120 = digital silence.
    var peakDbfs: Double = -120
    /// The full route tag, e.g. "hfp+phone-mic".
    var route = ""
    /// True when the live call's own capture was paused so the listen could have a clean mic.
    var callPaused = false

    /// Below this peak nothing audible reached the mic — a no-match here is not Shazam's verdict.
    static let silenceFloorDbfs = -55.0
    /// Under this the capture cannot carry a fingerprint (HFP narrowband is 8 kHz, wideband 16).
    static let narrowbandRate = 22_050.0

    /// One compact line for the wire and the log (≤96 chars).
    var wire: String {
        "mic=\(mic) rate=\(Int(sampleRate)) vp=\(voiceProcessing ? "on" : "off") mode=\(mode)"
        + " lvl=\(Int(peakDbfs.rounded()))dBFS route=\(route)\(callPaused ? " call=paused" : "")"
    }

    /// Why a no-match could not have worked — most decisive first. `nil` means the capture WAS
    /// music-capable and Shazam genuinely did not recognise what it heard.
    var noMatchReason: String? {
        if peakDbfs < Self.silenceFloorDbfs { return "silence" }
        if mic == "glasses" { return "glasses_narrowband" }
        if sampleRate > 0, sampleRate < Self.narrowbandRate { return "narrowband" }
        if voiceProcessing { return "voice_processed" }
        return nil
    }

    /// `no_match` or `no_match:<reason>` — the code the brain sees.
    var noMatchCode: String { noMatchReason.map { "no_match:\($0)" } ?? "no_match" }

    /// The sentence for the wearer. The reason decides what she can actually DO about it — the
    /// point of the taxonomy is that "hold the phone closer" is wrong advice four times out of five.
    var noMatchSpoken: String {
        switch noMatchReason {
        case "silence":
            return "Я вообще ничего не услышала — тихо. Поднеси телефон к колонке и попробуем ещё раз."
        case "glasses_narrowband":
            return "Не узнала трек — слушала через микрофон очков (узкая полоса, музыка по нему не ловится). Достань телефон и попробуем ещё раз."
        case "narrowband":
            return "Не узнала трек — микрофон отдал узкую полосу. Отключи очки от звонка и попробуем ещё раз."
        case "voice_processed":
            return "Не узнала трек — микрофон был в режиме разговора и вырезал музыку. Попробуем ещё раз."
        default:
            return "Не узнала трек. Поднеси телефон ближе к звуку и попробуем ещё раз."
        }
    }

    /// Test seam: a clean, music-capable phone capture.
    static func phone(rate: Double = 48_000, peakDbfs: Double = -25) -> MusicCaptureConditions {
        MusicCaptureConditions(mic: "phone", category: "playAndRecord", mode: "measurement",
                               voiceProcessing: false, sampleRate: rate, peakDbfs: peakDbfs,
                               route: "speaker+phone-mic", callPaused: true)
    }
    /// Test seam: the rig the field failure actually ran on.
    static func voiceProcessedPhone() -> MusicCaptureConditions {
        MusicCaptureConditions(mic: "phone", category: "playAndRecord", mode: "voiceChat",
                               voiceProcessing: true, sampleRate: 24_000, peakDbfs: -30,
                               route: "hfp+phone-mic")
    }
    /// Test seam: the glasses' HFP mic.
    static func glasses() -> MusicCaptureConditions {
        MusicCaptureConditions(mic: "glasses", category: "playAndRecord", mode: "voiceChat",
                               voiceProcessing: false, sampleRate: 16_000, peakDbfs: -30,
                               route: "hfp+bt-mic")
    }
}

/// What one listen produced. Every case carries the conditions it ran under (AUR-793b).
enum ShazamOutcome: Equatable {
    case match(ShazamMatch, MusicCaptureConditions)
    case noMatch(MusicCaptureConditions)
    /// A ShazamKit / audio failure: the short wire code and the sentence for the wearer.
    case failed(code: String, spoken: String, conditions: MusicCaptureConditions)
}

/// The last track she recognised, so «включи её» / «лайкни» have an antecedent without the model
/// having to remember an id. In memory only — one slot, newest wins.
@MainActor
final class ShazamLastMatch {
    static let shared = ShazamLastMatch()
    private(set) var last: ShazamMatch?
    func set(_ m: ShazamMatch) { last = m }
    func clear() { last = nil }
}

// MARK: - Listener seam (tests inject; the app uses ShazamKit)

protocol ShazamListening: Sendable {
    func listen(seconds: Double) async -> ShazamOutcome
}

/// One listen on a capture we own: a dedicated `AVAudioEngine` with voice processing explicitly
/// OFF, feeding `SHSession.matchStreamingBuffer`.
///
/// Why not `SHManagedSession` any more: it records on whatever the app's audio session happens to
/// be at that moment and hands back neither the level nor the format. During a live call that
/// session is `.playAndRecord` + `.voiceChat` with voice-processing IO on the input node — proven
/// in the field on 2026-08-21 — and a managed session gives no seam to change it or to say so.
struct SystemShazamListener: ShazamListening {
    func listen(seconds: Double) async -> ShazamOutcome {
        await MusicListen.run(seconds: seconds)
    }
}

/// Peak meter over the listen. Fed from the audio thread, read once at the end.
final class MusicLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var p: Float = 0
        for i in 0..<n { p = max(p, abs(channels[0][i])) }
        lock.lock(); peak = max(peak, p); lock.unlock()
    }

    /// Peak in dBFS; -120 for digital silence.
    var peakDbfs: Double {
        lock.lock(); let p = peak; lock.unlock()
        guard p > 0 else { return -120 }
        return max(-120, 20 * log10(Double(p)))
    }
}

/// `SHSessionDelegate` → one awaited outcome. A plain `didNotFindMatchFor` fires for EVERY
/// streaming batch and is not an answer — only a match, a real error, or the clock ends the listen.
final class ShazamMatchCollector: NSObject, SHSessionDelegate, @unchecked Sendable {
    enum Outcome { case match(SHMatch); case error(NSError) }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome?, Never>?
    private var done = false
    private var settled: Outcome?

    /// Wait up to `seconds` for a match. `nil` = the clock won (no match).
    func result(within seconds: Double) async -> Outcome? {
        await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { await self.next() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                // Resolve the waiter BEFORE returning: a continuation left suspended would hang
                // the group at scope exit, cancellation does not resume it.
                self.finish(nil)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func next() async -> Outcome? {
        await withCheckedContinuation { cont in
            lock.lock()
            if done { let s = settled; lock.unlock(); cont.resume(returning: s); return }
            continuation = cont
            lock.unlock()
        }
    }

    private func finish(_ outcome: Outcome?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        settled = outcome
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: outcome)
    }

    func session(_ session: SHSession, didFind match: SHMatch) { finish(.match(match)) }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // No error = "not this batch" — keep listening. An error IS the answer (202 = the App
        // Service is missing on the App ID, or a Shazam-side hiccup).
        guard let error else { return }
        finish(.error(error as NSError))
    }
}

/// The listen itself: open a music-capable window, capture on our own non-voice-processed engine,
/// hand every buffer to ShazamKit, and report BOTH the verdict and the conditions it ran under.
enum MusicListen {

    /// The live call's playout tail gets this long to drain before the rig is paused, so a short
    /// «Уже слушаю» is not chopped mid-word by the window opening.
    static let playoutGraceSeconds = 0.35

    @MainActor
    static func run(seconds: Double) async -> ShazamOutcome {
        let manager = AudioSessionManager.shared
        if manager.sharedEngine?.isRunning == true {
            try? await Task.sleep(nanoseconds: UInt64((manager.playoutTailSeconds + playoutGraceSeconds) * 1_000_000_000))
        }
        let window = manager.beginMusicWindow()
        defer { manager.endMusicWindow(window) }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // The engine has not started, so this is legal — AVAudioIONode.h: "Voice processing can
        // only be enabled or disabled when the engine is in a stopped state."
        do { try input.setVoiceProcessingEnabled(false) }
        catch { ovLog("🎧 shazam: could not disable voice processing on the listen engine: \(error)") }

        let format = input.outputFormat(forBus: 0)
        var conditions = manager.musicCaptureConditions(sampleRate: format.sampleRate,
                                                        voiceProcessing: input.isVoiceProcessingEnabled,
                                                        callPaused: window.enginePaused)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            ovLog("🎧 shazam ✘ mic_unavailable [\(conditions.wire)]")
            return .failed(code: "mic_unavailable",
                           spoken: "Микрофон сейчас занят. Попробуем ещё раз через секунду.",
                           conditions: conditions)
        }

        let meter = MusicLevelMeter()
        let collector = ShazamMatchCollector()
        let session = SHSession()
        session.delegate = collector
        input.installTap(onBus: 0, bufferSize: 8192, format: format) { buffer, when in
            meter.feed(buffer)
            session.matchStreamingBuffer(buffer, at: when)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            ovLog("🎧 shazam ✘ mic_unavailable (engine start): \(error) [\(conditions.wire)]")
            return .failed(code: "mic_unavailable",
                           spoken: "Микрофон сейчас занят. Попробуем ещё раз через секунду.",
                           conditions: conditions)
        }
        ovLog("🎧 shazam ▶ capture open — \(conditions.wire)")

        let outcome = await collector.result(within: seconds)
        input.removeTap(onBus: 0)
        engine.stop()
        conditions.peakDbfs = meter.peakDbfs

        switch outcome {
        case .none:
            return .noMatch(conditions)
        case .some(.error(let ns)):
            let code = ns.domain == SHErrorDomain ? "shazam_failed:\(ns.code)" : "shazam_failed"
            // 202 = MatchAttemptFailed — what a missing ShazamKit App Service on the App ID looks
            // like from here, and also what a real Shazam server hiccup looks like.
            return .failed(code: code,
                           spoken: "Не смогла спросить Shazam (\(ns.code)). Попробуй ещё раз.",
                           conditions: conditions)
        case .some(.match(let match)):
            guard let item = match.mediaItems.first, let title = item.title else {
                return .noMatch(conditions)
            }
            return .match(ShazamMatch(title: title,
                                      artist: item.artist,
                                      appleMusicID: item.appleMusicID,
                                      artworkURL: item.artworkURL?.absoluteString,
                                      isrc: item.isrc),
                          conditions)
        }
    }
}

// MARK: - Tool

/// Listen to the music around and name the track.
struct ShazamTool: NativeTool {
    let name = "shazam"
    let description = "Listen to the music playing nearby for a few seconds and identify the track "
        + "(title, artist, Apple Music id). Use when the user asks what song this is, says 'Shazam', "
        + "or wants the name of the music playing."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "seconds": [
                "type": "integer",
                "description": "How long to listen, 6-12 seconds. Default 8."
            ]
        ],
        "required": [] as [String]
    ]

    /// The mic is the one thing it cannot work without — pre-flighted by the bridge (AUR-836), so a
    /// first-use prompt is a state, not an 8-second timeout.
    var permissionKind: String? { "microphone" }

    /// AUR-793b — the field failure's call 1: the socket died 6.2 s into an 8-s listen (WS 1006)
    /// and the listen was cancelled with it, with the mic already reconfigured and the window
    /// already paid for. It now runs to the end: the match is banked in `ShazamLastMatch`, so
    /// «включи её» works in the NEXT session even though the answer to THAT call can never be
    /// delivered (the server clears its registry on close and resolves the call `session_closed`).
    var survivesSessionClose: Bool { true }

    static let minSeconds = 6.0
    static let maxSeconds = 12.0
    static let defaultSeconds = 8.0

    /// Seams: the listener and the START earcon (tests inject both).
    var listener: ShazamListening = SystemShazamListener()
    var earcon: @MainActor () -> Void = { SoundService.shared.playAlert() }
    var remember: @MainActor (ShazamMatch) -> Void = { ShazamLastMatch.shared.set($0) }

    init() {}
    init(listener: ShazamListening,
         earcon: @escaping @MainActor () -> Void = {},
         remember: @escaping @MainActor (ShazamMatch) -> Void = { ShazamLastMatch.shared.set($0) }) {
        self.listener = listener
        self.earcon = earcon
        self.remember = remember
    }

    /// 6…12 s, whatever the model asked for.
    static func seconds(from args: [String: Any]) -> Double {
        guard let raw = NativeToolSupport.int(args["seconds"]) else { return defaultSeconds }
        return min(maxSeconds, max(minSeconds, Double(raw)))
    }

    /// The result text. AUR-793b: the capture conditions ride it, so a MATCH is as diagnosable as
    /// a miss (a match at -52 dBFS on a voice-processed mic is luck, and the log should say so).
    static func spoken(_ match: ShazamMatch, conditions: MusicCaptureConditions) -> String {
        var line = "«\(match.title)»"
        if let artist = match.artist { line += " — \(artist)" }
        var extras: [String] = []
        if let id = match.appleMusicID { extras.append("appleMusicID \(id)") }
        if let art = match.artworkURL { extras.append("artwork \(art)") }
        extras.append("mic: \(conditions.mic)")
        extras.append(conditions.wire)
        return "Shazam: \(line) (\(extras.joined(separator: ", ")))"
    }

    /// The wire code for a failure: the short code FIRST (so any `startsWith` on the server still
    /// works), then the one-line conditions. The server wraps `error` into the model's turn with a
    /// 120-char budget (`toolResultNote`), which is exactly what this fits into.
    static func wireCode(_ code: String, _ conditions: MusicCaptureConditions) -> String {
        String("\(code) \(conditions.wire)".prefix(118))
    }

    func execute(args: [String: Any]) async throws -> String {
        let seconds = Self.seconds(from: args)
        await MainActor.run { earcon() }            // START earcon: she is listening NOW
        ovLog("🎧 shazam ▶ listening \(Int(seconds)) s")
        switch await listener.listen(seconds: seconds) {
        case .match(let match, let conditions):
            await MainActor.run { remember(match) }
            ovLog("🎧 shazam ✔ \(match.title) [\(conditions.wire)]")
            return Self.spoken(match, conditions: conditions)
        case .noMatch(let conditions):
            // Never `ok:true` for "nothing happened" (the AUR-833 rule): a no-match is a failure
            // the brain must be able to tell the wearer about. AUR-793b: it also says WHY it could
            // not have worked — silence, a narrowband mic, or a voice-processed capture — and the
            // conditions that back the claim ride the same code.
            let code = conditions.noMatchCode
            ovLog("🎧 shazam ✘ \(code) [\(conditions.wire)]")
            throw NativeToolError.failed(code: Self.wireCode(code, conditions),
                                         spoken: conditions.noMatchSpoken)
        case .failed(let code, let spoken, let conditions):
            ovLog("🎧 shazam ✘ \(code) [\(conditions.wire)]")
            throw NativeToolError.failed(code: Self.wireCode(code, conditions), spoken: spoken)
        }
    }
}
