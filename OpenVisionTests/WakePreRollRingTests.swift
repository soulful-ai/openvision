import XCTest
@testable import OpenVision

/// AUR-743: the wake-word pre-roll ring — bounded, tail-snapshot, recognizer-timeline clock.
final class WakePreRollRingTests: XCTestCase {

    private let rate = 24_000

    private func pcm(seconds: Double, value: Int16) -> Data {
        let count = Int(seconds * Double(rate))
        var samples = [Int16](repeating: value, count: count)
        return Data(bytes: &samples, count: count * 2)
    }

    func testCapacityIsTwoSecondsOfPCM16AtTheRealtimeRate() {
        let ring = WakePreRollRing(sampleRate: rate, seconds: 2.0)
        XCTAssertEqual(ring.capacityBytes, 2 * rate * 2)   // 96 000 bytes
        XCTAssertEqual(WakePreRollRing.bytes(forSeconds: 2.0, sampleRate: rate), 96_000)
        XCTAssertEqual(WakePreRollRing.bytes(forSeconds: -1, sampleRate: rate), 0)
    }

    func testOldestAudioFallsOffBeyondCapacity() {
        let ring = WakePreRollRing(sampleRate: rate, seconds: 2.0)
        ring.append(pcm(seconds: 1.5, value: 1))   // old
        ring.append(pcm(seconds: 1.0, value: 2))   // new
        XCTAssertEqual(ring.bufferedSeconds, 2.0, accuracy: 0.001)
        let all = ring.snapshot()
        XCTAssertEqual(all.count, ring.capacityBytes)
        // The head is the NEWEST 2 s → the first 0.5 s are value 1 (the tail of the old block),
        // the rest value 2.
        let samples = all.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(samples.first, 1)
        XCTAssertEqual(samples[Int(0.5 * Double(rate)) + 10], 2)
        XCTAssertEqual(samples.last, 2)
    }

    func testSnapshotTailReturnsOnlyTheLastSeconds() {
        let ring = WakePreRollRing(sampleRate: rate, seconds: 2.0)
        ring.append(pcm(seconds: 1.0, value: 7))   // «Аурелия»
        ring.append(pcm(seconds: 0.6, value: 9))   // «сколько…»
        let tail = ring.snapshot(lastSeconds: 0.6)
        XCTAssertEqual(tail.count, WakePreRollRing.bytes(forSeconds: 0.6, sampleRate: rate))
        let samples = tail.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertTrue(samples.allSatisfy { $0 == 9 }, "only the audio after the wake word")
        XCTAssertEqual(WakePreRollRing.milliseconds(of: tail, sampleRate: rate), 600)
        // Asking for nothing yields nothing (bare «Аурелия» → nothing fed to the model).
        XCTAssertTrue(ring.snapshot(lastSeconds: 0).isEmpty)
        // Asking for more than there is yields all of it.
        XCTAssertEqual(ring.snapshot(lastSeconds: 10).count, ring.snapshot().count)
    }

    func testEpochClockFollowsAppendedAudio() {
        let ring = WakePreRollRing(sampleRate: rate, seconds: 2.0)
        ring.append(pcm(seconds: 3.0, value: 0))
        ring.markEpoch()                                   // a new recognition request starts
        XCTAssertEqual(ring.secondsSinceEpoch, 0, accuracy: 0.001)
        ring.append(pcm(seconds: 1.25, value: 0))
        XCTAssertEqual(ring.secondsSinceEpoch, 1.25, accuracy: 0.001)
        // The clock is not affected by the ring trimming its buffer.
        ring.append(pcm(seconds: 2.5, value: 0))
        XCTAssertEqual(ring.secondsSinceEpoch, 3.75, accuracy: 0.001)
        XCTAssertEqual(ring.bufferedSeconds, 2.0, accuracy: 0.001)
    }

    func testClearKeepsTheClock() {
        let ring = WakePreRollRing(sampleRate: rate, seconds: 2.0)
        ring.markEpoch()
        ring.append(pcm(seconds: 0.5, value: 3))
        ring.clear()
        XCTAssertTrue(ring.snapshot().isEmpty)
        XCTAssertEqual(ring.secondsSinceEpoch, 0.5, accuracy: 0.001)
    }
}
