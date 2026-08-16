// OpenVision - TTSService.swift
// Text-to-speech service using AVSpeechSynthesizer — and, when the "Aurelia (server voice)"
// engine is selected, the brain's Chirp3-HD voice via AureliaServerTTSService with the Apple
// voice as the automatic fallback. Callers see one API either way.

import AVFoundation
import Foundation

/// Text-to-speech service for OpenClaw mode
@MainActor
final class TTSService: NSObject, ObservableObject {
    // MARK: - Singleton

    static let shared = TTSService()

    // MARK: - Published State

    @Published var isSpeaking: Bool = false

    // MARK: - Callbacks

    /// Called when speech starts
    var onSpeechStarted: (() -> Void)?

    /// Called when speech ends
    var onSpeechEnded: (() -> Void)?

    // MARK: - Speech Synthesizer

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Streaming state

    /// Utterances enqueued but not yet finished. `isSpeaking` only drops to false when this
    /// hits 0 AND no more chunks are coming — so it doesn't flap between queued sentences.
    private var pendingUtterances = 0

    /// True while a streamed reply is still being fed sentence-by-sentence. Keeps `isSpeaking`
    /// latched even if the audio queue momentarily drains faster than the LLM produces text.
    private var streamingActive = false

    // MARK: - Voice Selection

    /// The voice to speak with, for the language the app is configured for (`SpeechLocale`).
    ///
    /// A pinned voice only wins when it speaks that language. Otherwise it is ignored: a user who
    /// once picked "Samantha" and later switched the app to Russian would otherwise hear Cyrillic
    /// read by an American English voice — unintelligible. Falling back to the best installed
    /// voice for the language is always the more useful answer.
    private var selectedVoice: AVSpeechSynthesisVoice? {
        let languageTag = SpeechLocale.voiceLanguageTag
        let languageCode = SpeechLocale.voiceLanguageCode

        if let identifier = SettingsManager.shared.settings.selectedVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier),
           SpeechLocale.languageCode(of: SpeechLocale.normalized(voice.language)) == languageCode {
            return voice
        }

        // Best installed voice for the language (premium → enhanced → default), then the plain
        // language lookup, then English so we always hand the synthesizer *something*.
        return SpeechLocale.bestVoice(forLanguageTag: languageTag)
            ?? AVSpeechSynthesisVoice(language: languageTag)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Get all available voices for a language
    static func availableVoices(for languageCode: String = "en") -> [AVSpeechSynthesisVoice] {
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languageCode) }
            .sorted { v1, v2 in
                // Sort by quality (premium first), then by name
                if v1.quality != v2.quality {
                    return v1.quality.rawValue > v2.quality.rawValue
                }
                return v1.name < v2.name
            }
    }

    /// Get display name for a voice quality
    static func qualityDisplayName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Initialization

    private override init() {
        super.init()
        synthesizer.delegate = self
        wireServerVoice()
    }

    // MARK: - Server voice (Aurelia)

    /// True when chunks should be fetched from the brain instead of spoken by AVSpeechSynthesizer.
    /// Requires the OpenAI backend URL + key (the brain's /v1); otherwise the Apple voice speaks.
    private var usingServerVoice: Bool {
        SettingsManager.shared.settings.ttsEngine == .aureliaServer && AureliaServerTTSService.isConfigured
    }

    /// The server queue reports per-chunk lifecycle through these; they mirror the synthesizer
    /// delegate below so `pendingUtterances` / `isSpeaking` / the callbacks behave identically.
    private func wireServerVoice() {
        let server = AureliaServerTTSService.shared
        server.onChunkStarted = { [weak self] in self?.chunkDidStart() }
        server.onChunkFinished = { [weak self] in self?.chunkDidFinish() }
        // Fallback keeps the chunk's pending slot: Apple's didFinish/didCancel will release it.
        server.onFallback = { [weak self] text in self?.speakWithApple(text) }
    }

    private func chunkDidStart() {
        if !isSpeaking {
            isSpeaking = true
            onSpeechStarted?()
        }
    }

    private func chunkDidFinish() {
        pendingUtterances = max(0, pendingUtterances - 1)
        // Only truly "done" when the queue is empty AND no more sentences are coming.
        if pendingUtterances == 0 && !streamingActive {
            isSpeaking = false
            onSpeechEnded?()
        }
    }

    // MARK: - Speak

    /// Speak text (single-shot: replaces anything currently playing).
    func speak(_ text: String) {
        stop()
        if usingServerVoice {
            // Per-sentence requests: the first sentence starts playing while the rest are fetched.
            for sentence in TextChunking.sentences(text) { enqueue(sentence) }
        } else {
            enqueue(text)
        }
    }

    // MARK: - Streaming (sentence-by-sentence)

    /// Begin a streamed reply. Clears the queue and latches `isSpeaking` true so the recognizer
    /// stays paused across the gaps between sentences while the LLM is still generating.
    func beginStreaming() {
        stop()
        streamingActive = true
        isSpeaking = true
        onSpeechStarted?()
    }

    /// Enqueue one sentence without interrupting what's already queued. AVSpeechSynthesizer plays
    /// queued utterances back-to-back, so this pipelines speech behind the LLM as it streams.
    func speakChunk(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueue(trimmed)
    }

    /// Signal that no more sentences are coming. Releases the latch once the queue drains.
    func endStreaming() {
        streamingActive = false
        if pendingUtterances == 0 {
            isSpeaking = false
            onSpeechEnded?()
        }
    }

    /// Hand one chunk to the active engine's queue: the server voice when selected + configured,
    /// else an utterance with the selected Apple voice.
    private func enqueue(_ text: String) {
        pendingUtterances += 1
        if usingServerVoice {
            // Latch speaking immediately (like Kokoro does during synthesis) so the recognizer
            // stays paused during the ~0.5 s fetch instead of hearing the room.
            chunkDidStart()
            AureliaServerTTSService.shared.enqueue(text)
        } else {
            speakWithApple(text)
        }
    }

    /// Build an utterance with the selected voice and hand it to the synthesizer's queue. The
    /// caller has already counted it in `pendingUtterances`.
    private func speakWithApple(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    /// Stop speaking and clear the queue.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        AureliaServerTTSService.shared.stop()
        streamingActive = false
        pendingUtterances = 0
        isSpeaking = false
    }

    /// Pause speaking
    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    /// Continue speaking
    func continueSpeaking() {
        synthesizer.continueSpeaking()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.isSpeaking {
                self.isSpeaking = true
                self.onSpeechStarted?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtterances = max(0, self.pendingUtterances - 1)
            // Only truly "done" when the queue is empty AND no more sentences are coming.
            if self.pendingUtterances == 0 && !self.streamingActive {
                self.isSpeaking = false
                self.onSpeechEnded?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtterances = max(0, self.pendingUtterances - 1)
            if self.pendingUtterances == 0 {
                self.streamingActive = false
                self.isSpeaking = false
                self.onSpeechEnded?()
            }
        }
    }
}
