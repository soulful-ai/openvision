import XCTest
import AVFoundation
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
        /// The form/JSON body per "METHOD path" — the PKCE exchange is only checkable from here.
        private(set) var bodies: [String: String] = [:]
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            let method = request.httpMethod ?? "GET"
            let path = (request.url?.path ?? "")
            let key = "\(method) \(path)"
            calls.append("\(key)?\(request.url?.query ?? "")")
            if let body = request.httpBody { bodies[key] = String(decoding: body, as: UTF8.self) }
            guard let reply = replies[key] else { return (Data(), 500) }
            let data = (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data()
            return (data, reply.status)
        }
    }

    /// A tool that survives the socket close and finishes only when released.
    final class SlowSurvivingTool: NativeTool, @unchecked Sendable {
        let name = "slow survivor"
        let description = "test"
        let parametersSchema: [String: Any] = ["type": "object", "properties": [:]]
        var survivesSessionClose: Bool { true }
        private let gate = AsyncGate()
        private(set) var started = false
        func release() { gate.open() }
        func execute(args: [String: Any]) async throws -> String {
            started = true
            await gate.wait()
            return "done"
        }
    }

    /// One-shot gate: `wait()` returns once `open()` has been called.
    final class AsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func open() {
            lock.lock(); opened = true; let w = waiters; waiters = []; lock.unlock()
            for c in w { c.resume() }
        }
        func wait() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened { lock.unlock(); cont.resume(); return }
                waiters.append(cont); lock.unlock()
            }
        }
    }

    /// A reference box for the authorize seam: the closure is escaping and non-isolated, so it
    /// cannot write to a captured `var`.
    final class Captured: @unchecked Sendable {
        var url: URL?
        var scheme: String?
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
        let listener = FakeListener(.match(match, .phone()))
        let tool = ShazamTool(listener: listener, earcon: { fired = true })
        let out = try await tool.execute(args: ["seconds": 9])
        XCTAssertTrue(fired, "the START earcon must fire before the listen")
        XCTAssertEqual(listener.listenedSeconds, 9)
        XCTAssertTrue(out.contains("«Bohemian Rhapsody» — Queen"), out)
        XCTAssertTrue(out.contains("appleMusicID 1440806041"), out)
        XCTAssertTrue(out.contains("mic: phone"), out)
        // AUR-793b: a MATCH is as diagnosable as a miss.
        XCTAssertTrue(out.contains("rate=48000"), out)
        XCTAssertTrue(out.contains("vp=off"), out)
        XCTAssertTrue(out.contains("mode=measurement"), out)
        // «включи её» needs an antecedent.
        XCTAssertEqual(ShazamLastMatch.shared.last?.title, "Bohemian Rhapsody")
        XCTAssertEqual(ShazamLastMatch.shared.last?.searchQuery, "Queen Bohemian Rhapsody")
    }

    /// A no-match is never `ok:true`, and AUR-793b: the code says WHY it could not have worked and
    /// the conditions that back the claim ride the same string.
    func testNoMatchNamesTheReasonAndCarriesTheConditions() async {
        let cases: [(MusicCaptureConditions, String, String)] = [
            (.phone(), "no_match", "ближе к звуку"),
            (.glasses(), "no_match:glasses_narrowband", "микрофон очков"),
            (.voiceProcessedPhone(), "no_match:voice_processed", "режиме разговора"),
            (.phone(peakDbfs: -80), "no_match:silence", "ничего не услышала"),
            (MusicCaptureConditions(mic: "phone", category: "playAndRecord", mode: "voiceChat",
                                    voiceProcessing: false, sampleRate: 8000, peakDbfs: -30,
                                    route: "hfp+phone-mic"), "no_match:narrowband", "узкую полосу"),
        ]
        for (conditions, code, mustSay) in cases {
            let tool = ShazamTool(listener: FakeListener(.noMatch(conditions)), earcon: {})
            do {
                _ = try await tool.execute(args: [:])
                XCTFail("a no-match must not succeed")
            } catch let e as NativeToolError {
                XCTAssertTrue(e.wireCode.hasPrefix(code), "\(e.wireCode) must start with \(code)")
                // The whole read-out rides the wire: no device console needed to explain a miss.
                XCTAssertTrue(e.wireCode.contains("mic=\(conditions.mic)"), e.wireCode)
                XCTAssertTrue(e.wireCode.contains("vp="), e.wireCode)
                XCTAssertTrue(e.wireCode.contains("rate="), e.wireCode)
                XCTAssertTrue(e.wireCode.contains("lvl="), e.wireCode)
                XCTAssertTrue(e.wireCode.contains("mode=\(conditions.mode)"), e.wireCode)
                XCTAssertLessThanOrEqual(e.wireCode.count, 118, "the server budget for `error` is 120 chars")
                XCTAssertTrue((e.errorDescription ?? "").contains(mustSay), e.errorDescription ?? "")
            } catch { XCTFail("wrong error: \(error)") }
        }
    }

    /// Precedence: silence beats every other explanation — a mic that heard nothing was never given
    /// a chance, whatever else was wrong with it.
    func testSilenceWinsOverTheOtherReasons() {
        var c = MusicCaptureConditions.glasses()
        c.voiceProcessing = true
        c.peakDbfs = -90
        XCTAssertEqual(c.noMatchCode, "no_match:silence")
        c.peakDbfs = -20
        XCTAssertEqual(c.noMatchCode, "no_match:glasses_narrowband")
        XCTAssertNil(MusicCaptureConditions.phone().noMatchReason,
                     "a clean music-capable capture has no excuse to offer")
    }

    func testShazamKitErrorsKeepTheirCode() async {
        let tool = ShazamTool(listener: FakeListener(.failed(code: "shazam_failed:202",
                                                             spoken: "Не смогла спросить Shazam (202).",
                                                             conditions: .phone())),
                              earcon: {})
        do {
            _ = try await tool.execute(args: [:])
            XCTFail("must throw")
        } catch let e as NativeToolError {
            XCTAssertTrue(e.wireCode.hasPrefix("shazam_failed:202"), e.wireCode)
            XCTAssertTrue(e.wireCode.contains("mic=phone"), e.wireCode)
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: - AUR-793c: a listen must never take the call down with it

    /// THE regression test. Field, 2026-08-21 12:27Z (rt_4) and 12:30Z (rt_5): both sessions
    /// `appState:"background"`, both `code:1006` the instant the window opened, both
    /// `error:"session_closed"` mid-listen, and the wearer heard nothing at all. Cause: the window
    /// stopped the call's shared engine (the only way to switch voice processing off), which ends
    /// the app's audio IO — and an app alive in the background on the `audio` background mode is
    /// suspended the moment its audio IO stops. So: with a live rig, the window must leave the
    /// engine RUNNING and the category untouched.
    func testMusicWindowNeverStopsALiveCallEngine() throws {
        let manager = AudioSessionManager.shared
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
        // A live rig, without needing a real microphone on the test host: the window's whole
        // decision hangs on this one probe.
        manager.liveRigProbe = { true }
        defer { manager.liveRigProbe = { AudioSessionManager.shared.sharedEngine?.isRunning == true } }
        let engine = try? manager.startSharedEngine(voiceProcessing: false)
        defer { manager.stopSharedEngine() }
        let categoryBefore = session.category, modeBefore = session.mode, optionsBefore = session.categoryOptions

        let window = manager.beginMusicWindow()
        XCTAssertEqual(window.style, .inCall, "a live rig means the listen takes what it can get")
        if let engine { XCTAssertTrue(engine.isRunning, "STOPPING THIS ENGINE SUSPENDS THE APP AND KILLS THE SOCKET") }
        XCTAssertEqual(session.category, categoryBefore, "no category change while a call is live")
        XCTAssertEqual(session.mode, modeBefore, "changing the mode drops the glasses' HFP output mid-sentence")
        XCTAssertEqual(session.categoryOptions, optionsBefore)
        XCTAssertFalse(window.enginePaused)

        manager.endMusicWindow(window)
        if let engine { XCTAssertTrue(engine.isRunning, "and it is still running afterwards — the call never noticed") }
        XCTAssertFalse(manager.musicWindowActive)
        XCTAssertEqual(session.category, categoryBefore)
        XCTAssertEqual(session.mode, modeBefore)
    }

    /// An in-call listen tells the truth about the capture it got: the call's voice processing owns
    /// the input hardware, so `vp=on` even though OUR node asked for it off.
    func testInCallConditionsReportTheCallsVoiceProcessing() {
        var c = AudioSessionManager.shared.musicCaptureConditions(sampleRate: 24_000,
                                                                  voiceProcessing: true,
                                                                  style: .inCall)
        c.peakDbfs = -30          // the level is filled in at the end of the listen
        XCTAssertEqual(c.noMatchCode, "no_match:voice_processed")
        XCTAssertTrue(c.wire.contains("w=inCall"), c.wire)
        XCTAssertTrue(c.wire.contains("vp=on"), c.wire)
    }

    /// A result the socket could not carry is banked and handed to the NEXT call — the work is not
    /// repeated and the failure string survives the drop.
    func testAnUndeliveredResultIsHandedToTheNextListen() async throws {
        ShazamLastMatch.shared.clear()
        let bridge = ClientToolBridge(tools: NativeToolRegistry.shared.allTools,
                                      connectionsProvider: { PhoneConnections() },
                                      pendingClipboard: PendingClipboard(notifier: ClipboardToolTests.FakeNotifier(),
                                                                         appState: { .active }))
        bridge.bankUndelivered("phone.shazam", .failure("no_match:voice_processed mic=phone vp=on"))
        // The next listen answers from the bank without touching the microphone at all.
        let listener = FakeListener(.noMatch(.phone()))
        let tool = ShazamTool(listener: listener, earcon: {}, earconStop: {})
        do {
            _ = try await tool.execute(args: [:])
            XCTFail("the banked failure must be re-thrown")
        } catch let e as NativeToolError {
            XCTAssertEqual(e.wireCode, "no_match:voice_processed mic=phone vp=on")
            XCTAssertNil(listener.listenedSeconds, "it must not listen again — the answer is already known")
        }
        // One delivery only: the slot is empty now.
        let tool2 = ShazamTool(listener: FakeListener(.match(match, .phone())), earcon: {}, earconStop: {})
        _ = try await tool2.execute(args: [:])
    }

    /// A banked answer goes stale — a different song may be playing by then.
    func testAStaleBankedAnswerIsNotDelivered() async throws {
        ShazamLastMatch.shared.clear()
        ShazamLastMatch.shared.bank(.init(result: "Shazam: «Old»", code: nil, spoken: nil,
                                          at: Date().addingTimeInterval(-ShazamLastMatch.undeliveredWindow - 5)))
        let listener = FakeListener(.match(match, .phone()))
        let out = try await ShazamTool(listener: listener, earcon: {}, earconStop: {}).execute(args: [:])
        XCTAssertTrue(out.contains("Bohemian Rhapsody"), out)
        XCTAssertNotNil(listener.listenedSeconds, "a stale bank means listen again")
    }

    /// Both cues fire — the wearer hears the listen start and stop even when the answer is slow.
    func testBothEarconsFire() async throws {
        ShazamLastMatch.shared.clear()
        var started = false, stopped = false
        let tool = ShazamTool(listener: FakeListener(.noMatch(.phone())),
                              earcon: { started = true }, earconStop: { stopped = true })
        _ = try? await tool.execute(args: [:])
        XCTAssertTrue(started, "he must hear that she started listening")
        XCTAssertTrue(stopped, "…and that she stopped — never an unexplained silence")
    }

    // MARK: - AUR-793b: the listen outlives the socket

    /// Field call 1 (2026-08-21 12:03Z): the socket died 6.2 s into an 8-s listen (WS 1006) and the
    /// listen was cancelled with it — the mic window already paid for, the match thrown away. Now
    /// `phone.shazam` runs to the end and banks its match; the other tools are still cancelled,
    /// because nobody can hear their answer.
    func testShazamSurvivesTheSocketCloseAndOthersDoNot() {
        XCTAssertTrue(ShazamTool().survivesSessionClose)
        for tool in NativeToolRegistry.shared.allTools where !(tool is ShazamTool) {
            XCTAssertFalse(tool.survivesSessionClose, "\(tool.name) must not outlive the socket")
        }
    }

    /// A slow tool that survives keeps its name RESERVED across the close — it still owns the mic,
    /// so a second listen in the next session is honestly `busy`, not a fight over the hardware.
    func testASurvivingCallKeepsItsNameBusyAcrossTheClose() async throws {
        let slow = SlowSurvivingTool()
        let bridge = ClientToolBridge(tools: [slow],
                                      connectionsProvider: { PhoneConnections() },
                                      pendingClipboard: PendingClipboard(notifier: ClipboardToolTests.FakeNotifier(),
                                                                         appState: { .active }))
        var sent: [[String: Any]] = []
        bridge.send = { sent.append($0) }
        bridge.sessionDidConnect()
        bridge.handleToolCall(["id": "tc_1", "name": "phone.slow_survivor", "args": [:], "timeoutMs": 20000])
        try await waitUntil { slow.started }

        bridge.sessionDidDisconnect()
        XCTAssertTrue(bridge.isBusy("phone.slow_survivor"), "the mic is still held — the name stays reserved")

        // A new session: the call is still running, so a second one is refused honestly.
        sent.removeAll()
        bridge.sessionDidConnect()
        bridge.handleToolCall(["id": "tc_2", "name": "phone.slow_survivor", "args": [:]])
        try await waitUntil { sent.contains { $0["id"] as? String == "tc_2" } }
        let refusal = sent.first { $0["id"] as? String == "tc_2" }
        XCTAssertEqual(refusal?["error"] as? String, "busy")

        // …and when it finishes, nothing is written for the dead call's id, but the name frees up.
        slow.release()
        try await waitUntil { !bridge.isBusy("phone.slow_survivor") }
        XCTAssertFalse(sent.contains { $0["id"] as? String == "tc_1" },
                       "the answer to a call whose socket died must not be posted to the next one")
        XCTAssertTrue(bridge.recentCalls.contains { $0.id == "tc_1" && $0.ok },
                      "it still lands in the Debug read-out")
    }

    // MARK: - AUR-793b: the music-capture window saves and restores the rig

    /// The window must leave the session EXACTLY as it found it — a `phone.shazam` that quietly
    /// changed the call's category or mode would break the conversation it interrupted.
    func testMusicWindowRestoresTheSessionItFound() throws {
        let session = AVAudioSession.sharedInstance()
        let manager = AudioSessionManager.shared
        // The rig the field failure ran on: a full-duplex call.
        let callOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers]
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: callOptions)
        // iOS adds `.mixWithOthers` of its own accord alongside `.duckOthers`, so the truth to
        // restore is what the session REPORTS, not what we asked for.
        let established = session.categoryOptions

        let window = manager.beginMusicWindow()
        XCTAssertTrue(manager.musicWindowActive)
        XCTAssertEqual(window.style, .exclusive)
        XCTAssertEqual(window.category, .playAndRecord)
        XCTAssertEqual(window.mode, .voiceChat, "the snapshot must remember the mode it displaced")
        XCTAssertEqual(window.options, established)

        // …and while it is open the capture is music-capable, not speech-shaped.
        XCTAssertEqual(session.mode, .measurement, "voiceChat is a speech isolator — the listen needs measurement")
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers),
                       "ducking the music is ducking the thing we are listening for")
        XCTAssertFalse(session.categoryOptions.contains(.allowBluetoothHFP),
                       "an HFP SCO link pins the input to 8/16 kHz — no fingerprint survives that")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))

        manager.endMusicWindow(window)
        XCTAssertFalse(manager.musicWindowActive)
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.mode, .voiceChat, "the call's mode must come back")
        XCTAssertEqual(session.categoryOptions, established, "the call's options must come back")
    }

    /// With no call up (push-to-ask, or the app just open) there is no engine to pause — the
    /// window still opens, still restores, and says the call was never paused.
    func testMusicWindowWithNoLiveCallPausesNothing() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        let manager = AudioSessionManager.shared
        XCTAssertNil(manager.sharedEngine, "this test assumes no realtime rig is up")

        let window = manager.beginMusicWindow()
        XCTAssertEqual(window.style, .exclusive, "no live rig — the session is ours to shape")
        XCTAssertFalse(window.callVoiceProcessing)
        manager.endMusicWindow(window)

        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .default)
    }

    /// The conditions read-out is built from the LISTEN's own tap, not from the session's wishes.
    func testConditionsReportTheTapNotThePreferredValues() {
        let c = AudioSessionManager.shared.musicCaptureConditions(sampleRate: 48_000,
                                                                  voiceProcessing: false,
                                                                  style: .exclusive)
        XCTAssertEqual(c.sampleRate, 48_000)
        XCTAssertFalse(c.voiceProcessing)
        XCTAssertEqual(c.style, "exclusive")
        XCTAssertTrue(c.wire.contains("w=exclusive"), c.wire)
        XCTAssertTrue(c.wire.contains("app="), c.wire)
        XCTAssertFalse(c.category.hasPrefix("AVAudioSessionCategory"), "the wire wants the short name: \(c.category)")
    }

    // MARK: - Spotify: the unconfigured state (no client id in the build)
    //
    // These three used to clear the override to `nil` and lean on an empty Info.plist. That was
    // only ever true while there was no Spotify developer app: the tests run HOSTED (TEST_HOST is
    // OpenVision.app), so `Bundle.main` is the app, and the moment SPOTIFY_CLIENT_ID landed in
    // Config.xcconfig the fallback started handing them a real id and the assertions inverted.
    // `""` is the honest way to say "this build has no client id" — it overrides the bundle
    // instead of deferring to it, so the not-linked contract stays testable forever.

    func testEverySpotifyToolIsHonestlyNotLinkedWithoutAClientID() async {
        SpotifyConfig.overrideClientID = ""
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
        SpotifyConfig.overrideClientID = ""
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
        SpotifyConfig.overrideClientID = ""
        let blocker = SpotifyConnection(tokens: nil).blocker
        XCTAssertNotNil(blocker)
        XCTAssertTrue(blocker!.contains("developer.spotify.com"), blocker!)
        XCTAssertTrue(blocker!.contains("openvision://spotify"), blocker!)
        XCTAssertEqual(SpotifyConnection(tokens: nil).wireState, "unlinked")
        XCTAssertEqual(SpotifyConnection(tokens: SpotifyTokens(accessToken: "a", refreshToken: "r",
                                                               expiresAt: .distantFuture)).wireState,
                       "linked")
    }

    // MARK: - Spotify: the real developer app (AUR-845b — the day the id exists IS today)

    /// The client id stopped being a human step: the Spotify app "OpenVision (Aurelia)" exists and
    /// `SPOTIFY_CLIENT_ID` rides Config.xcconfig → Info.plist into the build. No override, no seam —
    /// this reads exactly what the shipped binary reads. If someone builds from a fresh checkout
    /// without the id, this fails loudly instead of quietly shipping a dark feature.
    func testTheShippedBuildCarriesARealClientIDAndTheRegisteredRedirect() {
        SpotifyConfig.overrideClientID = nil            // read the real bundle, not a fake
        XCTAssertTrue(SpotifyConfig.isConfigured,
                      "SPOTIFY_CLIENT_ID missing — copy it into Config.xcconfig")
        let id = SpotifyConfig.clientID
        XCTAssertEqual(id.count, 32, "a Spotify client id is 32 hex chars, got \(id.count)")
        XCTAssertTrue(id.allSatisfy(\.isHexDigit), id)

        // The redirect must match the dashboard entry VERBATIM — one character off and Spotify
        // answers INVALID_CLIENT before the user ever sees a login form.
        XCTAssertEqual(SpotifyConfig.redirectURI, "openvision://spotify")

        // ...and the scheme has to be REGISTERED, or the callback has nowhere to come home to.
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains("openvision"), "openvision:// not registered: \(schemes)")

        // Spotify's own scheme must be queryable or canOpenURL lies and the deferred play gives up.
        let queried = Bundle.main.infoDictionary?["LSApplicationQueriesSchemes"] as? [String] ?? []
        XCTAssertTrue(queried.contains("spotify"), "spotify not in LSApplicationQueriesSchemes")

        // Nothing left to block the Connections row: the button is now a real Connect.
        XCTAssertNil(SpotifyConnection(tokens: nil).blocker)
    }

    /// The whole PKCE dance end to end against the REAL client id, with only the two seams the
    /// device supplies faked (the browser sheet and the network). Everything between them — the
    /// authorize URL, the state check, the S256 challenge/verifier pair, the token exchange, the
    /// link state — is the shipping code path. The one thing a test cannot do is Anton's tap.
    func testTheFullPKCEDanceRunsAgainstTheRealClientID() async throws {
        SpotifyConfig.overrideClientID = nil            // the real id, deliberately
        let http = FakeHTTP()
        http.replies["POST /api/token"] = .init(status: 200, json: [
            "access_token": "AT-real", "refresh_token": "RT-real", "expires_in": 3600
        ])
        let connection = SpotifyConnection(tokens: nil)
        connection.http = http

        let seen = Captured()
        connection.authorize = { url, scheme in
            seen.url = url
            seen.scheme = scheme
            // Spotify redirects back with the code and echoes the state we sent.
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "openvision://spotify?code=AUTH_CODE&state=\(state)")!
        }

        try await connection.connect()

        // (a) the authorization request
        let url = try XCTUnwrap(seen.url)
        XCTAssertEqual(url.host, "accounts.spotify.com")
        XCTAssertEqual(url.path, "/authorize")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], SpotifyConfig.clientID)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["redirect_uri"], "openvision://spotify")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(Set((q["scope"] ?? "").split(separator: " ").map(String.init)),
                       Set(SpotifyConfig.scopes))
        // ASWebAuthenticationSession is handed the bare scheme, never the whole URI.
        XCTAssertEqual(seen.scheme, "openvision")

        // (b) the token exchange — and the PKCE proof: the verifier we sent hashes to the
        //     challenge we advertised. If these two ever drift, every real login 400s.
        let body = try XCTUnwrap(http.bodies["POST /api/token"])
        var form = URLComponents()
        form.percentEncodedQuery = body
        let f = Dictionary(uniqueKeysWithValues: (form.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(f["grant_type"], "authorization_code")
        XCTAssertEqual(f["code"], "AUTH_CODE")
        XCTAssertEqual(f["redirect_uri"], "openvision://spotify")
        XCTAssertEqual(f["client_id"], SpotifyConfig.clientID)
        XCTAssertNil(f["client_secret"], "a PKCE public client must never send a secret")
        let verifier = try XCTUnwrap(f["code_verifier"])
        XCTAssertEqual(SpotifyConnection.codeChallenge(for: verifier), q["code_challenge"])

        // (c) the state the Connections row and the wire both read afterwards
        XCTAssertTrue(connection.isLinked)
        XCTAssertEqual(connection.wireState, "linked")
        XCTAssertEqual(connection.tokens?.accessToken, "AT-real")
        let fresh = try await connection.accessToken()
        XCTAssertEqual(fresh, "AT-real", "a fresh token must be handed back without a refresh round-trip")
    }

    /// A mismatched `state` is a hijacked callback, and the only safe answer is to link nothing.
    func testAMismatchedStateLinksNothing() async {
        SpotifyConfig.overrideClientID = nil
        let connection = SpotifyConnection(tokens: nil)
        connection.http = FakeHTTP()
        connection.authorize = { _, _ in URL(string: "openvision://spotify?code=C&state=not-ours")! }
        do {
            try await connection.connect()
            XCTFail("a forged state must not link")
        } catch {
            XCTAssertEqual(error as? SpotifyError, .cancelled)
        }
        XCTAssertFalse(connection.isLinked)
    }

    /// With the id in the build and an account linked, `phone.spotify_now_playing` is reachable
    /// over the realtime bridge — the same call the brain makes. This is the far end of the wire
    /// that AUR-845b had to reach; only Anton's tap sits between it and a real account.
    func testNowPlayingIsReachableOverTheBridgeOnceLinked() async throws {
        SpotifyConfig.overrideClientID = nil            // the real id
        let http = FakeHTTP()
        http.replies["GET /v1/me/player/currently-playing"] = .init(status: 200, json: [
            "is_playing": true,
            "item": ["name": "Bohemian Rhapsody", "uri": "spotify:track:1", "id": "1",
                     "artists": [["name": "Queen"]]]
        ])
        let connection = SpotifyConnection(tokens: SpotifyTokens(accessToken: "AT", refreshToken: "RT",
                                                                 expiresAt: .distantFuture))
        connection.http = http
        var tool = SpotifyNowPlayingTool()
        tool.ctx.connection = { connection }
        tool.ctx.client = { SpotifyClient(connection: connection) }
        let spoken = try await tool.execute(args: [:])
        XCTAssertEqual(spoken, "Играет: «Bohemian Rhapsody» — Queen.")
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
