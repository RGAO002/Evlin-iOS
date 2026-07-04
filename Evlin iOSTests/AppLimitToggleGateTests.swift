import XCTest
@testable import Evlin_iOS

/// Phantom-toggle hardening — the row no longer forwards arbitrary
/// `Toggle(isOn:)` setter calls to the network. A direct tap on the row's
/// switch control creates one explicit intent for that row: flip its current
/// state. Programmatic SwiftUI binding churn should not be part of this path.
final class AppLimitToggleIntentTests: XCTestCase {

    func test_explicitTapRequestsOppositeOfCurrentState() {
        XCTAssertFalse(AppLimitToggleIntent.nextValue(currentEnabled: true))
        XCTAssertTrue(AppLimitToggleIntent.nextValue(currentEnabled: false))
    }
}
