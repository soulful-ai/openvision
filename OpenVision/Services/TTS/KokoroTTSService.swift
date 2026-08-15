// OpenVision - KokoroTTSService.swift
// On-device neural TTS via the vendored Kokoro-82M (MLX). Natural, offline, private.
//
// Model + voices download from HuggingFace (prince-canuma/Kokoro-82M) on demand — the model is
// ~600 MB, each voice ~0.5 MB. Synthesis runs on-device via KokoroSwift; the 24 kHz float output
// is played through AVAudioEngine. Apple's AVSpeechSynthesizer TTS remains the untouched default.

import Foundation
import AVFoundation
import MLX
import KokoroSwift

@MainActor
final class KokoroTTSService: ObservableObject {

    static let shared = KokoroTTSService()

    // Kokoro outputs mono 24 kHz float samples.
    private let sampleRate: Double = 24000

    // MARK: - Storage

    private static let modelFile = "kokoro-v1_0.safetensors"
    private static let hfBase = "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main"

    /// Curated voices (a* = American, b* = British; first letter drives the Language).
    static let voices: [String] = [
        "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky",
        "am_michael", "am_adam", "am_onyx",
        "bf_emma", "bf_isabella", "bm_george", "bm_lewis"
    ]

    /// Languages this engine can actually pronounce — **English only**, and that is a property of
    /// the build, not a shortlist we chose:
    ///
    /// 1. `KokoroSwift.Language` (Vendor/kokoro-ios/.../Language.swift) has exactly three cases:
    ///    `none`, `enUS`, `enGB`. There is no way to *ask* the engine for Russian.
    /// 2. Its grapheme-to-phoneme stage is MisakiSwift, whose only sources are under
    ///    `Sources/MisakiSwift/English/`. The multilingual eSpeak NG processor exists in the
    ///    vendored source but is compiled out (`#if canImport(eSpeakNGLib)`, and no Package.swift
    ///    here links eSpeakNGLib), so Cyrillic text has no phonemizer at all.
    /// 3. Upstream Kokoro-82M ships no Russian voice pack either — the prefixes are a/b (English),
    ///    e (Spanish), f (French), h (Hindi), i (Italian), j (Japanese), p (Portuguese),
    ///    z (Mandarin). Russian is simply not in the model.
    ///
    /// So for any non-English language the app must fall back to AVSpeechSynthesizer; callers
    /// gate on `supportsCurrentLanguage` rather than assuming Kokoro is always eligible.
    static let supportedLanguageCodes: Set<String> = ["en"]

    /// Whether Kokoro can speak the language the app is currently set to.
    @MainActor
    static var supportsCurrentLanguage: Bool {
        supportedLanguageCodes.contains(SpeechLocale.voiceLanguageCode)
    }

