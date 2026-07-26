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
}
