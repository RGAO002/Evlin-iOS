import Foundation
import XCTest
@testable import Evlin_iOS

private struct TestMeteringClock: MeteringClock {
    var now: Date
}

private enum FakeMonitorError: Error {
    case installFailed
}

private struct FakeMonitorInstaller: MeteringMonitorInstalling {
    var installed: [MeteringGenerationKey] = []
    var stopped: [MeteringGenerationKey] = []
    var failNextInstall = false

    mutating func install(_ key: MeteringGenerationKey) throws {
        installed.append(key)
        if failNextInstall {
            failNextInstall = false
            throw FakeMonitorError.installFailed
        }
    }

    mutating func stop(_ key: MeteringGenerationKey) {
        stopped.append(key)
    }
}

final class MeteringEpochContractTests: XCTestCase {
    private static let childDeviceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let otherChildDeviceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let enforcementSetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let otherEnforcementSetID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let activeEpochID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private static let otherEpochID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private static let startedAt = Date(timeIntervalSince1970: 1_784_179_200)

    private func generationKey(
        protocolVersion: Int = 1,
        childDeviceID: UUID = MeteringEpochContractTests.childDeviceID,
        canonicalTimezone: String = "America/New_York",
        policyRevision: String = "policy-1",
        measurementSelectionDigest: String = "digest-1",
        enforcementSetID: UUID = MeteringEpochContractTests.enforcementSetID,
        offsetMinutes _: Int = 0,
        adjustedEstimateMinutes _: Int = 0
    ) -> MeteringGenerationKey {
        MeteringGenerationKey(
            protocolVersion: protocolVersion,
            childDeviceID: childDeviceID,
            canonicalTimezone: canonicalTimezone,
            policyRevision: policyRevision,
            measurementSelectionDigest: measurementSelectionDigest,
            enforcementSetID: enforcementSetID
        )
    }

    private func epochKey(
        protocolVersion: Int = 1,
        childDeviceID: UUID = MeteringEpochContractTests.childDeviceID,
        usageDate: String = "2026-07-16",
        canonicalTimezone: String = "America/New_York",
        policyRevision: String = "policy-1",
        measurementSelectionDigest: String = "digest-1",
        enforcementSetID: UUID = MeteringEpochContractTests.enforcementSetID
    ) -> MeteringEpochKey {
        MeteringEpochKey(
            protocolVersion: protocolVersion,
            childDeviceID: childDeviceID,
            usageDate: usageDate,
            canonicalTimezone: canonicalTimezone,
            policyRevision: policyRevision,
            measurementSelectionDigest: measurementSelectionDigest,
            enforcementSetID: enforcementSetID
        )
    }

    private func callbackInput(
        callbackEpochID: UUID = MeteringEpochContractTests.activeEpochID,
        callbackOwnerDeviceID: UUID = MeteringEpochContractTests.childDeviceID,
        callbackUsageDate: String = "2026-07-16",
        callbackPolicyRevision: String = "policy-1",
        callbackEventNamespace: String = "metering.v1",
        adjustedEstimateMinutes: Int = 5,
        baseAcceptedMinutes: Int = 0,
        callbackAt: Date = MeteringEpochContractTests.startedAt.addingTimeInterval(300),
        jitterSeconds: Int = MeteringEpochContract.defaultJitterSeconds
    ) -> MeteringCallbackInput {
        MeteringCallbackInput(
            activeEpochID: Self.activeEpochID,
            callbackEpochID: callbackEpochID,
            activeOwnerDeviceID: Self.childDeviceID,
            callbackOwnerDeviceID: callbackOwnerDeviceID,
            activeUsageDate: "2026-07-16",
            callbackUsageDate: callbackUsageDate,
            activePolicyRevision: "policy-1",
            callbackPolicyRevision: callbackPolicyRevision,
            expectedEventNamespace: "metering.v1",
            callbackEventNamespace: callbackEventNamespace,
            adjustedEstimateMinutes: adjustedEstimateMinutes,
            baseAcceptedMinutes: baseAcceptedMinutes,
            startedAt: Self.startedAt,
            callbackAt: callbackAt,
            jitterSeconds: jitterSeconds
        )
    }

