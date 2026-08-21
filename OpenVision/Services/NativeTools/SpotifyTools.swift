// OpenVision - SpotifyTools.swift
// AUR-793b: `phone.spotify_play` / `_like` / `_now_playing` / `_control` — the Meta-parity half of
// «Шазам → включи → лайкни».
//
// Every one of them is honest while unlinked: `not_linked:spotify` + «Spotify не подключён — открой
// Connections в настройках и подключи». Never a fake `ok`. The moment a client id exists and the
// Connections row is linked, the same code paths do the real thing over the Web API.
//
// The one place iOS forces a wait (AUR-845 deferred-effect contract): Spotify has no active device
// — nothing is playing anywhere — so the track cannot start until the Spotify app is open, and
// opening another app requires OUR app to be frontmost. Backgrounded (which a glasses call always
// is), `phone.spotify_play` therefore answers `ok:true, deferred:true` with «Включу, как только
// откроешь приложение», queues the uri, and sends `aurelia.client_tool.applied` when it lands —
// exactly like the queued clipboard write.

import Foundation
import UIKit

// MARK: - Web API client

/// The five calls the tools need. Thin on purpose: no model layer, no caching, no SDK.
struct SpotifyClient {
    let connection: SpotifyConnection

    struct Track: Equatable {
        let uri: String
        let id: String
        let name: String
        let artist: String
        var spoken: String { "«\(name)» — \(artist)" }
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:],
                         body: [String: Any]? = nil) async throws -> (Data, Int) {
        let token = try await connection.accessToken()
        var comps = URLComponents(string: "https://api.spotify.com/v1\(path)")!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await connection.http.send(request)
    }

    /// The first track matching a free-text query.
    func search(_ query: String) async throws -> Track {
        let (data, status) = try await request("GET", "/search",
                                               query: ["q": query, "type": "track", "limit": "1"])
        guard status == 200 else { throw SpotifyError.http(status) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = ((json?["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        guard let first = items.first,
              let uri = first["uri"] as? String,
              let id = first["id"] as? String,
              let name = first["name"] as? String else {
            throw SpotifyError.noResults(query)
        }
        let artists = (first["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return Track(uri: uri, id: id, name: name, artist: artists.joined(separator: ", "))
    }

    /// Start playback of one uri on the active device. 404 = there is no device (see the deferred
    /// path in the tool).
    func play(uri: String) async throws {
        let (_, status) = try await request("PUT", "/me/player/play", body: ["uris": [uri]])
        try Self.check(status)
    }

    func like(trackID: String) async throws {
        let (_, status) = try await request("PUT", "/me/tracks", query: ["ids": trackID])
        try Self.check(status)
    }

    struct NowPlaying: Equatable {
        let track: String
        let artist: String
        let isPlaying: Bool
        let uri: String
        let id: String
    }

    func nowPlaying() async throws -> NowPlaying? {
        let (data, status) = try await request("GET", "/me/player/currently-playing")
        if status == 204 { return nil }                    // nothing is playing
        guard status == 200 else { throw SpotifyError.http(status) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let item = json["item"] as? [String: Any],
              let name = item["name"] as? String,
              let uri = item["uri"] as? String,
              let id = item["id"] as? String else { return nil }
        let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return NowPlaying(track: name, artist: artists.joined(separator: ", "),
                          isPlaying: (json["is_playing"] as? Bool) ?? false, uri: uri, id: id)
    }

    func pause() async throws { try Self.check(try await request("PUT", "/me/player/pause").1) }
    func resume() async throws { try Self.check(try await request("PUT", "/me/player/play").1) }
    func next() async throws { try Self.check(try await request("POST", "/me/player/next").1) }
    func volume(_ percent: Int) async throws {
        let clamped = min(100, max(0, percent))
        try Self.check(try await request("PUT", "/me/player/volume",
                                         query: ["volume_percent": "\(clamped)"]).1)
    }

    static func check(_ status: Int) throws {
        switch status {
        case 200, 202, 204: return
        case 404: throw SpotifyError.noActiveDevice       // NO_ACTIVE_DEVICE
        default: throw SpotifyError.http(status)
        }
    }
}

// MARK: - Deferred play (AUR-845: the effect that must wait for the foreground)

/// The same shape the clipboard's landing uses — one `aurelia.client_tool.applied` frame per queued
/// effect. `verifiedByReadback` is false here on purpose: a started playback is confirmed by
/// Spotify's own 204, not by reading anything back.
typealias DeferredEffectApplied = ClipboardApplied

/// Holds the uri that could not start because nothing was playing anywhere, and starts it when the
/// app is next in front (where `UIApplication.open` can actually launch Spotify). One slot: a newer
/// request replaces an older one — the wearer wants the last track he asked for.
@MainActor
final class PendingSpotifyPlay {
    static let shared = PendingSpotifyPlay()

    private(set) var uri: String?
    private(set) var spoken: String?
    private(set) var queuedAt: Date?
    private(set) var call: NativeToolCall?
    private(set) var lastApplied: DeferredEffectApplied?
    /// The realtime bridge sets this to send `aurelia.client_tool.applied`.
    var onApplied: ((DeferredEffectApplied) -> Void)?
    /// Seams.
    var appState: () -> AppForegroundState
    var openSpotifyApp: () async -> Void = {
        if let url = URL(string: "spotify://"), await UIApplication.shared.canOpenURL(url) {
            await UIApplication.shared.open(url)
        }
    }
    var play: (String) async throws -> Void = { uri in
        try await SpotifyClient(connection: SpotifyConnection.shared).play(uri: uri)
    }
    private var observers: [NSObjectProtocol] = []

    init(appState: (() -> AppForegroundState)? = nil) {
        self.appState = appState ?? { AppForegroundState.current() }
    }

    var isPending: Bool { uri != nil }

    func queue(uri: String, spoken: String, call: NativeToolCall?) {
        self.uri = uri
        self.spoken = spoken
        self.queuedAt = Date()
        self.call = call
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.applyPending(stage: "active") }
            })
        }
        ovLog("🎵 spotify play queued for the foreground (\(uri)\(call.map { ", call \($0.id)" } ?? ""))")
    }

    /// Open Spotify (so a device exists) and start the track. Reports the landing either way — the
    /// wearer must never be left with a promise that quietly failed.
    @discardableResult
    func applyPending(stage: String) async -> DeferredEffectApplied? {
        guard let uri else { return nil }
        await openSpotifyApp()
        // Spotify needs a moment to register as an active device after it comes up.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var ok = true
        do { try await play(uri) } catch {
            ok = false
            ovLog("🎵 spotify pending play failed: \(error.localizedDescription)")
        }
        let queuedMs = Int(Date().timeIntervalSince(queuedAt ?? Date()) * 1000)
        let event = DeferredEffectApplied(callId: call?.id,
                                          wireName: call?.wireName ?? "phone.spotify_play",
                                          ok: ok, verifiedByReadback: false, stage: stage,
                                          queuedMs: queuedMs, appState: appState(), chars: 0)
        self.uri = nil; self.spoken = nil; self.queuedAt = nil; self.call = nil
        lastApplied = event
        ovLog("🎵 spotify pending play \(ok ? "started" : "FAILED") after \(queuedMs) ms")
        onApplied?(event)
        return event
    }

    func clear() { uri = nil; spoken = nil; queuedAt = nil; call = nil }
}

// MARK: - Shared plumbing for the four tools

/// Everything a Spotify tool needs, behind seams so the tests never touch the network, the
/// Keychain or UIKit.
struct SpotifyToolContext {
    var connection: @MainActor () -> SpotifyConnection = { SpotifyConnection.shared }
    var client: @MainActor () -> SpotifyClient = { SpotifyClient(connection: SpotifyConnection.shared) }
    var appState: @MainActor () -> AppForegroundState = { AppForegroundState.current() }
    var pending: @MainActor () -> PendingSpotifyPlay = { PendingSpotifyPlay.shared }
    var lastShazam: @MainActor () -> ShazamMatch? = { ShazamLastMatch.shared.last }

    /// The gate every tool goes through first. Throws the typed not-linked error, which the bridge
    /// turns into `not_linked:spotify` and the push-to-ask path speaks as the Russian sentence.
    @MainActor
    func requireLink() throws {
        guard SpotifyConfig.isConfigured, connection().isLinked else {
            throw NativeToolError.notLinked(service: "spotify")
        }
    }
}

/// Map a `SpotifyError` onto the tool error contract so every caller reacts by kind.
private func toolError(_ error: Error) -> NativeToolError {
    guard let s = error as? SpotifyError else {
        return .failed(code: "spotify_failed", spoken: "Spotify не ответил. Попробуем ещё раз?")
    }
    switch s {
    case .notConfigured, .notLinked: return .notLinked(service: "spotify")
    default: return .failed(code: s.wireCode, spoken: s.errorDescription ?? "Spotify не ответил.")
    }
}

// MARK: - phone.spotify_play

struct SpotifyPlayTool: NativeTool {
    let name = "spotify_play"
    let description = "Play a track in Spotify. Give either a free-text `query` (artist + title) or "
        + "a Spotify `uri`. With neither, plays the track Shazam just recognised."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Artist and title to search for"],
            "uri": ["type": "string", "description": "A spotify:track:… uri, when known"]
        ],
        "required": [] as [String]
    ]

    var ctx = SpotifyToolContext()

    func execute(args: [String: Any]) async throws -> String {
        try await execute(args: args, call: nil).text
    }

    func execute(args: [String: Any], call: NativeToolCall?) async throws -> NativeToolReply {
        try await MainActor.run { try ctx.requireLink() }
        let client = await MainActor.run { ctx.client() }

        var uri = (args["uri"] as? String)?.trimmingCharacters(in: .whitespaces)
        var spoken: String
        if let uri, !uri.isEmpty {
            spoken = "Включаю."
        } else {
            var query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if query.isEmpty {
                // «включи её» right after a Shazam match.
                guard let last = await MainActor.run(resultType: ShazamMatch?.self, body: { ctx.lastShazam() }) else {
                    throw NativeToolError.failed(code: "spotify_no_query",
                                                 spoken: "Что включить? Назови трек или исполнителя.")
                }
                query = last.searchQuery
            }
            do {
                let track = try await client.search(query)
                uri = track.uri
                spoken = "Включаю \(track.spoken)."
            } catch { throw toolError(error) }
        }
        guard let uri else { throw toolError(SpotifyError.noResults("")) }

        do {
            try await client.play(uri: uri)
            return NativeToolReply(text: spoken)
        } catch SpotifyError.noActiveDevice {
            // AUR-845: nothing is playing anywhere, and launching Spotify needs OUR app in front.
            let state = await MainActor.run { ctx.appState() }
            let pending = await MainActor.run { ctx.pending() }
            await pending.queue(uri: uri, spoken: spoken, call: call)
            if state == .active {
                // We are in front already: open Spotify and start it right now, no promise needed.
                _ = await pending.applyPending(stage: "manual")
                return NativeToolReply(text: spoken)
            }
            return NativeToolReply(text: "Включу, как только откроешь приложение: \(spoken)",
                                   deferred: true)
        } catch { throw toolError(error) }
    }
}

