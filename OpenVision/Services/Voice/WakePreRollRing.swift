// OpenVision - WakePreRollRing.swift
// AUR-743: the wake-word 2 s pre-roll.
//
// The wake-word recognizer (Apple STT) hears «Аурелия, сколько сейчас времени» in one breath, but
// the realtime conversation only starts capturing ~1 s after the wake word fires — the question
// was lost and had to be repeated. This ring keeps the last N seconds of mic PCM16 at the
// realtime input rate (24 kHz mono, the `Constants.RealtimeAudio` conventions, a mirror of the
// offline mic ring in `OpenAIRealtimeService`) while the phone idles on the wake word. On
// detection the ViewModel takes the tail that FOLLOWS the wake word and primes the realtime
// service with it as the very first `input_audio_buffer.append`.
//
// Pure audio-thread object: `append` runs on the tap's render thread (lock + Data append, no
// main-actor hop); `snapshot` is called once from the main actor. Unit-tested without audio.

import Foundation

final class WakePreRollRing: @unchecked Sendable {
    /// Sample rate of the PCM16 mono audio held here.
    let sampleRate: Int
    /// How many seconds the ring holds at most.
    let seconds: Double
    /// Capacity in bytes (PCM16 → 2 bytes/sample).
    let capacityBytes: Int

    private var buffer = Data()
    private let lock = NSLock()
    /// Every sample ever appended (never trimmed) — the audio CLOCK, so a recognizer segment's
    /// `timestamp + duration` (seconds since the recognition request started) can be placed
    /// against "now" without any wall-clock guesswork.
    private var totalSamplesAppended = 0
    /// Sample count when the current recognition request started (`markEpoch()`).
    private var epochSamples = 0

    init(sampleRate: Int, seconds: Double) {
        self.sampleRate = max(1, sampleRate)
        self.seconds = max(0, seconds)
        self.capacityBytes = Int(Double(self.sampleRate) * self.seconds) * 2
        buffer.reserveCapacity(capacityBytes)
    }

    // MARK: - Audio thread

    /// Append converted PCM16 mono frames; the oldest bytes fall off beyond capacity.
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        lock.lock()
        buffer.append(pcm)
        if buffer.count > capacityBytes {
            buffer.removeFirst(buffer.count - capacityBytes)
        }
        totalSamplesAppended += pcm.count / 2
        lock.unlock()
    }

    // MARK: - Main actor

    /// A new recognition request started: its segment timestamps count from here.
    func markEpoch() {
        lock.lock()
        epochSamples = totalSamplesAppended
        lock.unlock()
    }

    /// Seconds of audio appended since `markEpoch()` — "now" on the recognizer's timeline.
    var secondsSinceEpoch: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(totalSamplesAppended - epochSamples) / Double(sampleRate)
    }

    /// Seconds currently held.
    var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(buffer.count / 2) / Double(sampleRate)
    }

    /// The most recent `lastSeconds` of audio (all of it when nil), sample-aligned. The ring is
    /// NOT cleared — call `clear()` when the tail has been handed over.
    func snapshot(lastSeconds: Double? = nil) -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let lastSeconds else { return buffer }
        let keepBytes = Self.bytes(forSeconds: lastSeconds, sampleRate: sampleRate)
        guard keepBytes < buffer.count else { return buffer }
        guard keepBytes > 0 else { return Data() }
        return buffer.suffix(keepBytes)
    }

    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: - Pure helpers

    /// PCM16 mono byte count for `seconds` at `sampleRate`, even (whole samples), never negative.
    static func bytes(forSeconds seconds: Double, sampleRate: Int) -> Int {
        guard seconds > 0 else { return 0 }
        return Int(seconds * Double(sampleRate)) * 2
    }

    /// Milliseconds of PCM16 mono audio in `pcm` at `sampleRate`.
    static func milliseconds(of pcm: Data, sampleRate: Int) -> Int {
        guard sampleRate > 0 else { return 0 }
        return Int(Double(pcm.count / 2) * 1000.0 / Double(sampleRate))
    }
}

/// What the ViewModel hands the realtime service on a wake: the PCM tail after the wake word.
struct WakePreRoll {
    /// PCM16 mono at `WakePreRollRing.sampleRate`, the audio AFTER the wake phrase.
    let pcm: Data
    /// How much of it there is.
    let keptMs: Int
    /// True when the wake phrase's end was located in the recognizer segments and trimmed away;
    /// false = not locatable, so ONLY audio after the detection moment was kept (never the wake
    /// word itself — the bare «Аурелия» must not reach the model and make her answer).
    let trimmedWakeWord: Bool
    /// Wall-clock ms between the wake detection and this snapshot (the recognizer-side share of
    /// the latency budget).
    let sinceDetectionMs: Int
}
