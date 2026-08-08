import XCTest
@testable import Evlin_iOS

@MainActor
final class ChildFinalSetupStepTests: XCTestCase {
    func testFinishStaysLockedUntilTrackingAndPINAreDone() {
        XCTAssertFalse(ChildFinalSetupStep.canFinish(trackingDone: false, pinDone: false))
        XCTAssertFalse(ChildFinalSetupStep.canFinish(trackingDone: true, pinDone: false))
        XCTAssertFalse(ChildFinalSetupStep.canFinish(trackingDone: false, pinDone: true))
        XCTAssertTrue(ChildFinalSetupStep.canFinish(trackingDone: true, pinDone: true))
    }

    func testFinishPersistsIdentifiersBeforeReportingAllSet() async {
        let deviceID = UUID()
        let familyID = UUID()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: CommandPoller.childDeviceIDDefaultsKey)
        defaults.removeObject(forKey: "evlin.familyID")
        var observedDeviceID: String?
        var order: [String] = []
        let recoveryLaunched = expectation(description: "v2 recovery launched")

        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: deviceID,
            familyID: familyID,
            markAllSet: { _ in
                order.append("all-set")
                observedDeviceID = defaults.string(
                    forKey: CommandPoller.childDeviceIDDefaultsKey
                )
                return true
            },
            recoverV2: {
                order.append("recover-v2")
                recoveryLaunched.fulfill()
                return true
            }
        )

        XCTAssertTrue(done)
        XCTAssertEqual(observedDeviceID, deviceID.uuidString)
        XCTAssertEqual(defaults.string(forKey: "evlin.familyID"), familyID.uuidString)
        await fulfillment(of: [recoveryLaunched], timeout: 0.5)
        XCTAssertEqual(order, ["all-set", "recover-v2"])
    }

    func testFinishRepairsCommittedPairingConfigurationBeforeAllSetAndRecovery() async {
        let deviceID = UUID()
        var order: [String] = []
        let recoveryLaunched = expectation(description: "v2 recovery launched")

        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: deviceID,
            familyID: UUID(),
            prepareMeteringConfiguration: { preparedDeviceID in
                XCTAssertEqual(preparedDeviceID, deviceID)
                order.append("prepare-metering")
                return true
            },
            markAllSet: { _ in
                order.append("all-set")
                return true
            },
            recoverV2: {
                order.append("recover-v2")
                recoveryLaunched.fulfill()
                return true
            }
        )

        XCTAssertTrue(done)
        await fulfillment(of: [recoveryLaunched], timeout: 0.5)
        XCTAssertEqual(order, ["prepare-metering", "all-set", "recover-v2"])
    }

    func testFinishStopsBeforeAllSetWhenLockTargetsAreNotPublished() async {
        let deviceID = UUID()
        var order: [String] = []
        var failure: ChildFinalSetupStep.FinishFailure?

        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: deviceID,
            familyID: UUID(),
            prepareMeteringConfiguration: { _ in
                order.append("prepare-metering")
                return true
            },
            synchronizeLockTargets: { synchronizedDeviceID in
                XCTAssertEqual(synchronizedDeviceID, deviceID)
                order.append("sync-lock-targets")
                return false
            },
            markAllSet: { _ in
                XCTFail("All-set must not run without a backend Locked set")
                return true
            },
            recoverV2: {
                XCTFail("Recovery must not run without an enforcement-set ID")
                return true
            },
            onFailure: { failure = $0 }
        )

        XCTAssertFalse(done)
        XCTAssertEqual(order, ["prepare-metering", "sync-lock-targets"])
        XCTAssertEqual(failure, .lockTargets)
    }

    func testFinishDoesNotPublishNewCommandIdentityBeforeCleanupConverges() async {
        let oldDeviceID = UUID()
        let newDeviceID = UUID()
        UserDefaults.standard.set(
            oldDeviceID.uuidString,
            forKey: CommandPoller.childDeviceIDDefaultsKey
        )

        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: newDeviceID,
            familyID: UUID(),
            prepareMeteringConfiguration: { _ in
                XCTAssertEqual(
                    UserDefaults.standard.string(
                        forKey: CommandPoller.childDeviceIDDefaultsKey
                    ),
                    oldDeviceID.uuidString
                )
                return false
            },
            markAllSet: { _ in
                XCTFail("All-set must not run while identity cleanup is pending")
                return true
            },
            recoverV2: {
                XCTFail("Recovery must not run while identity cleanup is pending")
                return true
            }
        )

        XCTAssertFalse(done)
        XCTAssertEqual(
            UserDefaults.standard.string(
                forKey: CommandPoller.childDeviceIDDefaultsKey
            ),
            oldDeviceID.uuidString
        )
    }

    func testFinishReportsTheStageThatBlockedCompletion() async {
        var failure: ChildFinalSetupStep.FinishFailure?

        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: UUID(),
            familyID: UUID(),
            prepareMeteringConfiguration: { _ in false },
            markAllSet: { _ in true },
            recoverV2: { true },
            onFailure: { failure = $0 }
        )

        XCTAssertFalse(done)
        XCTAssertEqual(failure, .identityConvergence)
    }

    func testIdentityConvergenceFinishesExistingCleanupBeforeSwitchingToPairedOwner() async {
        let targetOwner = UUID()
        let intermediateOwner = UUID()
        var persistedOwner = UUID()
        var cleanupPending = true
        var recoveryPasses = 0
        var order: [String] = []

        let converged = await ChildFinalSetupStep.convergeIdentityTransition(
            targetOwner: targetOwner,
            maximumPasses: 4,
            snapshot: {
                .init(
                    persistedOwner: persistedOwner,
                    cleanupPending: cleanupPending
                )
            },
            recoverCurrentCleanup: {
                recoveryPasses += 1
                order.append("recover")
                cleanupPending = false
                persistedOwner = recoveryPasses == 1 ? intermediateOwner : targetOwner
            },
            mirrorTargetOwner: {
                order.append("mirror")
                cleanupPending = true
            },
            waitBeforeRetry: {}
        )

        XCTAssertTrue(converged)
        XCTAssertEqual(order, ["recover", "mirror", "recover"])
        XCTAssertEqual(persistedOwner, targetOwner)
        XCTAssertFalse(cleanupPending)
    }

    func testFinishClearsMatchingPendingAdoptionAfterDurableSetupEvenWhileV2Converges() async {
        let deviceID = UUID()
        var cleared = false

        let finished = await ChildFinalSetupStep.runFinish(
            childDeviceID: deviceID,
            familyID: UUID(),
            prepareMeteringConfiguration: { _ in true },
            markAllSet: { _ in true },
            recoverV2: { false },
            clearMatchingPendingAdoption: { cleared = true }
        )
        XCTAssertTrue(finished)
        XCTAssertTrue(cleared)
    }

    func testFinishDoesNotRequireTheFirstRecoveryAttemptToProveActivation() async {
        var recoveryCalls = 0

        let finished = await ChildFinalSetupStep.runFinish(
            childDeviceID: UUID(),
            familyID: UUID(),
            prepareMeteringConfiguration: { _ in true },
            markAllSet: { _ in true },
            recoverV2: {
                recoveryCalls += 1
                return false
            }
        )

        XCTAssertTrue(finished)
        XCTAssertEqual(recoveryCalls, 1)
    }

    func testExactV2ReadinessRetriesUntilDaemonAndActivationAreBothVerified() async {
        var attempts = 0

        let evidence = await ChildFinalSetupStep.awaitExactV2Readiness(
            maximumPasses: 3,
            recover: {
                attempts += 1
                return .attempted
            },
            readEvidence: {
                Self.evidence(ready: attempts >= 2)
            },
            waitBeforeRetry: {}
        )

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(evidence?.stage, .v2Ready)
        XCTAssertTrue(evidence?.v2Ready == true)
    }

    func testExactV2ReadinessDoesNotTreatAttemptedRecoveryAsReady() async {
        var attempts = 0

        let evidence = await ChildFinalSetupStep.awaitExactV2Readiness(
            maximumPasses: 3,
            recover: {
                attempts += 1
                return .attempted
            },
            readEvidence: { Self.evidence(ready: false) },
            waitBeforeRetry: {}
        )

        XCTAssertEqual(attempts, 3)
        XCTAssertNil(evidence)
    }

    func testOnboardingAcceptsDurableV2ActivationWhenDiagnosticReadbackWasRotated() async {
        let durableEvidence = MeteringDaemonActivationEvidence.make(input: .init(
            advertisedVersion: 2,
            localSelection: .v2,
            epochID: UUID(),
            routeID: UUID(),
            routeLifecycle: .active,
            installPhase: .active,
            activationAcknowledged: true,
            exactDaemonReadback: false
        ))

        let evidence = await ChildFinalSetupStep.awaitExactV2Readiness(
            maximumPasses: 1,
            recover: { .attempted },
            readEvidence: { durableEvidence },
            waitBeforeRetry: {}
        )

        XCTAssertNotNil(evidence)
        XCTAssertFalse(evidence?.exactDaemonReadback == true)
    }

    func testFinalSetupWaitBudgetCoversDatedHorizonBeforeActivationSettles() async {
        var attempts = 0

        let evidence = await ChildFinalSetupStep.awaitExactV2Readiness(
            maximumPasses: ChildFinalSetupStep.finalActivationMaximumPasses,
            recover: {
                attempts += 1
                return .attempted
            },
            readEvidence: {
                Self.evidence(ready: attempts >= 13)
            },
            waitBeforeRetry: {}
        )

        XCTAssertEqual(attempts, 13)
        XCTAssertTrue(evidence.map(ChildFinalSetupStep.hasDurableV2Activation) == true)
    }

    func testExactV2ReadinessStopsWhenRecoveryConfigurationDoesNotMatch() async {
        var attempts = 0

        let evidence = await ChildFinalSetupStep.awaitExactV2Readiness(
            maximumPasses: 3,
            recover: {
                attempts += 1
                return .skippedConfigurationMismatch
            },
            readEvidence: { Self.evidence(ready: true) },
            waitBeforeRetry: {}
        )

        XCTAssertEqual(attempts, 1)
        XCTAssertNil(evidence)
    }

    func testFinishFailsWhenAllSetFails() async {
        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: UUID(),
            familyID: UUID(),
            markAllSet: { _ in false },
            recoverV2: {
                XCTFail("Recovery must not run when all-set failed")
                return true
            }
        )

        XCTAssertFalse(done)
    }

    func testFinishRunsOneV2RecoveryAttemptBeforeCompleting() async {
        var recoveryCalls = 0

        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: UUID(),
            familyID: UUID(),
            markAllSet: { _ in true },
            recoverV2: {
                recoveryCalls += 1
                return false
            }
        )

        XCTAssertTrue(done)
        XCTAssertEqual(recoveryCalls, 1)
    }

    func testFinishWaitsForTheFirstPostAllSetRecoveryAttempt() async {
        var recoveryFinished = false

        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: UUID(),
            familyID: UUID(),
            markAllSet: { _ in true },
            recoverV2: {
                try? await Task.sleep(for: .milliseconds(50))
                recoveryFinished = true
                return true
            }
        )

        XCTAssertTrue(done)
        XCTAssertTrue(recoveryFinished)
    }

    private static func evidence(ready: Bool) -> MeteringDaemonActivationEvidence {
        MeteringDaemonActivationEvidence.make(input: .init(
            advertisedVersion: 2,
            localSelection: ready ? .v2 : .dualActive,
            epochID: UUID(),
            routeID: UUID(),
            routeLifecycle: ready ? .active : .planned,
            installPhase: ready ? .active : .pendingStart,
            activationAcknowledged: ready,
            exactDaemonReadback: ready
        ))
    }
}
