// OpenVision - CallEarconService.swift
// AUR-773: the two short call cues — "listening" (start) and "hung up" (end) — synthesized on the
// fly and rendered through the live rig's own AVAudioEngine, so they come out of the SAME route
// the call uses (the glasses over HFP), never from the phone speaker after a route switch.
//
// Why procedural: no asset pipeline, no licence, no bundle lookups that can come back nil, and the
// tones can be tuned in one place. Why the shared engine: an `AVAudioPlayer` or a system sound
// would go to whatever route iOS has at that instant — which on a Bluetooth hang-up is already the
// phone speaker. Attaching a player node to the running rig puts the cue in the HFP stream itself.
//
// The cues replace the spoken "Live video mode active / ended" (field ruling 2026-08-19 — "it's not
// video, it's annoying"): short, soft, Meta-style — an ascending pair on start, a descending pair
// on end.

import AVFoundation
import Foundation

/// Plays the call start / end earcons through a given engine (or a throwaway one).
@MainActor
final class CallEarconService {
    // MARK: - Singleton

    static let shared = CallEarconService()

    // MARK: - Cues

    enum Cue {
        /// The rig is up and she is listening: two soft ascending tones (E5 → A5, ~250 ms).
        case callStart
        /// The call is over: two soft descending tones (A5 → D5, ~250 ms).
        case callEnd

        /// (frequency Hz, duration s) per note, peak amplitude. Quiet on purpose — on HFP these
        /// land right in the ear.
        var notes: [(hz: Double, seconds: Double)] {
            switch self {
            case .callStart: return [(659.25, 0.11), (880.00, 0.14)]
            case .callEnd:   return [(880.00, 0.11), (587.33, 0.14)]
            }
        }

        var peak: Float {
            switch self {
            case .callStart: return 0.18
            case .callEnd:   return 0.16
            }
        }

        var label: String {
            switch self {
            case .callStart: return "start"
            case .callEnd:   return "end"
            }
        }
    }

    // MARK: - Settings

    /// Settings → Voice Control → Feedback → "Call sounds" (default on).
    private var enabled: Bool {
        SettingsManager.shared.settings.callSoundsEnabled
    }

    // MARK: - State

    /// A throwaway engine for the paths that have no live rig (on-device live mode, fallbacks).
    private var fallbackEngine: AVAudioEngine?
    private var bufferCache: [String: AVAudioPCMBuffer] = [:]

    private init() {}

    // MARK: - Play

    /// Render `cue` through `engine` (the live rig's shared engine, so the cue rides the call's
    /// route) and return once it has been played back. Falls back to a private engine on the
    /// current audio session when `engine` is nil. Never throws — a missing cue is a log line, not
    /// a failed call. Respects the "Call sounds" setting.
    func play(_ cue: Cue, on engine: AVAudioEngine?) async {
        guard enabled else { return }
        let target: AVAudioEngine
        var usingFallback = false
        if let engine {
            target = engine
        } else {
            let fb = fallbackEngine ?? AVAudioEngine()
            fallbackEngine = fb
            target = fb
            usingFallback = true
        }

        let rate = target.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 48_000
        guard let buffer = buffer(for: cue, sampleRate: sampleRate) else {
            ovLog("[CallEarcon] Could not synthesize the \(cue.label) cue")
            return
        }

        let player = AVAudioPlayerNode()
        target.attach(player)
        target.connect(player, to: target.mainMixerNode, format: buffer.format)
        defer {
            player.stop()
            target.disconnectNodeOutput(player)
            target.detach(player)
            if usingFallback, target.isRunning { target.stop() }
        }

        if !target.isRunning {
            do {
                target.prepare()
                try target.start()
            } catch {
                ovLog("[CallEarcon] Engine start failed for the \(cue.label) cue: \(error)")
                return
            }
        }

        let route = AudioSessionManager.shared.routeInfo.tag
        ovLog("[CallEarcon] ▶ \(cue.label) cue on \(usingFallback ? "fallback" : "shared") engine, route \(route)")

        // Wait for the cue to actually leave the player. `.dataPlayedBack` fires after the render
        // reached the output; a ceiling covers an engine that is stopped under us mid-cue (a route
        // change, a teardown) so the caller is never stranded.
        let once = OnceGate()
        let cueSeconds = cue.notes.reduce(0) { $0 + $1.seconds }
        player.play()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                once.run { cont.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64((cueSeconds + 1.0) * 1_000_000_000))
                once.run {
                    ovLog("[CallEarcon] \(cue.label) cue completion timed out — continuing")
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Synthesis

    /// Mono Float32 buffer: each note a sine with a touch of 2nd harmonic, 6 ms attack, gentle
    /// exponential decay and a 15 ms release so there is no click at the boundaries.
    private func buffer(for cue: Cue, sampleRate: Double) -> AVAudioPCMBuffer? {
        let key = "\(cue.label)@\(Int(sampleRate))"
        if let cached = bufferCache[key] { return cached }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            return nil
        }
        let totalFrames = cue.notes.reduce(0) { $0 + Int($1.seconds * sampleRate) }
        guard totalFrames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            return nil
        }
        buf.frameLength = AVAudioFrameCount(totalFrames)
        guard let out = buf.floatChannelData?[0] else { return nil }

        let attack = 0.006 * sampleRate
        let release = 0.015 * sampleRate
        var cursor = 0
        for note in cue.notes {
            let n = Int(note.seconds * sampleRate)
            let w = 2.0 * Double.pi * note.hz / sampleRate
            for i in 0..<n {
                let t = Double(i)
                // Envelope: linear attack → exponential decay, linear release at the tail.
                var env = 1.0
                if t < attack { env = t / attack }
                env *= exp(-2.2 * t / Double(n))          // ~ -19 dB over the note
                let tail = Double(n - i)
                if tail < release { env *= tail / release }
                let s = sin(w * t) + 0.25 * sin(2 * w * t)
                out[cursor + i] = Float(s * env) * cue.peak
            }
            cursor += n
        }
        bufferCache[key] = buf
        return buf
    }
}

/// Resume a continuation exactly once from whichever thread gets there first.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
