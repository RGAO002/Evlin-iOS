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

    private var profileViewSource: String {
        get throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "Evlin iOS/Views/Profile/ProfileView.swift"
                ),
                encoding: .utf8
            )
        }
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
        XCTAssertTrue(source.contains(".presentationDragIndicator(.hidden)"))
        XCTAssertTrue(source.contains(".presentationContentInteraction(.scrolls)"))
        XCTAssertTrue(source.contains(".interactiveDismissDisabled()"))
    }

    func testMasterUnlockActionsStayOutsideScrollableContent() throws {
        let source = try masterUnlockSheetSource

        XCTAssertFalse(source.contains(".safeAreaInset(edge: .bottom)"))
        XCTAssertTrue(source.contains("Divider()"))
    }

    func testTaskOverrideChoiceCapturesProjectionBeforeDialogDismissal() throws {
        let source = try profileViewSource

        XCTAssertTrue(source.contains("beginTaskOverrideChoice(.lockNow)"))
        XCTAssertTrue(source.contains("beginTaskOverrideChoice(.keepUnlocked)"))
        XCTAssertFalse(source.contains("Task { await resolveTaskOverrideChoice(.lockNow) }"))
        XCTAssertFalse(source.contains("Task { await resolveTaskOverrideChoice(.keepUnlocked) }"))
    }
}
