import XCTest
@testable import Evlin_iOS

@MainActor
final class EarnedBudgetArmingTests: XCTestCase {
    func test_legacyActiveGenerationRequiresReplacement() {
        let legacy = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 5,
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York"
        )
        let timestamped = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 5,
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York",
            armedAt: Date()
        )

        XCTAssertTrue(EarnedBudgetArming.requiresGenerationReplacement(legacy))
        XCTAssertFalse(EarnedBudgetArming.requiresGenerationReplacement(timestamped))
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

    func test_failedReplacementPreservesOffsetAndGeneration() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(suiteName: suiteName)
        let priorGeneration = EarnedActivityGeneration.generatedActivityName(id: UUID())
        store.earnedUsageOffsetMinutes = 5
        defaults.set(priorGeneration, forKey: EarnedActivityGeneration.activeActivityNameKey)

        let installed = EarnedBudgetArming.installReplacement(
            replacementOffset: 15,
            store: store,
            startMonitoring: { false }
        )

        XCTAssertFalse(installed)
        XCTAssertEqual(store.earnedUsageOffsetMinutes, 5)
        XCTAssertEqual(
            defaults.string(forKey: EarnedActivityGeneration.activeActivityNameKey),
            priorGeneration
        )
    }

    func test_stopPersistsStoppedLifecycle() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        EarnedActivityGeneration.persistLifecycle(
            .init(
                active: .init(
                    activityName: EarnedActivityGeneration.legacyActivityName,
                    deviceID: "b21411cb-63a5-4489-bc68-bf8ac26ee15b",
                    offsetMinutes: 5,
                    usageDate: "2026-07-11",
                    timezoneIdentifier: "America/New_York"
                ),
                pending: nil
            ),
            defaults: defaults
        )
        var stopCount = 0

        EarnedBudgetArming.stopLegacyMonitoring(
            defaults: defaults,
            stopMonitoring: { stopCount += 1 }
        )

        XCTAssertEqual(stopCount, 1)
        let stoppedLifecycle = EarnedActivityGeneration.loadLifecycle(defaults: defaults)
        XCTAssertEqual(stoppedLifecycle?.isStopped, true)
    }

    func test_interruptedStopTombstonePreventsLegacyMigrationAndForcesInstall() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stopped: [String] = []

        EarnedActivityGeneration.stopPersisted(
            defaults: defaults,
            stopMonitoring: { stopped = $0 }
        )
        let stoppedLifecycle = EarnedActivityGeneration.loadLifecycle(defaults: defaults)
        let legacy = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.legacyActivityName,
            deviceID: "b21411cb-63a5-4489-bc68-bf8ac26ee15b",
            offsetMinutes: 5,
            usageDate: "2026-07-11",
            timezoneIdentifier: "America/New_York"
        )
        EarnedActivityGeneration.migrateActiveIfNeeded(legacy, defaults: defaults)

        XCTAssertTrue(stopped.contains(EarnedActivityGeneration.legacyActivityName))
        XCTAssertEqual(stoppedLifecycle?.isStopped, true)
        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: EarnedActivityGeneration.legacyActivityName,
            currentDeviceID: legacy.deviceID,
            lifecycle: EarnedActivityGeneration.loadLifecycle(defaults: defaults)
        ))
    }

    func test_identityMirrorStopsOldGenerationBeforeWritingNewChildID() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldID = UUID(uuidString: "b21411cb-63a5-4489-bc68-bf8ac26ee15b")!
        let newID = UUID(uuidString: "0d45589a-722c-4e43-a06e-7501f484a46c")!
        defaults.set(oldID.uuidString, forKey: "evlin.childId")
        var events: [String] = []

        EarnedBudgetArming.mirrorChildIdentity(
            newID,
            appGroupDefaults: defaults,
            hasGenerationState: true,
            stopMonitoring: {
                events.append("stop")
                XCTAssertEqual(defaults.string(forKey: "evlin.childId"), oldID.uuidString)
            }
        )
        events.append("mirror")

        XCTAssertEqual(events, ["stop", "mirror"])
        XCTAssertEqual(defaults.string(forKey: "evlin.childId"), newID.uuidString.lowercased())
    }

    func test_identityMirrorClearsPriorAuthoritativeReadinessBeforeWritingNewChildID() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(suiteName: suiteName)
        let oldID = UUID()
        let newID = UUID()
        defaults.set(oldID.uuidString, forKey: "evlin.childId")
        store.markAuthoritativeStateReady(deviceID: oldID)

        EarnedBudgetArming.mirrorChildIdentity(
            newID,
            appGroupDefaults: defaults,
            readinessStore: store,
            hasGenerationState: false
        )

        XCTAssertFalse(store.isAuthoritativeStateReady(deviceID: oldID))
        XCTAssertFalse(store.isAuthoritativeStateReady(deviceID: newID))
        XCTAssertEqual(defaults.string(forKey: "evlin.childId"), newID.uuidString.lowercased())
    }

    func test_identityTeardownStopsAndRemovesMirrorBeforeClearingUsage() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(suiteName: suiteName)
        let oldID = UUID()
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: oldID.uuidString,
            offsetMinutes: 10,
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York"
        )
        defaults.set(oldID.uuidString, forKey: "evlin.childId")
        XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(
            .init(active: generation, pending: nil),
            defaults: defaults
        ))
        store.latestDeviceEstimate = 45

        EarnedBudgetArming.teardownFamilyIdentity(
            appGroupDefaults: defaults,
            store: store,
            stopMonitoring: {},
            beforeUsageClear: {
                XCTAssertNil(defaults.string(forKey: "evlin.childId"))
                XCTAssertEqual(
                    EarnedActivityGeneration.loadLifecycle(defaults: defaults)?.isStopped,
                    true
                )
                XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
                    activityName: generation.activityName,
                    currentDeviceID: defaults.string(forKey: "evlin.childId"),
                    lifecycle: EarnedActivityGeneration.loadLifecycle(defaults: defaults)
                ))
            }
        )

        XCTAssertNil(store.latestDeviceEstimate)
    }

    func test_epochIdentityTeardownPreparesAndClearsUsageBeforeRemovingMirror() throws {
        let suiteName = "EarnedBudgetArmingTests.epochIdentity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldOwner = UUID()
        defaults.set(oldOwner.uuidString.lowercased(), forKey: "evlin.childId")
        let usageStore = EarnedTimeStore(suiteName: suiteName)
        usageStore.latestDeviceEstimate = 45
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-budget-identity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let epochStore = DeviceEpochStore(
            fileURL: fileURL,
            ownerProvider: {
                defaults.string(forKey: "evlin.childId").flatMap(UUID.init(uuidString:))
            }
        )
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        try seedEpochOwner(oldOwner, store: epochStore, now: now)
        var observedPreparedBeforeClear = false

        EarnedBudgetArming.teardownFamilyIdentity(
            appGroupDefaults: defaults,
            store: usageStore,
            epochStore: epochStore,
            stopMonitoring: {},
            beforeUsageClear: {
                XCTAssertEqual(
                    defaults.string(forKey: "evlin.childId"),
                    oldOwner.uuidString.lowercased()
                )
                XCTAssertNotNil(try? epochStore.read().identityCleanupWork)
                observedPreparedBeforeClear = true
            },
            now: now
        )

        XCTAssertTrue(observedPreparedBeforeClear)
        XCTAssertNil(usageStore.latestDeviceEstimate)
        XCTAssertNil(defaults.string(forKey: "evlin.childId"))
        let cleanup = try XCTUnwrap(epochStore.read().identityCleanupWork)
        XCTAssertEqual(cleanup.clearedUsageDates, Set(cleanup.oldUsageDates))
        XCTAssertTrue(cleanup.ownerMirrorTransitionAcknowledged)
    }

    func test_epochIdentityTeardownKeepsOldMirrorWhenCleanupCannotBePersisted() throws {
        let suiteName = "EarnedBudgetArmingTests.epochIdentityFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldOwner = UUID()
        defaults.set(oldOwner.uuidString.lowercased(), forKey: "evlin.childId")
        let usageStore = EarnedTimeStore(suiteName: suiteName)
        usageStore.latestDeviceEstimate = 45
        let epochStore = DeviceEpochStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("unwritable-identity-\(UUID().uuidString).json"),
            lock: IdentityCleanupUnavailableLock(),
            ownerProvider: { oldOwner }
        )
        var stopped = false

        EarnedBudgetArming.teardownFamilyIdentity(
            appGroupDefaults: defaults,
            store: usageStore,
            epochStore: epochStore,
            stopMonitoring: { stopped = true }
        )

        XCTAssertTrue(stopped)
        XCTAssertEqual(
            defaults.string(forKey: "evlin.childId"),
            oldOwner.uuidString.lowercased()
        )
        XCTAssertEqual(usageStore.latestDeviceEstimate, 45)
    }

    private func seedEpochOwner(
        _ owner: UUID,
        store: DeviceEpochStore,
        now: Date
    ) throws {
        let selection = Data([0x41, 0x42, 0x43])
        let key = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "identity-ordering",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selection
            ),
            enforcementSetID: UUID()
        )
        _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-18",
            generationKey: key,
            persistedSelectionBytes: selection,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: now
        ))
    }

    func test_callbackAuthorizedBeforeTeardownCannotMutateAfterContinuationResumes() async {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(suiteName: suiteName)
        let oldID = UUID()
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: oldID.uuidString,
            offsetMinutes: 0,
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York"
        )
        defaults.set(oldID.uuidString, forKey: "evlin.childId")
        XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(
            .init(active: generation, pending: nil),
            defaults: defaults
        ))
        var resumeCallback: CheckedContinuation<Void, Never>?
        var didMutate = false

        let callback = Task {
            XCTAssertEqual(EarnedActivityGeneration.authorizedCallback(
                activityName: generation.activityName,
                currentDeviceID: defaults.string(forKey: "evlin.childId"),
                lifecycle: EarnedActivityGeneration.loadLifecycle(defaults: defaults)
            ), generation)
            await withCheckedContinuation { resumeCallback = $0 }
            return EarnedActivityGeneration.performIfAuthorized(
                generation: generation,
                defaults: defaults
            ) {
                didMutate = true
            }
        }
        while resumeCallback == nil { await Task.yield() }
        EarnedBudgetArming.teardownFamilyIdentity(
            appGroupDefaults: defaults,
            store: store,
            stopMonitoring: {}
        )
        resumeCallback?.resume()

        let callbackAuthorized = await callback.value
        XCTAssertFalse(callbackAuthorized)
        XCTAssertFalse(didMutate)
    }

    func test_generationMutationRollsBackItsWriteWhenAuthorizationChangesAfterOperation() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldID = UUID()
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: oldID.uuidString,
            offsetMinutes: 0,
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York"
        )
        let mutationKey = "test.earned.old-generation-write"
        defaults.set("prior", forKey: mutationKey)
        defaults.set(oldID.uuidString, forKey: "evlin.childId")
        XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(
            .init(active: generation, pending: nil),
            defaults: defaults
        ))

        let authorized = EarnedActivityGeneration.performIfAuthorized(
            generation: generation,
            defaults: defaults,
            mutationKeys: [mutationKey],
            beforeFinalAuthorizationCheck: {
                defaults.removeObject(forKey: "evlin.childId")
                XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(
                    .init(active: nil, pending: nil, isStopped: true),
                    defaults: defaults
                ))
            }
        ) {
            defaults.set("old-write", forKey: mutationKey)
        }

        XCTAssertFalse(authorized)
        XCTAssertEqual(defaults.string(forKey: mutationKey), "prior")
    }

    func test_generationRollbackDoesNotOverwriteNewerIdentityWrite() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldID = UUID()
        let newID = UUID()
        let oldGeneration = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: oldID.uuidString,
            offsetMinutes: 0,
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York"
        )
        let newGeneration = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: newID.uuidString,
            offsetMinutes: 0,
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York"
        )
        let mutationKey = "test.earned.new-generation-write"
        defaults.set("prior", forKey: mutationKey)
        defaults.set(oldID.uuidString, forKey: "evlin.childId")
        XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(
            .init(active: oldGeneration, pending: nil),
            defaults: defaults
        ))

        let authorized = EarnedActivityGeneration.performIfAuthorized(
            generation: oldGeneration,
            defaults: defaults,
            mutationKeys: [mutationKey],
            beforeFinalAuthorizationCheck: {
                defaults.set(newID.uuidString, forKey: "evlin.childId")
                XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(
                    .init(active: newGeneration, pending: nil),
                    defaults: defaults
                ))
                defaults.set("new-write", forKey: mutationKey)
                defaults.synchronize()
            }
        ) {
            defaults.set("old-write", forKey: mutationKey)
        }

        XCTAssertFalse(authorized)
        XCTAssertEqual(defaults.string(forKey: mutationKey), "new-write")
        XCTAssertEqual(EarnedActivityGeneration.loadLifecycle(defaults: defaults)?.active, newGeneration)
    }

    func test_authoritativeReadinessGateRejectsMissingAndMismatchedDeviceMarkers() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(suiteName: suiteName)
        let current = UUID()

        XCTAssertFalse(EarnedBudgetArming.canArmAuthoritativeState(
            deviceID: current,
            store: store
        ))
        store.markAuthoritativeStateReady(deviceID: UUID())
        XCTAssertFalse(EarnedBudgetArming.canArmAuthoritativeState(
            deviceID: current,
            store: store
        ))
        store.markAuthoritativeStateReady(deviceID: current)
        XCTAssertTrue(EarnedBudgetArming.canArmAuthoritativeState(
            deviceID: current,
            store: store
        ))
    }

    func test_legacyLadderCannotReplaceDualOrActivatedV2Routes() {
        XCTAssertTrue(EarnedBudgetScheduler.canInstallLegacyLadder(localSelection: nil))
        XCTAssertTrue(EarnedBudgetScheduler.canInstallLegacyLadder(localSelection: .v1))
        XCTAssertFalse(EarnedBudgetScheduler.canInstallLegacyLadder(localSelection: .dualActive))
        XCTAssertFalse(EarnedBudgetScheduler.canInstallLegacyLadder(localSelection: .v2))
    }

    func test_legacyGenerationIdentityReplacesPolicyAndSelectionButNotOffset() {
        let deviceID = UUID()
        let enforcementSetID = UUID()
        let baseKey = EarnedBudgetArming.legacyGenerationKey(
            deviceID: deviceID,
            timezoneIdentifier: "America/New_York",
            policyRevision: "policy-1",
            selectionBytes: Data("persisted-selection-a".utf8),
            enforcementSetID: enforcementSetID
        )
        let active = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: deviceID.uuidString,
            offsetMinutes: 5,
            usageDate: "2026-07-18",
            timezoneIdentifier: "America/New_York",
            generationKey: baseKey,
            armedAt: Date()
        )
        let sameIdentityWithAdvancedOffset = EarnedActivityGeneration.Generation(
            activityName: active.activityName,
            deviceID: active.deviceID,
            offsetMinutes: 25,
            usageDate: active.usageDate,
            timezoneIdentifier: active.timezoneIdentifier,
            generationKey: baseKey,
            armedAt: active.armedAt
        )

        XCTAssertFalse(EarnedBudgetArming.shouldReplaceLegacyGeneration(
            sameIdentityWithAdvancedOffset,
            with: baseKey,
            usageDate: "2026-07-18",
            force: false
        ))

        let changedPolicy = EarnedBudgetArming.legacyGenerationKey(
            deviceID: deviceID,
            timezoneIdentifier: "America/New_York",
            policyRevision: "policy-2",
            selectionBytes: Data("persisted-selection-a".utf8),
            enforcementSetID: enforcementSetID
        )
        let changedSelection = EarnedBudgetArming.legacyGenerationKey(
            deviceID: deviceID,
            timezoneIdentifier: "America/New_York",
            policyRevision: "policy-1",
            selectionBytes: Data("persisted-selection-b".utf8),
            enforcementSetID: enforcementSetID
        )

        XCTAssertTrue(EarnedBudgetArming.shouldReplaceLegacyGeneration(
            active,
            with: changedPolicy,
            usageDate: active.usageDate,
            force: false
        ))
        XCTAssertTrue(EarnedBudgetArming.shouldReplaceLegacyGeneration(
            active,
            with: changedSelection,
            usageDate: active.usageDate,
            force: false
        ))
        XCTAssertTrue(EarnedBudgetArming.shouldReplaceLegacyGeneration(
            active,
            with: baseKey,
            usageDate: "2026-07-19",
            force: false
        ))
    }

}

private struct IdentityCleanupUnavailableLock: DeviceEpochStoreLocking {
    func withLock<T>(_ body: () -> T) -> T? { nil }
}
