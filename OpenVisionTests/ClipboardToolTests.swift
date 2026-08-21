import XCTest
@testable import OpenVision

/// AUR-833: the clipboard that lands — tolerant arg keys, read-back decides `ok`, background
/// writes are queued and re-applied on app-active, typed failures (never `ok:true` for nothing).
/// AUR-845: …and the queued copy now FINISHES — re-applied on `willEnterForeground` /
/// `didBecomeActive`, verified by read-back, reported on the wire as
/// `aurelia.client_tool.applied`, and told apart in the spoken result («Скопировано» vs
/// «Скопирую, как только откроешь приложение»).
/// A fake pasteboard only; `UIPasteboard.general` is never touched.
@MainActor
final class ClipboardToolTests: XCTestCase {

    /// A pasteboard that either mirrors writes (the happy path) or drops them (the iOS
    /// background / failure behaviour). Records the op ORDER so the tests can pin AUR-845's
    /// write-before-read rule (a read of another app's items raises the iOS 16+ paste alert).
    final class FakePasteboard: PasteboardWriting {
        var stored: String?
        var dropWrites = false
        var writes: [String] = []
        var reads = 0
        /// "w" / "r" per operation, in order.
        var ops: [String] = []
        func writePlainText(_ text: String) {
            writes.append(text); ops.append("w")
            if !dropWrites { stored = text }
        }
        var string: String? { reads += 1; ops.append("r"); return stored }
        var hasStrings: Bool { stored != nil }
    }

    /// Counts the tap-to-apply notification without touching UNUserNotificationCenter.
    final class FakeNotifier: PendingClipboardNotifying {
        var posted: [String] = []
        var cleared = 0
        func post(preview: String) { posted.append(preview) }
        func clear() { cleared += 1 }
    }

    private func makePending(_ notifier: FakeNotifier? = nil,
                             state: AppForegroundState = .active) -> PendingClipboard {
        PendingClipboard(notifier: notifier ?? FakeNotifier(), appState: { state })
    }

    private func makeTool(_ board: FakePasteboard, state: AppForegroundState, pending: PendingClipboard)
    -> ClipboardTool {
        ClipboardTool(pasteboard: { board }, appState: { state }, pending: { pending })
    }

    // MARK: - Arg tolerance

    func testAcceptsTextContentValueStringKeys() async throws {
        for key in ["text", "content", "value", "string"] {
            let board = FakePasteboard()
            let tool = makeTool(board, state: .active, pending: makePending())
            let out = try await tool.execute(args: [key: "hello \(key)"])
            XCTAssertEqual(board.stored, "hello \(key)", "key \(key) must land")
            XCTAssertTrue(out.hasPrefix("\(ClipboardTool.copiedPrefix): hello \(key)"), out)
        }
    }

    func testFirstNonEmptyKeyWinsAndNumbersCount() {
        XCTAssertEqual(ClipboardTool.textArgument(["text": "", "content": "b"]), "b")
        XCTAssertEqual(ClipboardTool.textArgument(["value": 4242]), "4242")
        XCTAssertEqual(ClipboardTool.textArgument(["text": "   ", "value": "  "]), nil)
        XCTAssertNil(ClipboardTool.textArgument(["title": "wrong key"]))
        XCTAssertNil(ClipboardTool.textArgument([:]))
    }

    func testEmptyOrMissingTextIsNothingToCopyNeverOk() async {
        for args in [[:], ["text": ""], ["title": "x"], ["text": "  \n"]] as [[String: Any]] {
            let board = FakePasteboard()
            let tool = makeTool(board, state: .active, pending: makePending())
            do {
                let out = try await tool.execute(args: args)
                XCTFail("must not succeed for \(args): \(out)")
            } catch let e as NativeToolError {
                XCTAssertEqual(e.wireCode, "nothing_to_copy")
                XCTAssertEqual(e.errorDescription, "There's nothing to copy.")
            } catch {
                XCTFail("typed error expected, got \(error)")
            }
            XCTAssertTrue(board.writes.isEmpty, "nothing is written for an empty copy")
        }
    }

    // MARK: - Read-back (in front)

    func testActiveWriteReadsBackAndSaysCopied() async throws {
        let board = FakePasteboard()
        let pending = makePending()
        let tool = makeTool(board, state: .active, pending: pending)
        let text = String(repeating: "я", count: 100)
        let outcome = try await tool.copy(text)
        XCTAssertTrue(outcome.readbackOK)
        XCTAssertFalse(outcome.queued)
        XCTAssertEqual(outcome.appState, .active)
        XCTAssertEqual(outcome.result,
                       "\(ClipboardTool.copiedPrefix): " + String(repeating: "я", count: 60) + "…")
        XCTAssertNil(pending.text, "an active copy queues nothing")
        XCTAssertEqual(board.ops.first, "w", "write BEFORE read — a pre-read raises the iOS paste alert")
    }

