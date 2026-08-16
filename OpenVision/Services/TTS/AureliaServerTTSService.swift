// OpenVision - AureliaServerTTSService.swift
// "Aurelia (server voice)": sentence-by-sentence TTS fetched from the brain's OpenAI-compatible
// `POST <baseURL>/audio/speech` (Google Chirp3-HD on the server: en = Zephyr, ru = Aoede), so
// push-to-ask speaks with the SAME voice as live/realtime mode instead of the phone's Apple or
// Kokoro voice.
//
// The service is a plain ordered player queue behind `TTSService`: it never touches
// `isSpeaking` itself. `TTSService.enqueue` hands it one chunk at a time and keeps counting
// pending utterances exactly as it does for AVSpeechSynthesizer; this class reports back via
// three callbacks (chunk started playing / chunk finished / chunk needs the Apple fallback).
//
// Failure policy: the first chunk that cannot be fetched or decoded (no network, HTTP error,
// timeout, bad WAV) DEGRADES the rest of the current reply to the Apple voice, in order, once
// whatever the server already delivered has finished playing — never a silent gap, never two
// voices talking over each other. `stop()`/`reset()` (called from `TTSService.stop()`, i.e. at
// every new reply) clears the degraded flag so the next reply tries the server again.
//
// Wire format: `{input, response_format:"wav", provider:"chirp", language:<2-letter>}` with the
// OpenAI backend's Bearer key. WAV (PCM16 mono 24 kHz) is what AVAudioPlayer plays natively —
// the server's default OGG Opus has no decoder on iOS.

import AVFoundation
import Foundation

@MainActor
final class AureliaServerTTSService: NSObject {

    static let shared = AureliaServerTTSService()

    // MARK: - Callbacks (wired by TTSService)

    /// A chunk's audio actually started playing.
    var onChunkStarted: (() -> Void)?
    /// A chunk finished playing (or was cut short by `stop()`).
    var onChunkFinished: (() -> Void)?
    /// A chunk could not be fetched — the caller must speak this text with the Apple voice. Called
    /// in queue order, only after any server audio that was already fetched has played out.
    var onFallback: ((String) -> Void)?

    // MARK: - Configuration

    /// The server voice needs the OpenAI backend's base URL + key (the brain accepts a JWT there).
    static var isConfigured: Bool { SettingsManager.shared.settings.isOpenAIConfigured }

    /// `<baseURL>/audio/speech`, tolerating a trailing slash in the stored base URL.
    static var speechURL: URL? {
        var base = SettingsManager.shared.settings.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty else { return nil }
        return URL(string: base + "/audio/speech")
    }

    /// Per-sentence request timeout. Chirp answers in ~0.5-0.7 s; anything past this is treated as
    /// a network failure so the Apple fallback speaks instead of leaving a hole in the reply.
    private let requestTimeout: TimeInterval = 8

    // MARK: - Queue state

    private struct Item {
        let id: Int
        let text: String
        var data: Data?
        var failed = false
    }

    private var queue: [Item] = []
    private var nextID = 0
    /// Bumped by `stop()`; a fetch that completes for an older generation is dropped on the floor.
    private var generation = 0
    /// True after the first failure of the current reply: everything else goes to Apple directly.
    private var degraded = false
    private var player: AVAudioPlayer?
    private var playingID: Int?

    private override init() { super.init() }

    // MARK: - API

    /// Queue one chunk. Fetches start immediately (in parallel) so later sentences are ready by
    /// the time earlier ones finish; playback stays strictly in enqueue order.
    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onChunkFinished?(); return }
        if degraded || !Self.isConfigured {
            onFallback?(trimmed)
            return
        }
        let id = nextID
        nextID += 1
        queue.append(Item(id: id, text: trimmed))
        let gen = generation
        Task { [weak self] in
            let result = await Self.fetch(trimmed)
            await MainActor.run {
                guard let self, self.generation == gen, let idx = self.queue.firstIndex(where: { $0.id == id }) else { return }
                switch result {
                case .success(let data): self.queue[idx].data = data
                case .failure(let error):
                    NSLog("[OV] Aurelia server voice failed, falling back to Apple: %@", "\(error)")
                    self.queue[idx].failed = true
                }
                self.pump()
            }
        }
    }

    /// Drop everything: in-flight fetches, queued audio, the current player.
    func stop() {
        generation += 1
        queue.removeAll()
        degraded = false
        if let p = player {
            p.delegate = nil
            p.stop()
            player = nil
            playingID = nil
            onChunkFinished?()
        }
    }

    // MARK: - Playback pump

    /// Play the head of the queue when it is ready; on a failed head, degrade the rest of the
    /// reply to Apple in order.
    private func pump() {
        guard player == nil, let head = queue.first else { return }
        if head.failed {
            degraded = true
            let rest = queue
            queue.removeAll()
            for item in rest { onFallback?(item.text) }
            return
        }
        guard let data = head.data else { return }   // still fetching — wait for its callback
        queue.removeFirst()
        do {
            let p = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
            p.delegate = self
            p.prepareToPlay()
            guard p.play() else { throw ServerVoiceError.playbackRefused }
            player = p
            playingID = head.id
            onChunkStarted?()
        } catch {
            NSLog("[OV] Aurelia server voice: unplayable audio (%@) — degrading to Apple", "\(error)")
            degraded = true
            onFallback?(head.text)
            let rest = queue
            queue.removeAll()
            for item in rest { onFallback?(item.text) }
        }
    }

    private func finishedCurrent() {
        player = nil
        playingID = nil
        onChunkFinished?()
        pump()
    }

    // MARK: - Network

    private static func fetch(_ text: String) async -> Result<Data, Error> {
        let (url, apiKey, language, timeout) = await MainActor.run {
            (speechURL, SettingsManager.shared.settings.openAIAPIKey, SpeechLocale.voiceLanguageCode, shared.requestTimeout)
        }
        guard let url else { return .failure(ServerVoiceError.notConfigured) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "input": text,
            "response_format": "wav",
            "provider": "chirp",
            "language": language,
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(ServerVoiceError.badResponse) }
            guard (200...299).contains(http.statusCode) else { return .failure(ServerVoiceError.http(http.statusCode)) }
            // A WAV always starts with "RIFF"; anything else (a JSON error body served with 200,
            // an OGG from an older server without wav support) is not playable here.
            guard data.count > 44, data.prefix(4) == Data("RIFF".utf8) else { return .failure(ServerVoiceError.badResponse) }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }

    enum ServerVoiceError: LocalizedError {
        case notConfigured, badResponse, playbackRefused
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Server voice needs the OpenAI backend URL and API key."
            case .badResponse: return "Server did not return WAV audio."
            case .playbackRefused: return "AVAudioPlayer refused to play."
            case .http(let code): return "Server voice HTTP \(code)."
            }
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AureliaServerTTSService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.finishedCurrent()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            NSLog("[OV] Aurelia server voice: decode error %@", "\(String(describing: error))")
            self.finishedCurrent()
        }
    }
}
