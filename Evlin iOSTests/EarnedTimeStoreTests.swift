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
            XCTAssertEqual(store.reconcileAcceptedUsage(
                usageDate: "2026-07-10", serverEstimatedMinutes: 15,
                allowSameDayDecrease: false
            ), 15)
            XCTAssertEqual(store.reconcileAcceptedUsage(
                usageDate: "2026-07-10", serverEstimatedMinutes: 5,
                allowSameDayDecrease: false
            ), 15)
            XCTAssertEqual(store.acceptedEstimateMinutes, 15)
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 15)
        }
    }

    func test_reconcileAcceptedUsage_newDateResetsToServer() {
        withIsolatedStore { store in
            _ = store.reconcileAcceptedUsage(
                usageDate: "2026-07-10", serverEstimatedMinutes: 40,
                allowSameDayDecrease: false
            )
            XCTAssertEqual(store.reconcileAcceptedUsage(
                usageDate: "2026-07-11", serverEstimatedMinutes: 0,
                allowSameDayDecrease: false
            ), 0)
            XCTAssertEqual(store.latestDeviceEstimate, 0)
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
        }
    }

    func test_reconcileAcceptedUsage_pausedResponseMayLowerSameDate() {
        withIsolatedStore { store in
            _ = store.reconcileAcceptedUsage(
                usageDate: "2026-07-10", serverEstimatedMinutes: 10,
                allowSameDayDecrease: false
            )
            XCTAssertEqual(store.reconcileAcceptedUsage(
                usageDate: "2026-07-10", serverEstimatedMinutes: 0,
                allowSameDayDecrease: true
            ), 0)
            XCTAssertEqual(store.latestDeviceEstimate, 0)
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
        }
    }

    func test_reconcileAcceptedUsageIfNotStale_rejectsOlderDateWithoutMutation() {
        withIsolatedStore { store in
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
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 8)
        }
    }

    func test_reconcileAcceptedUsageLock_serializesSameProcessCriticalSections() {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            let _: Void = EarnedTimeStore.withAcceptedUsageReconciliationLock {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            let _: Void = EarnedTimeStore.withAcceptedUsageReconciliationLock {
                secondEntered.signal()
            }
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut)

        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)
    }

    // MARK: - Child-state runtime policy

    func test_reconcileRuntimePolicy_validSnapshotWritesPolicyAndMonotonicAcceptedUsage() {
        withIsolatedStore { store in
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
            XCTAssertEqual(store.earnedUsageOffsetMinutes, 20)
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
