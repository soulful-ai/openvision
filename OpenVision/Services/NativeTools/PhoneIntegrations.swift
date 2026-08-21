// OpenVision - PhoneIntegrations.swift
// AUR-795: the Connections model — one row per integration, and the row IS the wire.
//
// The phone-body plan (§2) asks for "Settings → Connections: one row per integration with state
// (linked / needs permission / off), a Connect button, a one-line 'what she can do with it', and a
// per-row kill switch". The rule that keeps this honest: **the switch state is what the wire
// carries.** Every row here contributes exactly one key to `aurelia.client_tools.connections`, and
// a killed row (a) reports `off` on that key and (b) removes its tools from the advertised set — so
// the brain is never told about a tool the wearer switched off, and the Connections screen can
// never disagree with what the model believes.
//
// Rows are integrations that EXIST or land in the very next commit (shazam / spotify, AUR-793 — the
// manifest simply never advertises a tool that is not registered yet, so the map stays truthful
// either way). Apple Music and Shortcuts are on the plan (AUR-796) and are deliberately NOT listed
// until they have tools — a row that promises nothing is worse than no row.

import Foundation

/// One integration = one row in Settings → Connections = one key in the `connections` map.
enum PhoneIntegration: String, CaseIterable, Identifiable {
    case calendar
    case reminders
    case notifications
    case location
    case notes
    case clipboard
    case documents
    /// The phone itself (AUR-794 `phone.status`) — no account, no permission.
    case device
    /// AUR-793: music recognition on the phone mic.
    case shazam
    /// AUR-793: the only row that needs an OAuth account link.
    case spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .notifications: return "Notifications"
        case .location: return "Location"
        case .notes: return "Notes"
        case .clipboard: return "Clipboard"
        case .documents: return "My Documents"
        case .device: return "Phone status"
        case .shazam: return "Shazam"
        case .spotify: return "Spotify"
        }
    }

    var icon: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .notifications: return "bell.badge"
        case .location: return "location"
        case .notes: return "note.text"
        case .clipboard: return "doc.on.clipboard"
        case .documents: return "books.vertical"
        case .device: return "iphone"
        case .shazam: return "music.mic"
        case .spotify: return "music.note.list"
        }
    }

    /// The one line the wearer reads: what she can actually do with it.
    var blurb: String {
        switch self {
        case .calendar: return "Читает сегодняшние и ближайшие события, добавляет новые."
        case .reminders: return "Создаёт напоминания со сроком."
        case .notifications: return "Таймеры и помодоро — без этого будильник молчит."
        case .location: return "Название Wi-Fi сети в «сколько батареи» и место в заметках."
        case .notes: return "Заметки в приложении, с местом и временем."
        case .clipboard: return "Копирует текст в буфер, чтобы вставить в другом приложении."
        case .documents: return "Ищет по твоим документам в приложении."
        case .device: return "Батарея, зарядка, Wi-Fi, температура, свободное место."
        case .shazam: return "Слушает музыку вокруг и называет трек."
        case .spotify: return "Включает, ставит на паузу и лайкает треки в Spotify."
        }
    }

    /// Registry tool names this row owns. Killing the row removes exactly these from the manifest.
    var toolNames: [String] {
        switch self {
        case .calendar: return ["calendar"]
        case .reminders: return ["create_reminder"]
        case .notifications: return ["set_timer", "start_pomodoro"]
        case .location: return []          // no tool of its own; it unlocks fields in others
        case .notes: return ["note"]
        case .clipboard: return ["copy_to_clipboard"]
        case .documents: return ["search_docs"]
        case .device: return ["status"]
        case .shazam: return ["shazam"]
        case .spotify: return ["spotify_play", "spotify_like", "spotify_now_playing", "spotify_control"]
        }
    }

    /// The OS permission behind the row, if any (the same strings `NativeTool.permissionKind` uses).
    var permissionKind: String? {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "reminders"
        case .notifications: return "notifications"
        case .location: return "location"
        case .shazam: return "microphone"
        default: return nil
        }
    }

    /// The account link behind the row, if any (`connections` reports linked/unlinked for these).
    var linkService: String? { self == .spotify ? "spotify" : nil }

    /// The integration that owns a registry tool name, if any.
    static func owning(toolNamed name: String) -> PhoneIntegration? {
        allCases.first { $0.toolNames.contains(name) }
    }
}

/// The kill switches, persisted locally (UserDefaults — a per-phone preference, not a secret).
/// Default: everything ON; only an explicit switch-off is stored, so a new integration is live the
/// moment it ships without a migration.
@MainActor
final class PhoneIntegrationStore: ObservableObject {
    static let shared = PhoneIntegrationStore()

    static let storageKey = "aurelia.phone.integrations.disabled"
    /// Posted after any change so the live realtime bridge re-advertises (the brain must never keep
    /// believing in a tool the wearer just switched off).
    static let didChange = Notification.Name("aurelia.phone.integrations.didChange")

    private let defaults: UserDefaults
    @Published private(set) var disabled: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.storageKey) ?? []
        self.disabled = Set(stored.filter { PhoneIntegration(rawValue: $0) != nil })
    }

    func isEnabled(_ integration: PhoneIntegration) -> Bool { !disabled.contains(integration.rawValue) }

    func setEnabled(_ integration: PhoneIntegration, _ enabled: Bool) {
        let was = disabled
        if enabled { disabled.remove(integration.rawValue) } else { disabled.insert(integration.rawValue) }
        guard disabled != was else { return }
        defaults.set(Array(disabled).sorted(), forKey: Self.storageKey)
        ovLog("🔌 connections: \(integration.rawValue) \(enabled ? "ON" : "OFF") — advertised tools now exclude \(disabledToolNames.sorted().joined(separator: ", "))")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Registry names currently switched off.
    var disabledToolNames: Set<String> {
        Set(disabled.compactMap { PhoneIntegration(rawValue: $0) }.flatMap(\.toolNames))
    }

    /// Wire names (`phone.<tool>`) currently switched off — what the bridge filters on.
    var disabledWireNames: Set<String> {
        Set(disabledToolNames.map { ClientToolBridge.wireName(for: $0) })
    }
}
