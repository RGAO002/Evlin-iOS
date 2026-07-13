import XCTest
import FamilyControls
@testable import Evlin_iOS

/// B3: EarnedTimeStore — App Group persistence for the earned screen-time subsystem.
///
/// Tests are written against real App-Group UserDefaults (`group.com.evlin.ios`)
/// — the same suite the DeviceActivity extension reads. `FamilyActivitySelection`
/// is Codable via JSON. `ApplicationToken` values cannot be minted in a unit test,
/// so we exercise the selection round-trip with an empty selection (zero tokens),
/// which proves the encode/decode path without hitting the ScreenTime entitlement
/// wall. The Locked-set id round-trip uses a plain UUID string, which is the only
/// field the extension needs for its offline tripwire.
final class EarnedTimeStoreTests: XCTestCase {

    private var isolatedSuiteName: String?

    private func freshStore() -> EarnedTimeStore {
        let s = EarnedTimeStore.shared
        s.removeAll()
        return s
    }

    override func tearDown() {
        if let isolatedSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: isolatedSuiteName)
            self.isolatedSuiteName = nil
        } else {
            EarnedTimeStore.shared.removeAll()
        }
        super.tearDown()
    }

    private func withIsolatedStore(_ body: (EarnedTimeStore) -> Void) {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        isolatedSuiteName = suiteName
        body(EarnedTimeStore(suiteName: suiteName))
    }

    func test_productionSuiteSelectsSharedAppGroupLockFile() {
        let container = URL(fileURLWithPath: "/tmp/earned-app-group", isDirectory: true)

        XCTAssertEqual(
            EarnedTimeStore.reconciliationLockSelection(
                suiteName: EarnedTimeStore.appGroupSuiteName,
                containerURL: container
            ),
            .file(container.appendingPathComponent("earned-runtime.lock"))
        )
    }

    func test_productionSuiteWithoutContainerIsExplicitlyUnavailable() {
        XCTAssertEqual(
            EarnedTimeStore.reconciliationLockSelection(
                suiteName: EarnedTimeStore.appGroupSuiteName,
                containerURL: nil
            ),
            .unavailable("missing_app_group_container")
        )
    }

    func test_explicitFileLockSerializesIndependentStoresAndPreservesMonotonicUsage() {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        isolatedSuiteName = suiteName
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let first = EarnedTimeStore(
            suiteName: suiteName,
            lockSelection: .file(lockURL),
            useInProcessLock: false
        )
        let second = EarnedTimeStore(
            suiteName: suiteName,
            lockSelection: .file(lockURL),
            useInProcessLock: false
        )
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            XCTAssertTrue(first.withReconciliationLockForTesting {
                firstEntered.signal()
                releaseFirst.wait()
            })
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            XCTAssertTrue(second.withReconciliationLockForTesting {
                secondEntered.signal()
            })
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            _ = (index.isMultiple(of: 2) ? first : second).reconcileAcceptedUsage(
                usageDate: "2026-07-11",
                serverEstimatedMinutes: index.isMultiple(of: 3) ? 100 : 5,
                allowSameDayDecrease: false
            )
        }
        XCTAssertEqual(first.acceptedEstimateMinutes, 100)
        XCTAssertEqual(second.acceptedEstimateMinutes, 100)
    }

    func test_independentStoresCannotLowerSameDayAcceptedUsageUnderConcurrentWrites() {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        isolatedSuiteName = suiteName
        let first = EarnedTimeStore(suiteName: suiteName)
        let second = EarnedTimeStore(suiteName: suiteName)

        DispatchQueue.concurrentPerform(iterations: 400) { index in
            let store = index.isMultiple(of: 2) ? first : second
            _ = store.reconcileAcceptedUsage(
                usageDate: "2026-07-11",
                serverEstimatedMinutes: index.isMultiple(of: 3) ? 100 : 5,
                allowSameDayDecrease: false
            )
        }

        XCTAssertEqual(first.acceptedEstimateMinutes, 100)
        XCTAssertEqual(second.acceptedEstimateMinutes, 100)
    }

    func test_lockOpenFailureIsDiagnosticAndFailClosedWithoutRuntimeWrites() throws {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        isolatedSuiteName = suiteName
        let seeded = EarnedTimeStore(suiteName: suiteName)
        XCTAssertEqual(seeded.reconcileRuntimePolicy(
            usageDate: "2026-07-11",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 60,
            capMinutes: 45,
            remainingMinutes: 30,
            estimatedMinutes: 20
        ), .reconciled(20))
        let failing = EarnedTimeStore(
            suiteName: suiteName,
            lockSelection: .file(
                URL(fileURLWithPath: "/dev/null/earned-runtime.lock")
            )
        )

        XCTAssertEqual(failing.reconcileAcceptedUsage(
            usageDate: "2026-07-11",
            serverEstimatedMinutes: 0,
            allowSameDayDecrease: true
        ), 20)
        XCTAssertEqual(failing.reconcileAcceptedUsageIfNotStale(
            usageDate: "2026-07-11",
            serverEstimatedMinutes: 0,
            allowSameDayDecrease: true
        ), .lockUnavailable)
        XCTAssertEqual(failing.reconcileRuntimePolicy(
            usageDate: "2026-07-11",
            timezoneIdentifier: "America/Los_Angeles",
            poolMinutes: 10,
            capMinutes: 10,
            remainingMinutes: 5,
            estimatedMinutes: 0
        ), .lockUnavailable)

        XCTAssertEqual(seeded.acceptedEstimateMinutes, 20)
        XCTAssertEqual(seeded.poolMinutes, 60)
        XCTAssertEqual(seeded.capMinutes, 45)
        XCTAssertEqual(seeded.runtimeTimezoneIdentifier, "America/New_York")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertTrue(
            defaults.string(forKey: EarnedTimeStore.reconciliationLockFailureKey)?
                .contains("stage=open") == true
        )
    }

    func test_transactionWithNilDefaultsDoesNotRunBody() {
        var bodyRan = false
        let store = EarnedTimeStore(
            suiteName: "EarnedTimeStoreTests.nil-defaults",
            defaultsFactory: { _ in nil }
        )

        let acquired = store.withReconciliationLockForTesting { bodyRan = true }

        XCTAssertFalse(acquired)
        XCTAssertFalse(bodyRan)
    }

    func test_falseSynchronizeStillRunsAndCommitsTransactionBody() {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = UserDefaults(suiteName: suiteName)
        var bodyRan = false
        let store = EarnedTimeStore(
            suiteName: suiteName,
            synchronizeDefaults: { _ in false }
        )

        let acquired = store.withReconciliationLockForTesting { bodyRan = true }

        XCTAssertTrue(acquired)
        XCTAssertTrue(bodyRan)
        XCTAssertNil(defaults?.string(forKey: EarnedTimeStore.reconciliationLockFailureKey))
        XCTAssertTrue(
            defaults?.string(
                forKey: EarnedTimeStore.reconciliationSynchronizeDiagnosticKey
            )?.contains("synchronize_nonfatal") == true
        )
    }

    func test_readBackMismatchRollsBackRuntimeFields() {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        let staleSuite = "EarnedTimeStoreTests.stale.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removePersistentDomain(forName: staleSuite)
        }
        let deviceID = UUID()
        let oldSync = Date(timeIntervalSince1970: 100)
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(deviceID.uuidString.lowercased(), forKey: "evlin.childId")
        let seeded = EarnedTimeStore(suiteName: suiteName)
        XCTAssertEqual(seeded.reconcileRuntimePolicy(
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 90,
            capMinutes: 60,
            remainingMinutes: 40,
            estimatedMinutes: 20,
            syncedAt: oldSync
        ), .reconciled(20))
        seeded.markPendingUncountedReconciliation(
            deviceID: deviceID,
            usageDate: "2026-07-13"
        )
        let failing = EarnedTimeStore(
            suiteName: suiteName,
            verificationDefaultsFactory: { _ in UserDefaults(suiteName: staleSuite) },
            synchronizeDefaults: { _ in false }
        )

        XCTAssertEqual(failing.reconcileRuntimePolicy(
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/Los_Angeles",
            poolMinutes: 30,
            capMinutes: 25,
            remainingMinutes: 5,
            estimatedMinutes: 25,
            syncedAt: Date(timeIntervalSince1970: 200)
        ), .lockUnavailable)
        XCTAssertEqual(seeded.poolMinutes, 90)
        XCTAssertEqual(seeded.capMinutes, 60)
        XCTAssertEqual(seeded.runtimeTimezoneIdentifier, "America/New_York")
        XCTAssertEqual(seeded.backendRemainingAtLastSync, 40)
        XCTAssertEqual(seeded.lastBackendSyncAt, oldSync)
        XCTAssertEqual(seeded.acceptedUsageDate, "2026-07-13")
        XCTAssertEqual(seeded.acceptedEstimateMinutes, 20)
        XCTAssertEqual(seeded.latestDeviceEstimate, 20)
        XCTAssertTrue(seeded.hasPendingUncountedReconciliation(
            deviceID: deviceID,
            usageDate: "2026-07-13"
        ))
    }

    func test_falsePostWriteSynchronizeCommitsAcceptedUsageAfterReadBack() {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        var outcomes = [true, false]
        let store = EarnedTimeStore(
            suiteName: suiteName,
            synchronizeDefaults: { _ in outcomes.removeFirst() }
        )

        let result = store.reconcileAcceptedUsageIfNotStale(
            usageDate: "2026-07-12",
            serverEstimatedMinutes: 10,
            allowSameDayDecrease: false
        )

        XCTAssertEqual(result, .reconciled(10))
        XCTAssertEqual(store.acceptedEstimateMinutes, 10)
        XCTAssertEqual(store.acceptedUsageDate, "2026-07-12")
        XCTAssertEqual(store.latestDeviceEstimate, 10)
    }

    func test_falseSynchronizeCommitsEveryRuntimeFieldAfterReadBack() {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let seeded = EarnedTimeStore(suiteName: suiteName)
        let oldSync = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(seeded.reconcileRuntimePolicy(
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 90,
            capMinutes: 60,
            remainingMinutes: 40,
            estimatedMinutes: 20,
            syncedAt: oldSync
        ), .reconciled(20))
        let failing = EarnedTimeStore(
            suiteName: suiteName,
            synchronizeDefaults: { _ in false }
        )

        let result = failing.reconcileRuntimePolicy(
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/Los_Angeles",
            poolMinutes: 30,
            capMinutes: 25,
            remainingMinutes: 5,
            estimatedMinutes: 25,
            syncedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(result, .reconciled(25))
        XCTAssertEqual(seeded.poolMinutes, 30)
        XCTAssertEqual(seeded.capMinutes, 25)
        XCTAssertEqual(seeded.runtimeTimezoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(seeded.backendRemainingAtLastSync, 5)
        XCTAssertEqual(seeded.lastBackendSyncAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(seeded.acceptedUsageDate, "2026-07-12")
        XCTAssertEqual(seeded.acceptedEstimateMinutes, 25)
        XCTAssertEqual(seeded.latestDeviceEstimate, 25)
    }

    func test_localThresholdLockFailureDoesNotMutateEstimate() {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let seeded = EarnedTimeStore(suiteName: suiteName)
        seeded.latestDeviceEstimate = 25
        let unavailable = EarnedTimeStore(
            suiteName: suiteName,
            lockSelection: .unavailable("test_lock_unavailable")
        )

        XCTAssertEqual(unavailable.recordLocalThresholdEstimate(300), .lockUnavailable)
        XCTAssertEqual(seeded.latestDeviceEstimate, 25)
    }

    func test_falsePostWriteSynchronizeCommitsLocalThresholdAfterReadBack() {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let seeded = EarnedTimeStore(suiteName: suiteName)
        seeded.latestDeviceEstimate = 25
        var outcomes = [true, false]
        let failing = EarnedTimeStore(
            suiteName: suiteName,
            synchronizeDefaults: { _ in outcomes.removeFirst() }
        )

        XCTAssertEqual(failing.recordLocalThresholdEstimate(300), .reconciled)
        XCTAssertEqual(seeded.latestDeviceEstimate, 300)
    }

    func test_localThresholdRollbackDoesNotOverwriteCompetingNewerEstimate() {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let competing = EarnedTimeStore(suiteName: suiteName)
        competing.latestDeviceEstimate = 25
        var synchronizeCount = 0
        let failing = EarnedTimeStore(
            suiteName: suiteName,
            synchronizeDefaults: { _ in
                synchronizeCount += 1
                if synchronizeCount == 2 {
                    competing.latestDeviceEstimate = 400
                    return false
                }
                return true
            }
        )

        XCTAssertEqual(failing.recordLocalThresholdEstimate(300), .lockUnavailable)
        XCTAssertEqual(competing.latestDeviceEstimate, 400)
    }

    func test_generationDecodesLegacyJSONWithoutArmedAt() throws {
        let activityName = EarnedActivityGeneration.generatedActivityName(id: UUID())
        let json = """
        {"activityName":"\(activityName)","deviceID":"b21411cb-63a5-4489-bc68-bf8ac26ee15b","offsetMinutes":5,"armSignature":"legacy-signature","usageDate":"2026-07-13","timezoneIdentifier":"America/New_York"}
        """

        let generation = try JSONDecoder().decode(
            EarnedActivityGeneration.Generation.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(generation.armedAt)
        XCTAssertTrue(generation.isValid)
    }

    func test_generationRoundTripsArmedAtTimestamp() throws {
        let armedAt = Date(timeIntervalSince1970: 1_784_003_200)
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 5,
            armSignature: "timestamped-signature",
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York",
            armedAt: armedAt
        )

        let decoded = try JSONDecoder().decode(
            EarnedActivityGeneration.Generation.self,
            from: JSONEncoder().encode(generation)
        )

        XCTAssertEqual(decoded, generation)
        XCTAssertEqual(decoded.armedAt, armedAt)
    }

    func test_futureLifecycleVersionIsCorruptAndCannotAuthorizeCallback() throws {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 0,
            armSignature: "future-signature",
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York"
        )
        let future = EarnedActivityGeneration.Lifecycle(
            version: EarnedActivityGeneration.currentLifecycleVersion + 1,
            active: generation,
            pending: nil
        )
        let futureData = try JSONEncoder().encode(future)
        defaults.set(futureData, forKey: EarnedActivityGeneration.lifecycleKey)
        defaults.set([generation.activityName], forKey: EarnedActivityGeneration.lifecycleBreadcrumbsKey)
        var stopped: [String] = []

        XCTAssertThrowsError(try JSONDecoder().decode(
            EarnedActivityGeneration.Lifecycle.self,
            from: futureData
        ))
        XCTAssertNil(EarnedActivityGeneration.loadLifecycle(defaults: defaults))
        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: generation.activityName,
            currentDeviceID: generation.deviceID,
            lifecycle: future
        ))
        EarnedActivityGeneration.recoverPending(
            defaults: defaults,
            stopMonitoring: { stopped = $0 }
        )

        XCTAssertTrue(stopped.contains(generation.activityName))
        XCTAssertEqual(EarnedActivityGeneration.loadLifecycle(defaults: defaults)?.isStopped, true)
    }

    func test_promotionPersistenceFailureStopsNewGenerationAndRestoresPriorState() throws {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prior = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 10,
            armSignature: "prior-signature",
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York"
        )
        let priorLifecycle = EarnedActivityGeneration.Lifecycle(active: prior, pending: nil)
        XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(priorLifecycle, defaults: defaults))
        defaults.set(prior.activityName, forKey: EarnedActivityGeneration.activeActivityNameKey)
        let next = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: prior.deviceID,
            offsetMinutes: 20,
            armSignature: "next-signature",
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York"
        )
        var persistAttempt = 0
        var stopped: [[String]] = []

        let installed = EarnedActivityGeneration.installReplacement(
            next,
            defaults: defaults,
            startMonitoring: { _ in },
            stopMonitoring: { stopped.append($0) },
            persistLifecycle: { lifecycle, defaults in
                persistAttempt += 1
                if persistAttempt == 2 {
                    defaults?.removeObject(forKey: EarnedActivityGeneration.lifecycleKey)
                    defaults?.removeObject(forKey: EarnedActivityGeneration.lifecycleBreadcrumbsKey)
                    defaults?.removeObject(forKey: EarnedActivityGeneration.activeActivityNameKey)
                    return false
                }
                return EarnedActivityGeneration.persistLifecycle(lifecycle, defaults: defaults)
            }
        )

        XCTAssertFalse(installed)
        XCTAssertEqual(stopped, [[next.activityName]])
        XCTAssertEqual(EarnedActivityGeneration.loadLifecycle(defaults: defaults), priorLifecycle)
        XCTAssertEqual(
            defaults.stringArray(forKey: EarnedActivityGeneration.lifecycleBreadcrumbsKey),
            EarnedActivityGeneration.stopTargets(lifecycle: priorLifecycle)
        )
        XCTAssertEqual(
            defaults.string(forKey: EarnedActivityGeneration.activeActivityNameKey),
            prior.activityName
        )
    }

    func test_falseSynchronizePersistsLifecycleWhenExactReadBackMatches() throws {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 0,
            armSignature: "false-sync-signature",
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York"
        )
        let lifecycle = EarnedActivityGeneration.Lifecycle(
            active: generation,
            pending: nil
        )

        XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(
            lifecycle,
            defaults: defaults,
            synchronizeDefaults: { _ in false }
        ))
        XCTAssertEqual(
            EarnedActivityGeneration.loadLifecycle(defaults: defaults),
            lifecycle
        )
        XCTAssertEqual(
            defaults.stringArray(forKey: EarnedActivityGeneration.lifecycleBreadcrumbsKey),
            EarnedActivityGeneration.stopTargets(lifecycle: lifecycle)
        )
    }

    func test_lifecycleReadBackMismatchRemainsHardFailure() throws {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 0,
            armSignature: "mismatch-signature",
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York"
        )
        let lifecycle = EarnedActivityGeneration.Lifecycle(
            active: generation,
            pending: nil
        )

        XCTAssertFalse(EarnedActivityGeneration.persistLifecycle(
            lifecycle,
            defaults: defaults,
            synchronizeDefaults: { _ in false },
            readBackObject: { defaults, key in
                if key == EarnedActivityGeneration.lifecycleKey { return Data() }
                return defaults.object(forKey: key)
            }
        ))
    }

    func test_falseSynchronizeClearsLifecycleWhenReadBackIsEmpty() throws {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data([0x01]), forKey: EarnedActivityGeneration.lifecycleKey)
        defaults.set(
            [EarnedActivityGeneration.legacyActivityName],
            forKey: EarnedActivityGeneration.lifecycleBreadcrumbsKey
        )

        XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(
            .init(active: nil, pending: nil),
            defaults: defaults,
            synchronizeDefaults: { _ in false }
        ))
        XCTAssertNil(defaults.object(forKey: EarnedActivityGeneration.lifecycleKey))
        XCTAssertNil(defaults.object(forKey: EarnedActivityGeneration.lifecycleBreadcrumbsKey))
    }

    func test_runtimeTimezonePersistsAndDrivesUsageDateWhenDeviceTimezoneDiffers() {
        withIsolatedStore { store in
            let result = store.reconcileRuntimePolicy(
                usageDate: "2026-07-11",
                timezoneIdentifier: "America/Los_Angeles",
                poolMinutes: 60,
                capMinutes: 45,
                remainingMinutes: 30,
                estimatedMinutes: 15
            )

            XCTAssertEqual(result, .reconciled(15))
            XCTAssertEqual(store.runtimeTimezoneIdentifier, "America/Los_Angeles")
            XCTAssertEqual(
                store.usageContext(),
                .init(usageDate: "2026-07-11", timezoneIdentifier: "America/Los_Angeles")
            )

            store.acceptedUsageDate = nil
            let instant = Date(timeIntervalSince1970: 1_783_827_000) // 2026-07-12T03:30:00Z
            XCTAssertEqual(
                store.usageContext(
                    now: instant,
                    fallbackTimeZone: TimeZone(identifier: "Asia/Tokyo")!
                ),
                .init(usageDate: "2026-07-11", timezoneIdentifier: "America/Los_Angeles")
            )
        }
    }

    func test_identityResetClearsRuntimeTimezone() {
        withIsolatedStore { store in
            _ = store.reconcileRuntimePolicy(
                usageDate: "2026-07-11",
                timezoneIdentifier: "America/New_York",
                poolMinutes: 60,
                capMinutes: 45,
                remainingMinutes: 30,
                estimatedMinutes: 15
            )

            store.clearUsageStateForIdentityChange()

            XCTAssertNil(store.runtimeTimezoneIdentifier)
        }
    }

    func test_authoritativeReadinessRequiresExactDeviceAndClearsOnIdentityReset() {
        withIsolatedStore { store in
            let readyID = UUID()
            let otherID = UUID()

            store.markAuthoritativeStateReady(deviceID: readyID)

            XCTAssertTrue(store.isAuthoritativeStateReady(deviceID: readyID))
            XCTAssertFalse(store.isAuthoritativeStateReady(deviceID: otherID))
            store.clearUsageStateForIdentityChange()
            XCTAssertFalse(store.isAuthoritativeStateReady(deviceID: readyID))
        }
    }

    func test_counterRecoveryMarkerPersistsPerDeviceAndClearsOnIdentityReset() {
        withIsolatedStore { store in
            let deviceID = UUID()
            let otherID = UUID()

            store.setCounterRecoveryRequired(true, deviceID: deviceID)

            XCTAssertTrue(store.isCounterRecoveryRequired(deviceID: deviceID))
            XCTAssertFalse(store.isCounterRecoveryRequired(deviceID: otherID))
            store.clearUsageStateForIdentityChange()
            XCTAssertFalse(store.isCounterRecoveryRequired(deviceID: deviceID))
        }
    }

    func test_pendingUncountedMarkerNeverAppliesAcrossIdentityOrDate() throws {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldID = UUID()
        let newID = UUID()
        let store = EarnedTimeStore(suiteName: suiteName)
        defaults.set(oldID.uuidString, forKey: "evlin.childId")
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-12",
            serverEstimatedMinutes: 25,
            allowSameDayDecrease: false
        )
        store.markPendingUncountedReconciliation(
            deviceID: oldID,
            usageDate: "2026-07-12"
        )

        defaults.set(newID.uuidString, forKey: "evlin.childId")
        XCTAssertEqual(store.reconcileRuntimePolicy(
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 60,
            capMinutes: 60,
            remainingMinutes: 60,
            estimatedMinutes: 0
        ), .reconciled(25))
        XCTAssertEqual(store.acceptedEstimateMinutes, 25)
        XCTAssertTrue(store.hasPendingUncountedReconciliation(
            deviceID: oldID,
            usageDate: "2026-07-12"
        ))

        defaults.set(oldID.uuidString, forKey: "evlin.childId")
        XCTAssertEqual(store.reconcileRuntimePolicy(
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 60,
            capMinutes: 60,
            remainingMinutes: 60,
            estimatedMinutes: 0
        ), .reconciled(0))
        XCTAssertFalse(store.hasPendingUncountedReconciliation(
            deviceID: oldID,
            usageDate: "2026-07-12"
        ))
    }

    // MARK: - isEarnedTimeReady

    func test_isEarnedTimeReady_falseWhenNeitherPresent() {
        let store = freshStore()
        XCTAssertFalse(store.isEarnedTimeReady)
    }

    func test_isEarnedTimeReady_falseWhenOnlyMeasurementSelectionPresent() {
        let store = freshStore()
        store.saveMeasurementSelection(FamilyActivitySelection())
        XCTAssertFalse(store.isEarnedTimeReady)
    }

    func test_hasMeasurableSelection_falseForEmptySavedSelection() {
        let store = freshStore()
        store.saveMeasurementSelection(FamilyActivitySelection())

        XCTAssertFalse(store.hasMeasurableSelection)
    }

    @MainActor
    func test_identityOwnerComparison_treatsUUIDCaseAsSameIdentity() {
        let id = UUID()

        XCTAssertTrue(EarnedBudgetArming.isSameDeviceIdentity(
            id.uuidString.lowercased(),
            id.uuidString.uppercased()
        ))
    }

    func test_localThresholdRollsBackUnderLockWhenMirrorChangesBeforeCommit() throws {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(suiteName: suiteName)
        let oldID = UUID()
        let newID = UUID()
        defaults.set(oldID.uuidString, forKey: "evlin.childId")
        store.latestDeviceEstimate = 25

        let result = store.recordLocalThresholdEstimate(
            60,
            expectedDeviceID: oldID,
            beforeCommit: {
                defaults.set(newID.uuidString, forKey: "evlin.childId")
            }
        )

        XCTAssertEqual(result, .identityMismatch)
        XCTAssertEqual(store.latestDeviceEstimate, 25)
        XCTAssertEqual(defaults.string(forKey: "evlin.childId"), newID.uuidString)
    }

    func test_localThresholdTeardownAfterWriteDoesNotResurrectOldEstimate() throws {
        let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(suiteName: suiteName)
        let oldID = UUID()
        defaults.set(oldID.uuidString, forKey: "evlin.childId")
        store.latestDeviceEstimate = 25

        let result = store.recordLocalThresholdEstimate(
            60,
            expectedDeviceID: oldID,
            beforeCommit: {
                defaults.removeObject(forKey: "evlin.childId")
                store.clearUsageStateForIdentityChange()
            }
        )

        XCTAssertEqual(result, .identityMismatch)
        XCTAssertNil(store.latestDeviceEstimate)
        XCTAssertNil(defaults.string(forKey: "evlin.childId"))
    }

    func test_isEarnedTimeReady_falseWhenOnlyLockedSetIdPresent() {
        let store = freshStore()
        let id = UUID()
        store.saveLockedSetID(id.uuidString, tokenData: nil)
        XCTAssertFalse(store.isEarnedTimeReady)
    }

    func test_isEarnedTimeReady_falseWhenLockedSetIdAndEmptySelectionPresent() {
        let store = freshStore()
        store.saveMeasurementSelection(FamilyActivitySelection())
        store.saveLockedSetID(UUID().uuidString, tokenData: nil)
        XCTAssertFalse(store.isEarnedTimeReady)
    }

    // MARK: - Measurement selection round-trip

    func test_measurementSelection_roundTrips_emptySelection() throws {
        let store = freshStore()
        let sel = FamilyActivitySelection()
        store.saveMeasurementSelection(sel)

        let loaded = try XCTUnwrap(store.measurementSelection)
        // applicationTokens + categoryTokens are empty; equality holds because
        // FamilyActivitySelection is Equatable.
        XCTAssertEqual(loaded.applicationTokens, sel.applicationTokens)
        XCTAssertEqual(loaded.categoryTokens, sel.categoryTokens)
    }

    func test_measurementSelection_nilBeforeSave() {
        let store = freshStore()
        XCTAssertNil(store.measurementSelection)
    }

    func test_measurementSelection_persistsAcrossInstances() throws {
        let store = freshStore()
        store.saveMeasurementSelection(FamilyActivitySelection())

        let reloaded = EarnedTimeStore()
        XCTAssertNotNil(reloaded.measurementSelection)
    }

    // MARK: - Locked-set id round-trip

    func test_lockedSetID_roundTrips() {
        let store = freshStore()
        let id = UUID().uuidString
        store.saveLockedSetID(id, tokenData: nil)

        XCTAssertEqual(store.lockedSetID, id)
    }

    func test_lockedSetID_nilBeforeSave() {
        let store = freshStore()
        XCTAssertNil(store.lockedSetID)
    }

    func test_lockedSetTokenData_roundTrips() throws {
        let store = freshStore()
        let payload = Data("fake-token-blob".utf8)
        store.saveLockedSetID(UUID().uuidString, tokenData: payload)

        let loaded = try XCTUnwrap(store.lockedSetTokenData)
        XCTAssertEqual(loaded, payload)
    }

    func test_lockedSetID_persistsAcrossInstances() {
        let store = freshStore()
        let id = UUID().uuidString
        store.saveLockedSetID(id, tokenData: nil)

        let reloaded = EarnedTimeStore()
        XCTAssertEqual(reloaded.lockedSetID, id)
    }

    // MARK: - Override flag

    func test_overrideFlag_falseByDefault() {
        let store = freshStore()
        XCTAssertFalse(store.isOverridden(forUsageDate: "2026-06-23"))
    }

    func test_overrideFlag_setForDate() {
        let store = freshStore()
        store.setOverride(true, forUsageDate: "2026-06-23")
        XCTAssertTrue(store.isOverridden(forUsageDate: "2026-06-23"))
    }

    func test_overrideFlag_clearForDate() {
        let store = freshStore()
        store.setOverride(true, forUsageDate: "2026-06-23")
        store.setOverride(false, forUsageDate: "2026-06-23")
        XCTAssertFalse(store.isOverridden(forUsageDate: "2026-06-23"))
    }

    func test_overrideFlag_doesNotLeakToOtherDate() {
        let store = freshStore()
        store.setOverride(true, forUsageDate: "2026-06-23")
        XCTAssertFalse(store.isOverridden(forUsageDate: "2026-06-24"))
    }

    // MARK: - backendRemainingAtLastSync

    func test_backendRemaining_roundTrips() {
        let store = freshStore()
        store.backendRemainingAtLastSync = 42
        XCTAssertEqual(store.backendRemainingAtLastSync, 42)
    }

    func test_backendRemaining_nilBeforeSave() {
        let store = freshStore()
        XCTAssertNil(store.backendRemainingAtLastSync)
    }

    func test_backendRemaining_persistsAcrossInstances() {
        let store = freshStore()
        store.backendRemainingAtLastSync = 99
        let reloaded = EarnedTimeStore()
        XCTAssertEqual(reloaded.backendRemainingAtLastSync, 99)
    }

    // MARK: - latestDeviceEstimate

    func test_latestDeviceEstimate_roundTrips() {
        let store = freshStore()
        store.latestDeviceEstimate = 15
        XCTAssertEqual(store.latestDeviceEstimate, 15)
    }

    func test_latestDeviceEstimate_nilBeforeSave() {
        let store = freshStore()
        XCTAssertNil(store.latestDeviceEstimate)
    }

    func test_latestDeviceEstimate_persistsAcrossInstances() {
        let store = freshStore()
        store.latestDeviceEstimate = 7
        let reloaded = EarnedTimeStore()
        XCTAssertEqual(reloaded.latestDeviceEstimate, 7)
    }

    // MARK: - Accepted usage baseline

    func test_reconcileAcceptedUsage_isMonotoneWithinUsageDate() {
        withIsolatedStore { store in
            store.earnedUsageOffsetMinutes = 3
            XCTAssertEqual(store.reconcileAcceptedUsage(
                usageDate: "2026-07-10", serverEstimatedMinutes: 15,
                allowSameDayDecrease: false
            ), 15)
            XCTAssertEqual(store.reconcileAcceptedUsage(
                usageDate: "2026-07-10", serverEstimatedMinutes: 5,
                allowSameDayDecrease: false
            ), 15)
            XCTAssertEqual(store.acceptedEstimateMinutes, 15)
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 3)
        }
    }

    func test_reconcileAcceptedUsage_newDateResetsToServer() {
        withIsolatedStore { store in
            store.earnedUsageOffsetMinutes = 12
            _ = store.reconcileAcceptedUsage(
                usageDate: "2026-07-10", serverEstimatedMinutes: 40,
                allowSameDayDecrease: false
            )
            XCTAssertEqual(store.reconcileAcceptedUsage(
                usageDate: "2026-07-11", serverEstimatedMinutes: 0,
                allowSameDayDecrease: false
            ), 0)
            XCTAssertEqual(store.latestDeviceEstimate, 0)
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 12)
        }
    }

    func test_reconcileAcceptedUsage_pausedResponseMayLowerSameDate() {
        withIsolatedStore { store in
            store.earnedUsageOffsetMinutes = 4
            _ = store.reconcileAcceptedUsage(
                usageDate: "2026-07-10", serverEstimatedMinutes: 10,
                allowSameDayDecrease: false
            )
            XCTAssertEqual(store.reconcileAcceptedUsage(
                usageDate: "2026-07-10", serverEstimatedMinutes: 0,
                allowSameDayDecrease: true
            ), 0)
            XCTAssertEqual(store.latestDeviceEstimate, 0)
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 4)
        }
    }

    func test_countedT5LeavesRunningOffsetZeroSoRawT10AdjustsToTen() {
        withIsolatedStore { store in
            store.earnedUsageOffsetMinutes = 0

            _ = store.reconcileAcceptedUsage(
                usageDate: "2026-07-10",
                serverEstimatedMinutes: 5,
                allowSameDayDecrease: false
            )

            XCTAssertEqual(store.acceptedEstimateMinutes, 5)
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
            XCTAssertEqual(
                EarnedTimeStore.adjustedEarnedThreshold(
                    rawThresholdMinutes: 10,
                    runningOffsetMinutes: store.earnedUsageOffsetMinutes
                ),
                10
            )
        }
    }

    func test_reconcileAcceptedUsageIfNotStale_rejectsOlderDateWithoutMutation() {
        withIsolatedStore { store in
            store.earnedUsageOffsetMinutes = 3
            _ = store.reconcileAcceptedUsage(
                usageDate: "2026-07-11",
                serverEstimatedMinutes: 8,
                allowSameDayDecrease: false
            )

            let result = store.reconcileAcceptedUsageIfNotStale(
                usageDate: "2026-07-10",
                serverEstimatedMinutes: 100,
                allowSameDayDecrease: true
            )

            XCTAssertEqual(result, .stale(acceptedUsageDate: "2026-07-11"))
            XCTAssertEqual(store.acceptedUsageDate, "2026-07-11")
            XCTAssertEqual(store.acceptedEstimateMinutes, 8)
            XCTAssertEqual(store.latestDeviceEstimate, 8)
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 3)
        }
    }

    // MARK: - Child-state runtime policy

    func test_reconcileRuntimePolicy_validSnapshotWritesPolicyAndMonotonicAcceptedUsage() {
        withIsolatedStore { store in
            store.earnedUsageOffsetMinutes = 5
            _ = store.reconcileAcceptedUsage(
                usageDate: "2026-07-11",
                serverEstimatedMinutes: 20,
                allowSameDayDecrease: false
            )
            let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)

            let result = store.reconcileRuntimePolicy(
                usageDate: "2026-07-11",
                timezoneIdentifier: "America/New_York",
                poolMinutes: 120,
                capMinutes: 90,
                remainingMinutes: 75,
                estimatedMinutes: 15,
                syncedAt: syncedAt
            )

            XCTAssertEqual(result, .reconciled(20))
            XCTAssertEqual(store.poolMinutes, 120)
            XCTAssertEqual(store.capMinutes, 90)
            XCTAssertEqual(store.backendRemainingAtLastSync, 75)
            XCTAssertEqual(store.lastBackendSyncAt, syncedAt)
            XCTAssertEqual(store.acceptedUsageDate, "2026-07-11")
            XCTAssertEqual(store.acceptedEstimateMinutes, 20)
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 5)
        }
    }

    func test_reconcileRuntimePolicy_staleSnapshotWritesNoPolicyFields() {
        withIsolatedStore { store in
            _ = store.reconcileRuntimePolicy(
                usageDate: "2026-07-11",
                timezoneIdentifier: "America/New_York",
                poolMinutes: 120,
                capMinutes: 100,
                remainingMinutes: 80,
                estimatedMinutes: 20,
                syncedAt: Date(timeIntervalSince1970: 200)
            )

            let result = store.reconcileRuntimePolicy(
                usageDate: "2026-07-10",
                timezoneIdentifier: "America/New_York",
                poolMinutes: 30,
                capMinutes: 25,
                remainingMinutes: 5,
                estimatedMinutes: 25,
                syncedAt: Date(timeIntervalSince1970: 300)
            )

            XCTAssertEqual(result, .stale(acceptedUsageDate: "2026-07-11"))
            XCTAssertEqual(store.poolMinutes, 120)
            XCTAssertEqual(store.capMinutes, 100)
            XCTAssertEqual(store.backendRemainingAtLastSync, 80)
            XCTAssertEqual(store.lastBackendSyncAt, Date(timeIntervalSince1970: 200))
            XCTAssertEqual(store.acceptedUsageDate, "2026-07-11")
            XCTAssertEqual(store.acceptedEstimateMinutes, 20)
        }
    }

    func test_reconcileRuntimePolicy_rejectsMalformedRuntimeWithoutWrites() {
        withIsolatedStore { store in
            store.poolMinutes = 90
            store.capMinutes = 60
            store.backendRemainingAtLastSync = 42
            store.lastBackendSyncAt = Date(timeIntervalSince1970: 100)

            let invalidInputs: [(String, String, Int, Int, Int, Int)] = [
                ("2026-7-11", "America/New_York", 120, 120, 100, 20),
                ("2026-02-30", "America/New_York", 120, 120, 100, 20),
                ("2026-07-11", "Not/A_Timezone", 120, 120, 100, 20),
                ("2026-07-11", "America/New_York", 0, 120, 100, 20),
                ("2026-07-11", "America/New_York", 1441, 120, 100, 20),
                ("2026-07-11", "America/New_York", 120, 0, 100, 20),
                ("2026-07-11", "America/New_York", 120, 1441, 100, 20),
                ("2026-07-11", "America/New_York", 120, 120, -1, 20),
                ("2026-07-11", "America/New_York", 120, 120, 1441, 20),
                ("2026-07-11", "America/New_York", 120, 120, 100, -1),
                ("2026-07-11", "America/New_York", 120, 120, 100, 1441),
            ]

            for input in invalidInputs {
                XCTAssertEqual(store.reconcileRuntimePolicy(
                    usageDate: input.0,
                    timezoneIdentifier: input.1,
                    poolMinutes: input.2,
                    capMinutes: input.3,
                    remainingMinutes: input.4,
                    estimatedMinutes: input.5,
                    syncedAt: Date(timeIntervalSince1970: 999)
                ), .invalid)
            }

            XCTAssertEqual(store.poolMinutes, 90)
            XCTAssertEqual(store.capMinutes, 60)
            XCTAssertEqual(store.backendRemainingAtLastSync, 42)
            XCTAssertEqual(store.lastBackendSyncAt, Date(timeIntervalSince1970: 100))
            XCTAssertNil(store.acceptedUsageDate)
            XCTAssertNil(store.acceptedEstimateMinutes)
        }
    }

    // MARK: - usage counting gate

    func test_usageCountingAllowed_defaultsToTrueBeforeChildStateArrives() {
        let store = freshStore()
        XCTAssertTrue(store.usageCountingAllowed)
    }

    func test_usageCountingAllowed_roundTripsAcrossInstances() {
        let store = freshStore()
        store.usageCountingAllowed = false

        XCTAssertFalse(UserDefaults(suiteName: "group.com.evlin.ios")?.bool(
            forKey: "evlin.usageCountingAllowed"
        ) ?? true)

        store.usageCountingAllowed = true
        XCTAssertTrue(store.usageCountingAllowed)
    }

    // MARK: - Locked-set list alias key (locked-set-sync)

    func test_lockedSetListAliasKey_isNilByDefault() {
        let store = freshStore()
        XCTAssertNil(store.lockedSetListAliasKey)
    }

    func test_saveLockedSetListAliasKey_roundTrips() {
        let store = freshStore()
        let key = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        store.saveLockedSetListAliasKey(key)
        XCTAssertEqual(store.lockedSetListAliasKey, key)
    }

    func test_saveLockedSetListAliasKey_overwritesPreviousValue() {
        let store = freshStore()
        let key1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let key2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        store.saveLockedSetListAliasKey(key1)
        store.saveLockedSetListAliasKey(key2)
        XCTAssertEqual(store.lockedSetListAliasKey, key2)
    }

    func test_removeAll_clearsLockedSetListAliasKey() {
        let store = freshStore()
        store.saveLockedSetListAliasKey(UUID())
        store.removeAll()
        XCTAssertNil(store.lockedSetListAliasKey)
    }

    func test_clearUsageStateForIdentityChange_clearsAcceptedUsage() {
        let store = freshStore()
        store.acceptedUsageDate = "2026-07-10"
        store.acceptedEstimateMinutes = 10

        store.clearUsageStateForIdentityChange()

        XCTAssertNil(store.acceptedUsageDate)
        XCTAssertNil(store.acceptedEstimateMinutes)
    }

    // MARK: - removeAll (teardown helper)

    func test_removeAll_clearsEverything() {
        let store = freshStore()
        store.saveMeasurementSelection(FamilyActivitySelection())
        store.saveLockedSetID(UUID().uuidString, tokenData: Data("blob".utf8))
        store.setOverride(true, forUsageDate: "2026-06-23")
        store.backendRemainingAtLastSync = 30
        store.latestDeviceEstimate = 10
        store.usageCountingAllowed = false
        store.acceptedUsageDate = "2026-07-10"
        store.acceptedEstimateMinutes = 10

        store.removeAll()

        XCTAssertNil(store.measurementSelection)
        XCTAssertNil(store.lockedSetID)
        XCTAssertNil(store.lockedSetTokenData)
        XCTAssertFalse(store.isOverridden(forUsageDate: "2026-06-23"))
        XCTAssertNil(store.backendRemainingAtLastSync)
        XCTAssertNil(store.latestDeviceEstimate)
        XCTAssertNil(store.acceptedUsageDate)
        XCTAssertNil(store.acceptedEstimateMinutes)
        XCTAssertTrue(store.usageCountingAllowed)
        XCTAssertFalse(store.isEarnedTimeReady)
    }

    // MARK: - Per-app usage day scoping

    func test_appLimitUsageDate_isGregorianAndTimezoneAware() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 7
        components.day = 9
        components.hour = 23
        components.minute = 30
        let instant = try XCTUnwrap(components.date)

        XCTAssertEqual(
            EarnedTimeStore.appLimitUsageDate(
                now: instant,
                timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
            ),
            "2026-07-09"
        )
        XCTAssertEqual(
            EarnedTimeStore.appLimitUsageDate(
                now: instant,
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
            ),
            "2026-07-10"
        )
    }

    func test_appLimitOffset_persistsWithinSameUsageDate() {
        let store = freshStore()
        let ruleID = UUID()

        store.setAppLimitUsageOffset(
            ruleID: ruleID, usageDate: "2026-07-08", usedMinutes: 20
        )

        XCTAssertEqual(
            store.appLimitUsageOffsetMinutes(ruleID: ruleID, usageDate: "2026-07-08"),
            20
        )
    }

    func test_appLimitOffset_doesNotLeakIntoNextUsageDate() {
        let store = freshStore()
        let ruleID = UUID()

        store.setAppLimitUsageOffset(
            ruleID: ruleID, usageDate: "2026-07-08", usedMinutes: 20
        )

        XCTAssertEqual(
            store.appLimitUsageOffsetMinutes(ruleID: ruleID, usageDate: "2026-07-09"),
            0
        )
    }

    func test_appLimitReported_isMonotoneOnlyWithinUsageDate() {
        let store = freshStore()
        let ruleID = UUID()

        store.recordAppLimitUsage(
            ruleID: ruleID, usageDate: "2026-07-08", usedMinutes: 45
        )
        store.recordAppLimitUsage(
            ruleID: ruleID, usageDate: "2026-07-08", usedMinutes: 30
        )

        XCTAssertEqual(
            store.appLimitReportedMinutes(ruleID: ruleID, usageDate: "2026-07-08"),
            45
        )
        XCTAssertEqual(
            store.appLimitReportedMinutes(ruleID: ruleID, usageDate: "2026-07-09"),
            0
        )
    }

    func test_appLimitLegacyUnscopedValues_areIgnored() throws {
        let store = freshStore()
        let ruleID = UUID()
        let suite = try XCTUnwrap(UserDefaults(suiteName: "group.com.evlin.ios"))
        let id = ruleID.uuidString.lowercased()
        suite.set(99, forKey: "evlin.appLimitUsageOffset.\(id)")
        suite.set(99, forKey: "evlin.appLimitReported.\(id)")

        XCTAssertEqual(
            store.appLimitUsageOffsetMinutes(ruleID: ruleID, usageDate: "2026-07-09"),
            0
        )
        XCTAssertEqual(
            store.appLimitReportedMinutes(ruleID: ruleID, usageDate: "2026-07-09"),
            0
        )
    }

    func test_appLimitWrite_prunesSameRuleOldDatesAndLegacyOnly() throws {
        let store = freshStore()
        let ruleA = UUID()
        let ruleB = UUID()
        let day1 = "2026-07-08"
        let day2 = "2026-07-09"
        let suite = try XCTUnwrap(UserDefaults(suiteName: "group.com.evlin.ios"))
        let idA = ruleA.uuidString.lowercased()
        let idB = ruleB.uuidString.lowercased()

        store.setAppLimitUsageOffset(ruleID: ruleA, usageDate: day1, usedMinutes: 20)
        store.recordAppLimitUsage(ruleID: ruleA, usageDate: day1, usedMinutes: 45)
        XCTAssertEqual(
            store.appLimitUsageOffsetMinutes(ruleID: ruleA, usageDate: day1), 20
        )
        store.setAppLimitUsageOffset(ruleID: ruleA, usageDate: day1, usedMinutes: 25)
        XCTAssertEqual(
            store.appLimitReportedMinutes(ruleID: ruleA, usageDate: day1), 45
        )
        store.setAppLimitUsageOffset(ruleID: ruleB, usageDate: day1, usedMinutes: 7)
        store.recordAppLimitUsage(ruleID: ruleB, usageDate: day1, usedMinutes: 12)
        suite.set(88, forKey: "evlin.appLimitUsageOffset.\(idA)")
        suite.set(88, forKey: "evlin.appLimitReported.\(idA)")

        store.setAppLimitUsageOffset(ruleID: ruleA, usageDate: day2, usedMinutes: 5)

        XCTAssertNil(suite.object(forKey: "evlin.appLimitUsageOffset.\(idA).\(day1)"))
        XCTAssertNil(suite.object(forKey: "evlin.appLimitReported.\(idA).\(day1)"))
        XCTAssertNil(suite.object(forKey: "evlin.appLimitUsageOffset.\(idA)"))
        XCTAssertNil(suite.object(forKey: "evlin.appLimitReported.\(idA)"))
        XCTAssertEqual(
            suite.integer(forKey: "evlin.appLimitUsageOffset.\(idA).\(day2)"), 5
        )
        XCTAssertEqual(
            suite.integer(forKey: "evlin.appLimitUsageOffset.\(idB).\(day1)"), 7
        )
        XCTAssertEqual(
            suite.integer(forKey: "evlin.appLimitReported.\(idB).\(day1)"), 12
        )
    }

    func test_appLimitWrite_doesNotLetStaleDateEraseNewerUsage() {
        let store = freshStore()
        let ruleID = UUID()
        let staleDate = "2026-07-08"
        let currentDate = "2026-07-09"

        store.setAppLimitUsageOffset(
            ruleID: ruleID, usageDate: currentDate, usedMinutes: 20
        )
        store.recordAppLimitUsage(
            ruleID: ruleID, usageDate: currentDate, usedMinutes: 45
        )

        store.setAppLimitUsageOffset(
            ruleID: ruleID, usageDate: staleDate, usedMinutes: 5
        )
        store.recordAppLimitUsage(
            ruleID: ruleID, usageDate: staleDate, usedMinutes: 10
        )

        XCTAssertEqual(
            store.appLimitUsageOffsetMinutes(ruleID: ruleID, usageDate: currentDate), 20
        )
        XCTAssertEqual(
            store.appLimitReportedMinutes(ruleID: ruleID, usageDate: currentDate), 45
        )
        XCTAssertEqual(
            store.appLimitUsageOffsetMinutes(ruleID: ruleID, usageDate: staleDate), 0
        )
        XCTAssertEqual(
            store.appLimitReportedMinutes(ruleID: ruleID, usageDate: staleDate), 0
        )
    }
}
