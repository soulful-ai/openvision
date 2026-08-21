// OpenVision - SpotifyConnection.swift
// AUR-793b: the Spotify half — OAuth (PKCE, no client secret on the device), a small Web API
// client, and the link state the Connections row (AUR-795) flips.
//
// THE HUMAN STEP THIS WAITS ON. There is no Spotify developer app yet, so there is no client id.
// Nothing here can be exercised until Anton creates one (5 minutes, developer.spotify.com — the
// exact steps are in the commit message and in docs/native-tools.md). Until then:
//   • `SpotifyConfig.isConfigured` is false, `SpotifyConnection.wireState` is "unlinked",
//   • the Connections row offers "Connect" and says what is missing,
//   • and every `phone.spotify_*` tool answers `not_linked:spotify` with the honest sentence
//     «Spotify не подключён — открой Connections в настройках и подключи». Never a fake `ok`.
// The moment the id is in Config.xcconfig, the same code links and works — no branch to flip.
//
// The client id is NOT a secret (a PKCE public client is designed to have it in the binary), but it
// is per-developer, so it lives in the gitignored `Config.xcconfig` → Info.plist, exactly like
// META_APP_ID / CLIENT_TOKEN. Tokens are secrets and live in the Keychain, never UserDefaults.
//
// Why the Web API and not the iOS SDK's App Remote: App Remote needs the Spotify app installed AND
// running, and it ships as a binary framework we would have to vendor. The Web API covers
// search / play / pause / next / volume / save-track over plain HTTPS, works while our app is
// backgrounded (a glasses call IS backgrounded), and needs nothing vendored. The one thing it
// cannot do is CREATE a playback device: if Spotify is not open anywhere, `PUT /me/player/play`
// answers 404 NO_ACTIVE_DEVICE — and opening the Spotify app requires our app to be frontmost.
// That is exactly the AUR-845 deferred-effect case, so it is handled as one (`PendingSpotifyPlay`).

import Foundation
import CryptoKit
import UIKit
import AuthenticationServices

// MARK: - Config

enum SpotifyConfig {
    /// From `SPOTIFY_CLIENT_ID` in Config.xcconfig → Info.plist. Empty until the developer app
    /// exists; nothing here pretends otherwise.
    static var clientID: String {
        if let overrideClientID { return overrideClientID }
        return (Bundle.main.infoDictionary?["SpotifyClientID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Test seam ONLY: pretend a client id exists so the linked paths can be exercised without a
    /// developer app. Never set from app code.
    static var overrideClientID: String?

    /// The app's own URL scheme + a fixed path. MUST be entered verbatim in the Spotify dashboard.
    static var redirectURI: String {
        let scheme = (Bundle.main.infoDictionary?["AppLinkURLScheme"] as? String) ?? "openvision"
        return "\(scheme)://spotify"
    }

    /// The least that covers play / pause / next / volume / now-playing / like.
    static let scopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "user-library-modify",
        "user-library-read"
    ]

    static var isConfigured: Bool { !clientID.isEmpty }
}

// MARK: - Tokens (Keychain — never UserDefaults)

struct SpotifyTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isFresh: Bool { expiresAt.timeIntervalSinceNow > 60 }
}

/// One generic-password item. Small on purpose: two calls and a delete.
enum SpotifyTokenStore {
    static let service = "app.soulless.openvision.spotify"
    static let account = "tokens"

