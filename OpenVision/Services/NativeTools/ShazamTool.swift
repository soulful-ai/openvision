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

/// What one listen produced.
enum ShazamOutcome: Equatable {
    /// `mic` = "phone" | "glasses" — which input actually carried the audio.
    case match(ShazamMatch, mic: String)
    case noMatch(mic: String)
    /// A ShazamKit / audio failure: the short wire code and the sentence for the wearer.
    case failed(code: String, spoken: String)
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

/// `SHManagedSession` + the phone-mic preference. The session owns its own audio capture; we only
/// steer which input it captures from, and we always put the preference back.
struct SystemShazamListener: ShazamListening {

    func listen(seconds: Double) async -> ShazamOutcome {
        let (mic, restore) = await MainActor.run { Self.preferPhoneMic() }
        defer { Task { @MainActor in restore() } }

        let session = SHManagedSession()
        await session.prepare()

        // Bounded listen: whichever finishes first wins, then the session is cancelled either way.
        let result: SHSession.Result? = await withTaskGroup(of: SHSession.Result?.self) { group in
            group.addTask { await session.result() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            session.cancel()
            return first
        }

        guard let result else { return .noMatch(mic: mic) }   // the clock won: nothing recognised
        switch result {
        case .match(let match):
            guard let item = match.mediaItems.first, let title = item.title else {
                return .noMatch(mic: mic)
            }
            return .match(ShazamMatch(title: title,
                                      artist: item.artist,
                                      appleMusicID: item.appleMusicID,
                                      artworkURL: item.artworkURL?.absoluteString,
                                      isrc: item.isrc),
                          mic: mic)
        case .noMatch:
            return .noMatch(mic: mic)
        case .error(let error, _):
            let ns = error as NSError
            let code = ns.domain == SHErrorDomain ? "shazam_failed:\(ns.code)" : "shazam_failed"
            // 202 = MatchAttemptFailed — what a missing ShazamKit App Service on the App ID looks
            // like from here, and also what a real Shazam server hiccup looks like. Same sentence:
            // try again, and if it keeps happening the capability is the thing to check.
            return .failed(code: code, spoken: "Не смогла спросить Shazam (\(ns.code)). Попробуй ещё раз.")
        }
    }

    /// Point the audio session at the built-in mic, and hand back the label + the undo.
    @MainActor
    static func preferPhoneMic() -> (String, () -> Void) {
        let session = AVAudioSession.sharedInstance()
        let previous = session.preferredInput
        let restore: () -> Void = { try? session.setPreferredInput(previous) }
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            ovLog("🎧 shazam: no built-in mic among the available inputs — listening on the current route")
            return ("glasses", restore)
        }
        do {
            try session.setPreferredInput(builtIn)
            ovLog("🎧 shazam: preferred input → built-in mic (was \(previous?.portName ?? "default"))")
            return ("phone", restore)
        } catch {
            ovLog("🎧 shazam: could not switch to the built-in mic (\(error.localizedDescription)) — listening on the current route")
            return ("glasses", restore)
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

    static func spoken(_ match: ShazamMatch, mic: String) -> String {
        var line = "«\(match.title)»"
        if let artist = match.artist { line += " — \(artist)" }
        var extras: [String] = []
        if let id = match.appleMusicID { extras.append("appleMusicID \(id)") }
        if let art = match.artworkURL { extras.append("artwork \(art)") }
        extras.append("mic: \(mic)")
        return "Shazam: \(line) (\(extras.joined(separator: ", ")))"
    }

    func execute(args: [String: Any]) async throws -> String {
        let seconds = Self.seconds(from: args)
        await MainActor.run { earcon() }            // START earcon: she is listening NOW
        ovLog("🎧 shazam ▶ listening \(Int(seconds)) s")
        switch await listener.listen(seconds: seconds) {
        case .match(let match, let mic):
            await MainActor.run { remember(match) }
            ovLog("🎧 shazam ✔ \(match.title) [mic \(mic)]")
            return Self.spoken(match, mic: mic)
        case .noMatch(let mic):
            ovLog("🎧 shazam ✘ no match [mic \(mic)]")
            // Never `ok:true` for "nothing happened" (the AUR-833 rule): a no-match is a failure
            // the brain must be able to tell the wearer about — including WHICH mic heard nothing,
            // since the glasses mic is narrowband and simply cannot match music.
            let hint = mic == "phone"
                ? "Не узнала трек. Поднеси телефон ближе к звуку и попробуем ещё раз."
                : "Не узнала трек — слушала через микрофон очков (узкая полоса, музыка по нему не ловится). Достань телефон и попробуем ещё раз."
            throw NativeToolError.failed(code: "no_match", spoken: hint)
        case .failed(let code, let spoken):
            ovLog("🎧 shazam ✘ \(code)")
            throw NativeToolError.failed(code: code, spoken: spoken)
        }
    }
}
