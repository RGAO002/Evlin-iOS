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
        EarnedActivityGeneration.persistLifecycle(
            .init(
                active: .init(
                    activityName: EarnedActivityGeneration.legacyActivityName,
                    deviceID: "b21411cb-63a5-4489-bc68-bf8ac26ee15b",
                    offsetMinutes: 5,
                    armSignature: "stable-signature",
                    usageDate: "2026-07-11",
                    timezoneIdentifier: "America/New_York"
                ),
                pending: nil
            ),
            defaults: defaults
        )
        var stopCount = 0

        EarnedBudgetArming.stopAndInvalidateSignature(
            defaults: defaults,
            stopMonitoring: { stopCount += 1 }
        )

        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(defaults.string(forKey: EarnedBudgetArming.armSignatureKey))
        let stoppedLifecycle = EarnedActivityGeneration.loadLifecycle(defaults: defaults)
        XCTAssertEqual(stoppedLifecycle?.isStopped, true)
        XCTAssertTrue(EarnedBudgetArming.shouldStartMonitoring(
            previousSignature: EarnedBudgetArming.previousArmSignature(
                lifecycle: stoppedLifecycle,
                scalarSignature: defaults.string(forKey: EarnedBudgetArming.armSignatureKey)
            ),
            nextSignature: "stable-signature",
            force: false
        ))
        defaults.set("stable-signature", forKey: EarnedBudgetArming.armSignatureKey)
        XCTAssertTrue(EarnedBudgetArming.shouldStartMonitoring(
            previousSignature: EarnedBudgetArming.previousArmSignature(
                lifecycle: stoppedLifecycle,
                scalarSignature: defaults.string(forKey: EarnedBudgetArming.armSignatureKey)
            ),
            nextSignature: "stable-signature",
            force: false
        ))
    }

    func test_interruptedStopTombstonePreventsLegacyMigrationAndForcesInstall() {
        let suiteName = "EarnedBudgetArmingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("stale-signature", forKey: EarnedBudgetArming.armSignatureKey)
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
            armSignature: "stale-signature",
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
        XCTAssertNil(EarnedBudgetArming.previousArmSignature(
            lifecycle: EarnedActivityGeneration.loadLifecycle(defaults: defaults),
            scalarSignature: defaults.string(forKey: EarnedBudgetArming.armSignatureKey)
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
            armSignature: "old-generation",
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
            armSignature: "old-generation",
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

    func test_policyTimezoneChangesArmSignatureEvenWhenDeviceTimezoneDoesNot() {
        let eastern = EarnedBudgetArming.makeArmSignature(
            deviceID: "device-a",
            usageDate: "2026-07-11",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 60,
            capMinutes: 45,
            offsetMinutes: 5,
            selectionFingerprint: "selection-a"
        )
        let pacific = EarnedBudgetArming.makeArmSignature(
            deviceID: "device-a",
            usageDate: "2026-07-11",
            timezoneIdentifier: "America/Los_Angeles",
            poolMinutes: 60,
            capMinutes: 45,
            offsetMinutes: 5,
            selectionFingerprint: "selection-a"
        )

        XCTAssertNotEqual(eastern, pacific)
    }
}