    static func save(_ tokens: SpotifyTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> SpotifyTokens? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifyTokens.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum SpotifyError: LocalizedError, Equatable {
    /// No developer app / client id on this build — the human step above.
    case notConfigured
    /// Configured, but this phone has not linked an account.
    case notLinked
    /// Linked, but Spotify is not playing anywhere: there is no device to send the command to.
    case noActiveDevice
    case noResults(String)
    case http(Int)
    case cancelled

    var wireCode: String {
        switch self {
        case .notConfigured, .notLinked: return "not_linked:spotify"
        case .noActiveDevice: return "spotify_no_active_device"
        case .noResults: return "spotify_no_results"
        case .http(let code): return "spotify_http_\(code)"
        case .cancelled: return "spotify_cancelled"
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured, .notLinked:
            return "Spotify не подключён — открой Connections в настройках и подключи."
        case .noActiveDevice:
            return "Spotify нигде не играет — открой приложение Spotify, и я включу."
        case .noResults(let q):
            return "Не нашла в Spotify: \(q)."
        case .http(let code):
            return "Spotify ответил ошибкой \(code)."
        case .cancelled:
            return "Подключение к Spotify отменено."
        }
    }
}

// MARK: - Connection (link state + tokens + the OAuth dance)

@MainActor
final class SpotifyConnection: ObservableObject {
    static let shared = SpotifyConnection()

    @Published private(set) var tokens: SpotifyTokens?

    /// Seam: how the authorization page is presented (tests never open a browser).
    var authorize: (URL, String) async throws -> URL = { url, scheme in
        try await WebAuth.run(url: url, callbackScheme: scheme)
    }
    /// Seam: the HTTP transport (tests inject canned responses).
    var http: SpotifyHTTP = URLSessionSpotifyHTTP()

    init(tokens: SpotifyTokens? = nil) {
        self.tokens = tokens ?? SpotifyTokenStore.load()
    }

    var isLinked: Bool { tokens != nil }

    /// What `aurelia.client_tools.connections["spotify"]` carries.
    var wireState: String { isLinked ? "linked" : "unlinked" }

    /// Why the Connections row cannot link yet, or nil when it can.
    var blocker: String? {
        SpotifyConfig.isConfigured ? nil
            : "Spotify client id не настроен: developer.spotify.com → Create app → "
              + "Redirect URI \(SpotifyConfig.redirectURI) → id в Config.xcconfig (SPOTIFY_CLIENT_ID)."
    }

    // MARK: Link / unlink

    /// The full PKCE dance. Needs the app to be frontmost (ASWebAuthenticationSession draws a
    /// browser sheet) — which is why linking is a Connections-screen action and never something a
    /// tool call tries to do mid-conversation.
    func connect() async throws {
        guard SpotifyConfig.isConfigured else { throw SpotifyError.notConfigured }
        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = UUID().uuidString

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: SpotifyConfig.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: SpotifyConfig.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: SpotifyConfig.scopes.joined(separator: " ")),
            .init(name: "state", value: state)
        ]
        let scheme = URL(string: SpotifyConfig.redirectURI)?.scheme ?? "openvision"
        let callback = try await authorize(comps.url!, scheme)

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw SpotifyError.cancelled
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw SpotifyError.cancelled
        }
        let tokens = try await exchange(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.redirectURI,
            "client_id": SpotifyConfig.clientID,
            "code_verifier": verifier
        ])
        set(tokens)
        ovLog("🎵 spotify linked (scopes: \(SpotifyConfig.scopes.count))")
    }

    func disconnect() {
        tokens = nil
        SpotifyTokenStore.clear()
        ovLog("🎵 spotify unlinked")
    }

    func set(_ tokens: SpotifyTokens) {
        self.tokens = tokens
        SpotifyTokenStore.save(tokens)
    }

    /// A usable access token, refreshed if it is about to expire. Throws the honest not-linked
    /// error rather than silently doing nothing.
    func accessToken() async throws -> String {
        guard SpotifyConfig.isConfigured else { throw SpotifyError.notConfigured }
        guard let current = tokens else { throw SpotifyError.notLinked }
        if current.isFresh { return current.accessToken }
        let refreshed = try await exchange(form: [
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": SpotifyConfig.clientID
        ], fallbackRefresh: current.refreshToken)
        set(refreshed)
        return refreshed.accessToken
    }

    private func exchange(form: [String: String], fallbackRefresh: String? = nil) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)
        let (data, status) = try await http.send(request)
        guard status == 200 else {
            // A refresh token can be revoked from the Spotify account page — then the honest state
            // is "unlinked", not "some HTTP error".
            if fallbackRefresh != nil, status == 400 || status == 401 { disconnect(); throw SpotifyError.notLinked }
            throw SpotifyError.http(status)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String else { throw SpotifyError.http(status) }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let refresh = (json["refresh_token"] as? String) ?? fallbackRefresh ?? ""
        return SpotifyTokens(accessToken: access, refreshToken: refresh,
                             expiresAt: Date().addingTimeInterval(expiresIn))
    }

    // MARK: PKCE

    static func codeVerifier() -> String {
        let allowed = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in allowed[Int.random(in: 0..<allowed.count)] })
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formBody(_ form: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }
}

// MARK: - HTTP seam

protocol SpotifyHTTP: Sendable {
    /// Returns the body and the status code. Network failures throw.
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionSpotifyHTTP: SpotifyHTTP {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - ASWebAuthenticationSession wrapper

/// The browser sheet, as an async call. Kept tiny and separate so `SpotifyConnection` stays testable.
@MainActor
enum WebAuth {
    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
    private static let anchor = Anchor()

    static func run(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback { c.resume(returning: callback) }
                else { c.resume(throwing: error ?? SpotifyError.cancelled) }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }
}
