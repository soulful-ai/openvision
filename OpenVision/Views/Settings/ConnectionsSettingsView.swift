// OpenVision - ConnectionsSettingsView.swift
// AUR-795: Settings → Connections. One row per integration: what she can do with it, the live
// state, a Connect button (the OS prompt or the account link) and a kill switch.
//
// The screen is not a mirror of the wire — it IS the wire. Every row's state is read from the same
// `PhoneConnections` snapshot the realtime bridge sends in `aurelia.client_tools.connections`, and
// the kill switch writes the set the bridge filters its advertised tools by. Flip a switch during a
// live call and the manifest goes out again immediately (PhoneIntegrationStore.didChange →
// ClientToolBridge.refreshConnections), so the brain can never keep believing in a tool the wearer
// just switched off.

import SwiftUI

struct ConnectionsSettingsView: View {

    @ObservedObject private var store = PhoneIntegrationStore.shared
    @ObservedObject private var bridge = OpenAIRealtimeService.shared.clientTools

    /// The live permission / link states — re-read on appear, on every return to the foreground
    /// (the moment a system prompt resolves) and after each Connect.
    @State private var connections = PhoneConnections()
    /// The row whose Connect button is currently waiting on a prompt.
    @State private var connecting: String?
    /// A row-level note (why Connect can't do anything yet).
    @State private var notes: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(PhoneIntegration.allCases) { row($0) }
            } header: {
                Text("Integrations")
            } footer: {
                Text("Off = the tool is not advertised to the brain at all for the next session, "
                     + "and the connection reports «off» on the wire.")
            }

            Section {
                HStack {
                    Text("Advertised now")
                    Spacer()
                    Text("\(bridge.toolNames.count) tool\(bridge.toolNames.count == 1 ? "" : "s")")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
                Text(bridge.toolNames.joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                HStack {
                    Text("Last sent to the brain")
                    Spacer()
                    Text(bridge.lastManifestSentAt?.formatted(date: .omitted, time: .standard)
                         ?? "not yet (no live session)")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            } header: {
                Text("On the wire")
            }
        }
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    // MARK: - One row

    @ViewBuilder
    private func row(_ integration: PhoneIntegration) -> some View {
        let state = connections.state(of: integration)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(integration.title, systemImage: integration.icon)
                Spacer()
                Text(state)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(color(for: state))
            }
            Text(integration.blurb)
                .font(.caption)
                .foregroundColor(.secondary)
            if let note = notes[integration.rawValue] {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            HStack {
                if let title = connectTitle(integration, state: state) {
                    Button(title) { Task { await connect(integration) } }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .disabled(connecting == integration.rawValue)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.isEnabled(integration) },
                    set: { store.setEnabled(integration, $0) }
                ))
                .labelsHidden()
            }
        }
        .padding(.vertical, 2)
    }

    /// What the button offers, or nil when there is nothing to do (already granted / linked / off).
    private func connectTitle(_ integration: PhoneIntegration, state: String) -> String? {
        guard store.isEnabled(integration) else { return nil }
        switch state {
        case "unknown": return "Connect"
        case "denied": return "Open Settings"
        case "unlinked": return "Connect"
        default: return nil
        }
    }

    private func connect(_ integration: PhoneIntegration) async {
        connecting = integration.rawValue
        defer { connecting = nil }
        notes[integration.rawValue] = nil

        if let kind = integration.permissionKind {
            if connections.state(for: kind) == .denied {
                // iOS shows a permission prompt exactly once; after a "Don't Allow" the only way
                // back is the app's own page in Settings.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    await UIApplication.shared.open(url)
                }
                return
            }
            _ = await PhoneConnections.requestPermission(kind: kind)
            await refresh()
            bridge.refreshConnections(reason: "connections screen: \(integration.rawValue)")
            return
        }

        if integration.linkService == "spotify" {
            // AUR-793 lands the OAuth flow in the next commit; until then the row says what is
            // missing instead of pretending to link.
            notes[integration.rawValue] = "Spotify: OAuth ещё не настроен (AUR-793)."
            return
        }
    }

    private func refresh() async {
        connections = await PhoneConnections.current()
    }

    private func color(for state: String) -> Color {
        switch state {
        case "granted", "linked", "on": return .green
        case "denied": return .orange
        case "off": return .secondary
        default: return .secondary
        }
    }
}

#Preview {
    NavigationStack { ConnectionsSettingsView() }
}
