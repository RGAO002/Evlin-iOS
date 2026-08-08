import XCTest
@testable import Evlin_iOS

final class HomeSettingsSessionExitTests: XCTestCase {
    func testOrdinarySettingsDismissalDoesNotTearDownSession() {
        var coordinator = HomeSettingsSessionExitCoordinator()
        var teardownCount = 0

        coordinator.completeAfterDismissal {
            teardownCount += 1
        }

        XCTAssertEqual(teardownCount, 0)
    }

    func testSessionTeardownRunsOnlyAfterSettingsDismissesAndOnlyOnce() {
        var coordinator = HomeSettingsSessionExitCoordinator()
        var events: [String] = []

        coordinator.requestExit {
            events.append("dismiss")
        }
        coordinator.requestExit {
            events.append("duplicate dismiss")
        }

        XCTAssertEqual(events, ["dismiss"])

        coordinator.completeAfterDismissal {
            events.append("teardown")
        }
        coordinator.completeAfterDismissal {
            events.append("duplicate teardown")
        }

        XCTAssertEqual(events, ["dismiss", "teardown"])
    }
}
