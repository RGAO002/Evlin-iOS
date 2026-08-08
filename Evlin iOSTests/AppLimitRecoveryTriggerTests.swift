import XCTest
@testable import Evlin_iOS

@MainActor
final class AppLimitRecoveryTriggerTests: XCTestCase {
    func testLifecycleRecoveryReprojectsRestrictionsAfterRecoveryAndRearm() async {
        var steps: [String] = []

        await AppLimitRecoveryTrigger.runLifecycleRecovery(
            convergeIdentity: { steps.append("identity") },
            recoverOwnerWork: { steps.append("owner") },
            recoverEffects: { steps.append("effects") },
            reconcileRules: { steps.append("rearm") },
            reapplyRestrictions: { steps.append("project") }
        )

        XCTAssertEqual(steps, ["identity", "owner", "effects", "rearm", "project"])
    }

    func testPollRecoveryReconcilesConsumedPhysicalEventsAfterDurableWork() async {
        var steps: [String] = []

        await AppLimitRecoveryTrigger.runPollRecovery(
            convergeIdentity: { steps.append("identity") },
            recoverOwnerWork: { steps.append("owner") },
            recoverEffects: { steps.append("effects") },
            reconcileConsumedPhysicalEvents: { steps.append("physical") }
        )

        XCTAssertEqual(steps, ["identity", "owner", "effects", "physical"])
    }

    func testPollPhysicalRecoveryRequiresCurrentOwnerSetSlotWithConsumedMarker() {
        let owner = UUID()
        let ruleID = UUID()
        let armID = UUID()
        var provenance = AppLimitArmProvenance(
            ruleID: ruleID,
            ruleRevision: 1,
            childDeviceID: owner,
            usageDate: "2026-08-03",
            timezone: "America/New_York",
            scheduleWindow: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/New_York"
            ),
            tokenDigest: "digest",
            budgetMinutes: 15,
            startedAt: Date(timeIntervalSince1970: 1_785_798_167),
            baseAcceptedMinutes: 0,
            lastRawThresholdMinutes: 0,
            ignoredWhilePausedMinutes: 0,
            activityName: "evlin.limit.v2.\(armID.uuidString.lowercased())",
            armID: armID
        )
        provenance.physicalEventsConsumedAt = Date(timeIntervalSince1970: 1_785_798_178)
        var slot = AppLimitVersionSlot(
            ruleID: ruleID,
            latestOrderingToken: 1,
            latestKind: .set,
            latestPayloadDigest: "payload",
            activeRule: nil,
            clearTombstone: nil,
            pendingOwnerWork: nil,
            appliedReceipt: nil,
            armProvenance: provenance
        )

        XCTAssertFalse(AppLimitRecoveryTrigger.shouldReconcileConsumedPhysicalEvents(
            state: AppLimitEpochStoreState(ownerChildDeviceID: owner),
            owner: owner
        ))
        XCTAssertFalse(AppLimitRecoveryTrigger.shouldReconcileConsumedPhysicalEvents(
            state: AppLimitEpochStoreState(
                ownerChildDeviceID: UUID(),
                slots: [ruleID: slot]
            ),
            owner: owner
        ))
        XCTAssertTrue(AppLimitRecoveryTrigger.shouldReconcileConsumedPhysicalEvents(
            state: AppLimitEpochStoreState(
                ownerChildDeviceID: owner,
                slots: [ruleID: slot]
            ),
            owner: owner
        ))

        slot.latestKind = .clear
        XCTAssertFalse(AppLimitRecoveryTrigger.shouldReconcileConsumedPhysicalEvents(
            state: AppLimitEpochStoreState(
                ownerChildDeviceID: owner,
                slots: [ruleID: slot]
            ),
            owner: owner
        ))
    }
}
