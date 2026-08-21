import XCTest
@testable import OpenVision

/// AUR-793: Shazam → Spotify.
///
/// The Shazam half needs no account and is exercised end to end here behind a listener seam (the
/// real one is `SHManagedSession`, which needs a device and real music). The Spotify half has no
/// developer app yet, so the tests pin BOTH sides of that: the honest `not_linked:spotify` answer
/// while unlinked (the state Anton's phone is in tonight), and the real behaviour once a client id
/// exists — search → play, like, now-playing, control, and the AUR-845 deferred play when Spotify
/// has no active device and our app is not in front to launch it.
@MainActor
final class ShazamSpotifyToolsTests: XCTestCase {

    // MARK: - Fakes

    final class FakeListener: ShazamListening, @unchecked Sendable {
        var outcome: ShazamOutcome
        var listenedSeconds: Double?
        init(_ outcome: ShazamOutcome) { self.outcome = outcome }
        func listen(seconds: Double) async -> ShazamOutcome {
            listenedSeconds = seconds
            return outcome
        }
    }

    /// Canned HTTP: matches on "METHOD path" prefix, in order of registration.
    final class FakeHTTP: SpotifyHTTP, @unchecked Sendable {
        struct Reply { let status: Int; let json: Any }
        var replies: [String: Reply] = [:]
        private(set) var calls: [String] = []
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            let method = request.httpMethod ?? "GET"
            let path = (request.url?.path ?? "")
            let key = "\(method) \(path)"
            calls.append("\(key)?\(request.url?.query ?? "")")
            guard let reply = replies[key] else { return (Data(), 500) }
            let data = (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data()
            return (data, reply.status)
        }
    }

    private let match = ShazamMatch(title: "Bohemian Rhapsody", artist: "Queen",
                                    appleMusicID: "1440806041",
                                    artworkURL: "https://is1.example/art.jpg", isrc: "GBUM71029604")

