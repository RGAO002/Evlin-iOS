import XCTest
@testable import Evlin_iOS

final class HomeNotificationsBaselineTests: XCTestCase {

    func test_baseline_notifications_is_empty_for_beta() {
        XCTAssertTrue(HomeMockData.notifications.isEmpty,
                      "Beta must not ship the 8 mock liam/maya/emma notifications.")
    }

    func test_combiner_returns_only_real_reflection_entries() {
        let nudge = HomeMockData.ReflectionNudge(
            childId: "c1", childName: "Sam", reflectionId: UUID())
        let result = HomeMockData.notifications(completedReflections: [], pendingNudges: [nudge])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.childId, "c1")
    }

    func test_combiner_empty_streams_yields_empty() {
        XCTAssertTrue(
            HomeMockData.notifications(completedReflections: [], pendingNudges: []).isEmpty)
    }
}
