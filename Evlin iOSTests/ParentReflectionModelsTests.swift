import XCTest
@testable import Evlin_iOS

final class ParentReflectionModelsTests: XCTestCase {
    func testStoreStartsWithoutReflectionSummary() {
        let store = ParentReflectionFixtureStore()

        let summary = store.summary(for: .liam)

        XCTAssertNil(summary)
    }

    func testSimulateAssignmentCreatesLiamPendingSummary() {
        let store = ParentReflectionFixtureStore()

        store.simulateAssignment(childId: ChildProfile.liam.id)

        let summary = store.summary(for: .liam)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.childId, ChildProfile.liam.id)
        XCTAssertEqual(summary?.childName, ChildProfile.liam.name)
        XCTAssertEqual(summary?.state, .assignedPending)
        XCTAssertNil(summary?.submittedAt)
        XCTAssertNil(summary?.essayText)
        XCTAssertNil(summary?.takeaway)
    }

    func testSimulateCompletionFlipsLiamToCompletedReady() {
        let store = ParentReflectionFixtureStore()

        store.simulateCompletion(childId: ChildProfile.liam.id)

        let summary = store.summary(childId: ChildProfile.liam.id)
        XCTAssertEqual(summary?.state, .completedReady)
        XCTAssertNotNil(summary?.submittedAt)
        XCTAssertNotNil(summary?.essayText)
        XCTAssertNotNil(summary?.takeaway)
    }

    func testCompletedFixtureHasExactlyThreeStandardSteps() {
        let store = ParentReflectionFixtureStore()

        store.simulateCompletion(childId: ChildProfile.liam.id)

        let steps = store.summary(childId: ChildProfile.liam.id)?.steps
        XCTAssertEqual(steps?.count, 3)
        XCTAssertEqual(steps?.map(\.kind), [.video, .quiz, .writing])
    }
}
