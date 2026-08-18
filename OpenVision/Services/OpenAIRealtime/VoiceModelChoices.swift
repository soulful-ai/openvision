// OpenVision - VoiceModelChoices.swift
// AUR-759: which brain answers a live conversation. The picker in Settings → Voice Control lists
// what the server offers (GET <openAIBaseURL>/realtime/models, Bearer = the OpenAI backend key);
// until that answers — or when the backend isn't configured — a built-in trio stands in. The pick
// is stored in `openAIRealtimeModel` and rides the realtime WebSocket URL as `?model=`; empty =
// "Server default" (the brain's REALTIME_MODEL).

import Foundation

struct VoiceModelChoice: Identifiable, Equatable, Decodable {
    let id: String
    let displayName: String
    let isDefault: Bool

    private enum CodingKeys: String, CodingKey { case id, displayName = "display_name", isDefault = "default" }

    init(id: String, displayName: String, isDefault: Bool = false) {
        self.id = id; self.displayName = displayName; self.isDefault = isDefault
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

@MainActor
final class VoiceModelChoices: ObservableObject {
    static let shared = VoiceModelChoices()

    /// The picker's tag for "let the server decide".
    static let serverDefault = ""

    /// Offered when the server can't be asked (mirrors the brain's REALTIME_MODEL_CHOICES default).
    static let fallback: [VoiceModelChoice] = [
        VoiceModelChoice(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
        VoiceModelChoice(id: "gemini-3-flash-preview", displayName: "Gemini 3 Flash"),
        VoiceModelChoice(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash"),
    ]

    @Published private(set) var choices: [VoiceModelChoice] = VoiceModelChoices.fallback
    /// The server's REALTIME_MODEL when known (shown next to "Server default").
    @Published private(set) var serverDefaultId: String?
    @Published private(set) var isFromServer = false

    private var lastFetch: Date?

    /// Human name for a model id (server list first, then the fallback, then the raw id).
    func displayName(for id: String) -> String {
        (choices + Self.fallback).first(where: { $0.id == id })?.displayName ?? id
    }

    /// `<openAIBaseURL>/realtime/models`, tolerating a trailing slash.
    private static var listURL: URL? {
        var base = SettingsManager.shared.settings.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty else { return nil }
        return URL(string: base + "/realtime/models")
    }

    /// Ask the server (at most once a minute) — silently keeps the fallback on any failure.
    func refresh(force: Bool = false) async {
        guard SettingsManager.shared.settings.isOpenAIConfigured, let url = Self.listURL else { return }
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < 60 { return }
        lastFetch = Date()
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("Bearer \(SettingsManager.shared.settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            struct Envelope: Decodable { let data: [VoiceModelChoice]; let `default`: String? }
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            guard !env.data.isEmpty else { return }
            choices = env.data
            serverDefaultId = env.default ?? env.data.first(where: { $0.isDefault })?.id
            isFromServer = true
        } catch {
            ovLog("[VoiceModelChoices] fetch failed, keeping fallback: \(error)")
        }
    }
}
