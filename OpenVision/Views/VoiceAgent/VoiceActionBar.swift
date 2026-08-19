// OpenVision - VoiceActionBar.swift
// AUR-776: the small action row on the live screen (Photo · Video · Listen) and the recording
// badge with elapsed time. Buttons only REQUEST (`aurelia.action.request`); the brain echoes
// `aurelia.action` and the action runs on that echo — voice and taps share one path.

import SwiftUI

/// Photo · Video · Listen — shown while a realtime conversation is live.
struct VoiceActionBar: View {
    @ObservedObject var actions: VoiceActionService
    let onPhoto: () -> Void
    /// mode: silent (tap) or assist (long-press).
    let onVideo: (VoiceActionMode) -> Void
    let onListen: () -> Void
    /// AUR-776b: the canonical phrase list, on the "?" (or a long-press on the row).
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 10) {
            actionPill(symbol: "camera.fill", title: "Photo", active: false) { onPhoto() }
                .accessibilityLabel("Take a photo")

            // Tap = silent video (or stop); hold = assist video. Gestures rather than a Button so
            // a long press does not ALSO fire the tap on release.
            pillLabel(symbol: actions.videoRecording != nil ? "stop.fill" : "video.badge.plus",
                      title: actions.videoRecording != nil ? "Stop" : "Video",
                      active: actions.videoRecording != nil)
                .onTapGesture { onVideo(.silent) }
                .onLongPressGesture(minimumDuration: 0.5) {
                    if actions.videoRecording == nil { onVideo(.assist) }
                }
                .accessibilityLabel(actions.videoRecording != nil ? "Stop video" : "Record video")
                .accessibilityHint("Touch and hold to record with the assistant watching")

            actionPill(symbol: actions.audioRecording != nil ? "stop.fill" : "waveform.badge.mic",
                       title: actions.audioRecording != nil ? "Stop" : "Listen",
                       active: actions.audioRecording != nil) { onListen() }
                .accessibilityLabel(actions.audioRecording != nil ? "Stop listening" : "Listen and record")

            Button { showHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .accessibilityLabel("Voice phrases")
        }
        .onLongPressGesture(minimumDuration: 0.6) { showHelp = true }
        .sheet(isPresented: $showHelp) { VoicePhraseHelpSheet() }
    }

    private func actionPill(symbol: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(symbol: symbol, title: title, active: active) }
    }

    private func pillLabel(symbol: String, title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption.bold())
            Text(title).font(.caption.bold())
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(active ? Color.red.opacity(0.85) : Color.white.opacity(0.15)))
        .contentShape(Capsule())
    }
}

/// Red dot + "REC 00:12" / "LISTEN 00:12" while a voice-action recording runs.
struct RecordingBadge: View {
    @ObservedObject var actions: VoiceActionService

    var body: some View {
        if let rec = actions.videoRecording ?? actions.audioRecording {
            TimelineView(.periodic(from: rec.startedAt, by: 1)) { context in
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .opacity(Int(context.date.timeIntervalSince(rec.startedAt)) % 2 == 0 ? 1 : 0.35)
                    Text(label(for: rec))
                        .font(.caption.bold().monospacedDigit())
                    Text(Self.clock(context.date.timeIntervalSince(rec.startedAt)))
                        .font(.caption.monospacedDigit())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.55)))
            }
            .accessibilityLabel("\(label(for: rec)) recording")
        }
    }

    private func label(for rec: VoiceActionService.ActiveRecording) -> String {
        switch rec.kind {
        case .video: return rec.mode == .assist ? "REC · assist" : "REC"
        case .audio: return "LISTEN"
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Transient outcome line after an action ("Photo saved", "Recording video", …). Auto-clears.
struct ActionStatusPill: View {
    @ObservedObject var actions: VoiceActionService

    var body: some View {
        if let status = actions.lastStatus {
            Text(status)
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.55)))
                .transition(.opacity)
        }
    }
}

/// AUR-776b: the canonical phrases the brain recognises (ru / en), so nobody has to guess them.
struct VoicePhraseHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    static let phrases: [(ru: String, en: String, what: String)] = [
        ("Сделай фото", "Take a photo", "Photo"),
        ("Запиши видео", "Record video", "Video, silent"),
        ("Снимай и смотри", "Record and watch", "Video, assistant watching"),
        ("Стоп видео", "Stop video", "Stop the video"),
        ("Смотри", "Look", "Eye on"),
        ("Не смотри", "Stop looking", "Eye off"),
        ("Слушай", "Listen", "Listen / record audio"),
        ("Стоп запись", "Stop recording", "Stop listening"),
        ("Стоп", "Stop", "Stop what is running"),
        ("Пока", "Bye", "End the conversation")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(Self.phrases.enumerated()), id: \.offset) { _, p in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("«\(p.ru)»").font(.body.bold())
                                Text("·").foregroundColor(.secondary)
                                Text("\"\(p.en)\"").font(.body)
                            }
                            Text(p.what).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Say it during the conversation")
                } footer: {
                    Text("Each action answers with a short sound. Eye on/off also works with «открой / закрой камеру».")
                }
            }
            .navigationTitle("Voice phrases")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
