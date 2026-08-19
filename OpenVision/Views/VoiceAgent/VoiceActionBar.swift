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
        }
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