    private var storageDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KokoroTTS", isDirectory: true)
    }
    private var modelURL: URL { storageDir.appendingPathComponent(Self.modelFile) }
    private func voiceURL(_ name: String) -> URL {
        storageDir.appendingPathComponent("voices", isDirectory: true).appendingPathComponent("\(name).safetensors")
    }

    /// Whether the main model is on disk.
    var isModelReady: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    /// True from the moment synthesis starts until playback finishes — mirrors TTSService.isSpeaking
    /// so VoiceAgentView can gate the recognizer/conversation state on it.
    @Published var isSpeaking = false

    // MARK: - Engine + playback

    private var engine: KokoroTTS?
    private var voiceCache: [String: MLXArray] = [:]

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioReady = false

    private init() {
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    // MARK: - Download

    /// Download the ~600 MB Kokoro model (idempotent — skipped if present).
    func downloadModel(onProgress: @escaping (Double) -> Void) async throws {
        if isModelReady { onProgress(1); return }
        isDownloading = true
        defer { isDownloading = false }
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try await download(from: "\(Self.hfBase)/\(Self.modelFile)", to: modelURL) { [weak self] p in
            self?.downloadProgress = p
            onProgress(p)
        }
    }

    private func ensureVoice(_ name: String) async throws -> MLXArray {
        if let cached = voiceCache[name] { return cached }
        let url = voiceURL(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await download(from: "\(Self.hfBase)/voices/\(name).safetensors", to: url, onProgress: { _ in })
        }
        let arrays = try MLX.loadArrays(url: url)
        guard let voice = arrays["voice"] ?? arrays.values.first else {
            throw KokoroError.badVoice(name)
        }
        voiceCache[name] = voice
        return voice
    }

    private func ensureEngine() throws -> KokoroTTS {
        if let engine { return engine }
        guard isModelReady else { throw KokoroError.modelMissing }
        let e = KokoroTTS(modelPath: modelURL, g2p: .misaki)
        engine = e
        return e
    }

    // MARK: - Speak

    /// Synthesize + play `text` in the given voice. Runs generation off the main actor.
    ///
    /// Synthesis is per-SENTENCE, not whole-reply: a single `generateAudio` pass allocates MLX
    /// memory proportional to text length, and a ~400-char reply spiked >1 GB — enough to jetsam
    /// the app when SmolVLM2 is resident (~6 GB ceiling; confirmed twice from the device's memory
    /// telemetry). Per-sentence generation bounds each spike, and the first sentence starts
    /// playing while the rest still synthesize, so long replies also START sooner.
    func speak(_ text: String, voice: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isModelReady else { return }
        isSpeaking = true   // set immediately so the UI pauses the recognizer during synthesis too
        generationActive = true
        defer {
            generationActive = false
            if pendingBuffers <= 0 { isSpeaking = false }   // everything already played (or nothing to play)
        }
        do {
            let voiceArray = try await ensureVoice(voice)
            let tts = try ensureEngine()
            let language: Language = voice.first == "b" ? .enGB : .enUS
            var first = true
            for sentence in TextChunking.sentences(clean) {
                guard isSpeaking else { break }   // stop() was called mid-reply
                let samples: [Float] = try await Task.detached(priority: .userInitiated) {
                    let (audio, _) = try tts.generateAudio(voice: voiceArray, language: language, text: sentence)
                    return audio
                }.value
                guard isSpeaking else { break }
                if !samples.isEmpty {
                    enqueue(samples, restartPlayer: first)
                    first = false
                }
            }
        } catch {
            NSLog("[OV] Kokoro speak failed: %@", "\(error)")
            isSpeaking = false
        }
    }

    func stop() {
        isSpeaking = false          // breaks the per-sentence synthesis loop
        pendingBuffers = 0
        if audioReady { playerNode.stop() }
    }

    // MARK: - Playback (24 kHz mono float, sentence-queued)

    /// Buffers scheduled on the player that haven't finished playing yet. Combined with
    /// `generationActive` this decides when the whole reply is done: `isSpeaking` only clears
    /// once generation has finished AND the last queued sentence has played out.
    private var pendingBuffers = 0
    private var generationActive = false

    /// Queue one sentence's audio. `restartPlayer` is true for a reply's first sentence — it
    /// clears anything left from a previous (interrupted) reply; later sentences append to the
    /// player's queue so playback is gapless while synthesis runs ahead.
    private func enqueue(_ samples: [Float], restartPlayer: Bool) {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        }
        do {
            if !audioReady {
                audioEngine.attach(playerNode)
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
                // Forward what we play to the session recorder (cheap no-op when not recording):
                // the assistant's voice is mixed into demo recordings digitally, since the mic
                // path buries it under ambient noise.
                let tapFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
                audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, when in
                    SessionRecorder.shared.appendPlaybackAudio(buffer, at: when)
                }
                audioReady = true
            }
            if !audioEngine.isRunning { try audioEngine.start() }
            if restartPlayer {
                playerNode.stop()
                pendingBuffers = 0
            }
            pendingBuffers += 1
            // .dataPlayedBack fires when the audio has actually finished playing (not just scheduled).
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.pendingBuffers -= 1
                    if self.pendingBuffers <= 0 && !self.generationActive {
                        self.isSpeaking = false
                    }
                }
            }
            playerNode.play()
        } catch {
            NSLog("[OV] Kokoro playback failed: %@", "\(error)")
            isSpeaking = false
        }
    }

    // MARK: - Storage management

    static func downloadedSizeBytes() -> Int64 {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KokoroTTS", isDirectory: true)
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func deleteModel() {
        engine = nil
        voiceCache.removeAll()
        MLX.GPU.clearCache()
        try? FileManager.default.removeItem(at: storageDir)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        downloadProgress = 0
    }

    // MARK: - Downloader

    private func download(from urlString: String, to dest: URL, onProgress: @escaping (Double) -> Void) async throws {
        guard let url = URL(string: urlString) else { throw KokoroError.badURL }
        let (tempURL, response) = try await URLSession.shared.download(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw KokoroError.download((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tempURL, to: dest)
        onProgress(1)
    }

    enum KokoroError: LocalizedError {
        case modelMissing, badURL, badVoice(String), download(Int)
        var errorDescription: String? {
            switch self {
            case .modelMissing: return "Kokoro model isn't downloaded yet."
            case .badURL: return "Invalid download URL."
            case .badVoice(let v): return "Couldn't load voice \(v)."
            case .download(let c): return "Download failed (HTTP \(c))."
            }
        }
    }
}