    func testActiveWriteThatDoesNotLandIsPasteboardWriteFailed() async {
        let board = FakePasteboard()
        board.dropWrites = true
        let tool = makeTool(board, state: .active, pending: makePending())
        do {
            _ = try await tool.execute(args: ["text": "gone"])
            XCTFail("a dropped write must not be ok")
        } catch let e as NativeToolError {
            XCTAssertEqual(e.wireCode, "pasteboard_write_failed")
        } catch {
            XCTFail("typed error expected, got \(error)")
        }
    }

    func testActiveReadbackMismatchIsPasteboardWriteFailed() async {
        let board = FakePasteboard()
        board.stored = "someone else's text"
        board.dropWrites = true          // hasStrings true, but not OUR text
        let tool = makeTool(board, state: .active, pending: makePending())
        do {
            _ = try await tool.execute(args: ["text": "mine"])
            XCTFail("a mismatched read-back must not be ok")
        } catch let e as NativeToolError {
            XCTAssertEqual(e.wireCode, "pasteboard_write_failed")
        } catch {
            XCTFail("typed error expected, got \(error)")
        }
    }

    // MARK: - Not in front: try anyway, then queue

    func testBackgroundWriteIsQueuedWithTheHonestResultAndDeferredReply() async throws {
        let board = FakePasteboard()
        board.dropWrites = true          // iOS in the background: the write does not land
        let notifier = FakeNotifier()
        let pending = makePending(notifier)
        let tool = makeTool(board, state: .background, pending: pending)

        let reply = try await tool.execute(args: ["content": "ride note"], call: nil)
        XCTAssertEqual(reply.text, "\(ClipboardTool.queuedPrefix): ride note")
        XCTAssertTrue(reply.deferred, "the bridge must send aurelia.tool_result.deferred:true")
        XCTAssertFalse(reply.text.hasPrefix(ClipboardTool.copiedPrefix),
                       "a queued copy is NEVER announced as «Скопировано»")
        XCTAssertEqual(board.writes, ["ride note"], "written anyway — the read-back gets to decide")
        XCTAssertEqual(board.ops.first, "w", "write BEFORE read on the background path too")
        XCTAssertEqual(pending.text, "ride note", "and queued")
        XCTAssertTrue(pending.isPending)
        XCTAssertEqual(notifier.posted, ["ride note"], "the tap-to-apply notification is posted once")
    }

    /// The one case where the doc is wrong and the field is right: if iOS ever DOES honour a
    /// background write, the read-back says so and we report «Скопировано», queueing nothing.
    func testBackgroundWriteThatActuallyLandsIsReportedCopiedAndQueuesNothing() async throws {
        let board = FakePasteboard()          // honours writes
        let pending = makePending()
        let tool = makeTool(board, state: .background, pending: pending)
        let reply = try await tool.execute(args: ["text": "surprise"], call: nil)
        XCTAssertEqual(reply.text, "\(ClipboardTool.copiedPrefix): surprise")
        XCTAssertFalse(reply.deferred)
        XCTAssertNil(pending.text, "nothing queued — a re-apply could clobber a newer copy")
    }

    func testInactiveCountsAsNotInFrontAndNewerCopyReplacesOlder() async throws {
        let board = FakePasteboard()
        board.dropWrites = true
        let pending = makePending()
        let tool = makeTool(board, state: .inactive, pending: pending)
        _ = try await tool.execute(args: ["text": "first"])
        _ = try await tool.execute(args: ["text": "second"])
        XCTAssertEqual(pending.text, "second", "one slot: the latest copy wins")
    }

    // MARK: - The re-apply that finishes the job

