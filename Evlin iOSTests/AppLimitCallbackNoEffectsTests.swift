import Foundation
import XCTest
@testable import Evlin_iOS

final class AppLimitCallbackNoEffectsTests: XCTestCase {
    func testAcceptedCallbackInvokesEffectExactlyOnceAndDuplicateInvokesNone() throws {
        let fixture = try AppLimitCallbackFixture(budgetMinutes: 20)
        var effects = AppLimitCallbackEffectSpy()

        let first = try fixture.validator.process(
            activityName: fixture.provenance.activityName,
            eventName: fixture.measurementEventName(5),
            canonicalUsageDate: fixture.usageDate,
            observedAt: fixture.observedAt(minutes: 5),
            usageCountingAllowed: true
        ) { callback in
            effects.record(callback)
        }
        let duplicate = try fixture.validator.process(
            activityName: fixture.provenance.activityName,
            eventName: fixture.measurementEventName(5),
            canonicalUsageDate: fixture.usageDate,
            observedAt: fixture.observedAt(minutes: 6),
            usageCountingAllowed: true
        ) { callback in
            effects.record(callback)
        }

        XCTAssertAccepted(first, kind: .measurement)
        guard case .rejected = duplicate else {
            return XCTFail("duplicate callback must reject")
        }
        XCTAssertEqual(effects.ledgerMutations, 1)
        XCTAssertEqual(effects.networkRequests, 1)
        XCTAssertEqual(effects.notifications, 0)
        XCTAssertEqual(effects.shieldMutations, 0)
        XCTAssertEqual(effects.scheduleMutations, 0)
        XCTAssertEqual(
            try fixture.store.read().slots[fixture.rule.id]?.armProvenance?.lastRawThresholdMinutes,
            5
        )
    }

    func testHigherCallbackFromSameValidatedSnapshotWinsAfterLowerHighWaterCommits() throws {
        let fixture = try AppLimitCallbackFixture(budgetMinutes: 20)
        let lowDecision = try fixture.validator.validate(
            activityName: fixture.provenance.activityName,
            eventName: fixture.measurementEventName(5),
            canonicalUsageDate: fixture.usageDate,
            observedAt: fixture.observedAt(minutes: 10),
            usageCountingAllowed: true
        )
        let highDecision = try fixture.validator.validate(
            activityName: fixture.provenance.activityName,
            eventName: fixture.measurementEventName(10),
            canonicalUsageDate: fixture.usageDate,
            observedAt: fixture.observedAt(minutes: 10),
            usageCountingAllowed: true
        )
        guard case .accepted(let low) = lowDecision,
              case .accepted(let high) = highDecision else {
            return XCTFail("both callbacks must validate against the same initial snapshot")
        }

        XCTAssertTrue(try fixture.validator.recordAcceptedHighWater(low))
        XCTAssertTrue(try fixture.validator.recordAcceptedHighWater(high))
        XCTAssertEqual(
            try fixture.store.read().slots[fixture.rule.id]?.armProvenance?.lastRawThresholdMinutes,
            10
        )
    }

    func testPausedCallbackUpdatesOnlyIgnoredHighWaterWithEveryEffectZero() throws {
        let fixture = try AppLimitCallbackFixture(budgetMinutes: 20)
        var effects = AppLimitCallbackEffectSpy()

        let decision = try fixture.validator.process(
            activityName: fixture.provenance.activityName,
            eventName: fixture.measurementEventName(5),
            canonicalUsageDate: fixture.usageDate,
            observedAt: fixture.provenance.startedAt,
            usageCountingAllowed: false
        ) { callback in
            effects.record(callback)
        }

        guard case .paused(let callback) = decision else {
            return XCTFail("paused callback must return paused")
        }
        XCTAssertEqual(callback.effectKind, .measurement)
        XCTAssertEqual(effects, AppLimitCallbackEffectSpy())
        let persisted = try fixture.store.read().slots[fixture.rule.id]?.armProvenance
        XCTAssertEqual(persisted?.ignoredWhilePausedMinutes, 5)
        XCTAssertEqual(persisted?.lastRawThresholdMinutes, 0)
    }

    func testTwoRuleStoreMutatesOnlyMatchingHighWaterAndEffectIdentity() throws {
        let unrelatedRule = AppLimitCallbackFixture.makeRule(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            budgetMinutes: 45,
            bundleID: "com.example.unrelated"
        )
        let fixture = try AppLimitCallbackFixture(
            budgetMinutes: 20,
            additionalRule: unrelatedRule
        )
        let unrelatedArm = AppLimitArmProvenance(
            ruleID: unrelatedRule.id,
            ruleRevision: 7,
            childDeviceID: fixture.owner,
            usageDate: fixture.usageDate,
            timezone: "America/New_York",
            scheduleWindow: unrelatedRule.window,
            tokenDigest: AppLimitCallbackFixture.canonicalTokenDigest(unrelatedRule),
            budgetMinutes: unrelatedRule.budgetMinutes,
            startedAt: fixture.provenance.startedAt,
            baseAcceptedMinutes: 11,
            lastRawThresholdMinutes: 9,
            ignoredWhilePausedMinutes: 4,
            activityName: AppLimitPlanner.v2ActivityName(
                armID: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
            ),
            armID: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        )
        _ = try fixture.store.transaction(source: .wakeRecovery, expectedOwner: fixture.owner) { state in
            var slot = state.slots[unrelatedRule.id]!
            slot.armProvenance = unrelatedArm
            state.slots[unrelatedRule.id] = slot
        }
        let unrelatedBefore = try fixture.store.read().slots[unrelatedRule.id]
        var effects = AppLimitCallbackEffectSpy()

        _ = try fixture.validator.process(
            activityName: fixture.provenance.activityName,
            eventName: fixture.measurementEventName(5),
            canonicalUsageDate: fixture.usageDate,
            observedAt: fixture.observedAt(minutes: 5),
            usageCountingAllowed: true
        ) { callback in
            effects.record(callback)
        }

        let state = try fixture.store.read()
        XCTAssertEqual(
            state.slots[fixture.rule.id]?.armProvenance?.lastRawThresholdMinutes,
            5
        )
        XCTAssertEqual(state.slots[unrelatedRule.id], unrelatedBefore)
        XCTAssertEqual(effects.effectRuleIDs, [fixture.rule.id])
        XCTAssertEqual(effects.ledgerMutations, 1)
        XCTAssertEqual(effects.networkRequests, 1)
        XCTAssertEqual(effects.notifications, 0)
        XCTAssertEqual(effects.shieldMutations, 0)
        XCTAssertEqual(effects.scheduleMutations, 0)
    }

