// OpenVision - AppSettings.swift
// Settings data model with Codable support for JSON persistence

import Foundation

/// The type of AI backend to use
enum AIBackendType: String, Codable, CaseIterable {
    case openClaw = "openclaw"
    case geminiLive = "gemini_live"
    case openAI = "openai"
    case appleFoundation = "apple_foundation"
    case localGemma = "local_gemma"

    var displayName: String {
        switch self {
        case .openClaw: return "OpenClaw"
        case .geminiLive: return "Gemini Live"
        case .openAI: return "OpenAI"
        case .appleFoundation: return "Apple Intelligence"
        case .localGemma: return "Local (MLX)"
        }
    }

    var description: String {
        switch self {
        case .openClaw:
            return "Wake word activation, 56+ tools, task execution"
        case .geminiLive:
            return "Real-time voice + vision, continuous conversation"
        case .openAI:
            return "GPT-4o — cloud text + vision (OpenAI-compatible)"
        case .appleFoundation:
            return "On-device Apple model — private, no download (iOS 26+)"
        case .localGemma:
            return "On-device Gemma 4 — private, offline, no API cost"
        }
    }

    var icon: String {
        switch self {
        case .openClaw: return "terminal"
        case .geminiLive: return "waveform"
        case .openAI: return "sparkles"
        case .appleFoundation: return "apple.logo"
        case .localGemma: return "cpu"
        }
    }
}

/// Which text-to-speech engine to use.
enum TTSEngineType: String, Codable, CaseIterable, Identifiable {
    case appleSystem = "apple"
    case kokoro = "kokoro"
    /// Aurelia's own voice, synthesized on the brain server (Chirp3-HD; en Zephyr, ru Aoede) via
    /// the OpenAI backend's `/audio/speech`. Same voice as live/realtime mode. Needs network; the
    /// Apple voice is the automatic fallback.
    case aureliaServer = "aurelia"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appleSystem: return "Apple (system voice)"
        case .kokoro: return "Kokoro (natural, on-device)"
        case .aureliaServer: return "Aurelia (server voice)"
        }
    }
}

/// AUR-742: which eye the live conversation opens with. The call itself is AUDIO-first (AUR-757,
/// principal ruling 2026-08-18): `.off` keeps both cameras shut until the wearer asks (the in-call
/// camera button, or «смотри» / "look" → the brain's `eye.on`); `.glasses` / `.phone` open that eye
/// as soon as the conversation is up. The in-call button cycles the eye for THIS call only.
enum CameraSourcePreference: String, Codable, CaseIterable, Identifiable {
    case off = "off"
    case phone = "phone"
    case glasses = "glasses"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "Off (ask for it)"
        case .phone: return "Phone camera"
        case .glasses: return "Glasses"
        }
    }
}

/// App settings persisted to Documents/settings.json
struct AppSettings: Codable, Equatable {
    // MARK: - AI Backend Selection

    /// Which AI backend to use
    var aiBackend: AIBackendType = .openClaw

    // MARK: - OpenClaw Configuration

    /// OpenClaw gateway WebSocket URL (e.g., "wss://openclaw.example.com")
    var openClawGatewayURL: String = ""

    /// OpenClaw authentication token
    var openClawAuthToken: String = ""

    // MARK: - Gemini Live Configuration

    /// Google Gemini API key
    var geminiAPIKey: String = ""

    // MARK: - OpenAI Configuration

    /// OpenAI (or OpenAI-compatible) API key.
    var openAIAPIKey: String = ""

    /// Chat model id. gpt-4o-mini is cheap and supports vision — a good default for testing.
    var openAIModel: String = "gpt-4o-mini"

    /// API base URL. Override to point at any OpenAI-compatible endpoint (OpenRouter, a local
    /// server, Azure-style gateways, etc.). No trailing slash.
    var openAIBaseURL: String = "https://api.openai.com/v1"

    /// Stream chat replies token-by-token (`stream: true`) so text renders and TTS starts speaking
    /// while the model is still generating. Turn off for endpoints that mishandle SSE — the app
    /// also detects that on its own and falls back to a buffered request.
    var openAIStreamResponses: Bool = true

    /// AUR-759: which brain answers a live conversation — a MODEL_REGISTRY id the server offers
    /// (Settings → Voice Control → Voice model), sent as `?model=` on the realtime socket. Empty
    /// = the server's default. (Older builds stored OpenAI's `gpt-realtime` here; the server treats
    /// any id it doesn't offer as "default", so that value still means the same thing.)
    var openAIRealtimeModel: String = ""

    /// Voice used by the OpenAI Realtime backend.
    var openAIRealtimeVoice: String = "marin"

    // MARK: - Web Search

    /// Tavily API key (free tier). When set, web search uses Tavily (real live content, built for
    /// LLMs) as the primary source, falling back to keyless DuckDuckGo otherwise.
    var tavilyAPIKey: String = ""

    // MARK: - Local Gemma Configuration

    /// HuggingFace repo id of the on-device Gemma 4 model to load.
    /// Matches `GemmaLocalModel.e2b.modelId` (note the validated capital-E2B casing).
    var localGemmaModelId: String = "mlx-community/gemma-4-E2B-it-4bit"