    /// Spin the main queue until `cond` or the timeout (the bridge answers from a Task).
    private func waitUntil(timeout: TimeInterval = 5, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    override func tearDown() {
        SpotifyConfig.overrideClientID = nil
        ShazamLastMatch.shared.clear()
        PendingSpotifyPlay.shared.clear()
        super.tearDown()
    }

    private func linkedConnection(_ http: FakeHTTP) -> SpotifyConnection {
        SpotifyConfig.overrideClientID = "test-client-id"
        let c = SpotifyConnection(tokens: SpotifyTokens(accessToken: "at", refreshToken: "rt",
                                                        expiresAt: Date().addingTimeInterval(3600)))
        c.http = http
        return c
    }

    private func linkedContext(_ http: FakeHTTP, appState: AppForegroundState = .active,
                               pending: PendingSpotifyPlay? = nil) -> SpotifyToolContext {
        let connection = linkedConnection(http)
        var ctx = SpotifyToolContext()
        ctx.connection = { connection }
        ctx.client = { SpotifyClient(connection: connection) }
        ctx.appState = { appState }
        if let pending { ctx.pending = { pending } }
        return ctx
    }

    // MARK: - Shazam: the listen window

    func testSecondsAreClampedToSixTwelveWithEightAsTheDefault() {
        XCTAssertEqual(ShazamTool.seconds(from: [:]), 8)
        XCTAssertEqual(ShazamTool.seconds(from: ["seconds": 2]), 6)
        XCTAssertEqual(ShazamTool.seconds(from: ["seconds": 30]), 12)
        XCTAssertEqual(ShazamTool.seconds(from: ["seconds": "10"]), 10)
    }

    /// The manifest must give the listen room — the 8-s default would cut it off mid-listen.
    func testShazamGetsALongerTimeoutOnTheWire() {
        let bridge = ClientToolBridge(tools: NativeToolRegistry.shared.allTools,
                                      connectionsProvider: { PhoneConnections() },
                                      pendingClipboard: PendingClipboard(notifier: ClipboardToolTests.FakeNotifier(),
                                                                         appState: { .active }))
        let tools = (bridge.manifest(connections: PhoneConnections())["tools"] as? [[String: Any]]) ?? []
        let shazam = tools.first { $0["name"] as? String == "phone.shazam" }
        XCTAssertEqual(shazam?["timeoutMs"] as? Int, 20000)
        XCTAssertEqual(bridge.permissionKind(for: "phone.shazam"), "microphone")
        for name in ["phone.spotify_play", "phone.spotify_like", "phone.spotify_now_playing",
                     "phone.spotify_control"] {
            XCTAssertTrue(bridge.toolNames.contains(name), "\(name) must be advertised")
        }
    }

    // MARK: - Shazam: results

    func testMatchIsSpokenWithIdsAndRemembered() async throws {
        var fired = false
        let listener = FakeListener(.match(match, mic: "phone"))
        let tool = ShazamTool(listener: listener, earcon: { fired = true })
        let out = try await tool.execute(args: ["seconds": 9])
        XCTAssertTrue(fired, "the START earcon must fire before the listen")
        XCTAssertEqual(listener.listenedSeconds, 9)
        XCTAssertTrue(out.contains("«Bohemian Rhapsody» — Queen"), out)
        XCTAssertTrue(out.contains("appleMusicID 1440806041"), out)
        XCTAssertTrue(out.contains("mic: phone"), out)
        // «включи её» needs an antecedent.
        XCTAssertEqual(ShazamLastMatch.shared.last?.title, "Bohemian Rhapsody")
        XCTAssertEqual(ShazamLastMatch.shared.last?.searchQuery, "Queen Bohemian Rhapsody")
    }

    /// A no-match is never `ok:true` — and it names the mic, because the glasses mic is narrowband
    /// and physically cannot match music.
    func testNoMatchFailsAndTheGlassesMicSaysWhy() async {
        for (mic, mustContain) in [("phone", "ближе к звуку"), ("glasses", "микрофон очков")] {
            let tool = ShazamTool(listener: FakeListener(.noMatch(mic: mic)), earcon: {})
            do {
                _ = try await tool.execute(args: [:])
                XCTFail("a no-match must not succeed")
            } catch let e as NativeToolError {
                XCTAssertEqual(e.wireCode, "no_match")
                XCTAssertTrue((e.errorDescription ?? "").contains(mustContain), e.errorDescription ?? "")
            } catch { XCTFail("wrong error: \(error)") }
        }
    }

    func testShazamKitErrorsKeepTheirCode() async {
        let tool = ShazamTool(listener: FakeListener(.failed(code: "shazam_failed:202",
                                                             spoken: "Не смогла спросить Shazam (202).")),
                              earcon: {})
        do {
            _ = try await tool.execute(args: [:])
            XCTFail("must throw")
        } catch let e as NativeToolError {
            XCTAssertEqual(e.wireCode, "shazam_failed:202")
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: - Spotify: the state Anton's phone is in tonight (no developer app)

    func testEverySpotifyToolIsHonestlyNotLinkedWithoutAClientID() async {
        SpotifyConfig.overrideClientID = nil
        XCTAssertFalse(SpotifyConfig.isConfigured)
        XCTAssertEqual(SpotifyConfig.redirectURI, "openvision://spotify")

        let tools: [NativeTool] = [SpotifyPlayTool(), SpotifyLikeTool(),
                                   SpotifyNowPlayingTool(), SpotifyControlTool()]
        for tool in tools {
            do {
                _ = try await tool.execute(args: ["query": "queen", "action": "pause"])
                XCTFail("\(tool.name) must not pretend to work")
            } catch let e as NativeToolError {
                XCTAssertEqual(e.wireCode, "not_linked:spotify", tool.name)
                XCTAssertEqual(e.errorDescription,
                               "Spotify не подключён — открой Connections в настройках и подключи.")
            } catch { XCTFail("\(tool.name): wrong error \(error)") }
        }
    }

    /// End to end over the realtime bridge — what the brain actually sees tonight.
    func testBridgeAnswersNotLinkedForASpotifyCall() async throws {
        SpotifyConfig.overrideClientID = nil
        var sent: [[String: Any]] = []
        let bridge = ClientToolBridge(tools: NativeToolRegistry.shared.allTools,
                                      connectionsProvider: { PhoneConnections() },
                                      pendingClipboard: PendingClipboard(notifier: ClipboardToolTests.FakeNotifier(),
                                                                         appState: { .active }))
        bridge.disabledToolsProvider = { [] }
        bridge.send = { sent.append($0) }
        bridge.appStateProvider = { .active }
        bridge.sessionDidConnect()
        bridge.handleToolCall(["type": "aurelia.tool_call", "id": "s1", "name": "phone.spotify_play",
                               "args": ["query": "queen bohemian rhapsody"]])
        try await waitUntil { sent.contains { ($0["type"] as? String) == "aurelia.tool_result" } }
        let result = try XCTUnwrap(sent.first { ($0["type"] as? String) == "aurelia.tool_result" })
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "not_linked:spotify")
        bridge.sessionDidDisconnect()
    }

    func testConnectionsRowNamesTheMissingClientID() {
        SpotifyConfig.overrideClientID = nil
        let blocker = SpotifyConnection(tokens: nil).blocker
        XCTAssertNotNil(blocker)
        XCTAssertTrue(blocker!.contains("developer.spotify.com"), blocker!)
        XCTAssertTrue(blocker!.contains("openvision://spotify"), blocker!)
        XCTAssertEqual(SpotifyConnection(tokens: nil).wireState, "unlinked")
        XCTAssertEqual(SpotifyConnection(tokens: SpotifyTokens(accessToken: "a", refreshToken: "r",
                                                               expiresAt: .distantFuture)).wireState,
                       "linked")
    }

    // MARK: - Spotify: the linked behaviour (what turns on the day the id exists)

    func testPlaySearchesThenPlays() async throws {
        let http = FakeHTTP()
        http.replies["GET /v1/search"] = .init(status: 200, json: [
            "tracks": ["items": [["uri": "spotify:track:1", "id": "1", "name": "Bohemian Rhapsody",
                                  "artists": [["name": "Queen"]]]]]
        ])
        http.replies["PUT /v1/me/player/play"] = .init(status: 204, json: [:])
        var tool = SpotifyPlayTool()
        tool.ctx = linkedContext(http)
        let out = try await tool.execute(args: ["query": "queen bohemian"])
        XCTAssertEqual(out, "Включаю «Bohemian Rhapsody» — Queen.")
    }

    /// «Шазам… а теперь включи её» — no query at all, the last match is the antecedent.
    func testPlayWithNoArgsUsesTheLastShazamMatch() async throws {
        ShazamLastMatch.shared.set(match)
        let http = FakeHTTP()
        http.replies["GET /v1/search"] = .init(status: 200, json: [
            "tracks": ["items": [["uri": "spotify:track:9", "id": "9", "name": "Bohemian Rhapsody",
                                  "artists": [["name": "Queen"]]]]]
        ])
        http.replies["PUT /v1/me/player/play"] = .init(status: 204, json: [:])
        var tool = SpotifyPlayTool()
        tool.ctx = linkedContext(http)
        _ = try await tool.execute(args: [:])
        XCTAssertTrue(http.calls.contains { $0.contains("Queen") && $0.contains("Rhapsody") },
                      "the search must use the Shazam match: \(http.calls)")
    }

    /// AUR-845 in its Spotify shape: nothing is playing anywhere and we are NOT in front, so the
    /// track cannot start — say so honestly, queue it, and report the landing later.
    func testNoActiveDeviceInTheBackgroundIsDeferredAndThenApplied() async throws {
        let http = FakeHTTP()
        http.replies["GET /v1/search"] = .init(status: 200, json: [
            "tracks": ["items": [["uri": "spotify:track:7", "id": "7", "name": "Skyline",
                                  "artists": [["name": "Nu"]]]]]
        ])
        http.replies["PUT /v1/me/player/play"] = .init(status: 404, json: [:])   // NO_ACTIVE_DEVICE

        let pending = PendingSpotifyPlay(appState: { .active })
        var opened = false
        var played: String?
        pending.openSpotifyApp = { opened = true }
        pending.play = { uri in played = uri }
        var applied: DeferredEffectApplied?
        pending.onApplied = { applied = $0 }

        var tool = SpotifyPlayTool()
        tool.ctx = linkedContext(http, appState: .background, pending: pending)
        let reply = try await tool.execute(args: ["query": "skyline"],
                                           call: NativeToolCall(id: "p1", wireName: "phone.spotify_play"))
        XCTAssertTrue(reply.deferred, "a play that cannot start yet must not claim it started")
        XCTAssertTrue(reply.text.hasPrefix("Включу, как только откроешь приложение"), reply.text)
        XCTAssertTrue(pending.isPending)
        XCTAssertEqual(pending.uri, "spotify:track:7")

        _ = await pending.applyPending(stage: "active")
        XCTAssertTrue(opened, "the pending play must launch Spotify from the foreground")
        XCTAssertEqual(played, "spotify:track:7")
        let event = try XCTUnwrap(applied)
        XCTAssertEqual(event.callId, "p1")
        XCTAssertEqual(event.wireName, "phone.spotify_play")
        XCTAssertTrue(event.ok)
        XCTAssertFalse(event.verifiedByReadback, "a playback start is confirmed by Spotify's 204, not a read-back")
        // The frame the server half is coded against is the same 8-key shape as the clipboard's.
        let payload = ClientToolBridge.appliedPayload(event)
        XCTAssertEqual(payload["type"] as? String, "aurelia.client_tool.applied")
        XCTAssertEqual(payload.count, 9)   // 8 + the id
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        XCTAssertFalse(pending.isPending)
    }

    func testLikeUsesTheCurrentTrackWhenNoUriIsGiven() async throws {
        let http = FakeHTTP()
        http.replies["GET /v1/me/player/currently-playing"] = .init(status: 200, json: [
            "is_playing": true,
            "item": ["uri": "spotify:track:5", "id": "5", "name": "Skyline", "artists": [["name": "Nu"]]]
        ])
        http.replies["PUT /v1/me/tracks"] = .init(status: 200, json: [:])
        var like = SpotifyLikeTool()
        like.ctx = linkedContext(http)
        let out = try await like.execute(args: [:])
        XCTAssertEqual(out, "Лайкнула Skyline — Nu.")
        XCTAssertTrue(http.calls.contains { $0.hasPrefix("PUT /v1/me/tracks?ids=5") }, "\(http.calls)")
    }

    func testLikeParsesTheTrackIDOutOfAUri() {
        XCTAssertEqual(SpotifyLikeTool.trackID(from: "spotify:track:abc123"), "abc123")
        XCTAssertEqual(SpotifyLikeTool.trackID(from: "abc123"), "abc123")
    }

    func testNowPlayingTellsPlayingFromPausedAndSilence() async throws {
        let http = FakeHTTP()
        var tool = SpotifyNowPlayingTool()
        tool.ctx = linkedContext(http)

        http.replies["GET /v1/me/player/currently-playing"] = .init(status: 204, json: [:])
        let silent = try await tool.execute(args: [:])
        XCTAssertEqual(silent, "Сейчас в Spotify ничего не играет.")

        http.replies["GET /v1/me/player/currently-playing"] = .init(status: 200, json: [
            "is_playing": false,
            "item": ["uri": "spotify:track:5", "id": "5", "name": "Skyline", "artists": [["name": "Nu"]]]
        ])
        let paused = try await tool.execute(args: [:])
        XCTAssertEqual(paused, "На паузе: «Skyline» — Nu.")
    }

    func testControlMapsEveryAction() async throws {
        let http = FakeHTTP()
        http.replies["PUT /v1/me/player/pause"] = .init(status: 204, json: [:])
        http.replies["PUT /v1/me/player/play"] = .init(status: 204, json: [:])
        http.replies["POST /v1/me/player/next"] = .init(status: 204, json: [:])
        http.replies["PUT /v1/me/player/volume"] = .init(status: 204, json: [:])
        var tool = SpotifyControlTool()
        tool.ctx = linkedContext(http)

        for (action, expected) in [("pause", "Поставила на паузу."), ("resume", "Продолжаю."),
                                   ("next", "Следующий трек.")] {
            let out = try await tool.execute(args: ["action": action])
            XCTAssertEqual(out, expected)
        }
        let volume = try await tool.execute(args: ["action": "volume", "volume": 140])
        XCTAssertEqual(volume, "Громкость 100%.")
        XCTAssertTrue(http.calls.contains { $0.contains("volume_percent=100") }, "\(http.calls)")

        // A volume with no number asks instead of guessing.
        do {
            _ = try await tool.execute(args: ["action": "volume"])
            XCTFail("must ask for the level")
        } catch let e as NativeToolError {
            XCTAssertEqual(e.wireCode, "spotify_no_volume")
        }
    }

    func testHttpStatusMapping() {
        XCTAssertNoThrow(try SpotifyClient.check(204))
        XCTAssertThrowsError(try SpotifyClient.check(404)) {
            XCTAssertEqual($0 as? SpotifyError, .noActiveDevice)
        }
        XCTAssertThrowsError(try SpotifyClient.check(502)) {
            XCTAssertEqual($0 as? SpotifyError, .http(502))
        }
        XCTAssertEqual(SpotifyError.noActiveDevice.wireCode, "spotify_no_active_device")
    }

    /// A revoked refresh token must land the app back in the honest "unlinked" state, not in a
    /// permanent HTTP error.
    func testRevokedRefreshTokenUnlinks() async {
        SpotifyConfig.overrideClientID = "test-client-id"
        let http = FakeHTTP()
        http.replies["POST /api/token"] = .init(status: 400, json: ["error": "invalid_grant"])
        let connection = SpotifyConnection(tokens: SpotifyTokens(accessToken: "old", refreshToken: "rt",
                                                                 expiresAt: Date().addingTimeInterval(-10)))
        connection.http = http
        do {
            _ = try await connection.accessToken()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? SpotifyError, .notLinked)
        }
        XCTAssertFalse(connection.isLinked)
        XCTAssertEqual(connection.wireState, "unlinked")
    }

    // MARK: - PKCE

    /// RFC 7636 appendix B test vector — if this ever drifts, no Spotify login will ever succeed.
    func testCodeChallengeMatchesTheRFCVector() {
        XCTAssertEqual(SpotifyConnection.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testCodeVerifierIsLongAndUnreserved() {
        let v = SpotifyConnection.codeVerifier()
        XCTAssertEqual(v.count, 64)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(v.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertNotEqual(v, SpotifyConnection.codeVerifier())
    }

    func testScopesCoverEverythingTheToolsDo() {
        XCTAssertEqual(Set(SpotifyConfig.scopes), [
            "user-read-playback-state", "user-modify-playback-state",
            "user-read-currently-playing", "user-library-modify", "user-library-read"
        ])
    }
}