    func testP4V20EnforcementMutatesOnlyTargetProductionLedgerAndShield() throws {
        let fixture = try AppLimitCallbackFixture(budgetMinutes: 20)
        let unrelatedRuleID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let suiteName = "AppLimitCallbackNoEffectsTests.P4V20.\(UUID().uuidString)"
        let usageStore = EarnedTimeStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        usageStore.poolMinutes = 120
        usageStore.capMinutes = 60
        usageStore.backendRemainingAtLastSync = 42
        usageStore.latestDeviceEstimate = 18
        usageStore.recordAppLimitUsage(
            ruleID: fixture.rule.id,
            usageDate: fixture.usageDate,
            usedMinutes: 4
        )
        usageStore.recordAppLimitUsage(
            ruleID: unrelatedRuleID,
            usageDate: fixture.usageDate,
            usedMinutes: 11
        )
        let manual = makeShieldRecord(
            recordKey: "exactApp:com.example.manual",
            tier: .exactApp,
            targetKey: "com.example.manual",
            sources: [.manual]
        )
        let earned = makeShieldRecord(
            recordKey: "savedList:40000000-0000-0000-0000-000000000001",
            tier: .savedList,
            targetKey: "40000000-0000-0000-0000-000000000001",
            sources: [.earnedTime]
        )
        let shieldsBefore = [manual.recordKey: manual, earned.recordKey: earned]
        var shields = shieldsBefore
        var acceptedEstimate: Int?
        var networkRequests = 0
        var notifications = 0
        let scheduleMutations = 0

        let decision = try fixture.validator.process(
            activityName: fixture.provenance.activityName,
            eventName: fixture.enforcementEventName,
            canonicalUsageDate: fixture.usageDate,
            observedAt: fixture.observedAt(minutes: 20),
            usageCountingAllowed: true
        ) { callback in
            acceptedEstimate = callback.adjustedEstimateMinutes
            try AppLimitCallbackLocalLedger.record(callback, store: usageStore)
            shields = LimitShieldLogic.applyingLimit(
                to: shields,
                rule: callback.rule,
                now: callback.provenance.startedAt
            )
            networkRequests += 1
            if callback.effectKind == .enforcement { notifications += 1 }
        }

        XCTAssertAccepted(decision, kind: .enforcement)
        XCTAssertEqual(acceptedEstimate, 20)
        XCTAssertEqual(
            usageStore.appLimitReportedMinutes(
                ruleID: fixture.rule.id,
                usageDate: fixture.usageDate
            ),
            acceptedEstimate
        )
        XCTAssertEqual(
            usageStore.appLimitReportedMinutes(
                ruleID: unrelatedRuleID,
                usageDate: fixture.usageDate
            ),
            11
        )
        XCTAssertEqual(usageStore.poolMinutes, 120)
        XCTAssertEqual(usageStore.capMinutes, 60)
        XCTAssertEqual(usageStore.backendRemainingAtLastSync, 42)
        XCTAssertEqual(usageStore.latestDeviceEstimate, 18)
        let targetKey = LimitShieldLogic.recordKey(for: fixture.rule)
        let record = try XCTUnwrap(shields[targetKey])
        XCTAssertEqual(record.sources, [.limit])
        XCTAssertEqual(record.lastCommandID, fixture.rule.id)
        XCTAssertEqual(record.targetKey, LimitShieldLogic.targetKey(for: fixture.rule))
        XCTAssertEqual(record.appTokens, fixture.rule.appTokens)
        XCTAssertEqual(shields[manual.recordKey], manual)
        XCTAssertEqual(shields[earned.recordKey], earned)
        XCTAssertEqual(Set(shields.keys).subtracting(shieldsBefore.keys), [targetKey])
        let addedRecords = shields.filter { shieldsBefore[$0.key] == nil }.map(\.value)
        XCTAssertTrue(addedRecords.allSatisfy {
            $0.tier == .exactApp && $0.sources == [.limit]
        })
        XCTAssertEqual(networkRequests, 1)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(scheduleMutations, 0)
    }

    private func makeShieldRecord(
        recordKey: String,
        tier: ShieldTier,
        targetKey: String,
        sources: Set<ShieldSource>
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: recordKey,
            tier: tier,
            targetKey: targetKey,
            displayName: targetKey,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 2_000),
            expiresAt: nil,
            originalRequest: "seeded unrelated shield",
            targetChildID: UUID(),
            sources: sources
        )
    }
}