    /// Whether the selected Gemma model has finished downloading and is ready to load.
    /// Set by the model-manager / GemmaLocalService once the snapshot is on disk.
    var localGemmaModelReady: Bool = false

    // MARK: - Voice Settings

    /// Wake word phrase (default: "Ok Vision")
    var wakeWord: String = "Ok Vision"

    /// Whether wake word detection is enabled (OpenClaw mode only)
    var wakeWordEnabled: Bool = true

    /// Play activation chime on wake word detection
    var playActivationSound: Bool = true

    /// AUR-773: short start/end earcons for the realtime call (the Meta-style beeps) instead of
    /// the spoken "Live video mode active / ended". Off = the call starts and ends silently.
    var callSoundsEnabled: Bool = true

    /// AUR-742: end the live conversation after this many seconds of silence (nobody talking, no
    /// recording, no delegated task running) — back to the wake word. 0 = never.
    var conversationTimeout: TimeInterval = 30

    /// AUR-742: the eye at call start — off (audio-only until asked, the AUR-757 default), the
    /// phone camera, or the glasses. See `CameraSourcePreference`.
    var cameraSource: CameraSourcePreference = .off

    /// AUR-744: the banked push-to-ask path (wake word → Apple STT → `/v1/chat/completions` →
    /// per-sentence TTS). OFF by default: «Аурелия» opens the realtime conversation. A runtime
    /// flag on purpose (no `#if`): the archived code keeps compiling and can be flipped back on in
    /// five seconds from Settings → Voice Control → Debug if a rig cannot do full duplex.
    var pushToAskEnabled: Bool = false

    /// AUR-742 §3.5: the one-time "now just say «Аурелия» and talk" note was shown.
    var oneConversationNoteSeen: Bool = false

    /// Language the app listens in and speaks in, as a BCP-47 identifier ("ru-RU", "nl-NL", …).
    /// Empty string (the default) means "follow the device locale". Resolved through
    /// `SpeechLocale`, which snaps it to a locale Speech/AVFoundation actually support.
    var speechLocaleIdentifier: String = ""

    /// Selected TTS voice identifier for the Apple system voice (nil = system default)
    var selectedVoiceIdentifier: String? = nil

    /// Which TTS engine to speak with. Apple (system voice) is the default and always available;
    /// Kokoro is on-device neural TTS (natural, offline) once its model is downloaded.
    var ttsEngine: TTSEngineType = .appleSystem

    /// Selected Kokoro voice (e.g. "af_heart"). First letter: a = American, b = British.
    var kokoroVoice: String = "af_heart"

    /// Prefer the glasses' Bluetooth microphone for voice input when they're the connected audio
    /// device — true hands-free. Falls back to the phone mic automatically when the glasses aren't
    /// the audio route. Turn off to always use the phone. (Glasses mic uses more battery.)
    var preferGlassesMic: Bool = true

    // MARK: - AI Customization

    /// Custom instructions appended to AI system prompt
    var userPrompt: String = ""

    /// Key-value memories the AI can read and manage
    var memories: [String: String] = [:]

    // MARK: - Advanced Settings

    /// Auto-reconnect on connection drop
    var autoReconnect: Bool = true

    /// Show live transcripts in UI
    var showTranscripts: Bool = true

    /// AUR-823: auto-upload every finished listen-mode backup ≥ 60 s to the brain for
    /// re-transcription (`POST /v1/voice/recordings/{stem}/audio`). Off = keep local only;
    /// Settings → Debug → Listen backups still uploads on demand.
    var listenBackupUpload: Bool = true

    /// Video frame rate for Gemini Live (frames per second)
    var geminiVideoFPS: Int = 1

    // MARK: - Computed Properties

    /// Whether OpenClaw is configured (has URL and token)
    var isOpenClawConfigured: Bool {
        !openClawGatewayURL.isEmpty && !openClawAuthToken.isEmpty
    }

    /// Whether Gemini is configured (has API key)
    var isGeminiConfigured: Bool {
        !geminiAPIKey.isEmpty
    }

    /// Whether OpenAI is configured (has API key)
    var isOpenAIConfigured: Bool {
        !openAIAPIKey.isEmpty && !openAIBaseURL.isEmpty
    }

    /// Whether the local Gemma backend is ready (model downloaded)
    var isLocalGemmaConfigured: Bool {
        localGemmaModelReady
    }

    /// Whether the currently selected backend is configured
    var isCurrentBackendConfigured: Bool {
        switch aiBackend {
        case .openClaw: return isOpenClawConfigured
        case .geminiLive: return isGeminiConfigured
        case .openAI: return isOpenAIConfigured
        case .appleFoundation: return true   // OS-managed; availability checked at connect
        case .localGemma: return isLocalGemmaConfigured
        }
    }

    /// Backend label for the UI. For the local backend, reflects the *actually selected* MLX model
    /// (Qwen / SmolVLM / FastVLM / …) instead of a fixed name, so the main-screen pill is accurate.
    var backendDisplayName: String {
        guard aiBackend == .localGemma else { return aiBackend.displayName }
        return "Local · \(GemmaLocalModel.from(modelId: localGemmaModelId).displayName)"
    }
}
