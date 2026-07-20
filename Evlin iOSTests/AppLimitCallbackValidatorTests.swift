import CryptoKit
import Foundation
import XCTest
@testable import Evlin_iOS

final class AppLimitCallbackValidatorTests: XCTestCase {
    func testV2MeasurementAndEnforcementEventsCarryExplicitEffectKinds() throws {
        let measurement = try AppLimitCallbackFixture(budgetMinutes: 20)
        var measurementEffects = AppLimitCallbackEffectSpy()

        let measurementDecision = try measurement.validator.process(
            activityName: measurement.provenance.activityName,
            eventName: measurement.measurementEventName(5),
            canonicalUsageDate: measurement.usageDate,
            observedAt: measurement.observedAt(minutes: 5),
            usageCountingAllowed: true
        ) { callback in
            measurementEffects.record(callback)
        }

        XCTAssertAccepted(measurementDecision, kind: .measurement)
        XCTAssertEqual(
            measurementEffects,
            AppLimitCallbackEffectSpy(
                ledgerMutations: 1,
                networkRequests: 1,
                notifications: 0,
                shieldMutations: 0,
                scheduleMutations: 0,
                effectRuleIDs: [measurement.rule.id]
            )
        )

        let enforcement = try AppLimitCallbackFixture(budgetMinutes: 20)
        var enforcementEffects = AppLimitCallbackEffectSpy()

        let enforcementDecision = try enforcement.validator.process(
            activityName: enforcement.provenance.activityName,
            eventName: enforcement.enforcementEventName,
            canonicalUsageDate: enforcement.usageDate,
            observedAt: enforcement.observedAt(minutes: 20),
            usageCountingAllowed: true
        ) { callback in
            enforcementEffects.record(callback)
        }

        XCTAssertAccepted(enforcementDecision, kind: .enforcement)
        XCTAssertEqual(
            enforcementEffects,
            AppLimitCallbackEffectSpy(
                ledgerMutations: 1,
                networkRequests: 1,
                notifications: 1,
                shieldMutations: 1,
                scheduleMutations: 0,
                effectRuleIDs: [enforcement.rule.id]
            )
        )
    }

    func testAdjustedEstimateUsesBasePlusRawThresholdMinusPausedHighWater() throws {
        let measurement = try AppLimitCallbackFixture(
            budgetMinutes: 30,
            baseAcceptedMinutes: 10,
            ignoredWhilePausedMinutes: 3
        )
        var accepted: AppLimitValidatedCallback?

        _ = try measurement.validator.process(
            activityName: measurement.provenance.activityName,
            eventName: measurement.measurementEventName(10),
            canonicalUsageDate: measurement.usageDate,
            observedAt: measurement.observedAt(minutes: 7),
            usageCountingAllowed: true
        ) { callback in
            accepted = callback
        }

        XCTAssertEqual(accepted?.rawThresholdMinutes, 10)
        XCTAssertEqual(accepted?.adjustedEstimateMinutes, 17)

        let enforcement = try AppLimitCallbackFixture(
            budgetMinutes: 30,
            baseAcceptedMinutes: 10,
            ignoredWhilePausedMinutes: 3
        )
        accepted = nil

        _ = try enforcement.validator.process(
            activityName: enforcement.provenance.activityName,
            eventName: enforcement.enforcementEventName,
            canonicalUsageDate: enforcement.usageDate,
            observedAt: enforcement.observedAt(minutes: 17),
            usageCountingAllowed: true
        ) { callback in
            accepted = callback
        }

        XCTAssertEqual(accepted?.rawThresholdMinutes, 20)
        XCTAssertEqual(accepted?.adjustedEstimateMinutes, 27)
    }

