import DeviceActivity
import XCTest
@testable import Evlin_iOS

final class MeteringIdentityCleanupTests: XCTestCase {
    private var currentOwner: UUID?
    private var storeURL: URL!
    private var store: DeviceEpochStore!

    override func setUpWithError() throws {
        currentOwner = UUID()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-identity-cleanup-\(UUID().uuidString).json")
        store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { self.currentOwner })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeURL)
        store = nil
        storeURL = nil
        currentOwner = nil
    }

    func testPrepareCapturesAndTombstonesOldAuthorityBeforeMirrorTransition() throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        let before = try store.read()

        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: ["\(oldOwner.uuidString.lowercased()):2026-07-18:t5"],
            now: now
        )

        let prepared = try store.read()
        let work = try XCTUnwrap(prepared.identityCleanupWork)
        XCTAssertEqual(work.workID, workID)
        XCTAssertEqual(work.oldOwnerChildDeviceID, oldOwner)
        XCTAssertEqual(work.newOwnerChildDeviceID, newOwner)
        XCTAssertEqual(Set(work.oldEpochIDs), Set(before.epochs.keys))
        XCTAssertEqual(Set(work.oldRouteIDs), Set(before.routes.keys))
        XCTAssertEqual(Set(work.oldInstallWorkIDs), Set(before.installWork.keys))
        XCTAssertEqual(Set(work.oldUsageDates), Set(before.epochs.values.map(\.usageDate)))
        XCTAssertEqual(work.oldFallbackKeys, ["\(oldOwner.uuidString.lowercased()):2026-07-18:t5"])
        XCTAssertNil(prepared.activeGenerationID)
        XCTAssertNil(prepared.activeEpochID)
        XCTAssertNil(prepared.activeRouteID)
        XCTAssertTrue(prepared.generations.values.allSatisfy { $0.retiredAt == now })
        XCTAssertTrue(prepared.epochs.values.allSatisfy {
            $0.status == .retired && $0.retireReason == .identityRecovery
        })
        XCTAssertTrue(prepared.routes.values.allSatisfy { $0.lifecycle == .tombstoned })
        XCTAssertEqual(Set(prepared.tombstones.keys), Set(before.routes.keys))

        currentOwner = newOwner
        XCTAssertThrowsError(try store.transaction(expectedOwner: oldOwner) { _ in }) {
            XCTAssertEqual($0 as? DeviceEpochStoreError, .ownerMismatch)
        }

        try store.identityCleanupTransaction(workID: workID) { _, cleanup in
            cleanup.ownerMirrorTransitionAcknowledged = true
        }
        XCTAssertTrue(try XCTUnwrap(store.read().identityCleanupWork).ownerMirrorTransitionAcknowledged)
    }

    func testPrepareIsIdempotentForSameTransition() throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)

        let first = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: ["old-key"],
            now: now
        )
        let firstBytes = try Data(contentsOf: storeURL)
        let second = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: ["old-key"],
            now: now.addingTimeInterval(30)
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: storeURL), firstBytes)
    }

    func testCleanupWithoutTargetCanBeAdoptedOnceByNewPairing() throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: nil,
            oldFallbackKeys: [],
            now: now
        )
        try acknowledgeEveryCapturedEffect(workID: workID)
        XCTAssertTrue(try store.markIdentityCleanupSucceeded(workID: workID))

        XCTAssertTrue(
            try store.adoptIdentityCleanupTarget(
                workID: workID,
                newOwner: newOwner
            )
        )
        let adopted = try XCTUnwrap(store.read().identityCleanupWork)
        XCTAssertEqual(adopted.workID, workID)
        XCTAssertEqual(adopted.newOwnerChildDeviceID, newOwner)
        XCTAssertFalse(adopted.ownerMirrorTransitionAcknowledged)
        XCTAssertEqual(adopted.retry.terminal, .pending)
        XCTAssertFalse(
            try store.adoptIdentityCleanupTarget(
                workID: workID,
                newOwner: newOwner
            )
        )
    }

    func testCleanupAlreadyTargetingAnotherOwnerCannotBeAdopted() throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let assignedOwner = UUID()
        let differentOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: assignedOwner,
            oldFallbackKeys: [],
            now: now
        )

        XCTAssertThrowsError(
            try store.adoptIdentityCleanupTarget(
                workID: workID,
                newOwner: differentOwner
            )
        ) {
            XCTAssertEqual($0 as? DeviceEpochStoreError, .ownerMismatch)
        }
        XCTAssertEqual(
            try store.read().identityCleanupWork?.newOwnerChildDeviceID,
            assignedOwner
        )
    }

    func testPrepareAtomicallyTerminatesAnInFlightOldOwnerHandoff() throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        try store.transaction(expectedOwner: oldOwner) { state in
            let fromRoute = try XCTUnwrap(state.routes.values.min {
                $0.usageDate < $1.usageDate
            })
            let fromGenerationID = fromRoute.generationID
            let fromEpochID = fromRoute.epochID
            let fromRouteID = fromRoute.routeID
            state.activeGenerationID = fromGenerationID
            state.activeEpochID = fromEpochID
            state.activeRouteID = fromRouteID
            state.epochs[fromEpochID]?.status = .active
            state.routes[fromRouteID]?.lifecycle = .active
            let toRoute = try XCTUnwrap(state.routes.values.first {
                $0.routeID != fromRouteID && $0.lifecycle == .planned
            })
            let alreadyStoppedRoute = try XCTUnwrap(state.routes.values.first {
                $0.routeID != fromRouteID
                    && $0.routeID != toRoute.routeID
                    && $0.lifecycle == .planned
            })
            let stoppedAt = now.addingTimeInterval(-60)
            state.routes[alreadyStoppedRoute.routeID]?.lifecycle = .tombstoned
            state.tombstones[alreadyStoppedRoute.routeID] = MeteringRouteTombstone(
                routeID: alreadyStoppedRoute.routeID,
                activityName: alreadyStoppedRoute.activityName,
                eventNames: alreadyStoppedRoute.plannedEvents.map(\.eventName),
                ownerChildDeviceID: oldOwner,
                usageDate: alreadyStoppedRoute.usageDate,
                epochID: alreadyStoppedRoute.epochID,
                generationID: alreadyStoppedRoute.generationID,
                canonicalDayEnd: now.addingTimeInterval(86_400),
                stopAcknowledgedAt: stoppedAt,
                referencedWorkIDs: [],
                retainedUntil: nil
            )
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: oldOwner,
                fromGenerationID: fromGenerationID,
                fromEpochID: fromEpochID,
                fromRouteID: fromRouteID,
                toGenerationID: toRoute.generationID,
                toEpochID: toRoute.epochID,
                toRouteID: toRoute.routeID,
                phase: .preparing,
                priorRouteInputClosedAt: nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: now
            )
        }

        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: [],
            now: now.addingTimeInterval(1)
        )

        let prepared = try store.read()
        XCTAssertEqual(prepared.identityCleanupWork?.workID, workID)
        XCTAssertNil(prepared.v2RouteHandoff)
        XCTAssertNil(prepared.activeGenerationID)
        XCTAssertNil(prepared.activeEpochID)
        XCTAssertNil(prepared.activeRouteID)
        XCTAssertTrue(prepared.routes.values.allSatisfy { $0.lifecycle == .tombstoned })
        XCTAssertTrue(prepared.epochs.values.allSatisfy {
            $0.status == .retired && $0.retireReason == .identityRecovery
        })
        XCTAssertEqual(
            prepared.tombstones.values.filter { $0.stopAcknowledgedAt != nil }.count,
            1
        )
    }

    func testWrongCleanupWorkIDCannotMutateAfterOwnerMirrorChanges() throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        _ = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: [],
            now: now
        )
        currentOwner = newOwner
        let before = try Data(contentsOf: storeURL)

        XCTAssertThrowsError(
            try store.identityCleanupTransaction(workID: UUID()) { state, cleanup in
                state.activeEpochID = UUID()
                cleanup.ownerMirrorTransitionAcknowledged = true
            }
        ) {
            XCTAssertEqual($0 as? DeviceEpochStoreError, .ownerMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: storeURL), before)
    }

    func testCleanupCannotBecomeTerminalBeforeEveryCapturedEffectIsAcknowledged() throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: ["old-retry"],
            now: now
        )
        currentOwner = newOwner

        XCTAssertFalse(try store.markIdentityCleanupSucceeded(workID: workID))
        let cleanup = try XCTUnwrap(store.read().identityCleanupWork)
        XCTAssertEqual(cleanup.retry.terminal, .pending)
    }

    func testLostOwnerMirrorAckIsRecoveredOnlyForExactTarget() throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let thirdOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: [],
            now: now
        )

        currentOwner = thirdOwner
        XCTAssertFalse(
            try store.recoverIdentityCleanupMirrorAcknowledgement(workID: workID)
        )
        XCTAssertFalse(
            try XCTUnwrap(store.read().identityCleanupWork)
                .ownerMirrorTransitionAcknowledged
        )

        currentOwner = newOwner
        XCTAssertTrue(
            try store.recoverIdentityCleanupMirrorAcknowledgement(workID: workID)
        )
        XCTAssertTrue(
            try XCTUnwrap(store.read().identityCleanupWork)
                .ownerMirrorTransitionAcknowledged
        )
        XCTAssertFalse(
            try store.recoverIdentityCleanupMirrorAcknowledgement(workID: workID)
        )
    }

    func testSucceededCleanupHandsOffToOneEmptyNewOwnerRoot() throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: ["old-retry"],
            now: now
        )
        currentOwner = newOwner
        try acknowledgeEveryCapturedEffect(workID: workID)

        XCTAssertTrue(try store.markIdentityCleanupSucceeded(workID: workID))
        XCTAssertEqual(try store.read().identityCleanupWork?.retry.terminal, .succeeded)
        XCTAssertTrue(try store.finalizeIdentityCleanup(workID: workID))

        let handedOff = try store.read()
        XCTAssertEqual(handedOff.ownerChildDeviceID, newOwner)
        XCTAssertNil(handedOff.identityCleanupWork)
        XCTAssertNil(handedOff.pendingRegistrationRecovery)
        XCTAssertTrue(handedOff.generations.isEmpty)
        XCTAssertTrue(handedOff.epochs.isEmpty)
        XCTAssertTrue(handedOff.routes.isEmpty)
        XCTAssertTrue(handedOff.tombstones.isEmpty)
        XCTAssertTrue(handedOff.registrationWork.isEmpty)
        XCTAssertTrue(handedOff.activationWork.isEmpty)
        XCTAssertTrue(handedOff.sampleWork.isEmpty)
        XCTAssertTrue(handedOff.installWork.isEmpty)
        XCTAssertTrue(handedOff.shieldReferences.isEmpty)

        XCTAssertFalse(try store.finalizeIdentityCleanup(workID: workID))
        XCTAssertEqual(try store.read(), handedOff)
    }

    @MainActor
    func testRecoveryContinuesAfterMirrorChangeAndAcknowledgesExactCapturedEffects() async throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        let shieldOperationID = UUID()
        try seedShieldReference(owner: oldOwner, operationID: shieldOperationID, now: now)
        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: ["old-retry"],
            now: now
        )
        let activityNames = try XCTUnwrap(store.read().identityCleanupWork).oldActivityNames
        let center = IdentityCleanupCenter(activityNames: activityNames)
        var purges: [(UUID, [String])] = []
        var releases: [(UUID, UUID)] = []
        try store.identityCleanupTransaction(workID: workID) { _, cleanup in
            cleanup.clearedUsageDates = Set(cleanup.oldUsageDates)
        }
        currentOwner = newOwner
        let driver = makeRecoveryDriver(
            center: center,
            now: now,
            purgeRetryState: { owner, keys in
                purges.append((owner, keys))
                return Set(keys)
            },
            releaseShield: { operationID, owner in
                releases.append((operationID, owner))
            }
        )

        try await driver.recover(ownerChildDeviceID: newOwner)

        XCTAssertNil(try store.read().identityCleanupWork)
        XCTAssertEqual(try store.read().ownerChildDeviceID, newOwner)
        XCTAssertEqual(purges.count, 1)
        XCTAssertEqual(purges.first?.0, oldOwner)
        XCTAssertEqual(purges.first?.1, ["old-retry"])
        XCTAssertEqual(releases.map(\.0), [shieldOperationID])
        XCTAssertEqual(releases.map(\.1), [oldOwner])
        XCTAssertEqual(Set(center.stoppedNames), Set(activityNames))

        // Recovery is idempotent after the root handoff; a second wake must
        // not repeat purge, shield release, or activity stop work.
        try await driver.recover(ownerChildDeviceID: newOwner)

        XCTAssertEqual(try store.read().ownerChildDeviceID, newOwner)
        XCTAssertNil(try store.read().identityCleanupWork)
        XCTAssertEqual(purges.count, 1)
        XCTAssertEqual(releases.count, 1)
    }

    @MainActor
    func testRecoveryReturnsWhenDaemonHasNotAcknowledgedCleanupStop() async throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: [],
            now: now
        )
        let activityNames = try XCTUnwrap(store.read().identityCleanupWork).oldActivityNames
        let center = IdentityCleanupCenter(
            activityNames: activityNames,
            acknowledgesStops: false
        )
        currentOwner = newOwner
        let driver = makeRecoveryDriver(center: center, now: now)

        try await driver.recover(ownerChildDeviceID: newOwner)

        let cleanup = try XCTUnwrap(store.read().identityCleanupWork)
        XCTAssertEqual(cleanup.workID, workID)
        XCTAssertEqual(cleanup.retry.terminal, .pending)
        XCTAssertTrue(cleanup.stopAcknowledgedActivityNames.isEmpty)
        XCTAssertEqual(center.stopCalls, 1)
    }

    @MainActor
    func testRecoveryTreatsPersistedShieldCASConflictAsSettledAndContinuesCleanup() async throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        let shieldOperationID = UUID()
        try seedShieldReference(owner: oldOwner, operationID: shieldOperationID, now: now)
        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: [],
            now: now
        )
        let activityNames = try XCTUnwrap(store.read().identityCleanupWork).oldActivityNames
        let center = IdentityCleanupCenter(activityNames: activityNames)
        try store.identityCleanupTransaction(workID: workID) { _, cleanup in
            cleanup.clearedUsageDates = Set(cleanup.oldUsageDates)
        }
        currentOwner = newOwner
        let driver = makeRecoveryDriver(
            center: center,
            now: now,
            releaseShield: { operationID, owner in
                XCTAssertEqual(operationID, shieldOperationID)
                XCTAssertEqual(owner, oldOwner)
                throw EarnedShieldEffectError.casConflict(operationID)
            }
        )

        try await driver.recover(ownerChildDeviceID: newOwner)

        XCTAssertNil(try store.read().identityCleanupWork)
        XCTAssertEqual(try store.read().ownerChildDeviceID, newOwner)
        XCTAssertEqual(Set(center.stoppedNames), Set(activityNames))
    }

    @MainActor
    func testRecoveryDoesNotSwallowUnrelatedShieldRetirementFailure() async throws {
        let oldOwner = try XCTUnwrap(currentOwner)
        let newOwner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedOwner(oldOwner, now: now)
        let shieldOperationID = UUID()
        try seedShieldReference(owner: oldOwner, operationID: shieldOperationID, now: now)
        let workID = try store.prepareIdentityCleanup(
            oldOwner: oldOwner,
            newOwner: newOwner,
            oldFallbackKeys: [],
            now: now
        )
        let activityNames = try XCTUnwrap(store.read().identityCleanupWork).oldActivityNames
        let center = IdentityCleanupCenter(activityNames: activityNames)
        try store.identityCleanupTransaction(workID: workID) { _, cleanup in
            cleanup.clearedUsageDates = Set(cleanup.oldUsageDates)
        }
        currentOwner = newOwner
        let driver = makeRecoveryDriver(
            center: center,
            now: now,
            releaseShield: { _, _ in throw URLError(.cannotWriteToFile) }
        )

        do {
            try await driver.recover(ownerChildDeviceID: newOwner)
            XCTFail("unrelated shield retirement errors must remain retryable")
        } catch {
            XCTAssertEqual(error as? URLError, URLError(.cannotWriteToFile))
        }

        let cleanup = try XCTUnwrap(store.read().identityCleanupWork)
        XCTAssertEqual(cleanup.workID, workID)
        XCTAssertFalse(cleanup.releasedShieldOperationIDs.contains(shieldOperationID))
        XCTAssertEqual(center.stopCalls, 0)
    }

    private func acknowledgeEveryCapturedEffect(workID: UUID) throws {
        try store.identityCleanupTransaction(workID: workID) { state, cleanup in
            cleanup.terminalizedWorkIDs = Set(
                cleanup.oldRegistrationWorkIDs
                    + cleanup.oldActivationWorkIDs
                    + cleanup.oldSampleWorkIDs
                    + cleanup.oldInstallWorkIDs
            )
            cleanup.purgedFallbackKeys = Set(cleanup.oldFallbackKeys)
            cleanup.releasedShieldOperationIDs = Set(cleanup.oldShieldOperationIDs)
            cleanup.stopAcknowledgedActivityNames = Set(cleanup.oldActivityNames)
            cleanup.clearedUsageDates = Set(cleanup.oldUsageDates)
            cleanup.ownerMirrorTransitionAcknowledged = true
            for id in cleanup.oldRegistrationWorkIDs {
                state.registrationWork[id]?.retry.terminal = .superseded
            }
            for id in cleanup.oldActivationWorkIDs {
                state.activationWork[id]?.retry.terminal = .superseded
            }
            for id in cleanup.oldSampleWorkIDs {
                state.sampleWork[id]?.retry.terminal = .superseded
            }
            for id in cleanup.oldInstallWorkIDs {
                state.installWork[id]?.retry.terminal = .superseded
            }
        }
    }

    private func seedOwner(_ owner: UUID, now: Date) throws {
        let selection = Data([0x41, 0x42, 0x43])
        let generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "identity-cleanup",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: selection),
            enforcementSetID: UUID()
        )
        _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-18",
            generationKey: generationKey,
            persistedSelectionBytes: selection,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: now
        ))
    }

    private func seedShieldReference(owner: UUID, operationID: UUID, now: Date) throws {
        try store.transaction(expectedOwner: owner) { state in
            let generationID = try XCTUnwrap(state.generations.keys.first)
            let epochID = try XCTUnwrap(state.epochs.keys.first)
            let routeID = try XCTUnwrap(state.routes.keys.first)
            state.shieldReferences[operationID] = EarnedShieldReference(
                operationID: operationID,
                ownerChildDeviceID: owner,
                generationID: generationID,
                epochID: epochID,
                routeID: routeID,
                recordKey: "identity-cleanup-shield",
                expectedRecordBytes: Data([0x01]),
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: now,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: now
            )
        }
    }

    @MainActor
    private func makeRecoveryDriver(
        center: IdentityCleanupCenter,
        now: Date,
        purgeRetryState: @escaping (UUID, [String]) -> Set<String> = { _, keys in Set(keys) },
        releaseShield: @escaping (UUID, UUID) throws -> Void = { _, _ in }
    ) -> EarnedMeteringRecoveryDriver {
        let clock = IdentityCleanupClock(now: now)
        let delivery = MeteringEpochDelivery(
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            store: store,
            transport: IdentityCleanupTransport(),
            clock: clock,
            legacySuiteName: "identity-cleanup-\(UUID().uuidString)"
        )
        let process = MeteringProcessIdentity(role: .app, instanceID: UUID())
        return EarnedMeteringRecoveryDriver(
            store: store,
            delivery: delivery,
            installer: DatedRouteInstaller(
                store: store,
                center: center,
                processIdentity: process,
                clock: clock
            ),
            center: center,
            processIdentity: process,
            clock: clock,
            purgeIdentityRetryState: purgeRetryState,
            releaseIdentityShield: releaseShield
        )
    }
}

private struct IdentityCleanupClock: MeteringClock {
    let now: Date
}

private struct IdentityCleanupTransport: MeteringHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private nonisolated final class IdentityCleanupCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    private(set) var active: Set<DeviceActivityName>
    private(set) var stoppedNames: [String] = []
    private let acknowledgesStops: Bool
    private(set) var stopCalls = 0

    init(activityNames: [String], acknowledgesStops: Bool = true) {
        active = Set(activityNames.map { DeviceActivityName($0) })
        self.acknowledgesStops = acknowledgesStops
    }

    var activities: [DeviceActivityName] { Array(active) }
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { nil }
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] { [:] }
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        active.insert(activity)
    }
    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopCalls += 1
        stoppedNames.append(contentsOf: activities.map(\.rawValue))
        guard acknowledgesStops else { return }
        activities.forEach { active.remove($0) }
    }
}
