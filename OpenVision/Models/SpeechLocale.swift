// OpenVision - SpeechLocale.swift
// Single source of truth for WHICH LANGUAGE the app listens in and speaks in.
//
// Before this existed, speech recognition was hard-wired to en-US (VoiceCommandService) and TTS
// fell back to an en-US voice (TTSService) — so a Russian- (or Dutch-, Spanish-) speaking user
// got an English recognizer transcribing phonetic mush and an English voice reading Cyrillic.
//
// The user picks a language in Settings → Voice Control → Language; the default ("") follows the
// device locale. Everything downstream (STT recognizer, Apple TTS voice, Kokoro eligibility)
// resolves through this type, so there is exactly one place to change when adding a language.

import Foundation
import Speech
import AVFoundation

enum SpeechLocale {

    // MARK: - Options offered in Settings

    struct Option: Identifiable, Hashable {
        /// Settings value. "" means "follow the device locale".
        let id: String
        /// Shown in the picker (native name first — the person picking it reads that language).
        let displayName: String
    }

    /// The languages offered in the picker. Each is supported by Apple's on-device speech
    /// recognizer AND ships at least one AVSpeechSynthesis voice on iOS 18.
    static let options: [Option] = [
        Option(id: "", displayName: "Device Language"),
        Option(id: "en-US", displayName: "English (US)"),
        Option(id: "ru-RU", displayName: "Русский · Russian"),
        Option(id: "nl-NL", displayName: "Nederlands · Dutch"),
        Option(id: "es-ES", displayName: "Español · Spanish"),
        Option(id: "uk-UA", displayName: "Українська · Ukrainian")
    ]

    /// Display name for a stored setting value (falls back to the raw identifier).
    static func displayName(for identifier: String) -> String {
        if let option = options.first(where: { $0.id == identifier }) { return option.displayName }
        guard !identifier.isEmpty else { return "Device Language" }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    // MARK: - Resolution

    /// The locale the user configured, or the device locale when set to "Device Language".
    ///
    /// This is the *requested* locale — use `recognizerLocale` / `voiceLanguage` for the values
    /// actually handed to Speech / AVFoundation, which are snapped to what those frameworks have.
    @MainActor
    static var configured: Locale {
        let identifier = SettingsManager.shared.settings.speechLocaleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
    }

    /// The locale to hand to `SFSpeechRecognizer`, snapped to one it actually supports.
    ///
    /// Resolution order: exact identifier → same language + any region → en-US. The middle step
    /// matters for the device-locale default: a phone set to `ru_NL` (Russian UI, Dutch region)
    /// has no `ru-NL` recognizer, but `ru-RU` is exactly right.
    @MainActor
    static var recognizerLocale: Locale {
        supportedRecognizerLocale(for: configured)
    }

    static func supportedRecognizerLocale(for locale: Locale) -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        let wanted = normalized(locale.identifier)

        if let exact = supported.first(where: { normalized($0.identifier) == wanted }) {
            return exact
        }
        let language = languageCode(of: wanted)
        if !language.isEmpty,
           let sameLanguage = supported.first(where: { languageCode(of: normalized($0.identifier)) == language }) {
            return sameLanguage
        }
        return Locale(identifier: "en-US")
    }

    /// Language code the TTS voice should speak, e.g. "ru". Derived from the configured locale,
    /// NOT from the recognizer fallback — a missing recognizer shouldn't switch the voice to
    /// English while the model is still replying in Russian.
    @MainActor
    static var voiceLanguageCode: String {
        let code = languageCode(of: normalized(configured.identifier))
        return code.isEmpty ? "en" : code
    }

    /// Full BCP-47 tag preferred for TTS, e.g. "ru-RU". Used to prefer a region-exact voice.
    @MainActor
    static var voiceLanguageTag: String {
        let identifier = normalized(configured.identifier)
        return identifier.contains("-") ? identifier : voiceLanguageCode
    }

    /// True when the app is operating in English — the only language the vendored Kokoro engine
    /// can pronounce (its `Language` enum is en-us/en-gb and its G2P is English-only MisakiSwift).
    @MainActor
    static var isEnglish: Bool { voiceLanguageCode == "en" }

    /// Whether an on-device recognizer exists for the resolved locale. Surfaced in Settings so a
    /// user who picks a language iOS can't hear isn't left wondering why nothing transcribes.
    static func isRecognitionAvailable(for locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: supportedRecognizerLocale(for: locale))?.isAvailable ?? false
    }

    // MARK: - Voices

    /// Best available Apple voice for a language tag: exact region match first, then any voice of
    /// the same language, each time preferring the highest quality (premium → enhanced → default).
    static func bestVoice(forLanguageTag tag: String) -> AVSpeechSynthesisVoice? {
        let wanted = normalized(tag)
        let language = languageCode(of: wanted)
        let all = AVSpeechSynthesisVoice.speechVoices()

        let regionExact = all.filter { normalized($0.language) == wanted }
        let sameLanguage = all.filter { languageCode(of: normalized($0.language)) == language }

        return highestQuality(in: regionExact) ?? highestQuality(in: sameLanguage)
    }

    private static func highestQuality(in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        voices.max { a, b in
            a.quality.rawValue != b.quality.rawValue
                ? a.quality.rawValue < b.quality.rawValue
                : a.name > b.name
        }
    }

    /// Short spoken sample used by the voice picker's play button, in the target language.
    static func sampleUtterance(forLanguageCode code: String) -> String {
        switch code {
        case "ru": return "Привет! Так я звучу. Я ваш голосовой помощник."
        case "uk": return "Привіт! Так я звучу. Я ваш голосовий помічник."
        case "nl": return "Hallo! Zo klink ik. Ik ben je AI-assistent."
        case "es": return "¡Hola! Así sueno. Soy tu asistente de voz."
        default:   return "Hello! This is how I sound. I'm your AI assistant."
        }
    }

    // MARK: - String helpers
    //
    // Deliberately string-based rather than `Locale.language.languageCode`: the values compared
    // here come from three frameworks that disagree on separators — SFSpeechRecognizer reports
    // "ru-RU", `Locale.current.identifier` reports "ru_RU", AVSpeechSynthesisVoice reports
    // "ru-RU". Normalizing once keeps every comparison honest.

    /// Lowercased, hyphen-separated form: "ru_RU" → "ru-ru".
    static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// Language part of a normalized tag: "ru-ru" → "ru".
    static func languageCode(of normalizedIdentifier: String) -> String {
        String(normalizedIdentifier.split(separator: "-").first ?? "")
    }
}
