import XCTest
@testable import OpenVision

/// AUR-833: the clipboard that lands — tolerant arg keys, read-back decides `ok`, background
/// writes are queued and re-applied on app-active, typed failures (never `ok:true` for nothing).
/// A fake pasteboard only; `UIPasteboard.general` is never touched.
@MainActor
final class ClipboardToolTests: XCTestCase {

    /// A pasteboard that either mirrors writes (the happy path) or drops them (the iOS
    /// background / failure behaviour).
    final class FakePasteboard: PasteboardWriting {
        var stored: String?
        var dropWrites = false
        var writes: [String] = []
        func writePlainText(_ text: String) {
            writes.append(text)
            if !dropWrites { stored = text }
        }
        var string: String? { stored }
        var hasStrings: Bool { stored != nil }
    }

    private func makeTool(_ board: FakePasteboard, state: AppForegroundState, pending: PendingClipboard)
    -> ClipboardTool {
        ClipboardTool(pasteboard: { board }, appState: { state }, pending: { pending })
    }

    // MARK: - Arg tolerance

    func testAcceptsTextContentValueStringKeys() async throws {
        for key in ["text", "content", "value", "string"] {
            let board = FakePasteboard()
            let tool = makeTool(board, state: .active, pending: PendingClipboard())
            let out = try await tool.execute(args: [key: "hello \(key)"])
            XCTAssertEqual(board.stored, "hello \(key)", "key \(key) must land")
            XCTAssertTrue(out.hasPrefix("Copied to clipboard: hello \(key)"), out)
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
            let tool = makeTool(board, state: .active, pending: PendingClipboard())
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

    // MARK: - Read-back

    func testActiveWriteReadsBackAndReportsOk() async throws {
        let board = FakePasteboard()
        let pending = PendingClipboard()
        let tool = makeTool(board, state: .active, pending: pending)
        let text = String(repeating: "я", count: 100)
        let outcome = try await tool.copy(text)
        XCTAssertTrue(outcome.readbackOK)
        XCTAssertFalse(outcome.queued)
        XCTAssertEqual(outcome.appState, .active)
        XCTAssertEqual(outcome.result, "Copied to clipboard: " + String(repeating: "я", count: 60) + "…")
        XCTAssertNil(pending.text, "an active copy queues nothing")
    }

    func testActiveWriteThatDoesNotLandIsPasteboardWriteFailed() async {
        let board = FakePasteboard()
        board.dropWrites = true
        let tool = makeTool(board, state: .active, pending: PendingClipboard())
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
        let tool = makeTool(board, state: .active, pending: PendingClipboard())
        do {
            _ = try await tool.execute(args: ["text": "mine"])
            XCTFail("a mismatched read-back must not be ok")
        } catch let e as NativeToolError {
            XCTAssertEqual(e.wireCode, "pasteboard_write_failed")
        } catch {
            XCTFail("typed error expected, got \(error)")
        }
    }

    // MARK: - Background: write anyway + queue + re-apply on app active

    func testBackgroundWriteIsQueuedAndReappliedOnAppActive() async throws {
        let board = FakePasteboard()
        board.dropWrites = true          // iOS in the background: the write does not land
        let pending = PendingClipboard()
        let tool = makeTool(board, state: .background, pending: pending)
        let out = try await tool.execute(args: ["content": "ride note"])
        XCTAssertEqual(out, "Copied (will apply when the app is in front): ride note")
        XCTAssertEqual(board.writes, ["ride note"], "written anyway")
        XCTAssertEqual(pending.text, "ride note", "and queued")

        // The app comes to the front: the pending text is written again, and this time it lands.
        board.dropWrites = false
        XCTAssertTrue(pending.applyPending(reason: "test"))
        XCTAssertEqual(board.stored, "ride note")
        XCTAssertEqual(board.writes.count, 2)
        XCTAssertNil(pending.text, "slot cleared after the re-apply")
        XCTAssertEqual(pending.appliedCount, 1)
        XCTAssertFalse(pending.applyPending(reason: "again"), "nothing pending the second time")
    }

    func testInactiveCountsAsNotInFrontAndNewerCopyReplacesOlder() async throws {
        let board = FakePasteboard()
        let pending = PendingClipboard()
        let tool = makeTool(board, state: .inactive, pending: pending)
        _ = try await tool.execute(args: ["text": "first"])
        _ = try await tool.execute(args: ["text": "second"])
        XCTAssertEqual(pending.text, "second", "one slot: the latest copy wins")
    }

    // MARK: - Registry wiring

    func testRegistryClipboardToolHasNoPermissionKind() {
        let tool = NativeToolRegistry.shared.allTools.first { $0.name == "copy_to_clipboard" }
        XCTAssertNotNil(tool)
        XCTAssertNil(tool?.permissionKind)
    }
}
