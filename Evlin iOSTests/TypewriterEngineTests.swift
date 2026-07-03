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

    func test_burst_catches_up_geometrically() {
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock)
        e.append(String(repeating: "x", count: 600))
        for _ in 0..<6 { clock.now += 0.03; e.tick() }
        // ceil(backlog/6) per tick: 600→500→416→346→288→240→200 backlog,
        // i.e. ≥ 350 revealed after 6 ticks. Full drain is finalize's job.
        XCTAssertGreaterThanOrEqual(e.revealed.count, 350)
        e.finalize(with: String(repeating: "x", count: 600))
        for _ in 0..<6 { clock.now += 0.03; e.tick() }
        XCTAssertEqual(e.revealed.count, 600)
    }

    func test_finalize_flushes_within_200ms() {
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock, tickInterval: 0.03)
        e.append("partial that will be repla")
        e.tick()
        e.finalize(with: String(repeating: "y", count: 4000))
        var ticks = 0
        while e.revealed.count < 4000 { clock.now += 0.03; e.tick(); ticks += 1 }
        XCTAssertLessThanOrEqual(Double(ticks) * 0.03, 0.2 + 0.001)
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

    func test_total_reveal_never_slower_than_arrival_plus_200ms() {
        let clock = FakeClock()
        let e = TypewriterEngine(clock: clock)
        for i in 0..<50 { clock.now = Double(i) * 0.05; e.append("chunk"); e.tick() }
        let arrivalEnd = clock.now
        e.finalize(with: e.bufferForTesting)
        while e.revealed.count < e.bufferForTesting.count {
            clock.now += 0.03; e.tick()
        }
        XCTAssertLessThanOrEqual(clock.now - arrivalEnd, 0.2 + 0.001)
    }
}