// MARK: - phone.spotify_like

struct SpotifyLikeTool: NativeTool {
    let name = "spotify_like"
    let description = "Save (like) a track in Spotify. With no `uri`, likes whatever is playing now."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": ["uri": ["type": "string", "description": "A spotify:track:… uri; omit for the current track"]],
        "required": [] as [String]
    ]

    var ctx = SpotifyToolContext()

    func execute(args: [String: Any]) async throws -> String {
        try await MainActor.run { try ctx.requireLink() }
        let client = await MainActor.run { ctx.client() }
        do {
            if let uri = (args["uri"] as? String)?.trimmingCharacters(in: .whitespaces), !uri.isEmpty {
                try await client.like(trackID: Self.trackID(from: uri))
                return "Лайкнула."
            }
            guard let now = try await client.nowPlaying() else {
                throw NativeToolError.failed(code: "spotify_nothing_playing",
                                             spoken: "Сейчас ничего не играет — нечего лайкать.")
            }
            try await client.like(trackID: now.id)
            return "Лайкнула \(now.track) — \(now.artist)."
        } catch let e as NativeToolError {
            throw e
        } catch { throw toolError(error) }
    }

    /// `spotify:track:<id>` → `<id>`; anything else is passed through (the API rejects nonsense).
    static func trackID(from uri: String) -> String {
        uri.split(separator: ":").last.map(String.init) ?? uri
    }
}

