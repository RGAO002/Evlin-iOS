import XCTest
@testable import Evlin_iOS

final class BigKidRouterTests: XCTestCase {
    func testHomeWhenNothingActive() {
        let s = BigKidState(snapshot: .fixture(tasks: [.fixture(status: .todo)]))
        XCTAssertEqual(BigKidRouter.route(s), .home)
    }

    func testHomeReflectionAWhileInProgress() {
        let r = ReflectionRequest.fixture(status: .pending,
                                          stepsCompleted: [.video])
        let s = BigKidState(snapshot: .fixture(reflection: r))
        XCTAssertEqual(BigKidRouter.route(s), .homeReflectionA)
    }

    func testHomeReflectionBWhenAllStepsDone() {
        let r = ReflectionRequest.fixture(status: .submitted,
                                          stepsCompleted: [.video, .quiz, .writing])
        let s = BigKidState(snapshot: .fixture(reflection: r))
        XCTAssertEqual(BigKidRouter.route(s), .homeReflectionB)
    }

    func testCompleteWhenApprovedNotAcked() {
        let r = ReflectionRequest.fixture(status: .approved,
                                          stepsCompleted: [.video, .quiz, .writing])
        let s = BigKidState(snapshot: .fixture(reflection: r))
        XCTAssertEqual(BigKidRouter.route(s), .complete)
    }

    func testDailyCompleteWhenAllTasksDoneNotAcked() {
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)],
            minutesLeft: 120, dailyAck: false
        ))
        XCTAssertEqual(BigKidRouter.route(s), .dailyComplete)
    }

    func testHomeOnceDailyCompleteAcked() {
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)],
            minutesLeft: 120, dailyAck: true
        ))
        XCTAssertEqual(BigKidRouter.route(s), .home)
    }

    func testScreenTimeFinishedWhenZeroMinutes() {
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)],
            minutesLeft: 0, dailyAck: true, timeAck: false
        ))
        XCTAssertEqual(BigKidRouter.route(s), .screenTimeFinished)
    }

    func testHomeOnceScreenTimeFinishedAcked() {
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)],
            minutesLeft: 0, dailyAck: true, timeAck: true
        ))
        XCTAssertEqual(BigKidRouter.route(s), .home)
    }

    func testApprovedBypassCountsTowardAllDone() {
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .todo, bypass: .fixture(status: .approved))],
            minutesLeft: 120, dailyAck: false
        ))
        XCTAssertEqual(BigKidRouter.route(s), .dailyComplete)
    }

    func testReflectionApprovedTakesPriorityOverDailyComplete() {
        let r = ReflectionRequest.fixture(status: .approved,
                                          stepsCompleted: [.video, .quiz, .writing])
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)],
            reflection: r, minutesLeft: 120, dailyAck: false
        ))
        XCTAssertEqual(BigKidRouter.route(s), .complete)
    }
}
