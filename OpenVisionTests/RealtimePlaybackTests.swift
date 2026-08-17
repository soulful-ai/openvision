// OpenVision - RealtimePlaybackTests.swift
// AUR-723: the pure pieces of the full-duplex client — ring-buffer transport (pause/flush/resume)
// and the played-ms accounting that `conversation.item.truncate` is built on.
//
// These are the parts a barge-in gets wrong silently: if played-ms comes from bytes RECEIVED
// instead of frames RENDERED, the brain is told the wearer heard a sentence she never got.

import XCTest
@testable import OpenVision

final class RealtimePlaybackTests: XCTestCase {

    /// Render `frames` from the ring and return (writtenFrames, samples).
    private func render(_ ring: PlaybackRingBuffer, frames: Int) -> (written: Int, samples: [Float]) {
        var out = [Float](repeating: -99, count: frames)
        let written = out.withUnsafeMutableBufferPointer { buf -> Int in
            ring.render(into: buf.baseAddress!, frames: frames)
        }
        return (written, out)
    }

    private func ramp(_ n: Int, start: Float = 0) -> [Float] {
        (0..<n).map { start + Float($0) }
    }

    // MARK: - Basic transport

    func testAppendThenRenderReturnsSamplesInOrder() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(10), handle: 1)
        let (written, samples) = render(ring, frames: 10)
        XCTAssertEqual(written, 10)
        XCTAssertEqual(Array(samples.prefix(10)), ramp(10))
        XCTAssertEqual(ring.bufferedFrames, 0)
    }

    func testRenderPastEndOfDataIsPartialNotGarbage() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(4), handle: 1)
        let (written, _) = render(ring, frames: 16)
        XCTAssertEqual(written, 4, "the render block must report exactly what it produced so the caller can zero-fill")
    }

    func testWrapAroundPreservesOrder() {
        // Capacity is floored at 1024 frames by the initializer — walk the read/write heads past it.
        let ring = PlaybackRingBuffer(capacityFrames: 1024)
        for _ in 0..<3 {
            ring.append(ramp(600), handle: 1)
            let (written, samples) = render(ring, frames: 600)
            XCTAssertEqual(written, 600)
            XCTAssertEqual(Array(samples.prefix(600)), ramp(600))
        }
    }

    // MARK: - Pause / resume / flush (the barge-in transport)

    func testPauseStopsRenderingButKeepsTheBuffer() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(100), handle: 1)
        _ = render(ring, frames: 20)

        ring.pause()
        let (written, _) = render(ring, frames: 40)
        XCTAssertEqual(written, 0, "a paused ring renders silence")
        XCTAssertEqual(ring.bufferedFrames, 80, "pause must KEEP the buffer — the server may say 'false alarm'")
        XCTAssertTrue(ring.isPaused)
    }

    func testResumeContinuesWhereItPaused() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(100), handle: 1)
        _ = render(ring, frames: 20)
        ring.pause()
        _ = render(ring, frames: 40)
        ring.resume()

        let (written, samples) = render(ring, frames: 10)
        XCTAssertEqual(written, 10)
        XCTAssertEqual(Array(samples.prefix(10)), ramp(10, start: 20), "resume must not skip or replay audio")
        XCTAssertFalse(ring.isPaused)
    }

    func testFlushDropsTheBufferAndReportsWhatWasPlayed() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(1000), handle: 7)
        _ = render(ring, frames: 240)          // 240 frames actually left the speaker

        let head = ring.flush()
        XCTAssertEqual(head?.handle, 7)
        XCTAssertEqual(head?.rendered, 240, "played-ms must come from frames RENDERED, not bytes received")
        XCTAssertEqual(ring.bufferedFrames, 0, "flush drops everything still queued")

        let (written, _) = render(ring, frames: 100)
        XCTAssertEqual(written, 0)
    }

    func testFlushClearsThePausedFlagSoTheNextReplyPlays() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(100), handle: 1)
        ring.pause()
        _ = ring.flush()
        XCTAssertFalse(ring.isPaused)

        ring.append(ramp(50), handle: 2)
        let (written, _) = render(ring, frames: 50)
        XCTAssertEqual(written, 50, "the answer after a barge-in must be audible")
    }

    // MARK: - Per-item accounting

    func testConsecutiveAppendsForOneItemShareASegment() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(100), handle: 3)
        ring.append(ramp(100), handle: 3)
        _ = render(ring, frames: 150)
        XCTAssertEqual(ring.head()?.handle, 3)
        XCTAssertEqual(ring.head()?.rendered, 150, "an item spread over many deltas is ONE play-out position")
    }

    func testPlayedFramesAreAttributedPerItem() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(100), handle: 1)
        ring.closeItem(handle: 1)
        ring.append(ramp(100), handle: 2)

        _ = render(ring, frames: 130)          // all of item 1 + 30 frames of item 2
        let completed = ring.takeCompleted()
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.handle, 1)
        XCTAssertEqual(completed.first?.renderedFrames, 100)

        XCTAssertEqual(ring.head()?.handle, 2)
        XCTAssertEqual(ring.head()?.rendered, 30)
    }

    func testItemCompletesOnlyOnceClosed() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(50), handle: 9)
        _ = render(ring, frames: 50)
        XCTAssertTrue(ring.takeCompleted().isEmpty,
                      "a drained-but-open item is starvation, not the end of the reply — more deltas may follow")

        ring.append(ramp(50), handle: 9)
        _ = render(ring, frames: 50)
        ring.closeItem(handle: 9)
        let completed = ring.takeCompleted()
        XCTAssertEqual(completed.first?.handle, 9)
        XCTAssertEqual(completed.first?.renderedFrames, 100, "aurelia.playback.done reports the whole item")
    }

    func testCloseOnAnAlreadyDrainedItemCompletesImmediately() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(20), handle: 4)
        _ = render(ring, frames: 20)
        ring.closeItem(handle: 4)
        XCTAssertEqual(ring.takeCompleted().first?.renderedFrames, 20)
    }

    func testTakeCompletedDrainsOnce() {
        let ring = PlaybackRingBuffer(capacityFrames: 4096)
        ring.append(ramp(10), handle: 1)
        ring.closeItem(handle: 1)
        _ = render(ring, frames: 10)
        XCTAssertEqual(ring.takeCompleted().count, 1)
        XCTAssertTrue(ring.takeCompleted().isEmpty)
    }

    // MARK: - Overflow

    func testOverflowDropsTheTailInsteadOfCorruptingTheRing() {
        let ring = PlaybackRingBuffer(capacityFrames: 1024)
        let accepted = ring.append(ramp(2000), handle: 1)
        XCTAssertEqual(accepted, 1024)
        XCTAssertEqual(ring.overflowFrames, 976)
        let (written, samples) = render(ring, frames: 1024)
        XCTAssertEqual(written, 1024)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1023], 1023)
    }

    // MARK: - PCM16 → Float conversion

    func testPCM16DecodesLittleEndianSignedSamples() {
        var data = Data()
        for value in [Int16(0), Int16(Int16.max), Int16(-Int16.max), Int16(1000)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let samples = AudioPlaybackService.floatSamples(fromPCM16: data)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], 0, accuracy: 1e-6)
        XCTAssertEqual(samples[1], 1.0, accuracy: 1e-6)
        XCTAssertEqual(samples[2], -1.0, accuracy: 1e-6)
        XCTAssertEqual(samples[3], 1000.0 / Float(Int16.max), accuracy: 1e-6)
    }

    func testOddByteCountIsTruncatedNotCrashing() {
        let samples = AudioPlaybackService.floatSamples(fromPCM16: Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(samples.count, 1)
    }

    // MARK: - The barge-in sequence, end to end on the ring

    func testBargeInSequenceOnsetPauseConfirmFlush() {
        // 24 kHz: 1 s of reply arrives in one burst (the server emits faster than real time).
        let rate = 24_000
        let ring = PlaybackRingBuffer(capacityFrames: rate * 30)
        ring.append([Float](repeating: 0.5, count: rate), handle: 42)

        // ~300 ms have been rendered when the wearer starts talking.
        _ = render(ring, frames: rate * 300 / 1000)
        ring.pause()                                    // input_audio_buffer.speech_started

        // Nothing more may leave the ear while the server confirms.
        let (duringHold, _) = render(ring, frames: 960)
        XCTAssertEqual(duringHold, 0)

        // output_audio_buffer.cleared → drop the remaining 700 ms and report what was heard.
        let head = ring.flush()
        XCTAssertEqual(head?.handle, 42)
        let playedMs = Double(head!.rendered) / Double(rate) * 1000
        XCTAssertEqual(playedMs, 300, accuracy: 1.0, "truncate must carry the 300 ms she actually heard")
        XCTAssertEqual(ring.bufferedFrames, 0)
    }
}