    func testGenerationIdentityIgnoresMutableOffsetAndEstimate() {
        let first = generationKey(offsetMinutes: 5, adjustedEstimateMinutes: 10)
        let second = generationKey(offsetMinutes: 500, adjustedEstimateMinutes: 1_000)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            MeteringEpochContract.generationDecision(active: first, next: second),
            .keep
        )
    }

    func testGenerationIdentityContainsExactlySixStableFields() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(generationKey()))
                as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), [
            "protocolVersion",
            "childDeviceID",
            "canonicalTimezone",
            "policyRevision",
            "measurementSelectionDigest",
            "enforcementSetID"
        ])
    }

    func testSelectionDigestHashesExactPersistedBytesAsLowercaseHex() {
        let persistedBytes = Data([0x00, 0xff, 0x0a, 0x41])

        let digest = MeteringEpochContract.selectionDigest(persistedBytes: persistedBytes)

        XCTAssertEqual(digest, "8fc3156c066463c772e9493b112bec494bc8d5ba3f9a1198837a2e404ee793fd")
        XCTAssertEqual(digest.count, 64)
        XCTAssertNotNil(digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
    }

    func testChangingAnyStableGenerationFieldChangesIdentity() {
        let active = generationKey()
        let variants = [
            generationKey(protocolVersion: 2),
            generationKey(childDeviceID: Self.otherChildDeviceID),
            generationKey(canonicalTimezone: "UTC"),
            generationKey(policyRevision: "policy-2"),
            generationKey(measurementSelectionDigest: "digest-2"),
            generationKey(enforcementSetID: Self.otherEnforcementSetID)
        ]

        for variant in variants {
            XCTAssertNotEqual(active, variant)
            XCTAssertEqual(
                MeteringEpochContract.generationDecision(active: active, next: variant),
                .install(variant)
            )
        }
    }

    func testRepeatedReconcileAcrossTwentyVirtualMinutesInstallsOnce() throws {
        let start = Self.startedAt
        var clock = TestMeteringClock(now: start)
        var installer = FakeMonitorInstaller()
        var reconciler = MeteringGenerationReconciler()
        let next = generationKey()

        for tick in 0...120 {
            clock.now = start.addingTimeInterval(TimeInterval(tick * 10))
            try reconciler.reconcile(next: next, installer: &installer)
        }

        XCTAssertEqual(clock.now.timeIntervalSince(start), 20 * 60)
        XCTAssertEqual(installer.installed, [next])
        XCTAssertTrue(installer.stopped.isEmpty)
        XCTAssertEqual(reconciler.active, next)
    }

    func testFailedReplacementInstallPreservesPreviousActiveKey() throws {
        let previous = generationKey()
        let replacement = generationKey(policyRevision: "policy-2")
        var installer = FakeMonitorInstaller()
        var reconciler = MeteringGenerationReconciler()
        try reconciler.reconcile(next: previous, installer: &installer)
        installer.failNextInstall = true

        XCTAssertThrowsError(
            try reconciler.reconcile(next: replacement, installer: &installer)
        )
        XCTAssertEqual(reconciler.active, previous)
        XCTAssertTrue(installer.stopped.isEmpty)
    }

    func testSuccessfulReplacementInstallsBeforeStoppingPreviousKey() throws {
        let previous = generationKey()
        let replacement = generationKey(policyRevision: "policy-2")
        var installer = FakeMonitorInstaller()
        var reconciler = MeteringGenerationReconciler()

        try reconciler.reconcile(next: previous, installer: &installer)
        try reconciler.reconcile(next: replacement, installer: &installer)

        XCTAssertEqual(installer.installed, [previous, replacement])
        XCTAssertEqual(installer.stopped, [previous])
        XCTAssertEqual(reconciler.active, replacement)
    }

    func testDeltaFiveAtOneSecondRejectsTooEarlyWithZeroEffects() {
        let input = callbackInput(callbackAt: Self.startedAt.addingTimeInterval(1))

        let verdict = MeteringEpochContract.callbackVerdict(input)

        XCTAssertEqual(verdict, .rejectTooEarly)
        XCTAssertEqual(MeteringEpochContract.effects(for: verdict), MeteringEffects())
    }

    func testDeltaFiveAtFiveMinutesAccepts() {
        XCTAssertEqual(
            MeteringEpochContract.callbackVerdict(callbackInput()),
            .accept
        )
    }

    func testLateCallbackRemainsAccepted() {
        XCTAssertEqual(
            MeteringEpochContract.callbackVerdict(
                callbackInput(callbackAt: Self.startedAt.addingTimeInterval(24 * 60 * 60))
            ),
            .accept
        )
    }

    func testIdentityMismatchesWinBeforePlausibility() {
        let implausibleTime = Self.startedAt.addingTimeInterval(-1)
        let cases: [(MeteringCallbackInput, MeteringCallbackVerdict)] = [
            (
                callbackInput(
                    callbackOwnerDeviceID: Self.otherChildDeviceID,
                    adjustedEstimateMinutes: -1,
                    callbackAt: implausibleTime
                ),
                .rejectOwner
            ),
            (
                callbackInput(
                    callbackEpochID: Self.otherEpochID,
                    adjustedEstimateMinutes: -1,
                    callbackAt: implausibleTime
                ),
                .rejectEpoch
            ),
            (
                callbackInput(
                    callbackUsageDate: "2026-07-15",
                    adjustedEstimateMinutes: -1,
                    callbackAt: implausibleTime
                ),
                .rejectUsageDate
            ),
            (
                callbackInput(
                    callbackPolicyRevision: "policy-2",
                    adjustedEstimateMinutes: -1,
                    callbackAt: implausibleTime
                ),
                .rejectPolicy
            ),
            (
                callbackInput(
                    callbackEventNamespace: "metering.v2",
                    adjustedEstimateMinutes: -1,
                    callbackAt: implausibleTime
                ),
                .rejectNamespace
            )
        ]

        for (input, expected) in cases {
            let verdict = MeteringEpochContract.callbackVerdict(input)
            XCTAssertEqual(verdict, expected)
            XCTAssertEqual(MeteringEpochContract.effects(for: verdict), MeteringEffects())
        }
    }

    func testNegativeDeltaRejectsBeforeTimePlausibility() {
        let verdict = MeteringEpochContract.callbackVerdict(
            callbackInput(
                adjustedEstimateMinutes: 4,
                baseAcceptedMinutes: 5,
                callbackAt: Self.startedAt.addingTimeInterval(-1)
            )
        )

        XCTAssertEqual(verdict, .rejectNegativeDelta)
        XCTAssertEqual(MeteringEpochContract.effects(for: verdict), MeteringEffects())
    }

    func testExtremeNegativeDeltaRejectsWithoutOverflowAndHasZeroEffects() {
        let verdict = MeteringEpochContract.callbackVerdict(
            callbackInput(
                adjustedEstimateMinutes: .min,
                baseAcceptedMinutes: 1
            )
        )

        XCTAssertEqual(verdict, .rejectNegativeDelta)
        XCTAssertEqual(MeteringEpochContract.effects(for: verdict), MeteringEffects())
    }

    func testExtremePositiveDeltaRejectsTooEarlyWithoutOverflowAndHasZeroEffects() {
        let extremes = [
            (adjusted: Int.max / 60 + 1, base: 0),
            (adjusted: Int.max, base: -1)
        ]

        for extreme in extremes {
            let verdict = MeteringEpochContract.callbackVerdict(
                callbackInput(
                    adjustedEstimateMinutes: extreme.adjusted,
                    baseAcceptedMinutes: extreme.base
                )
            )

            XCTAssertEqual(verdict, .rejectTooEarly)
            XCTAssertEqual(MeteringEpochContract.effects(for: verdict), MeteringEffects())
        }
    }

    func testJitterConstantsAndHardMaximumClamp() {
        XCTAssertEqual(MeteringEpochContract.defaultJitterSeconds, 60)
        XCTAssertEqual(MeteringEpochContract.maximumJitterSeconds, 60)

        let verdict = MeteringEpochContract.callbackVerdict(
            callbackInput(
                adjustedEstimateMinutes: 2,
                callbackAt: Self.startedAt.addingTimeInterval(59),
                jitterSeconds: 120
            )
        )
        XCTAssertEqual(verdict, .rejectTooEarly)
    }

    func testDefaultJitterAcceptsObservedThirtyFiveSecondEarlyCallback() {
        let verdict = MeteringEpochContract.callbackVerdict(
            callbackInput(
                adjustedEstimateMinutes: 5,
                callbackAt: Self.startedAt.addingTimeInterval(265)
            )
        )

        XCTAssertEqual(verdict, .accept)
    }

    func testCallbackBeforeStartRejectsTooEarlyEvenWithZeroDelta() {
        XCTAssertEqual(
            MeteringEpochContract.callbackVerdict(
                callbackInput(
                    adjustedEstimateMinutes: 5,
                    baseAcceptedMinutes: 5,
                    callbackAt: Self.startedAt.addingTimeInterval(-0.001)
                )
            ),
            .rejectTooEarly
        )
    }

    func testEffectsAreZeroForEveryRejectionAndMinimalForAcceptance() {
        let rejectionVerdicts: [MeteringCallbackVerdict] = [
            .rejectOwner,
            .rejectEpoch,
            .rejectUsageDate,
            .rejectPolicy,
            .rejectNamespace,
            .rejectNegativeDelta,
            .rejectTooEarly
        ]

        for verdict in rejectionVerdicts {
            XCTAssertEqual(MeteringEpochContract.effects(for: verdict), MeteringEffects())
        }

        XCTAssertEqual(
            MeteringEpochContract.effects(for: .accept),
            MeteringEffects(
                localEstimateMutations: 1,
                retryEnqueues: 1,
                networkDispatches: 1
            )
        )
    }

    func testCanonicalUsageDateUsesExplicitGregorianTimezone() throws {
        let instant = Date(timeIntervalSince1970: 1_784_163_000)
        let originalDefault = NSTimeZone.default
        defer { NSTimeZone.default = originalDefault }

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let newYorkWithKiritimatiDefault = MeteringEpochContract.canonicalUsageDate(
            at: instant,
            timezoneIdentifier: "America/New_York"
        )
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        let newYorkWithHonoluluDefault = MeteringEpochContract.canonicalUsageDate(
            at: instant,
            timezoneIdentifier: "America/New_York"
        )

        XCTAssertEqual(newYorkWithKiritimatiDefault, "2026-07-15")
        XCTAssertEqual(newYorkWithHonoluluDefault, "2026-07-15")
        XCTAssertEqual(
            MeteringEpochContract.canonicalUsageDate(
                at: instant,
                timezoneIdentifier: "Asia/Tokyo"
            ),
            "2026-07-16"
        )
        XCTAssertNil(
            MeteringEpochContract.canonicalUsageDate(
                at: instant,
                timezoneIdentifier: "Not/A_Timezone"
            )
        )
    }

    func testReplacementClassifierReturnsAllAndOnlyClosedReasons() {
        let active = epochKey()
        let reasons = [
            MeteringEpochContract.replacementReason(
                active: nil,
                next: active,
                explicitRecovery: nil
            ),
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(childDeviceID: Self.otherChildDeviceID),
                explicitRecovery: nil
            ),
            MeteringEpochContract.replacementReason(
                active: active,
                next: active,
                explicitRecovery: .gateResumeExactRebase
            ),
            MeteringEpochContract.replacementReason(
                active: active,
                next: active,
                explicitRecovery: .gateResumeConservative
            ),
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(usageDate: "2026-07-17"),
                explicitRecovery: nil
            ),
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(policyRevision: "policy-2"),
                explicitRecovery: nil
            ),
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(measurementSelectionDigest: "digest-2"),
                explicitRecovery: nil
            ),
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(enforcementSetID: Self.otherEnforcementSetID),
                explicitRecovery: nil
            ),
            MeteringEpochContract.replacementReason(
                active: active,
                next: active,
                explicitRecovery: .deliveryRecovery
            )
        ].compactMap { $0 }

        XCTAssertEqual(reasons.count, 9)
        XCTAssertEqual(Set(reasons), Set(MeteringEpochReplacementReason.allCases))
    }

    func testReplacementClassifierCoversPolicyAxesAndRequiredPrecedence() {
        let active = epochKey()

        XCTAssertEqual(
            MeteringEpochContract.replacementReason(
                active: active,
                next: active,
                explicitRecovery: .identityRecovery
            ),
            .identityRecovery
        )
        XCTAssertEqual(
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(protocolVersion: 2),
                explicitRecovery: nil
            ),
            .policyChange
        )
        XCTAssertEqual(
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(canonicalTimezone: "UTC"),
                explicitRecovery: nil
            ),
            .policyChange
        )

        let everyAxisChanged = epochKey(
            protocolVersion: 2,
            childDeviceID: Self.otherChildDeviceID,
            usageDate: "2026-07-17",
            canonicalTimezone: "UTC",
            policyRevision: "policy-2",
            measurementSelectionDigest: "digest-2",
            enforcementSetID: Self.otherEnforcementSetID
        )
        XCTAssertEqual(
            MeteringEpochContract.replacementReason(
                active: active,
                next: everyAxisChanged,
                explicitRecovery: .gateResumeExactRebase
            ),
            .identityRecovery
        )
        XCTAssertEqual(
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(
                    protocolVersion: 2,
                    usageDate: "2026-07-17",
                    policyRevision: "policy-2",
                    measurementSelectionDigest: "digest-2",
                    enforcementSetID: Self.otherEnforcementSetID
                ),
                explicitRecovery: .gateResumeExactRebase
            ),
            .gateResumeExactRebase
        )
        XCTAssertEqual(
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(
                    protocolVersion: 2,
                    usageDate: "2026-07-17",
                    policyRevision: "policy-2",
                    measurementSelectionDigest: "digest-2",
                    enforcementSetID: Self.otherEnforcementSetID
                ),
                explicitRecovery: nil
            ),
            .dayRollover
        )
        XCTAssertEqual(
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(
                    protocolVersion: 2,
                    policyRevision: "policy-2",
                    measurementSelectionDigest: "digest-2",
                    enforcementSetID: Self.otherEnforcementSetID
                ),
                explicitRecovery: nil
            ),
            .policyChange
        )
        XCTAssertEqual(
            MeteringEpochContract.replacementReason(
                active: active,
                next: epochKey(
                    measurementSelectionDigest: "digest-2",
                    enforcementSetID: Self.otherEnforcementSetID
                ),
                explicitRecovery: nil
            ),
            .selectionChange
        )
    }

    func testUnchangedPollHasNoReplacementAndPollRefreshCannotDecode() throws {
        let active = epochKey()

        XCTAssertNil(
            MeteringEpochContract.replacementReason(
                active: active,
                next: active,
                explicitRecovery: nil
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MeteringEpochReplacementReason.self,
                from: Data(#""poll_refresh""#.utf8)
            )
        )
    }
}
