// OpenVision - VoiceAgentView.swift
// Beautiful main voice conversation UI with glassmorphism design.
//
// MVVM: this view only renders state and forwards interactions — every piece of orchestration
// (session lifecycle, command routing, live video, TTS streaming) lives in VoiceAgentViewModel.

import SwiftUI

struct VoiceAgentView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager

    // MARK: - ViewModel

    @StateObject private var viewModel = VoiceAgentViewModel()

    // MARK: - Observed services
    // Only the services whose @Published state the body reacts to directly. They are the same
    // singletons the ViewModel drives — observed here purely so onChange fires.

    @StateObject private var voiceCommandService = VoiceCommandService.shared
    @StateObject private var ttsService = TTSService.shared
    @StateObject private var kokoroTTS = KokoroTTSService.shared
    @StateObject private var documentFocus = DocumentFocus.shared

    // MARK: - Body

    var body: some View {
        ZStack {
            // Beautiful animated background
            AnimatedBackground()

            // Particle effects
            ParticleEffect(particleCount: 30)
                .opacity(0.5)

            // Main content — the orb stays vertically centered and STABLE. The transcript is a
            // separate overlay (below) so it can never push the orb around.
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 8)
                // Document-focus pill: visible whenever a document is "open" so the mode is never
                // silently steering answers. Tap to release focus.
                if let doc = documentFocus.activeDocument {
                    HStack(spacing: 6) {
                        Image(systemName: "book.fill").font(.caption2)
                        Text(doc.title).font(.caption.bold()).lineLimit(1)
                        Image(systemName: "xmark.circle.fill").font(.caption2).opacity(0.7)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.indigo.opacity(0.8)))
                    .padding(.top, 8)
                    .onTapGesture { documentFocus.deactivate() }
                    .transition(.opacity)
                }
                Spacer()
                centerContent
                Spacer()
            }

            // Transcript floats over the bottom; growing text stays inside its own card and doesn't
            // move the orb.
            if settingsManager.settings.showTranscripts
                && (!viewModel.userTranscript.isEmpty || !viewModel.aiTranscript.isEmpty || viewModel.agentState == .thinking) {
                VStack {
                    Spacer()
                    transcriptArea
                        .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Error overlay
            if let error = viewModel.errorMessage {
                errorOverlay(error)
            }
        }
        // Animate the state text and the transcript's appear/disappear only — NOT every streamed
        // token (the old .spring on userTranscript/aiTranscript sprang the whole view and jostled
        // the orb on every word).
        .animation(.easeInOut(duration: 0.3), value: viewModel.agentState)
        .animation(.easeInOut(duration: 0.35), value: viewModel.userTranscript.isEmpty)
        .animation(.easeInOut(duration: 0.35), value: viewModel.aiTranscript.isEmpty)
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .task {
            await viewModel.requestSpeechAuthorization()
        }
        // Observe TTS state changes
        .onChange(of: ttsService.isSpeaking) { isSpeaking in
            viewModel.ttsSpeakingChanged(isSpeaking)
        }
        .onChange(of: kokoroTTS.isSpeaking) { speaking in
            viewModel.kokoroSpeakingChanged(speaking)
        }
        // Control thinking sound based on agent state
        .onChange(of: viewModel.agentState) { newState in
            viewModel.agentStateChanged(newState)
        }
        // Observe VoiceCommandService state changes
        .onChange(of: voiceCommandService.state) { newState in
            viewModel.voiceStateChanged(newState)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // AI Backend status (or Live Video indicator)
            if viewModel.isLiveVideoMode {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .stroke(.red.opacity(0.5), lineWidth: 2)
                                .scaleEffect(1.5)
                        )

                    Text("LIVE")
                        .font(.caption.bold())
                        .foregroundColor(.white)

                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.red.opacity(0.8))
                )

                // AUR-723b: which eye she is actually seeing through — glasses, the phone's own
                // rear camera, or nothing (camera permission off).
                HStack(spacing: 4) {
                    Image(systemName: viewModel.liveCameraSource.symbol)
                        .font(.caption2)
                    Text(viewModel.liveCameraSource.label)
                        .font(.caption2.bold())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        viewModel.liveCameraSource == .none
                            ? Color.gray.opacity(0.7) : Color.blue.opacity(0.8)
                    )
                )
                .padding(.leading, 6)
                .accessibilityLabel("Live camera source: \(viewModel.liveCameraSource.label)")

                // AUR-759: which brain is answering (the server's resolved model for this session).
                if let model = viewModel.liveModel {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                            .font(.caption2)
                        Text(VoiceModelChoices.shared.displayName(for: model))
                            .font(.caption2.bold())
                            .lineLimit(1)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.purple.opacity(0.75)))
                    .padding(.leading, 6)
                    .accessibilityLabel("Voice model: \(VoiceModelChoices.shared.displayName(for: model))")
                }
            } else {
                StatusPill(
                    status: settingsManager.settings.backendDisplayName,
                    color: viewModel.agentState == .idle ? .gray : .green,
                    isConnected: viewModel.agentState != .idle && viewModel.agentState != .connecting
                )
            }

            Spacer()

            // AUR-776: REC / LISTEN badge with elapsed time while a voice-action recording runs.
            RecordingBadge(actions: viewModel.voiceActions)

            // AUR-776: transient action outcome ("Photo saved", …).
            if viewModel.recordingStatus == nil {
                ActionStatusPill(actions: viewModel.voiceActions)
            }

            // Transient "Saved to Photos" / failure status after a recording finishes.
            if let status = viewModel.recordingStatus {
                Text(status)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .transition(.opacity)
            }

            // POV recording toggle (glasses video + as-heard audio → Photos).
            if glassesManager.isRegistered {
                Button {
                    viewModel.toggleRecording()
                } label: {
                    Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.title2)
                        .foregroundColor(viewModel.isRecording ? .red : .white)
                        .padding(.horizontal, 4)
                }
                .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Record point of view")
            }

            // Glasses status
            HStack(spacing: 8) {
                Image(systemName: "eyeglasses")
                    .foregroundColor(glassesManager.isRegistered ? .green : .gray)

                if glassesManager.isStreaming {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Center Content

    /// Map the agent state to the orb's visual mode.
    private var orbMode: SwirlOrb.Mode {
        switch viewModel.agentState {
        case .listening: return .listening
        case .speaking: return .speaking
        case .thinking, .toolRunning, .connecting: return .thinking
        case .idle, .liveVideo: return .idle
        }
    }

    private var centerContent: some View {
        VStack(spacing: 28) {
            // Heading / status prompt
            Group {
                if viewModel.agentState == .liveVideo {
                    VStack(spacing: 6) {
                        Text(settingsManager.settings.backendDisplayName)
                            .font(.headline)
                            .foregroundColor(Theme.heading)
                        Text("Tap the orb to end")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                } else if viewModel.agentState == .idle && settingsManager.settings.wakeWordEnabled {
                    VStack(spacing: 8) {
                        Text("What can I see?")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.heading)
                        if viewModel.isVoiceReady {
                            VStack(spacing: 4) {
                                Text("Say \"\(settingsManager.settings.wakeWord)\" or tap to talk")
                                    .font(.subheadline)
                                    .foregroundColor(Theme.textSecondary)
                                Text("Long-press the orb for push-to-ask")
                                    .font(.caption2)
                                    .foregroundColor(Theme.textSecondary.opacity(0.7))
                            }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().tint(Theme.accent).scaleEffect(0.8)
                                Text("Initializing voice…")
                                    .font(.subheadline)
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            .transition(.opacity)

            // The assistant identity: swirling emerald orb (tap to start/stop a session)
            SwirlOrb(mode: orbMode, size: 250)
                // AUR-742a: ONE TAP opens the realtime conversation (no «включи видео» needed).
                // Push-to-ask — Margo's fallback until AUR-744 — moves to a long press.
                .onTapGesture { viewModel.toggleTalkMode() }
                .onLongPressGesture(minimumDuration: 0.6) { viewModel.toggleSession() }
                .accessibilityLabel(viewModel.isLiveVideoMode ? "End the conversation" : "Start the conversation")
                .accessibilityHint("Double tap to talk. Touch and hold for push-to-ask.")

            // Explicit entry next to the orb, so the conversation is discoverable without
            // knowing that the orb is tappable.
            HStack(spacing: 12) {
                Button {
                    viewModel.toggleTalkMode()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.isLiveVideoMode ? "stop.circle.fill" : "waveform.circle.fill")
                            .font(.title3)
                        Text(viewModel.isLiveVideoMode ? "End" : "Talk / Разговор")
                            .font(.subheadline.bold())
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(viewModel.isLiveVideoMode
                                       ? Color.red.opacity(0.85) : Theme.accent.opacity(0.9))
                    )
                }
                .disabled(!viewModel.canStartTalkMode)
                .opacity(viewModel.canStartTalkMode ? 1 : 0.4)

                if viewModel.isLiveVideoMode {
                    // AUR-742a/AUR-757: the eye is opt-in inside the conversation — BOTH eyes.
                    // The toggle opens the glasses camera when they are there, the phone otherwise.
                    Button {
                        viewModel.toggleLiveCamera()
                    } label: {
                        Image(systemName: viewModel.liveCameraSource == .none ? "video.slash.fill" : "video.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(
                                Circle().fill(viewModel.liveCameraSource == .none
                                              ? Color.white.opacity(0.15) : Theme.accent.opacity(0.9))
                            )
                    }
                    .accessibilityLabel(viewModel.liveCameraSource == .none
                                        ? (viewModel.glassesEyeAvailable ? "Turn the glasses camera on" : "Turn the camera on")
                                        : "Turn the camera off")
                }

                if !viewModel.isLiveVideoMode {
                    Button {
                        viewModel.toggleSession()
                    } label: {
                        Text(viewModel.isSessionActive ? "Stop push-to-ask" : "Push-to-ask")
                            .font(.caption.bold())
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Capsule().stroke(Theme.textSecondary.opacity(0.35), lineWidth: 1))
                    }
                }
            }

            // AUR-776: Photo · Video · Listen — fast actions, same path as the voice phrases.
            if viewModel.voiceActionsAvailable {
                VoiceActionBar(
                    actions: viewModel.voiceActions,
                    onPhoto: { viewModel.tapPhoto() },
                    onVideo: { mode in viewModel.tapVideo(mode: mode) },
                    onListen: { viewModel.tapListen() }
                )
                .transition(.opacity)
            }

            // Status text
            Text(viewModel.agentState.displayText)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(Theme.textPrimary)

            // Tool status
            if let tool = viewModel.currentToolName, viewModel.agentState == .toolRunning {
                ToolStatusView(toolName: tool, isRunning: true)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Transcript Area

    // Bubbles float directly over the background (no outer card box — the old GlassCard wrapper
    // was a mostly-empty gray slab).
    private var transcriptArea: some View {
        TranscriptView(
            userText: viewModel.userTranscript,
            aiText: viewModel.aiTranscript,
            isAIStreaming: viewModel.agentState == .speaking
        )
        .padding(.horizontal, 20)
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ message: String) -> some View {
        VStack {
            Spacer()

            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white)

                Spacer()

                Button {
                    viewModel.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.red.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
            .padding(.bottom, 150)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    VoiceAgentView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
        .preferredColorScheme(.dark)
}
