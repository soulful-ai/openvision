// OpenVision - SettingsView.swift
// Main settings menu with navigation to configuration panels

import SwiftUI

struct SettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // AI Backend Section
                Section {
                    NavigationLink {
                        AIBackendSettingsView()
                    } label: {
                        HStack {
                            Label("AI Backend", systemImage: "cpu")
                            Spacer()
                            Text(settingsManager.settings.aiBackend.displayName)
                                .foregroundColor(.secondary)
                            if !settingsManager.settings.isCurrentBackendConfigured {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    NavigationLink {
                        WebSearchSettingsView()
                    } label: {
                        HStack {
                            Label("Web Search", systemImage: "magnifyingglass")
                            Spacer()
                            Text(settingsManager.settings.tavilyAPIKey.isEmpty ? "DuckDuckGo" : "Tavily")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Only show for Gemini Live (OpenClaw has its own system prompt & memories)
                    if settingsManager.settings.aiBackend == .geminiLive {
                        NavigationLink {
                            AdditionalInstructionsView()
                        } label: {
                            Label("Custom Instructions", systemImage: "text.quote")
                        }

                        NavigationLink {
                            MemoriesView()
                        } label: {
                            HStack {
                                Label("Memories", systemImage: "brain")
                                Spacer()
                                Text("\(settingsManager.settings.memories.count)")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("AI")
                }

                // Hardware Section
                Section {
                    NavigationLink {
                        GlassesSettingsView()
                    } label: {
                        HStack {
                            Label("Glasses", systemImage: "eyeglasses")
                            Spacer()
                            if glassesManager.isRegistered {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                } header: {
                    Text("Hardware")
                }

                // Voice Section
                Section {
                    NavigationLink {
                        VoiceSettingsView()
                    } label: {
                        HStack {
                            Label("Voice Control", systemImage: "mic.fill")
                            Spacer()
                            if settingsManager.settings.wakeWordEnabled {
                                Text(settingsManager.settings.wakeWord)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Off")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Voice")
                }

                // Connections Section — AUR-795: every phone integration the brain can reach,
                // its live state, and the per-row kill switch that removes it from the wire.
                Section {
                    NavigationLink {
                        ConnectionsSettingsView()
                    } label: {
                        HStack {
                            Label("Connections", systemImage: "app.connected.to.app.below.fill")
                            Spacer()
                            Text("\(OpenAIRealtimeService.shared.clientTools.toolNames.count) tools")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Connections")
                }

                // Advanced Section
                Section {
                    NavigationLink {
                        DocumentsSettingsView()
                    } label: {
                        Label("My Documents", systemImage: "books.vertical")
                    }

                    Toggle(isOn: $settingsManager.settings.autoReconnect) {
                        Label("Auto-Reconnect", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Toggle(isOn: $settingsManager.settings.showTranscripts) {
                        Label("Show Transcripts", systemImage: "text.bubble")
                    }
                } header: {
                    Text("Advanced")
                }

                // Debug Section — AUR-823: the listen-mode backups on this phone + their
                // server re-transcription uploads.
                Section {
                    NavigationLink {
                        ListenBackupsView()
                    } label: {
                        Label("Listen backups", systemImage: "waveform.badge.mic")
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Local mic backups from «listen» calls; upload one to the brain to re-transcribe it (multilingual + speakers).")
                }

                // About Section
                Section {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text("\(Config.appVersion) (\(Config.buildNumber))")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/rayl15/OpenVision")!) {
                        Label("GitHub Repository", systemImage: "link")
                    }

                    Link(destination: URL(string: "https://github.com/openclaw/openclaw")!) {
                        Label("Get OpenClaw", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("OpenVision is open source under the MIT license.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
}
