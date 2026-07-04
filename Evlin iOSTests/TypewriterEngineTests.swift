import XCTest
@testable import Evlin_iOS

final class FakeClock: TypewriterClock {
    var now: TimeInterval = 0
}

final class TypewriterEngineTests: XCTestCase {
    func test_drip_reveals_at_base_rate() {
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock)
        e.append("abcdef")
        e.tick()
        XCTAssertEqual(e.revealed.count, 1)     // backlog 6 → ceil(6/6)=1/tick
        for _ in 0..<5 { clock.now += 0.03; e.tick() }
        XCTAssertEqual(e.revealed, "abcdef")
    }

    func test_large_backlog_advances_without_bursting() {
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock)
        e.append(String(repeating: "x", count: 600))
        for _ in 0..<6 { clock.now += 0.03; e.tick() }
        XCTAssertEqual(e.revealed.count, 18)
        e.finalize(with: String(repeating: "x", count: 600))
        for _ in 0..<6 { clock.now += 0.03; e.tick() }
        XCTAssertEqual(e.revealed.count, 36)
    }

    func test_isComplete_false_until_finalized_even_when_drained() {
        // Regression: the driving Timer must key off isComplete, NOT a transient
        // revealed==buffer. Between streamed deltas the engine drains its current
        // buffer (revealed==buffer) but is NOT finalized — stopping there would
        // freeze the reveal and drop later deltas (empty/partial bubble bug).
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock)
        e.append("Hel")
        for _ in 0..<3 { clock.now += 0.03; e.tick() }
        XCTAssertEqual(e.revealed, "Hel")            // drained the current buffer
        XCTAssertFalse(e.isComplete)                 // but NOT complete — more may come
        e.append("lo")                               // a later delta arrives
        for _ in 0..<3 { clock.now += 0.03; e.tick() }
        XCTAssertEqual(e.revealed, "Hello")          // still revealing because timer lived
        XCTAssertFalse(e.isComplete)                 // still not finalized
        e.finalize(with: "Hello")
        for _ in 0..<6 { clock.now += 0.03; e.tick() }
        XCTAssertTrue(e.isComplete)                  // finalized AND fully revealed
    }

    func test_isComplete_after_immediate_finalize_only_when_revealed() {
        // Fastpath path: append + finalize immediately (before any tick).
        // isComplete must be false until the ticks actually reveal the text —
        // otherwise the bubble would be declared done while still empty.
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock)
        e.append("done")
        e.finalize(with: "done")
        XCTAssertFalse(e.isComplete)                 // finalized but revealed=="" still
        for _ in 0..<6 { clock.now += 0.03; e.tick() }
        XCTAssertEqual(e.revealed, "done")
        XCTAssertTrue(e.isComplete)
    }

    func test_flushNow_reveals_first_delta_without_waiting_for_timer() {
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock)
        var changes: [String] = []
        e.onChange = { changes.append($0) }

        e.append("Hello")
        e.flushNow()

        XCTAssertEqual(e.revealed, "H")
        XCTAssertEqual(changes, ["H"])
    }

    func test_finalize_reveals_gradually_instead_of_bursting() {
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock)
        e.append(String(repeating: "x", count: 120))
        e.finalize(with: String(repeating: "x", count: 120))

        e.tick()

        XCTAssertLessThanOrEqual(e.revealed.count, 3)
    }

    func test_finalize_keeps_long_replies_incremental() {
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock, tickInterval: 0.03)
        e.append("partial that will be repla")
        e.tick()
        e.finalize(with: String(repeating: "y", count: 4000))

        let before = e.revealed.count
        clock.now += 0.03
        e.tick()

        XCTAssertLessThanOrEqual(e.revealed.count - before, 3)
    }

    func test_finalize_replaces_mismatched_prefix() {
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock)
        e.append("wrong prefix")
        for _ in 0..<20 { clock.now += 0.03; e.tick() }
        e.finalize(with: "right text")
        for _ in 0..<10 { clock.now += 0.03; e.tick() }
        XCTAssertEqual(e.revealed, "right text")
    }

    func test_total_reveal_eventually_completes_after_finalize() {
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock)
        for i in 0..<50 { clock.now = Double(i) * 0.05; e.append("chunk"); e.tick() }
        e.finalize(with: e.bufferForTesting)
        var ticks = 0
        while e.revealed.count < e.bufferForTesting.count {
            clock.now += 0.03; e.tick()
            ticks += 1
        }
        XCTAssertGreaterThan(ticks, 1)
        XCTAssertTrue(e.isComplete)
    }
}