    func testCorruptedDigestAndEveryStaleIdentityRejectBeforeEffects() throws {
        let wrongRuleID = UUID(uuidString: "10000000-0000-0000-0000-000000000099")!
        let wrongArmID = UUID(uuidString: "30000000-0000-0000-0000-000000000099")!
        let cases: [(String, AppLimitCallbackFixture, String, String, String)] = try [
            (
                "token digest",
                AppLimitCallbackFixture(tokenDigest: "corrupted"),
                "persisted",
                "enforcement",
                "2026-07-17"
            ),
            (
                "activity",
                AppLimitCallbackFixture(),
                "evlin.limit.v2.00000000-0000-0000-0000-000000000099",
                "enforcement",
                "2026-07-17"
            ),
            (
                "event arm",
                AppLimitCallbackFixture(),
                "persisted",
                "evlin.limit.v2.\(wrongArmID.uuidString.lowercased()).budget",
                "2026-07-17"
            ),
            (
                "unplanned measurement threshold",
                AppLimitCallbackFixture(budgetMinutes: 20),
                "persisted",
                "measurement6",
                "2026-07-17"
            ),
            (
                "usage date",
                AppLimitCallbackFixture(),
                "persisted",
                "enforcement",
                "2026-07-18"
            ),
            (
                "ordering token",
                AppLimitCallbackFixture(slotRevision: 8, provenanceRevision: 7),
                "persisted",
                "enforcement",
                "2026-07-17"
            ),
            (
                "rule identity",
                AppLimitCallbackFixture(provenanceRuleID: wrongRuleID),
                "persisted",
                "enforcement",
                "2026-07-17"
            ),
        ]

        for (name, fixture, activityValue, eventValue, usageDate) in cases {
            var effects = AppLimitCallbackEffectSpy()
            let activityName = activityValue == "persisted"
                ? fixture.provenance.activityName
                : activityValue
            let eventName = eventValue == "enforcement"
                ? fixture.enforcementEventName
                : eventValue == "measurement6"
                    ? fixture.measurementEventName(6)
                    : eventValue

            let decision = try fixture.validator.process(
                activityName: activityName,
                eventName: eventName,
                canonicalUsageDate: usageDate,
                observedAt: fixture.observedAt(minutes: 30),
                usageCountingAllowed: true
            ) { callback in
                effects.record(callback)
            }

            guard case .rejected = decision else {
                return XCTFail("\(name) must reject, got \(decision)")
            }
            XCTAssertEqual(effects, AppLimitCallbackEffectSpy(), name)
        }
    }

    func testPersistedActivityNameMustMatchPersistedArmIDBeforeEffects() throws {
        let corruptedActivityName = AppLimitPlanner.v2ActivityName(
            armID: UUID(uuidString: "30000000-0000-0000-0000-000000000099")!
        )
        let fixture = try AppLimitCallbackFixture(
            provenanceActivityName: corruptedActivityName
        )
        var effects = AppLimitCallbackEffectSpy()

        let decision = try fixture.validator.process(
            activityName: corruptedActivityName,
            eventName: fixture.enforcementEventName,
            canonicalUsageDate: fixture.usageDate,
            observedAt: fixture.observedAt(minutes: 30),
            usageCountingAllowed: true
        ) { callback in
            effects.record(callback)
        }

        XCTAssertEqual(decision, .rejected(reason: "stale_provenance"))
        XCTAssertEqual(effects, AppLimitCallbackEffectSpy())
    }

    func testImmediateImpossibleCallbackHasZeroEffectsButDelayedAndLateAccept() throws {
        let impossible = try AppLimitCallbackFixture(budgetMinutes: 30)
        var impossibleEffects = AppLimitCallbackEffectSpy()

        let impossibleDecision = try impossible.validator.process(
            activityName: impossible.provenance.activityName,
            eventName: impossible.enforcementEventName,
            canonicalUsageDate: impossible.usageDate,
            observedAt: impossible.provenance.startedAt,
            usageCountingAllowed: true
        ) { callback in
            impossibleEffects.record(callback)
        }

        guard case .rejected(reason: "physically_impossible") = impossibleDecision else {
            return XCTFail("immediate callback must be physically impossible")
        }
        XCTAssertEqual(impossibleEffects, AppLimitCallbackEffectSpy())

        for (name, elapsedMinutes) in [("delayed", 5), ("arbitrarily late", 50_000)] {
            let fixture = try AppLimitCallbackFixture(budgetMinutes: 20)
            var effects = AppLimitCallbackEffectSpy()
            let decision = try fixture.validator.process(
                activityName: fixture.provenance.activityName,
                eventName: fixture.measurementEventName(5),
                canonicalUsageDate: fixture.usageDate,
                observedAt: fixture.observedAt(minutes: elapsedMinutes),
                usageCountingAllowed: true
            ) { callback in
                effects.record(callback)
            }

            XCTAssertAccepted(decision, kind: .measurement, name)
            XCTAssertEqual(effects.ledgerMutations, 1, name)
            XCTAssertEqual(effects.networkRequests, 1, name)
            XCTAssertEqual(effects.notifications, 0, name)
            XCTAssertEqual(effects.shieldMutations, 0, name)
            XCTAssertEqual(effects.scheduleMutations, 0, name)
        }
    }
}

func XCTAssertAccepted(
    _ decision: AppLimitCallbackDecision,
    kind: AppLimitCallbackEffectKind,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .accepted(let callback) = decision else {
        return XCTFail("expected accepted callback, got \(decision). \(message)", file: file, line: line)
    }
    XCTAssertEqual(callback.effectKind, kind, message, file: file, line: line)
}