    func testQueuedCopyLandsOnForegroundAndReportsTheAppliedEvent() async throws {
        let board = FakePasteboard()
        board.dropWrites = true
        let notifier = FakeNotifier()
        let pending = makePending(notifier)
        let tool = makeTool(board, state: .background, pending: pending)
        var applied: [ClipboardApplied] = []
        pending.onApplied = { applied.append($0) }

        let call = NativeToolCall(id: "call-7", wireName: "phone.copy_to_clipboard")
        _ = try await tool.execute(args: ["text": "ride note"], call: call)

        // `willEnterForeground` — the scene is coming back but iOS still refuses the write.
        XCTAssertNil(pending.applyPending(stage: "foreground", final: false),
                     "a non-final attempt that did not verify reports nothing and keeps the slot")
        XCTAssertEqual(pending.text, "ride note", "still pending after the unverified attempt")
        XCTAssertTrue(applied.isEmpty)

        // `didBecomeActive` — the write iOS honours.
        board.dropWrites = false
        let event = try XCTUnwrap(pending.applyPending(stage: "active", final: true))
        XCTAssertEqual(board.stored, "ride note")
        XCTAssertTrue(event.ok)
        XCTAssertTrue(event.verifiedByReadback)
        XCTAssertEqual(event.callId, "call-7")
        XCTAssertEqual(event.wireName, "phone.copy_to_clipboard")
        XCTAssertEqual(event.stage, "active")
        XCTAssertEqual(event.chars, 9)
        XCTAssertEqual(event.appState, .active)
        XCTAssertGreaterThanOrEqual(event.queuedMs, 0)
        XCTAssertEqual(applied, [event], "the event goes out exactly once")
        XCTAssertNil(pending.text, "slot cleared after the re-apply")
        XCTAssertEqual(pending.appliedCount, 1)
        XCTAssertEqual(pending.lastApplied, event)
        XCTAssertEqual(notifier.cleared, 1, "the tap-to-apply notification is withdrawn")
        XCTAssertNil(pending.applyPending(stage: "active", final: true), "nothing pending the second time")
    }

    func testFinalReapplyThatStillFailsReportsNotAppliedAndClearsTheSlot() async throws {
        let board = FakePasteboard()
        board.dropWrites = true
        let pending = makePending()
        var applied: [ClipboardApplied] = []
        pending.onApplied = { applied.append($0) }
        let tool = makeTool(board, state: .background, pending: pending)
        _ = try await tool.execute(args: ["text": "doomed"], call: nil)

        let event = try XCTUnwrap(pending.applyPending(stage: "active", final: true))
        XCTAssertFalse(event.ok, "the wire hears the failure — never a silent drop")
        XCTAssertFalse(event.verifiedByReadback)
        XCTAssertNil(event.callId, "the push-to-ask path has no wire id")
        XCTAssertEqual(event.wireName, "phone.copy_to_clipboard", "…but the tool is still named")
        XCTAssertEqual(applied.count, 1)
        XCTAssertNil(pending.text)
    }

    func testReapplyWritesBeforeItReads() async throws {
        let board = FakePasteboard()
        board.dropWrites = true
        let pending = makePending()
        let tool = makeTool(board, state: .background, pending: pending)
        _ = try await tool.execute(args: ["text": "x"], call: nil)
        board.ops.removeAll()
        board.dropWrites = false
        _ = pending.applyPending(stage: "active", final: true)
        XCTAssertEqual(board.ops, ["w", "r"], "the re-apply never reads a foreign pasteboard first")
    }

    // MARK: - The wire frame the server half is coded against

    func testAppliedPayloadJSON() throws {
        let e = ClipboardApplied(callId: "call-7", wireName: "phone.copy_to_clipboard", ok: true,
                                 verifiedByReadback: true, stage: "active", queuedMs: 41230,
                                 appState: .active, chars: 42)
        let p = ClientToolBridge.appliedPayload(e)
        XCTAssertEqual(p["type"] as? String, "aurelia.client_tool.applied")
        XCTAssertEqual(p["id"] as? String, "call-7")
        XCTAssertEqual(p["tool"] as? String, "phone.copy_to_clipboard")
        XCTAssertEqual(p["ok"] as? Bool, true)
        XCTAssertEqual(p["verifiedByReadback"] as? Bool, true)
        XCTAssertEqual(p["stage"] as? String, "active")
        XCTAssertEqual(p["queuedMs"] as? Int, 41230)
        XCTAssertEqual(p["appState"] as? String, "active")
        XCTAssertEqual(p["chars"] as? Int, 42)
        XCTAssertEqual(p.count, 9, "exactly the nine keys documented in docs/native-tools.md")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(p))

