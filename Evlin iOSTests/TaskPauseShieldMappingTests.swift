import XCTest
@testable import Evlin_iOS

final class TaskPauseShieldMappingTests: XCTestCase {
    func test_wireLockSource_taskPause_mapsToTaskPauseSource() {
        XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: "task_pause"), [.taskPause])
    }

    func test_wireLockSource_earnedTime_stillMaps() {
        XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: "earned_time"), [.earnedTime])
    }

    func test_wireLockSource_unknown_defaultsToManual() {
        XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: nil), [.manual])
        XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: "schedule"), [.manual])
    }

    func test_shieldSource_rawValue_taskPause() {
        XCTAssertEqual(ShieldSource.taskPause.rawValue, "taskPause")
        XCTAssertEqual(ShieldSource(rawValue: "nope") ?? .manual, .manual)
    }
}
