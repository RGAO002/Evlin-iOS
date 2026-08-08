import XCTest
@testable import Evlin_iOS

@MainActor
final class EarnedBudgetArmingTests: XCTestCase {
    func test_legacyActiveGenerationRequiresReplacement() {
        let legacy = LegacyGenerationProvenance(
            activityName: LegacyMeteringActivity.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 5,
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York"
        )
        let timestamped = LegacyGenerationProvenance(
            activityName: LegacyMeteringActivity.generatedActivityName(id: UUID()),
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

    func test_identityMirrorClaimsEmptyEpochStoreForPairedOwner() throws {
        let suiteName = "EarnedBudgetArmingTests.emptyEpochOwner.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = UUID()
        defaults.set(owner.uuidString.lowercased(), forKey: "evlin.childId")
        let usageStore = EarnedTimeStore(suiteName: suiteName)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-budget-empty-owner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let epochStore = DeviceEpochStore(
            fileURL: fileURL,
            ownerProvider: {
                defaults.string(forKey: "evlin.childId").flatMap(UUID.init(uuidString:))
            }
        )
        XCTAssertNil(try epochStore.read().ownerChildDeviceID)

        EarnedBudgetArming.mirrorChildIdentity(
            owner,
            appGroupDefaults: defaults,
            readinessStore: usageStore,
            epochStore: epochStore
        )

        XCTAssertEqual(try epochStore.read().ownerChildDeviceID, owner)
        XCTAssertNil(try epochStore.read().identityCleanupWork)
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

    func test_newPairingAdoptsCompletedCleanupThatPreviouslyTargetedNoOwner() throws {
        let suiteName = "EarnedBudgetArmingTests.nilCleanupAdoption.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldOwner = UUID()
        let newOwner = UUID()
        defaults.set(oldOwner.uuidString.lowercased(), forKey: "evlin.childId")
        let usageStore = EarnedTimeStore(suiteName: suiteName)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-budget-nil-cleanup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let epochStore = DeviceEpochStore(
            fileURL: fileURL,
            ownerProvider: {
                defaults.string(forKey: "evlin.childId").flatMap(UUID.init(uuidString:))
            }
        )
        let now = Date(timeIntervalSince1970: 1_785_283_200)
        try seedEpochOwner(oldOwner, store: epochStore, now: now)

        EarnedBudgetArming.teardownFamilyIdentity(
            appGroupDefaults: defaults,
            store: usageStore,
            epochStore: epochStore,
            stopMonitoring: {},
            now: now
        )
        let originalWorkID = try XCTUnwrap(epochStore.read().identityCleanupWork?.workID)
        try epochStore.identityCleanupTransaction(workID: originalWorkID) { state, cleanup in
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
        XCTAssertTrue(try epochStore.markIdentityCleanupSucceeded(workID: originalWorkID))
        XCTAssertNil(try epochStore.read().identityCleanupWork?.newOwnerChildDeviceID)

        // Pairing persists the new mirror before this reconciliation runs.
        // The cleanup still needs to adopt that identity rather than treating
        // the already-written mirror as proof that no work remains.
        defaults.set(newOwner.uuidString.lowercased(), forKey: "evlin.childId")

        EarnedBudgetArming.mirrorChildIdentity(
            newOwner,
            appGroupDefaults: defaults,
            readinessStore: usageStore,
            epochStore: epochStore,
            stopMonitoring: {},
            now: now.addingTimeInterval(1)
        )

        let adopted = try XCTUnwrap(epochStore.read().identityCleanupWork)
        XCTAssertEqual(adopted.workID, originalWorkID)
        XCTAssertEqual(adopted.newOwnerChildDeviceID, newOwner)
        XCTAssertTrue(adopted.ownerMirrorTransitionAcknowledged)
        XCTAssertEqual(adopted.retry.terminal, .pending)
        XCTAssertEqual(
            defaults.string(forKey: "evlin.childId"),
            newOwner.uuidString.lowercased()
        )
        XCTAssertTrue(try epochStore.markIdentityCleanupSucceeded(workID: originalWorkID))
        XCTAssertTrue(try epochStore.finalizeIdentityCleanup(workID: originalWorkID))
        XCTAssertEqual(try epochStore.read().ownerChildDeviceID, newOwner)
        XCTAssertNil(try epochStore.read().identityCleanupWork)
    }

    func test_repairingSameDeviceAdoptsPendingCleanupThatTargetsNoOwner() throws {
        let suiteName = "EarnedBudgetArmingTests.sameOwnerCleanupAdoption.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = UUID()
        defaults.set(owner.uuidString.lowercased(), forKey: "evlin.childId")
        let usageStore = EarnedTimeStore(suiteName: suiteName)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-budget-same-owner-cleanup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let epochStore = DeviceEpochStore(
            fileURL: fileURL,
            ownerProvider: {
                defaults.string(forKey: "evlin.childId").flatMap(UUID.init(uuidString:))
            }
        )
        let now = Date(timeIntervalSince1970: 1_785_283_200)
        try seedEpochOwner(owner, store: epochStore, now: now)

        EarnedBudgetArming.teardownFamilyIdentity(
            appGroupDefaults: defaults,
            store: usageStore,
            epochStore: epochStore,
            stopMonitoring: {},
            now: now
        )
        let workID = try XCTUnwrap(epochStore.read().identityCleanupWork?.workID)
        XCTAssertNil(try epochStore.read().identityCleanupWork?.newOwnerChildDeviceID)

        // The backend may legitimately reuse the same child-device row when
        // this hardware signs out and pairs back to the same child.
        defaults.set(owner.uuidString.lowercased(), forKey: "evlin.childId")
        EarnedBudgetArming.mirrorChildIdentity(
            owner,
            appGroupDefaults: defaults,
            readinessStore: usageStore,
            epochStore: epochStore,
            stopMonitoring: {},
            now: now.addingTimeInterval(1)
        )

        let adopted = try XCTUnwrap(epochStore.read().identityCleanupWork)
        XCTAssertEqual(adopted.workID, workID)
        XCTAssertEqual(adopted.newOwnerChildDeviceID, owner)
        XCTAssertTrue(adopted.ownerMirrorTransitionAcknowledged)
    }

    func test_identityTransitionUsesChildMirrorWhenLegacyOwnerMarkerIsMissing() throws {
        let standardSuiteName = "EarnedBudgetArmingTests.standard.\(UUID().uuidString)"
        let appGroupSuiteName = "EarnedBudgetArmingTests.appGroup.\(UUID().uuidString)"
        let standardDefaults = try XCTUnwrap(UserDefaults(suiteName: standardSuiteName))
        let appGroupDefaults = try XCTUnwrap(UserDefaults(suiteName: appGroupSuiteName))
        defer {
            standardDefaults.removePersistentDomain(forName: standardSuiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupSuiteName)
        }
        let oldOwner = UUID()
        let newOwner = UUID()
        standardDefaults.set(
            newOwner.uuidString.lowercased(),
            forKey: CommandPoller.childDeviceIDDefaultsKey
        )
        appGroupDefaults.set(oldOwner.uuidString.lowercased(), forKey: "evlin.childId")
        XCTAssertNil(appGroupDefaults.string(forKey: EarnedBudgetArming.identityOwnerKey))

        let usageStore = EarnedTimeStore(suiteName: appGroupSuiteName)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-budget-missing-owner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let epochStore = DeviceEpochStore(
            fileURL: fileURL,
            ownerProvider: {
                appGroupDefaults.string(forKey: "evlin.childId").flatMap(UUID.init(uuidString:))
            }
        )
        let now = Date(timeIntervalSince1970: 1_785_283_200)
        try seedEpochOwner(oldOwner, store: epochStore, now: now)

        let transitioned = EarnedBudgetArming.reconcileIdentityTransition(
            epochStore: epochStore,
            standardDefaults: standardDefaults,
            appGroupDefaults: appGroupDefaults,
            readinessStore: usageStore
        )

        XCTAssertTrue(transitioned)
        XCTAssertEqual(
            appGroupDefaults.string(forKey: "evlin.childId"),
            newOwner.uuidString.lowercased()
        )
        XCTAssertEqual(
            appGroupDefaults.string(forKey: EarnedBudgetArming.identityOwnerKey),
            newOwner.uuidString.lowercased()
        )
        let cleanup = try XCTUnwrap(epochStore.read().identityCleanupWork)
        XCTAssertEqual(cleanup.oldOwnerChildDeviceID, oldOwner)
        XCTAssertEqual(cleanup.newOwnerChildDeviceID, newOwner)
        XCTAssertTrue(cleanup.ownerMirrorTransitionAcknowledged)
    }

    func test_identityTransitionDoesNotAdvanceMarkerWhenCleanupCannotPersist() throws {
        let standardSuiteName = "EarnedBudgetArmingTests.failed.standard.\(UUID().uuidString)"
        let appGroupSuiteName = "EarnedBudgetArmingTests.failed.appGroup.\(UUID().uuidString)"
        let standardDefaults = try XCTUnwrap(UserDefaults(suiteName: standardSuiteName))
        let appGroupDefaults = try XCTUnwrap(UserDefaults(suiteName: appGroupSuiteName))
        defer {
            standardDefaults.removePersistentDomain(forName: standardSuiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupSuiteName)
        }
        let oldOwner = UUID()
        let newOwner = UUID()
        standardDefaults.set(
            newOwner.uuidString.lowercased(),
            forKey: CommandPoller.childDeviceIDDefaultsKey
        )
        appGroupDefaults.set(oldOwner.uuidString.lowercased(), forKey: "evlin.childId")
        appGroupDefaults.set(
            newOwner.uuidString.lowercased(),
            forKey: EarnedBudgetArming.identityOwnerKey
        )
        let epochStore = DeviceEpochStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("unavailable-transition-\(UUID().uuidString).json"),
            lock: IdentityCleanupUnavailableLock(),
            ownerProvider: {
                appGroupDefaults.string(forKey: "evlin.childId").flatMap(UUID.init(uuidString:))
            }
        )

        let transitioned = EarnedBudgetArming.reconcileIdentityTransition(
            epochStore: epochStore,
            standardDefaults: standardDefaults,
            appGroupDefaults: appGroupDefaults,
            readinessStore: EarnedTimeStore(suiteName: appGroupSuiteName)
        )

        XCTAssertFalse(transitioned)
        XCTAssertEqual(
            appGroupDefaults.string(forKey: "evlin.childId"),
            oldOwner.uuidString.lowercased()
        )
        XCTAssertEqual(
            appGroupDefaults.string(forKey: EarnedBudgetArming.identityOwnerKey),
            oldOwner.uuidString.lowercased()
        )
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

    func test_legacyLadderIsDisabledForEveryProtocolSelection() {
        XCTAssertFalse(EarnedBudgetScheduler.canInstallLegacyLadder(localSelection: nil))
        XCTAssertFalse(EarnedBudgetScheduler.canInstallLegacyLadder(localSelection: .v1))
        XCTAssertFalse(EarnedBudgetScheduler.canInstallLegacyLadder(localSelection: .v2Pending))
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
        let active = LegacyGenerationProvenance(
            activityName: LegacyMeteringActivity.generatedActivityName(id: UUID()),
            deviceID: deviceID.uuidString,
            offsetMinutes: 5,
            usageDate: "2026-07-18",
            timezoneIdentifier: "America/New_York",
            generationKey: baseKey,
            armedAt: Date()
        )
        let sameIdentityWithAdvancedOffset = LegacyGenerationProvenance(
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
