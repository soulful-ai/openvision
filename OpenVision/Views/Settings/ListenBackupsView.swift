// OpenVision - ListenBackupsView.swift
// AUR-823: Settings → Debug → Listen backups. Every listen-mode backup on the phone (date,
// duration, uploaded ✓/—, the server's word count) with an Upload button per row and
// "Upload all pending" — the after-the-fact rail for a meeting whose live transcript came out
// thin. Rows for files that predate the index are reconciled on open (see ListenBackupUploader).

import SwiftUI

struct ListenBackupsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject private var uploader = ListenBackupUploader.shared
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settingsManager.settings.listenBackupUpload) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-upload after listen")
                        Text("Backups ≥ 60 s go to the brain for re-transcription")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Button {
                    uploader.uploadAllPending()
                } label: {
                    Label("Upload all pending (\(uploader.pending.count))", systemImage: "icloud.and.arrow.up")
                }
                .disabled(uploader.pending.isEmpty || !settingsManager.settings.isOpenAIConfigured)
            } footer: {
                Text("POST \(endpointHint) — the server re-transcribes with diarization and pushes the result to Telegram.")
            }

            Section {
                if !loaded {
                    HStack { ProgressView(); Text("Scanning Captures…").foregroundColor(.secondary) }
                } else if uploader.captures.isEmpty {
                    Text("No listen backups yet. Say «listen» / «послушай» in a call; the mic is backed up to Documents/Captures/listen-*.m4a.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(uploader.captures) { capture in
                        row(capture)
                    }
                }
            } header: {
                Text("Captures")
            }

            if let err = uploader.lastError {
                Section {
                    Text(err).font(.caption).foregroundColor(.red)
                } header: {
                    Text("Last error")
                }
            }
        }
        .navigationTitle("Listen backups")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await uploader.reload()
            loaded = true
        }
        .refreshable {
            await uploader.reload()
        }
    }

    @ViewBuilder
    private func row(_ capture: ListenCapture) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Self.dateFormatter.string(from: capture.startedAt))
                        .font(.subheadline.weight(.medium))
                    Text(Self.duration(capture.durationMs))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Text(capture.stem)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: capture.uploaded ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundColor(capture.uploaded ? .green : .secondary)
                    Text(capture.uploaded ? "uploaded" : "not uploaded")
                    if let r = capture.result {
                        Text("· \(r)").lineLimit(2)
                    }
                }
                .font(.caption)
                .foregroundColor(capture.result?.hasPrefix("error") == true ? .red : .secondary)
            }
            Spacer()
            if uploader.inFlight.contains(capture.stem) {
                ProgressView()
            } else {
                Button(capture.uploaded ? "Re-upload" : "Upload") {
                    uploader.upload(capture)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!settingsManager.settings.isOpenAIConfigured)
            }
        }
        .padding(.vertical, 2)
    }

    private var endpointHint: String {
        var base = settingsManager.settings.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        return (base.isEmpty ? "<backend URL>" : base) + "/voice/recordings/{stem}/audio"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func duration(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

#Preview {
    NavigationStack { ListenBackupsView() }
        .environmentObject(SettingsManager.shared)
}
