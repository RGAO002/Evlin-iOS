import XCTest
@testable import Evlin_iOS

final class MasterLockAccessibilityTests: XCTestCase {
    func testReflectionRemovesMasterControlFromAccessibilityTree() {
        XCTAssertEqual(
            EvlinV2MasterLockAccessibility.describe(.hiddenForReflection),
            .init(label: nil, enabled: false)
        )
    }

    func testEveryVisibleStableStateHasOneUnambiguousAction() {
        XCTAssertEqual(EvlinV2MasterLockAccessibility.describe(.lockApps).label, "Lock apps")
        XCTAssertEqual(EvlinV2MasterLockAccessibility.describe(.unlockDirect).label, "Unlock apps")
        XCTAssertEqual(
            EvlinV2MasterLockAccessibility.describe(.overrideActive(expiresAt: .distantFuture)).label,
            "Lock now"
        )
    }

    func testUpdatingStateCannotBeActivated() {
        XCTAssertFalse(EvlinV2MasterLockAccessibility.describe(.updating).enabled)
    }
}
