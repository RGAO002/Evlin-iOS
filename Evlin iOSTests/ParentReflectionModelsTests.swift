import XCTest
@testable import Evlin_iOS

final class ParentReflectionModelsTests: XCTestCase {
    func testStoreStartsWithoutReflectionSummary() {
        let store = ParentReflectionFixtureStore()

        let summary = store.summary(for: .previewLiam)

        XCTAssertNil(summary)
    }

    func testSimulateAssignmentCreatesLiamPendingSummary() {
        let store = ParentReflectionFixtureStore()

        store.simulateAssignment(childId: ChildProfile.previewLiam.id)

        let summary = store.summary(for: .previewLiam)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.childId, ChildProfile.previewLiam.id)
        XCTAssertEqual(summary?.childName, ChildProfile.previewLiam.name)
        XCTAssertEqual(summary?.state, .assignedPending)
        XCTAssertNil(summary?.submittedAt)
        XCTAssertNil(summary?.essayText)
        XCTAssertNil(summary?.takeaway)
    }

    func testSimulateCompletionFlipsLiamToCompletedReady() {
        let store = ParentReflectionFixtureStore()

        store.simulateCompletion(childId: ChildProfile.previewLiam.id)

        let summary = store.summary(childId: ChildProfile.previewLiam.id)
        XCTAssertEqual(summary?.state, .completedReady)
        XCTAssertNotNil(summary?.submittedAt)
        XCTAssertNotNil(summary?.essayText)
        XCTAssertNotNil(summary?.takeaway)
    }

    func testCompletedFixtureHasExactlyThreeStandardSteps() {
        let store = ParentReflectionFixtureStore()

        store.simulateCompletion(childId: ChildProfile.previewLiam.id)

        let steps = store.summary(childId: ChildProfile.previewLiam.id)?.steps
        XCTAssertEqual(steps?.count, 3)
        XCTAssertEqual(steps?.map(\.kind), [.video, .quiz, .writing])
    }
}
