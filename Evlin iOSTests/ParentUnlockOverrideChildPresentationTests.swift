import Foundation
import XCTest
@testable import Evlin_iOS

final class ParentUnlockOverrideChildPresentationTests: XCTestCase {
    private let ownerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_777_255_200)

    func testChildHomeShowsUnlockedByParentWithRemainingMinutes() {
        let presentation = ParentUnlockOverrideChildPresentation.active(
            snapshot: snapshot(expiresAt: now.addingTimeInterval(12 * 60 + 1)),
            now: now,
            expectedOwner: ownerID
        )

        XCTAssertEqual(presentation?.remainingMinutes, 13)
        XCTAssertEqual(presentation?.label, "Unlocked by parent")
    }

    func testChildHomeDoesNotShowTimeUpWhileOverrideIsActive() {
        let presentation = ParentUnlockOverrideChildPresentation.active(
            snapshot: snapshot(expiresAt: now.addingTimeInterval(60)),
            now: now,
            expectedOwner: ownerID
        )

        XCTAssertFalse(
            ParentUnlockOverrideChildPresentation.shouldShowTimeUp(
                allTasksDone: true,
                minutesLeft: 0,
                activeOverride: presentation
            )
        )
    }

    private func snapshot(expiresAt: Date) -> ParentUnlockOverrideSnapshot {
        ParentUnlockOverrideSnapshot(
            envelope: ParentUnlockOverrideEnvelope(
                revision: 7,
                childDeviceID: ownerID,
                usageDate: "2026-04-26",
                startedAt: now,
                expiresAt: expiresAt,
                operationID: UUID(),
                scopes: [.manual],
                cancelled: false
            ),
            status: .active
        )
    }
}
