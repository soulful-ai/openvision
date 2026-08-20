// OpenVision - VoiceSettingsView.swift
// Voice control settings — the ONE conversation (AUR-742): voice model, language, the wake-word
// door, microphone, camera at call start, silence auto-end, sounds, debug (push-to-ask flag).

import SwiftUI
import AVFoundation

struct VoiceSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    /// AUR-759: the server's voice-model list (fallback trio until it answers).
    @StateObject private var voiceModels = VoiceModelChoices.shared

    // MARK: - Computed Properties

    private var selectedVoiceName: String {
        guard let identifier = settingsManager.settings.selectedVoiceIdentifier,
              let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
            return "System Default"
        }
        // A voice pinned in another language is ignored at speak time (TTSService picks the best
        // voice for the current language instead) — say so here rather than showing a stale name.
        guard SpeechLocale.languageCode(of: SpeechLocale.normalized(voice.language)) == SpeechLocale.voiceLanguageCode else {
            return "Auto (\(voice.name) is \(voice.language))"
        }
        return voice.name
    }

    /// Resolved language tag actually in use — the picked one, or the device's when set to Device.
    private var resolvedLanguageTag: String { SpeechLocale.recognizerLocale.identifier }

    private var isRecognitionAvailable: Bool {
        SpeechLocale.isRecognitionAvailable(for: SpeechLocale.configured)
    }

    private var recognitionStatus: String {
        isRecognitionAvailable ? "Ready · \(resolvedLanguageTag)" : "Unavailable · \(resolvedLanguageTag)"
    }

    private var languageFooter: String {
        var text = "Sets the language the assistant listens in and speaks. \"Device Language\" follows your iPhone's language (\(resolvedLanguageTag))."
        if !isRecognitionAvailable {
            text += " iOS has no speech recognizer for this language on this device — try another, or install the language in iOS Settings → General → Keyboard → Dictation Languages."
        }
        if settingsManager.settings.pushToAskEnabled && !KokoroTTSService.supportsCurrentLanguage {
            text += " Kokoro speaks English only, so this language uses the Apple system voice."
        }
        return text
    }

    /// AUR-744: the banked push-to-ask path is on — its speech-engine controls come back.
    private var pushToAsk: Bool { settingsManager.settings.pushToAskEnabled }

    // MARK: - Voice model (AUR-759)

    /// The picker's selection: the stored id when the server offers it, otherwise "Server default"
    /// (older builds stored OpenAI's `gpt-realtime` here — the server treats it as default too).
    private var voiceModelSelection: Binding<String> {
        Binding(
            get: {
                let stored = settingsManager.settings.openAIRealtimeModel
                return voiceModels.choices.contains(where: { $0.id == stored }) ? stored : VoiceModelChoices.serverDefault
            },
            set: { settingsManager.settings.openAIRealtimeModel = $0 }
        )
    }

    private var voiceModelFooter: String {
        var text = "Which brain answers in the conversation. Applies to the NEXT conversation — a call already running keeps its model until you end it."
        if let def = voiceModels.serverDefaultId {
            text += " Server default is currently \(voiceModels.displayName(for: def))."
        }
        if !voiceModels.isFromServer {
            text += settingsManager.settings.isOpenAIConfigured
                ? " (Built-in list — the server hasn't answered yet.)"
                : " (Built-in list — set the OpenAI backend's Endpoint and API Key to load the server's list.)"
        }
        return text
    }

    // MARK: - Body

    var body: some View {
        Form {
            // Voice model (AUR-759) — the brain behind the conversation.
            Section {
                Picker("Voice Model", selection: voiceModelSelection) {
                    Text(voiceModels.serverDefaultId.map { "Server default (\(voiceModels.displayName(for: $0)))" } ?? "Server default")
                        .tag(VoiceModelChoices.serverDefault)
                    ForEach(voiceModels.choices) { choice in
                        Text(choice.displayName).tag(choice.id)
                    }
                }
            } header: {
                Text("Voice Model")
            } footer: {
                Text(voiceModelFooter)
            }
            .task { await voiceModels.refresh() }

            // Language Section — governs speech recognition (the wake word) and `?lang=` on the call.
            Section {
                Picker("Language", selection: $settingsManager.settings.speechLocaleIdentifier) {
                    ForEach(SpeechLocale.options) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .onChange(of: settingsManager.settings.speechLocaleIdentifier) { _, _ in
                    // SFSpeechRecognizer's locale is fixed at init — relaunch it on the new one.
                    VoiceCommandService.shared.applyLocaleChange()
                }

                HStack {
                    Text("Recognition")
                    Spacer()
                    Text(recognitionStatus)
                        .font(.caption)
                        .foregroundColor(isRecognitionAvailable ? .green : .orange)
                }
            } header: {
                Text("Language")
            } footer: {
                Text(languageFooter)
            }

            // Wake Word Section — THE door to the conversation (AUR-742).
            Section {
                Toggle(isOn: $settingsManager.settings.wakeWordEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Wake Word")
                        Text("Only listen after the wake phrase")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if settingsManager.settings.wakeWordEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wake Phrase")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Ok Vision", text: $settingsManager.settings.wakeWord)
                            .autocorrectionDisabled()
                    }
                }
            } header: {
                Text("Wake Word")
            } footer: {
                if settingsManager.settings.wakeWordEnabled {
                    Text("Say \"\(settingsManager.settings.wakeWord)\" to open the conversation, then just talk — interrupt her whenever you like. The phone listens for the wake phrase only; inside the conversation the brain hears everything.")
                } else {
                    Text("Wake word is disabled. Open the conversation by tapping the orb or the Talk button.")
                }
            }

            // Microphone Section — selects the Bluetooth routing policy for the call (plan §4.2).
            Section {
                Toggle(isOn: $settingsManager.settings.preferGlassesMic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use glasses microphone")
                        Text("Lower quality, hands-free")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Warning: on classic Bluetooth the glasses mic forces the call onto the HFP profile — her voice turns thin and robotic for the whole conversation, and echo cancellation then happens in the glasses, not the phone. Off = phone mic + full-quality playback in the glasses (recommended unless you need true hands-free).")
            }

            // Camera Section (AUR-742) — a toggle, never a phrase.
            Section {
                Picker("Camera at call start", selection: $settingsManager.settings.cameraSource) {
                    ForEach(CameraSourcePreference.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
            } header: {
                Text("Camera")
            } footer: {
                Text("Which eye the conversation opens with. \"Off\" keeps both cameras shut until you ask (say «смотри» / \"look\", or tap the camera button in the call); the button in the call switches Off / Phone / Glasses for that call only.")
            }

            // Conversation Section — silence auto-end (AUR-742 re-scope).
            Section {
                Picker("End after silence", selection: $settingsManager.settings.conversationTimeout) {
                    Text("15 seconds").tag(TimeInterval(15))
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("Never").tag(TimeInterval(0))
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text("End the conversation after this much silence — nobody talking, nothing recording, no task running — and go back to the wake word. A running video / listen recording or a delegated task keeps the call open.")
            }

            // Output voice — push-to-ask only (AUR-744). In the conversation the voice is the
            // server's (Chirp3-HD); these engines only speak the banked ask-and-answer path.
            if pushToAsk {
                Section {
                    Picker("Speech Engine", selection: $settingsManager.settings.ttsEngine) {
                        ForEach(TTSEngineType.allCases) { engine in
                            // Kokoro is English-only; label it so the picker doesn't promise a voice
                            // it can't deliver in Russian/Dutch/Spanish/Ukrainian.
                            Text(engine == .kokoro && !KokoroTTSService.supportsCurrentLanguage
                                 ? "\(engine.displayName) — English only"
                                 : engine.displayName)
                                .tag(engine)
                        }
                    }

                    // The Apple voice picker stays visible unless Kokoro is really in charge: it is
                    // the voice that speaks when Kokoro can't (non-English) and the fallback the
                    // server voice degrades to when the brain can't be reached.
                    if settingsManager.settings.ttsEngine != .kokoro || !KokoroTTSService.supportsCurrentLanguage {
                        NavigationLink {
                            VoiceSelectionView()
                        } label: {
                            HStack {
                                Text(settingsManager.settings.ttsEngine == .aureliaServer ? "Apple Voice (fallback)" : "Apple Voice")
                                Spacer()
                                Text(selectedVoiceName).foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Picker("Kokoro Voice", selection: $settingsManager.settings.kokoroVoice) {
                            ForEach(KokoroTTSService.voices, id: \.self) { voice in
                                Text(voice).tag(voice)
                            }
                        }
                        NavigationLink {
                            KokoroSettingsView()
                        } label: {
                            HStack {
                                Label("Kokoro Model", systemImage: "waveform")
                                Spacer()
                                Text(KokoroTTSService.shared.isModelReady ? "Ready" : "Download")
                                    .font(.caption)
                                    .foregroundColor(KokoroTTSService.shared.isModelReady ? .green : .orange)
                            }
                        }
                    }
                } header: {
                    Text("Output Voice (push-to-ask)")
                } footer: {
                    if settingsManager.settings.ttsEngine == .aureliaServer && !AureliaServerTTSService.isConfigured {
                        Text("Aurelia's server voice needs the OpenAI backend's Endpoint and API Key (Settings → OpenAI). Until they are set, replies are spoken by the Apple system voice.")
                    } else if settingsManager.settings.ttsEngine == .aureliaServer {
                        Text("Aurelia's own voice, synthesized on the server (Google Chirp3-HD, the same voice as the conversation) in \(resolvedLanguageTag) and streamed sentence by sentence. Needs a network connection; if the server can't be reached, the Apple voice speaks instead.")
                    } else if settingsManager.settings.ttsEngine == .kokoro && !KokoroTTSService.supportsCurrentLanguage {
                        Text("Kokoro can only pronounce English, so replies in \(resolvedLanguageTag) are spoken by the Apple system voice instead. Switch the language to English to use Kokoro.")
                    } else if settingsManager.settings.ttsEngine == .kokoro {
                        Text("Kokoro is a natural, on-device neural voice — private and offline. Download its model (~600 MB) under Kokoro Model, then it runs entirely on-device. English only.")
                    } else {
                        Text("Apple's built-in system voice, available in every language above. For higher quality, download a Premium/Enhanced voice in iOS Settings → Accessibility → Spoken Content.")
                    }
                }
            }

            // Feedback Section
            Section {
                Toggle(isOn: $settingsManager.settings.playActivationSound) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activation Sound")
                        Text("Play chime on wake word")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: $settingsManager.settings.callSoundsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Call Sounds")
                        Text("Short tone when a call starts and ends")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Feedback")
            } footer: {
                Text("Call sounds play in the call's own audio route (the glasses when connected): a rising tone when she starts listening, a falling one when the call ends. With call sounds on, the wake word plays that tone instead of the chime.")
            }

            // Examples — the conversation, not a command list (AUR-742).
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(samplePhrases, id: \.self) { phrase in
                        HStack(alignment: .top) {
                            Image(systemName: "quote.bubble")
                                .foregroundColor(.secondary)
                            Text(phrase)
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("How to talk to her")
            } footer: {
                Text("Just «\(settingsManager.settings.wakeWord)…» and talk — no \"start video\", no \"stop\": interrupt her by speaking, end with «пока» / \"bye\". Photo, video, look, listen are short phrases the brain recognises (the ? button in the call lists them).")
            }

            // Debug — the banked push-to-ask path (AUR-744). Present and reachable until the
            // removal gate (memo §4.4) is satisfied; off by default.
            Section {
                Toggle(isOn: $settingsManager.settings.pushToAskEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Push-to-ask fallback")
                        Text("Wake word → question → spoken answer (no full duplex)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Debug")
            } footer: {
                Text(pushToAsk
                     ? "ON: «\(settingsManager.settings.wakeWord)» captures one question with Apple speech recognition, sends it to the configured backend and speaks the reply with the Output Voice above; the orb's long press and the Push-to-ask button are back. Use this only on a rig that cannot hold a full-duplex call (classic Bluetooth glasses mic)."
                     : "OFF (default): «\(settingsManager.settings.wakeWord)» opens the realtime conversation. Flip on only if the glasses rig cannot do full duplex — the old ask-and-answer loop comes back in five seconds, nothing else changes.")
            }
        }
        .navigationTitle("Voice Control")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sample Phrases

    private var samplePhrases: [String] {
        let wake = settingsManager.settings.wakeWord
        if pushToAsk {
            return [
                "\(wake), what's the weather?",
                "\(wake), take a photo",
                "\(wake), remind me to...",
                "\(wake), search for..."
            ]
        }
        return [
            "«\(wake), сколько сейчас времени?» — in one breath, she answers",
            "«\(wake)» … then just talk, as long as you like",
            "Talk over her to interrupt — no magic word needed",
            "«Сделай фото» · «Смотри» · «Слушай» — fast actions inside the call",
            "«Пока» / \"bye\" — ends the call; so does the silence timeout above"
        ]
    }
}

#Preview {
    NavigationStack {
        VoiceSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
