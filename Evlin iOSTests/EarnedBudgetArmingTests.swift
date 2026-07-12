import XCTest
@testable import Evlin_iOS

@MainActor
final class EarnedBudgetArmingTests: XCTestCase {
    func test_acceptedAdvanceDoesNotChangeSignatureForRunningOffset() {
        let base = EarnedBudgetArming.makeArmSignature(
            deviceID: "b21411cb-63a5-4489-bc68-bf8ac26ee15b",
            usageDate: "2026-07-03",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 15,
            capMinutes: 15,
            offsetMinutes: 0,
            selectionFingerprint: "selection-a"
        )
        let afterAcceptedT5 = EarnedBudgetArming.makeArmSignature(
            deviceID: "b21411cb-63a5-4489-bc68-bf8ac26ee15b",
            usageDate: "2026-07-03",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 15,
            capMinutes: 15,
            offsetMinutes: 0,
            selectionFingerprint: "selection-a"
        )

        XCTAssertEqual(base, afterAcceptedT5)
        XCTAssertFalse(EarnedBudgetArming.shouldStartMonitoring(
            previousSignature: base,
            nextSignature: afterAcceptedT5,
            force: false
        ))
    }

    func test_realReplacementUsesAcceptedEstimateAsNewOffset() {
        XCTAssertEqual(
            EarnedBudgetArming.replacementOffset(
                acceptedEstimateMinutes: 15,
                runningOffsetMinutes: 5
            ),
            15
        )
        XCTAssertEqual(
            EarnedBudgetArming.replacementOffset(
                acceptedEstimateMinutes: nil,
                runningOffsetMinutes: 5
            ),
            5
        )
    }

    func test_failedReplacementPreservesOffsetSignatureAndGeneration() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(suiteName: suiteName)
        let priorGeneration = EarnedActivityGeneration.generatedActivityName(id: UUID())
        store.earnedUsageOffsetMinutes = 5
        defaults.set("old-signature", forKey: EarnedBudgetArming.armSignatureKey)
        defaults.set(priorGeneration, forKey: EarnedActivityGeneration.activeActivityNameKey)

        let installed = EarnedBudgetArming.installReplacement(
            replacementOffset: 15,
            replacementSignature: "new-signature",
            store: store,
            defaults: defaults,
            startMonitoring: { false }
        )

        XCTAssertFalse(installed)
        XCTAssertEqual(store.earnedUsageOffsetMinutes, 5)
        XCTAssertEqual(defaults.string(forKey: EarnedBudgetArming.armSignatureKey), "old-signature")
        XCTAssertEqual(
            defaults.string(forKey: EarnedActivityGeneration.activeActivityNameKey),
            priorGeneration
        )
    }

    func test_stopInvalidatesSignatureSoFalseToTrueReinstallsExactlyOnce() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("stable-signature", forKey: EarnedBudgetArming.armSignatureKey)
        var stopCount = 0

        EarnedBudgetArming.stopAndInvalidateSignature(
            defaults: defaults,
            stopMonitoring: { stopCount += 1 }
        )

        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(defaults.string(forKey: EarnedBudgetArming.armSignatureKey))
        XCTAssertTrue(EarnedBudgetArming.shouldStartMonitoring(
            previousSignature: defaults.string(forKey: EarnedBudgetArming.armSignatureKey),
            nextSignature: "stable-signature",
            force: false
        ))
        defaults.set("stable-signature", forKey: EarnedBudgetArming.armSignatureKey)
        XCTAssertFalse(EarnedBudgetArming.shouldStartMonitoring(
            previousSignature: defaults.string(forKey: EarnedBudgetArming.armSignatureKey),
            nextSignature: "stable-signature",
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
