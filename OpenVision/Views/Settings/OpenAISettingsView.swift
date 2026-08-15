// OpenVision - OpenAISettingsView.swift
// OpenAI (and OpenAI-compatible) backend configuration.

import SwiftUI

struct OpenAISettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = ""
    @State private var model: String = "gpt-4o-mini"
    @State private var baseURL: String = "https://api.openai.com/v1"

    var body: some View {
        Form {
            // API Key
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("sk-…", text: $apiKey)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Authentication")
            } footer: {
                if apiKey.isEmpty {
                    Label("Required for OpenAI mode", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange).font(.caption)
                } else {
                    Label("API key configured", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green).font(.caption)
                }
            }

            // Model
            Section {
                TextField("Model", text: $model)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Model")
            } footer: {
                Text("e.g. gpt-4o-mini (cheap, supports vision), gpt-4o, or any model your endpoint serves.")
            }

            // Endpoint (for OpenAI-compatible servers)
            Section {
                TextField("Base URL", text: $baseURL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("Endpoint")
            } footer: {
                Text("Default is OpenAI. Point this at any OpenAI-compatible API (OpenRouter, a local server, etc.). No trailing slash.")
            }

            // Streaming
            Section {
                Toggle(isOn: $settingsManager.settings.openAIStreamResponses) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stream Replies")
                        Text("Speak and show the answer as it's generated")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Streaming")
            } footer: {
                Text("Sends stream: true so the reply arrives token-by-token — the assistant starts speaking the first sentence while the rest is still being written. If your endpoint doesn't support SSE the app detects it and falls back automatically.")
            }

            // Help
            Section {
                Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                    HStack {
                        Text("Get API Key")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Help")
            } footer: {
                Text("OpenAI is a cloud backend for text and vision (photos). Useful for verifying the cloud command + camera path.")
            }
        }
        .navigationTitle("OpenAI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = settingsManager.settings.openAIAPIKey
            model = settingsManager.settings.openAIModel
            baseURL = settingsManager.settings.openAIBaseURL
        }
        .onDisappear { saveSettings() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveSettings(); dismiss() }
            }
        }
    }

    private func saveSettings() {
        settingsManager.settings.openAIAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.settings.openAIModel = trimmedModel.isEmpty ? "gpt-4o-mini" : trimmedModel
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url.removeLast() }
        settingsManager.settings.openAIBaseURL = url.isEmpty ? "https://api.openai.com/v1" : url
        settingsManager.saveNow()
    }
}

#Preview {
    NavigationStack {
        OpenAISettingsView().environmentObject(SettingsManager.shared)
    }
}