// MARK: - phone.spotify_now_playing

struct SpotifyNowPlayingTool: NativeTool {
    let name = "spotify_now_playing"
    let description = "What is playing in Spotify right now (title, artist, playing or paused)."
    let parametersSchema: [String: Any] = [
        "type": "object", "properties": [:] as [String: Any], "required": [] as [String]
    ]

    var ctx = SpotifyToolContext()

    func execute(args: [String: Any]) async throws -> String {
        try await MainActor.run { try ctx.requireLink() }
        do {
            guard let now = try await MainActor.run(resultType: SpotifyClient.self, body: { ctx.client() })
                .nowPlaying() else {
                return "Сейчас в Spotify ничего не играет."
            }
            return "\(now.isPlaying ? "Играет" : "На паузе"): «\(now.track)» — \(now.artist)."
        } catch { throw toolError(error) }
    }
}

// MARK: - phone.spotify_control

struct SpotifyControlTool: NativeTool {
    let name = "spotify_control"
    let description = "Control Spotify playback: pause, resume, next track, or set the volume."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["pause", "resume", "next", "volume"],
                       "description": "What to do"],
            "volume": ["type": "integer", "description": "0-100, only with action=volume"]
        ],
        "required": ["action"]
    ]

    var ctx = SpotifyToolContext()

    func execute(args: [String: Any]) async throws -> String {
        try await MainActor.run { try ctx.requireLink() }
        let client = await MainActor.run { ctx.client() }
        let action = ((args["action"] as? String) ?? "").lowercased()
        do {
            switch action {
            case "pause": try await client.pause(); return "Поставила на паузу."
            case "resume", "play": try await client.resume(); return "Продолжаю."
            case "next", "skip": try await client.next(); return "Следующий трек."
            case "volume":
                guard let v = NativeToolSupport.int(args["volume"]) else {
                    throw NativeToolError.failed(code: "spotify_no_volume",
                                                 spoken: "Насколько громко? Скажи число от 0 до 100.")
                }
                try await client.volume(v)
                return "Громкость \(min(100, max(0, v)))%."
            default:
                throw NativeToolError.failed(code: "spotify_unknown_action",
                                             spoken: "Не поняла команду для Spotify.")
            }
        } catch let e as NativeToolError {
            throw e
        } catch { throw toolError(error) }
    }
}
