import XCTest
@testable import Evlin_iOS

/// The kid's "all set" signal is the SINGLE thing that lets the parent's
/// waiting-for-kid onboarding screen advance (backend `child_onboarding_complete`
/// has exactly one writer). It used to be a one-shot fire-and-forget POST, so a
/// dropped/cancelled request stranded the parent forever. `deliverAllSet` retries
/// the idempotent POST with backoff until it lands. These tests pin that policy.
final class APIClientMarkChildAllSetRetryTests: XCTestCase {

    func test_deliverAllSet_succeedsOnFirstAttempt() async {
        var calls = 0
        let ok = await APIClient.deliverAllSet(
            childDeviceID: UUID(),
            maxAttempts: 5,
            sleep: { _ in },
            perform: { _ in calls += 1; return true }
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(calls, 1)
    }

    func test_deliverAllSet_retriesUntilSuccess() async {
        var calls = 0
        let ok = await APIClient.deliverAllSet(
            childDeviceID: UUID(),
            maxAttempts: 8,
            sleep: { _ in },
            perform: { _ in calls += 1; return calls >= 3 }  // fail twice, succeed on the 3rd
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(calls, 3)
    }

    func test_deliverAllSet_givesUpAfterMaxAttempts() async {
        var calls = 0
        let ok = await APIClient.deliverAllSet(
            childDeviceID: UUID(),
            maxAttempts: 4,
            sleep: { _ in },
            perform: { _ in calls += 1; return false }
        )
        XCTAssertFalse(ok)
        XCTAssertEqual(calls, 4)
    }
}
