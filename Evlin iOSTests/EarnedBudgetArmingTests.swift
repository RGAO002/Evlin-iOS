import XCTest
@testable import Evlin_iOS

final class EarnedBudgetArmingTests: XCTestCase {
    func test_armSignatureChangesWhenAcceptedOffsetChanges() {
        let base = EarnedBudgetArming.makeArmSignature(
            deviceID: "b21411cb-63a5-4489-bc68-bf8ac26ee15b",
            usageDate: "2026-07-03",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 15,
            capMinutes: 15,
            offsetMinutes: 0,
            selectionFingerprint: "selection-a"
        )
        let afterT5 = EarnedBudgetArming.makeArmSignature(
            deviceID: "b21411cb-63a5-4489-bc68-bf8ac26ee15b",
            usageDate: "2026-07-03",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 15,
            capMinutes: 15,
            offsetMinutes: 5,
            selectionFingerprint: "selection-a"
        )

        XCTAssertNotEqual(base, afterT5)
        XCTAssertTrue(EarnedBudgetArming.shouldStartMonitoring(
            previousSignature: base,
            nextSignature: afterT5,
            force: false
        ))
    }

    func test_armSignatureSkipsWhenIdentityDatePolicySelectionAndOffsetAreUnchanged() {
        let base = EarnedBudgetArming.makeArmSignature(
            deviceID: "device-a",
            usageDate: "2026-07-03",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 15,
            capMinutes: 15,
            offsetMinutes: 5,
            selectionFingerprint: "selection-a"
        )

        let unchanged = EarnedBudgetArming.makeArmSignature(
            deviceID: "device-a",
            usageDate: "2026-07-03",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 15,
            capMinutes: 15,
            offsetMinutes: 5,
            selectionFingerprint: "selection-a"
        )

        XCTAssertEqual(base, unchanged)
        XCTAssertFalse(EarnedBudgetArming.shouldStartMonitoring(
            previousSignature: base,
            nextSignature: unchanged,
            force: false
        ))
    }

    func test_armSignatureChangesWhenPolicyOrSelectionChanges() {
        let base = EarnedBudgetArming.makeArmSignature(
            deviceID: "device-a",
            usageDate: "2026-07-03",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 15,
            capMinutes: 15,
            offsetMinutes: 5,
            selectionFingerprint: "selection-a"
        )

        XCTAssertNotEqual(base, EarnedBudgetArming.makeArmSignature(
            deviceID: "device-a",
            usageDate: "2026-07-03",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 20,
            capMinutes: 15,
            offsetMinutes: 5,
            selectionFingerprint: "selection-a"
        ))
        XCTAssertNotEqual(base, EarnedBudgetArming.makeArmSignature(
            deviceID: "device-a",
            usageDate: "2026-07-03",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 15,
            capMinutes: 15,
            offsetMinutes: 5,
            selectionFingerprint: "selection-b"
        ))
        XCTAssertTrue(EarnedBudgetArming.shouldStartMonitoring(previousSignature: base, nextSignature: base, force: true))
    }
}