struct AppLimitCallbackEffectSpy: Equatable {
    var ledgerMutations = 0
    var networkRequests = 0
    var notifications = 0
    var shieldMutations = 0
    var scheduleMutations = 0
    var effectRuleIDs: [UUID] = []

    mutating func record(_ callback: AppLimitValidatedCallback) {
        ledgerMutations += 1
        networkRequests += 1
        effectRuleIDs.append(callback.rule.id)
        if callback.effectKind == .enforcement {
            notifications += 1
            shieldMutations += 1
        }
    }
}

final class AppLimitCallbackFixture {
    let directoryURL: URL
    let store: AppLimitEpochStore
    let validator: AppLimitCallbackValidator
    let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    let rule: AppLimitRule
    let provenance: AppLimitArmProvenance
    let usageDate = "2026-07-17"

    init(
        ruleID: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        armID: UUID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
        budgetMinutes: Int = 30,
        baseAcceptedMinutes: Int = 0,
        lastRawThresholdMinutes: Int = 0,
        ignoredWhilePausedMinutes: Int = 0,
        tokenDigest: String? = nil,
        slotRevision: Int64 = 7,
        provenanceRevision: Int64? = nil,
        provenanceRuleID: UUID? = nil,
        provenanceActivityName: String? = nil,
        additionalRule: AppLimitRule? = nil
    ) throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-limit-callback-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("store.json")
        store = AppLimitEpochStore(
            fileURL: fileURL,
            lock: ActiveLockPersistenceLock.shared,
            ownerProvider: { [owner] in owner },
            legacyDefaults: nil
        )
        validator = AppLimitCallbackValidator(store: store)
        rule = Self.makeRule(id: ruleID, budgetMinutes: budgetMinutes)
        let window = rule.window
        provenance = AppLimitArmProvenance(
            ruleID: provenanceRuleID ?? ruleID,
            ruleRevision: provenanceRevision ?? slotRevision,
            childDeviceID: owner,
            usageDate: usageDate,
            timezone: "America/New_York",
            scheduleWindow: window,
            tokenDigest: tokenDigest ?? Self.canonicalTokenDigest(rule),
            budgetMinutes: budgetMinutes,
            startedAt: Date(timeIntervalSince1970: 1_000),
            baseAcceptedMinutes: baseAcceptedMinutes,
            lastRawThresholdMinutes: lastRawThresholdMinutes,
            ignoredWhilePausedMinutes: ignoredWhilePausedMinutes,
            activityName: provenanceActivityName ?? AppLimitPlanner.v2ActivityName(armID: armID),
            armID: armID
        )
        let primarySlot = Self.makeSlot(
            rule: rule,
            revision: slotRevision,
            provenance: provenance
        )
        _ = try store.transaction(source: .poll, expectedOwner: owner) { state in
            state.slots[rule.id] = primarySlot
            if let additionalRule {
                state.slots[additionalRule.id] = Self.makeSlot(
                    rule: additionalRule,
                    revision: slotRevision,
                    provenance: nil
                )
            }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    var enforcementEventName: String {
        AppLimitPlanner.v2EnforcementEventName(armID: provenance.armID)
    }

    func measurementEventName(_ threshold: Int) -> String {
        AppLimitPlanner.v2MeasurementEventName(
            armID: provenance.armID,
            threshold: threshold
        )
    }

    func observedAt(minutes: Int) -> Date {
        provenance.startedAt.addingTimeInterval(TimeInterval(minutes * 60))
    }

    static func makeRule(
        id: UUID,
        budgetMinutes: Int = 30,
        bundleID: String = "com.example.focus"
    ) -> AppLimitRule {
        AppLimitRule(
            id: id,
            appTokens: [],
            bundleID: bundleID,
            displayName: "Focus",
            budgetMinutes: budgetMinutes,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/New_York"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 900),
            expiresAt: nil
        )
    }

    static func makeSlot(
        rule: AppLimitRule,
        revision: Int64,
        provenance: AppLimitArmProvenance?
    ) -> AppLimitVersionSlot {
        AppLimitVersionSlot(
            ruleID: rule.id,
            latestOrderingToken: revision,
            latestKind: .set,
            latestPayloadDigest: "digest-\(revision)",
            activeRule: rule,
            clearTombstone: nil,
            pendingOwnerWork: nil,
            appliedReceipt: nil,
            armProvenance: provenance
        )
    }

    static func canonicalTokenDigest(_ rule: AppLimitRule) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = rule.appTokens.compactMap { try? encoder.encode($0) }.sorted {
            $0.lexicographicallyPrecedes($1)
        }
        var bytes = Data()
        for token in encoded {
            var count = UInt64(token.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
            bytes.append(token)
        }
        return SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
