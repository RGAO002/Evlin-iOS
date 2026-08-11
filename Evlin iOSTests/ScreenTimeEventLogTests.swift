import XCTest
@testable import Evlin_iOS

final class ScreenTimeEventLogTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "test.screentime.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func event(_ reason: String) -> ScreenTimeEvent {
        ScreenTimeEvent(ts: "2026-07-01T00:00:00Z", emitter: .kidExtension,
                        deviceID: "D", dayKey: "2026-07-01@UTC", kind: .lock,
                        source: .perAppLimit, app: "a", reason: reason,
                        nums: nil, transition: nil, policyGen: nil, corrID: nil)
    }

    func test_emit_thenRead_returnsInOrder() {
        ScreenTimeEventLog.emit(event("one"), into: defaults)
        ScreenTimeEventLog.emit(event("two"), into: defaults)
        let read = ScreenTimeEventLog.read(from: defaults)
        XCTAssertEqual(read.map { $0.reason }, ["one", "two"])
    }

    func test_ringBuffer_capsAtCap_droppingOldest() {
        for i in 0..<(ScreenTimeEventLog.cap + 10) {
            ScreenTimeEventLog.emit(event("r\(i)"), into: defaults)
        }
        let read = ScreenTimeEventLog.read(from: defaults)
        XCTAssertEqual(read.count, ScreenTimeEventLog.cap)
        XCTAssertEqual(read.first?.reason, "r10")   // oldest 10 dropped
        XCTAssertEqual(read.last?.reason, "r\(ScreenTimeEventLog.cap + 9)")
    }

    func test_extensionBreadcrumbDoesNotRewriteTheDurableRing() {
        let original = (0..<50).map { "existing-\($0)" }
        defaults.set(original, forKey: ScreenTimeEventLog.key)

        ScreenTimeEventLog.emitExtensionBreadcrumb(event("arrived"), into: defaults)

        XCTAssertEqual(defaults.stringArray(forKey: ScreenTimeEventLog.key), original)
        XCTAssertNotNil(
            defaults.string(forKey: ScreenTimeEventLog.extensionBreadcrumbKey)
        )
    }

    func test_clear_empties() {
        ScreenTimeEventLog.emit(event("x"), into: defaults)
        ScreenTimeEventLog.clear(in: defaults)
        XCTAssertTrue(ScreenTimeEventLog.read(from: defaults).isEmpty)
    }


    // MARK: - Failure ring (2026-08-10)

    private func failure(_ reason: String) -> ScreenTimeEvent {
        ScreenTimeEvent(ts: "2026-07-01T00:00:00Z", emitter: .kidExtension,
                        deviceID: "D", dayKey: "2026-07-01@UTC",
                        kind: .meteringError,
                        source: .perAppLimit, app: "a", reason: reason,
                        nums: nil, transition: nil, policyGen: nil, corrID: nil)
    }

    /// The whole point: a device that carries on working normally must not erase
    /// the failure that explains what went wrong. Before this, an error and a
    /// heartbeat were equally disposable in one FIFO ring.
    func test_routineTrafficCannotEvictAFailure() {
        ScreenTimeEventLog.emit(failure("the_one_that_matters"), into: defaults)
        for i in 0..<(ScreenTimeEventLog.cap + 50) {
            ScreenTimeEventLog.emit(event("routine-\(i)"), into: defaults)
        }

        let main = ScreenTimeEventLog.readLines(from: defaults)
        XCTAssertFalse(
            main.contains(where: { $0.contains("the_one_that_matters") }),
            "the main ring is expected to have rolled the failure off"
        )
        let preserved = ScreenTimeEventLog.preservedLines(from: defaults)
        XCTAssertTrue(
            preserved.contains(where: { $0.contains("the_one_that_matters") }),
            "the failure must survive in the preserved ring"
        )
    }

    func test_routineKindsDoNotEnterThePreservedRing() {
        ScreenTimeEventLog.emit(event("routine"), into: defaults)
        XCTAssertEqual(
            ScreenTimeEventLog.preservedLines(from: defaults),
            [],
            "letting progress events in would make the failure ring evict itself"
        )
    }

    func test_preservedRingIsItselfCapped() {
        for i in 0..<(ScreenTimeEventLog.preservedCap + 25) {
            ScreenTimeEventLog.emit(failure("f-\(i)"), into: defaults)
        }
        let preserved = ScreenTimeEventLog.preservedLines(from: defaults)
        XCTAssertEqual(preserved.count, ScreenTimeEventLog.preservedCap)
        XCTAssertTrue(
            preserved.last?.contains("f-\(ScreenTimeEventLog.preservedCap + 24)") == true,
            "newest failures win when even the failure ring is full"
        )
    }

    func test_clearRemovesBothRings() {
        ScreenTimeEventLog.emit(failure("boom"), into: defaults)
        ScreenTimeEventLog.emit(event("routine"), into: defaults)
        ScreenTimeEventLog.clear(in: defaults)
        XCTAssertEqual(ScreenTimeEventLog.readLines(from: defaults), [])
        XCTAssertEqual(ScreenTimeEventLog.preservedLines(from: defaults), [])
    }
}
