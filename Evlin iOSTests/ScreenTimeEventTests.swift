import XCTest
@testable import Evlin_iOS

final class ScreenTimeEventTests: XCTestCase {

    private func sample() -> ScreenTimeEvent {
        ScreenTimeEvent(
            ts: "2026-07-01T15:02:00-04:00",
            emitter: .kidExtension,
            deviceID: "DEV-123",
            dayKey: "2026-07-01@America/New_York",
            kind: .lock,
            source: .perAppLimit,
            app: "com.instagram.app",
            reason: "budget_reached",
            nums: .init(used: 30, budget: 30, poolUsed: 45, poolTotal: 120, cap: 180, remaining: 0, rounded: 0),
            transition: .init(before: "shielded:false", after: "shielded:true"),
            policyGen: 7,
            corrID: "corr-abc"
        )
    }

    func test_jsonLine_roundTrips() {
        let e = sample()
        let line = e.jsonLine()
        XCTAssertFalse(line.contains("\n"), "a JSONL line must be single-line")
        let decoded = ScreenTimeEvent.from(jsonLine: line)
        XCTAssertEqual(decoded, e)
    }

    func test_from_returnsNil_onGarbage() {
        XCTAssertNil(ScreenTimeEvent.from(jsonLine: "not json"))
    }

    func test_enumsUseStableRawValues() {
        XCTAssertEqual(ScreenTimeEvent.Emitter.kidExtension.rawValue, "kid_extension")
        XCTAssertEqual(ScreenTimeEvent.Source.perAppLimit.rawValue, "perAppLimit")
        XCTAssertEqual(ScreenTimeEvent.Kind.commandAck.rawValue, "command_ack")
    }
}