        // No wire id (push-to-ask) → the `id` key is ABSENT, not null.
        let anon = ClipboardApplied(callId: nil, wireName: "phone.copy_to_clipboard", ok: false,
                                    verifiedByReadback: false, stage: "active", queuedMs: 10,
                                    appState: .background, chars: 3)
        let ap = ClientToolBridge.appliedPayload(anon)
        XCTAssertNil(ap["id"])
        XCTAssertEqual(ap.count, 8)
        XCTAssertEqual(ap["ok"] as? Bool, false)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(ap))
    }

    // MARK: - End to end over the bridge (tool_call → deferred result → applied event)

    func testBridgeAnswersDeferredThenSendsTheAppliedEvent() async throws {
        let board = FakePasteboard()
        board.dropWrites = true
        let pending = makePending()
        let tool = makeTool(board, state: .background, pending: pending)

        var sent: [[String: Any]] = []
        let bridge = ClientToolBridge(tools: [tool], connectionsProvider: { PhoneConnections() },
                                      pendingClipboard: pending)
        bridge.send = { sent.append($0) }
        bridge.appStateProvider = { .background }
        bridge.sessionDidConnect()

        bridge.handleToolCall(["type": "aurelia.tool_call", "id": "c1",
                               "name": "phone.copy_to_clipboard",
                               "args": ["text": "Синие киты танцуют на рассвете под дождём"]])
        // The result is answered from a Task; give it a spin of the main queue.
        try await waitUntil { sent.contains { ($0["type"] as? String) == "aurelia.tool_result" } }

        let result = try XCTUnwrap(sent.first { ($0["type"] as? String) == "aurelia.tool_result" })
        XCTAssertEqual(result["id"] as? String, "c1")
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["deferred"] as? Bool, true)
        XCTAssertEqual(result["appState"] as? String, "background")
        XCTAssertTrue((result["result"] as? String ?? "").hasPrefix(ClipboardTool.queuedPrefix))
        XCTAssertEqual(bridge.recentCalls.first?.statusText, "ok (deferred)")

        // The app comes to the front: the re-apply lands and the bridge reports it.
        board.dropWrites = false
        bridge.appStateProvider = { .active }
        _ = pending.applyPending(stage: "active", final: true)

        let ev = try XCTUnwrap(sent.first { ($0["type"] as? String) == "aurelia.client_tool.applied" })
        XCTAssertEqual(ev["id"] as? String, "c1", "the event names the call it completes")
        XCTAssertEqual(ev["tool"] as? String, "phone.copy_to_clipboard")
        XCTAssertEqual(ev["ok"] as? Bool, true)
        XCTAssertEqual(ev["verifiedByReadback"] as? Bool, true)
        XCTAssertEqual(bridge.lastApplied?.callId, "c1")
        XCTAssertEqual(bridge.recentCalls.first?.statusText, "applied")
        XCTAssertEqual(bridge.recentCalls.first?.id, "c1#applied")
    }

    /// No session open when the copy finally lands: logged + kept for the Debug read-out, never
    /// sent (there is no socket to send it on).
    func testAppliedEventIsNotSentWithoutASession() async throws {
        let board = FakePasteboard()
        let pending = makePending()
        var sent: [[String: Any]] = []
        let bridge = ClientToolBridge(tools: [makeTool(board, state: .background, pending: pending)],
                                      connectionsProvider: { PhoneConnections() },
                                      pendingClipboard: pending)
        bridge.send = { sent.append($0) }
        bridge.reportApplied(ClipboardApplied(callId: "gone", wireName: "phone.copy_to_clipboard",
                                              ok: true, verifiedByReadback: true, stage: "active",
                                              queuedMs: 5, appState: .active, chars: 1))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(bridge.lastApplied?.callId, "gone")
        XCTAssertEqual(bridge.recentCalls.first?.statusText, "applied")
    }

    // MARK: - Registry wiring

    func testRegistryClipboardToolHasNoPermissionKind() {
        let tool = NativeToolRegistry.shared.allTools.first { $0.name == "copy_to_clipboard" }
        XCTAssertNotNil(tool)
        XCTAssertNil(tool?.permissionKind)
    }

    /// Every other tool keeps the plain, never-deferred reply through the protocol default.
    func testDefaultExecuteIsNeverDeferred() async throws {
        struct Plain: NativeTool {
            let name = "plain"
            let description = "d"
            let parametersSchema: [String: Any] = ["type": "object", "properties": [:]]
            func execute(args: [String: Any]) async throws -> String { "done" }
        }
        let reply = try await Plain().execute(args: [:], call: NativeToolCall(id: "x", wireName: "phone.plain"))
        XCTAssertEqual(reply, NativeToolReply(text: "done"))
        XCTAssertFalse(reply.deferred)
    }

    // MARK: - Helper

    /// Spin the main queue until `cond` holds (the bridge answers from a Task).
    private func waitUntil(timeout: TimeInterval = 5, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("condition not met in \(timeout) s"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
