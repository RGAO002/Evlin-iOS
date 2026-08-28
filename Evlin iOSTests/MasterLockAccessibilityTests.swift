import XCTest
@testable import Evlin_iOS

final class MasterLockAccessibilityTests: XCTestCase {
    private var masterUnlockSheetSource: String {
        get throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "Evlin iOS/Views/Profile/EvlinV2MasterUnlockSheet.swift"
                ),
                encoding: .utf8
            )
        }
    }

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

    func testMasterUnlockSheetUsesOneStableHeight() throws {
        let source = try masterUnlockSheetSource

        XCTAssertTrue(source.contains(".presentationDetents([.large])"))
        XCTAssertFalse(source.contains(".presentationDetents([.medium, .large])"))
    }

    func testMasterUnlockActionsStayOutsideScrollableContent() throws {
        let source = try masterUnlockSheetSource

        XCTAssertTrue(source.contains(".safeAreaInset(edge: .bottom)"))
    }
}
