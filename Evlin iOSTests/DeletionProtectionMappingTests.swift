import XCTest
@testable import Evlin_iOS

final class DeletionProtectionMappingTests: XCTestCase {
    func test_denyAppRemovalRestrictionClearsWhenProtectionDisabled() {
        XCTAssertEqual(ScreenTimeManager.deletionRestrictionValue(for: true), true)
        XCTAssertNil(ScreenTimeManager.deletionRestrictionValue(for: false))
    }

    func test_disablingDeletionProtectionUsesFullManagedSettingsResetPlan() {
        XCTAssertEqual(
            ScreenTimeManager.deletionProtectionApplyPlan(for: true),
            .setDenyAppRemoval(true)
        )
        XCTAssertEqual(
            ScreenTimeManager.deletionProtectionApplyPlan(for: false),
            .clearAllSettingsThenReapplyActiveLocks
        )
    }

    func test_parentControlsReappliesDeletionProtectionBeforeRefreshingStatus() {
        XCTAssertEqual(
            ParentControlsPresentation.appearActions,
            [.syncDeletionProtection, .refreshNotificationStatus]
        )
    }
}
