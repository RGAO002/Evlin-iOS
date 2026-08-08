import Foundation
import XCTest
@testable import Evlin_iOS

final class AppLimitEffectJournalTests: XCTestCase {
    func testActiveLockPersistenceFalseSynchronizeStillPersistsExactReadback() throws {
        let suiteName = "ActiveLockPersistence.false-sync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(FalseSynchronizeUserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UserDefaultsActiveLockShieldPersistence(defaults: defaults)
        let record = ShieldRecord(
            recordKey: "exactApp:com.example.focus",
            tier: .exactApp,
            targetKey: "com.example.focus",
            displayName: "Focus",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: referenceDate,
            expiresAt: nil,
            originalRequest: "limit reached",
            targetChildID: UUID(),
            sources: [.limit]
        )

        try persistence.persist([record.recordKey: record])

        XCTAssertEqual(try persistence.load()[record.recordKey]?.recordKey, record.recordKey)
    }

    func testJournalFalseSynchronizeStillClaimsAfterExactReadback() throws {
        let fixture = try makeHarness().fixture
        let callback = try acceptedCallback(fixture, threshold: 5)
        let suiteName = "AppLimitEffectJournalTests.false-sync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(FalseSynchronizeUserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let journal = AppLimitEffectJournal(defaults: defaults, epochStore: fixture.store)

        _ = try journal.enqueue(callback, now: referenceDate)
        let claim = try journal.claimNext(
            workerID: workerA,
            now: referenceDate.addingTimeInterval(1),
            leaseDuration: 30
        )

        XCTAssertNotNil(claim)
    }

    func testShieldPersistenceFalseSynchronizeStillPersistsExactReadback() throws {
        let store = ShieldPersistenceStoreStub()
        store.synchronizeResult = false
        let persistence = AppLimitShieldPersistence(
            store: store,
            storageKey: shieldStorageKey
        )
        let record = ShieldRecord(
            recordKey: "exactApp:com.example.focus",
            tier: .exactApp,
            targetKey: "com.example.focus",
            displayName: "Focus",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: referenceDate,
            expiresAt: nil,
            originalRequest: "limit reached",
            targetChildID: UUID(),
            sources: [.limit]
        )

        try persistence.persist([record.recordKey: record])

        XCTAssertEqual(try persistence.load()[record.recordKey]?.recordKey, record.recordKey)
    }

    func testShieldPersistenceAcceptsByteExactFractionalDateRoundTrip() throws {
        let store = ShieldPersistenceStoreStub()
        let persistence = AppLimitShieldPersistence(
            store: store,
            storageKey: shieldStorageKey
        )
        let record = ShieldRecord(
            recordKey: "exactApp:com.example.focus",
            tier: .exactApp,
            targetKey: "com.example.focus",
            displayName: "Focus",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: fractionalDate,
            expiresAt: fractionalDate.addingTimeInterval(60.25),
            originalRequest: "limit reached",
            targetChildID: UUID(),
            sources: [.limit]
        )

        try persistence.persist([record.recordKey: record])

        let readback = try persistence.load()
        XCTAssertEqual(Set(readback.keys), [record.recordKey])
        XCTAssertEqual(readback[record.recordKey]?.recordKey, record.recordKey)
        XCTAssertNotNil(store.data(forKey: shieldStorageKey))
    }

    func testJournalAcceptsFractionalDatesThroughLeaseLocalAndUsageReceipts() async throws {
        let harness = try makeHarness()
        let callback = try acceptedCallback(harness.fixture, threshold: 5)

        let effect = try harness.journal.enqueue(callback, now: fractionalDate)
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: fractionalDate.addingTimeInterval(1.25),
            leaseDuration: 30.5
        ))
        XCTAssertEqual(
            try harness.journal.effect(for: effect.key)?.lease?.leaseID,
            claim.lease.leaseID
        )
        let localReceipt = try harness.journal.applyLocal(
            claim,
            source: "fractional_date_test",
            appliedAt: fractionalDate.addingTimeInterval(2.5)
        ) { _ in }
        let usageReceipt = try await harness.journal.submitUsage(
            claim,
            baseURL: URL(string: "https://example.invalid")!,
            deviceID: harness.fixture.owner,
            transport: UsageTransportStub(
                statusCode: 200,
                response: .accepted(
                    ruleID: harness.fixture.rule.id,
                    usageDate: harness.fixture.usageDate,
                    usedMinutes: 5,
                    currentOrderingToken: 7
                )
            ),
            appliedAt: fractionalDate.addingTimeInterval(3.75)
        )

        let readback = try XCTUnwrap(harness.journal.effect(for: effect.key))
        XCTAssertNil(readback.lease)
        XCTAssertEqual(readback.localReceipt?.key, localReceipt?.key)
        XCTAssertEqual(readback.usageReceipt?.key, usageReceipt?.key)
        XCTAssertNil(readback.retryNotBefore)
    }

    func testJournalAcceptsFractionalDateRetryState() async throws {
        let harness = try makeHarness()
        _ = try harness.journal.enqueue(
            acceptedCallback(harness.fixture, threshold: 5),
            now: fractionalDate
        )
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: fractionalDate.addingTimeInterval(1.25),
            leaseDuration: 30.5
        ))

        let receipt = try await harness.journal.submitUsage(
            claim,
            baseURL: URL(string: "https://example.invalid")!,
            deviceID: harness.fixture.owner,
            transport: UsageTransportStub(
                statusCode: 200,
                response: .rejected(
                    ruleID: harness.fixture.rule.id,
                    usageDate: harness.fixture.usageDate,
                    currentOrderingToken: 6,
                    reason: "future_ordering_token"
                )
            ),
            appliedAt: fractionalDate.addingTimeInterval(2.5)
        )

        XCTAssertNil(receipt)
        let readback = try XCTUnwrap(harness.journal.effect(for: claim.effect.key))
        XCTAssertNil(readback.lease)
        XCTAssertEqual(readback.retryAttemptCount, 1)
        XCTAssertNotNil(readback.retryNotBefore)
    }

    func testAcceptedCallbackIsDurableBeforeClaimAndDuplicateEnqueuesOnce() throws {
        let harness = try makeHarness()
        let callback = try acceptedCallback(harness.fixture, threshold: 5)

        let first = try harness.journal.enqueue(callback, now: referenceDate)
        let duplicate = try harness.journal.enqueue(callback, now: referenceDate)
        let reopened = AppLimitEffectJournal(
            defaults: harness.defaults,
            epochStore: harness.fixture.store
        )

        XCTAssertEqual(first, duplicate)
        XCTAssertEqual(try reopened.pendingEffects(), [first])
        XCTAssertNil(first.lease)
        XCTAssertNil(first.localReceipt)
        XCTAssertNil(first.usageReceipt)
    }

    func testCrashAfterClaimReclaimsExpiredLeaseWithoutDuplicatingWork() throws {
        let harness = try makeHarness()
        let effect = try harness.journal.enqueue(
            acceptedCallback(harness.fixture, threshold: 5),
            now: referenceDate
        )
        let first = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))

        XCTAssertEqual(first.effect.key, effect.key)
        XCTAssertNil(try harness.journal.claimNext(
            workerID: workerB,
            now: referenceDate.addingTimeInterval(29),
            leaseDuration: 30
        ))

        let reclaimed = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerB,
            now: referenceDate.addingTimeInterval(31),
            leaseDuration: 30
        ))
        XCTAssertEqual(reclaimed.effect.key, effect.key)
        XCTAssertNotEqual(reclaimed.lease.leaseID, first.lease.leaseID)
        XCTAssertEqual(try harness.journal.pendingEffects().count, 1)
    }

    func testLocalMutationAndReceiptAreIdempotentAcrossCrashAfterMutation() throws {
        let harness = try makeHarness()
        _ = try harness.journal.enqueue(
            acceptedCallback(harness.fixture, threshold: 5),
            now: referenceDate
        )
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        var localMutations = 0

        let receipt = try harness.journal.applyLocal(
            claim,
            source: "device_activity_monitor",
            appliedAt: referenceDate
        ) { _ in
            localMutations += 1
        }
        let duplicate = try harness.journal.applyLocal(
            claim,
            source: "device_activity_monitor",
            appliedAt: referenceDate.addingTimeInterval(1)
        ) { _ in
            localMutations += 1
        }

        XCTAssertEqual(localMutations, 1)
        XCTAssertEqual(duplicate, receipt)
        XCTAssertEqual(
            try harness.journal.effect(for: claim.effect.key)?.localReceipt,
            receipt
        )
        XCTAssertEqual(receipt?.source, "device_activity_monitor")
    }

    func testCrashAfterDurableLocalMutationReopensAndConvergesBeforeReceipt() throws {
        let harness = try makeHarness()
        let callback = try acceptedCallback(
            harness.fixture,
            kind: .enforcement,
            threshold: harness.fixture.rule.budgetMinutes
        )
        let usageStore = EarnedTimeStore(suiteName: harness.suiteName)
        let shieldPersistence = AppLimitShieldPersistence(
            store: harness.defaults,
            storageKey: shieldStorageKey
        )
        let crashingJournal = AppLimitEffectJournal(
            defaults: harness.defaults,
            epochStore: harness.fixture.store,
            afterLocalMutation: { throw JournalTestError.simulatedCrash }
        )
        _ = try crashingJournal.enqueue(callback, now: referenceDate)
        let firstClaim = try XCTUnwrap(crashingJournal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))

        XCTAssertThrowsError(try crashingJournal.applyLocal(
            firstClaim,
            source: "device_activity_monitor",
            appliedAt: referenceDate
        ) { callback in
            try applyDurableLocalEffects(
                callback,
                usageStore: usageStore,
                shieldPersistence: shieldPersistence
            )
        }) { error in
            XCTAssertEqual(error as? JournalTestError, .simulatedCrash)
        }
        XCTAssertNil(try crashingJournal.effect(for: firstClaim.effect.key)?.localReceipt)
        XCTAssertEqual(
            usageStore.appLimitReportedMinutes(
                ruleID: callback.rule.id,
                usageDate: callback.provenance.usageDate
            ),
            callback.adjustedEstimateMinutes
        )
        XCTAssertEqual(try shieldPersistence.load().count, 1)

        let reopened = AppLimitEffectJournal(
            defaults: harness.defaults,
            epochStore: harness.fixture.store
        )
        let reclaimed = try XCTUnwrap(reopened.claimNext(
            workerID: workerB,
            now: referenceDate.addingTimeInterval(31),
            leaseDuration: 30
        ))
        let receipt = try reopened.applyLocal(
            reclaimed,
            source: "lifecycle_recovery",
            appliedAt: referenceDate.addingTimeInterval(31)
        ) { callback in
            try applyDurableLocalEffects(
                callback,
                usageStore: usageStore,
                shieldPersistence: shieldPersistence
            )
        }

        XCTAssertNotNil(receipt)
        XCTAssertEqual(
            usageStore.appLimitReportedMinutes(
                ruleID: callback.rule.id,
                usageDate: callback.provenance.usageDate
            ),
            callback.adjustedEstimateMinutes
        )
        let shields = try shieldPersistence.load()
        XCTAssertEqual(shields.count, 1)
        XCTAssertEqual(shields[LimitShieldLogic.recordKey(for: callback.rule)]?.sources, [.limit])
        XCTAssertEqual(try reopened.effect(for: reclaimed.effect.key)?.localReceipt, receipt)
    }

    func testShieldPersistenceReadbackMismatchNeverRecordsLocalReceipt() throws {
        let harness = try makeHarness()
        let callback = try acceptedCallback(
            harness.fixture,
            kind: .enforcement,
            threshold: harness.fixture.rule.budgetMinutes
        )
        let store = ShieldPersistenceStoreStub()
        let persistence = AppLimitShieldPersistence(
            store: store,
            storageKey: shieldStorageKey
        )
        let shields = LimitShieldLogic.applyingLimit(
            to: [:],
            callback: callback,
            now: referenceDate
        )

        store.serveStaleReadback = true
        _ = try harness.journal.enqueue(callback, now: referenceDate)
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        XCTAssertThrowsError(try harness.journal.applyLocal(
            claim,
            source: "device_activity_monitor",
            appliedAt: referenceDate
        ) { _ in
            try persistence.persist(shields)
        })
        XCTAssertNil(try harness.journal.effect(for: claim.effect.key)?.localReceipt)
    }

    func testLedgerUnavailableOrStaleReadbackNeverRecordsLocalReceipt() throws {
        for failure in LocalLedgerFailure.allCases {
            let harness = try makeHarness()
            let callback = try acceptedCallback(harness.fixture, threshold: 5)
            let writerSuite = "AppLimitLocalLedger.writer.\(UUID().uuidString)"
            let staleSuite = "AppLimitLocalLedger.stale.\(UUID().uuidString)"
            let writerDefaults = try XCTUnwrap(UserDefaults(suiteName: writerSuite))
            writerDefaults.removePersistentDomain(forName: writerSuite)
            defer {
                writerDefaults.removePersistentDomain(forName: writerSuite)
                UserDefaults(suiteName: staleSuite)?.removePersistentDomain(forName: staleSuite)
            }
            let usageStore: EarnedTimeStore
            switch failure {
            case .unavailable:
                usageStore = EarnedTimeStore(
                    suiteName: writerSuite,
                    defaultsFactory: { _ in nil },
                    verificationDefaultsFactory: { _ in nil }
                )
            case .staleReadback:
                usageStore = EarnedTimeStore(
                    suiteName: writerSuite,
                    defaultsFactory: { _ in writerDefaults },
                    verificationDefaultsFactory: { _ in UserDefaults(suiteName: staleSuite) }
                )
            }
            _ = try harness.journal.enqueue(callback, now: referenceDate)
            let claim = try XCTUnwrap(harness.journal.claimNext(
                workerID: workerA,
                now: referenceDate,
                leaseDuration: 30
            ))

            XCTAssertThrowsError(try harness.journal.applyLocal(
                claim,
                source: "ledger_failure_test",
                appliedAt: referenceDate
            ) { callback in
                try AppLimitCallbackLocalLedger.record(callback, store: usageStore)
            })
            XCTAssertNil(try harness.journal.effect(for: claim.effect.key)?.localReceipt)
        }
    }

    func testLedgerFalseSynchronizeStillRecordsAfterMatchingReadback() throws {
        let harness = try makeHarness()
        let callback = try acceptedCallback(harness.fixture, threshold: 5)
        let suiteName = "AppLimitLocalLedger.false-sync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let usageStore = EarnedTimeStore(
            suiteName: suiteName,
            defaultsFactory: { _ in defaults },
            verificationDefaultsFactory: { _ in UserDefaults(suiteName: suiteName) },
            synchronizeDefaults: { _ in false }
        )
        _ = try harness.journal.enqueue(callback, now: referenceDate)
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))

        let receipt = try harness.journal.applyLocal(
            claim,
            source: "false_sync_readback_test",
            appliedAt: referenceDate
        ) { callback in
            try AppLimitCallbackLocalLedger.record(callback, store: usageStore)
        }

        XCTAssertNotNil(receipt)
        XCTAssertEqual(
            usageStore.appLimitReportedMinutes(
                ruleID: callback.rule.id,
                usageDate: callback.provenance.usageDate
            ),
            callback.adjustedEstimateMinutes
        )
    }

    func testNewerClearBetweenClaimAndShieldPreventsOldMutationAndReceipt() throws {
        let harness = try makeHarness()
        _ = try harness.journal.enqueue(
            acceptedCallback(harness.fixture, kind: .enforcement, threshold: 20),
            now: referenceDate
        )
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        try replaceWithClear(harness.fixture, token: 8)
        var shieldMutations = 0

        let receipt = try harness.journal.applyLocal(
            claim,
            source: "device_activity_monitor",
            appliedAt: referenceDate
        ) { _ in
            shieldMutations += 1
        }

        XCTAssertNil(receipt)
        XCTAssertEqual(shieldMutations, 0)
        XCTAssertNil(try harness.journal.effect(for: claim.effect.key))
    }

    func testDurablyAppliedTerminalUsageSurvivesRuleClearAndJournalReopen() async throws {
        let harness = try makeHarness()
        let callback = try acceptedCallback(
            harness.fixture,
            kind: .enforcement,
            threshold: harness.fixture.rule.budgetMinutes
        )
        _ = try harness.journal.enqueue(callback, now: referenceDate)
        let firstClaim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        let localReceipt = try harness.journal.applyLocal(
            firstClaim,
            source: "device_activity_monitor",
            appliedAt: referenceDate
        ) { _ in }
        XCTAssertNotNil(localReceipt)
        try replaceWithClear(harness.fixture, token: 8)

        let reopened = AppLimitEffectJournal(
            defaults: harness.defaults,
            epochStore: harness.fixture.store
        )
        let reclaimed = try XCTUnwrap(reopened.claimNext(
            workerID: workerB,
            now: referenceDate.addingTimeInterval(31),
            leaseDuration: 30
        ))
        var replayedLocalMutations = 0
        let recoveredLocalReceipt = try reopened.applyLocal(
            reclaimed,
            source: "wake_recovery",
            appliedAt: referenceDate.addingTimeInterval(31)
        ) { _ in
            replayedLocalMutations += 1
        }
        XCTAssertEqual(recoveredLocalReceipt, localReceipt)
        XCTAssertEqual(replayedLocalMutations, 0)
        let transport = UsageTransportStub(
            statusCode: 200,
            response: .accepted(
                ruleID: harness.fixture.rule.id,
                usageDate: harness.fixture.usageDate,
                usedMinutes: harness.fixture.rule.budgetMinutes,
                currentOrderingToken: 8
            )
        )

        let usageReceipt = try await reopened.submitUsage(
            reclaimed,
            baseURL: URL(string: "https://example.invalid")!,
            deviceID: harness.fixture.owner,
            transport: transport,
            appliedAt: referenceDate.addingTimeInterval(32)
        )
        let requestBodyData = await transport.requestBodyData

        XCTAssertNotNil(requestBodyData)
        XCTAssertEqual(usageReceipt?.usedMinutes, harness.fixture.rule.budgetMinutes)
        XCTAssertEqual(usageReceipt?.currentOrderingToken, 8)
        XCTAssertEqual(
            try reopened.effect(for: reclaimed.effect.key)?.localReceipt,
            localReceipt
        )
        XCTAssertEqual(
            try reopened.effect(for: reclaimed.effect.key)?.usageReceipt,
            usageReceipt
        )
        XCTAssertEqual(
            try harness.fixture.store.read().slots[harness.fixture.rule.id]?.latestKind,
            .clear
        )
    }

    func testStaleUnappliedUsageNeverReachesTransport() async throws {
        let harness = try makeHarness()
        _ = try harness.journal.enqueue(
            acceptedCallback(harness.fixture, threshold: 5),
            now: referenceDate
        )
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        try replaceWithClear(harness.fixture, token: 8)
        let transport = UsageTransportStub(
            statusCode: 200,
            response: .accepted(
                ruleID: harness.fixture.rule.id,
                usageDate: harness.fixture.usageDate,
                usedMinutes: 5,
                currentOrderingToken: 8
            )
        )

        let receipt = try await harness.journal.submitUsage(
            claim,
            baseURL: URL(string: "https://example.invalid")!,
            deviceID: harness.fixture.owner,
            transport: transport,
            appliedAt: referenceDate
        )
        let requestBodyData = await transport.requestBodyData

        XCTAssertNil(receipt)
        XCTAssertNil(requestBodyData)
    }

    func testReceiptBackedHistoricalUsageRejectsDifferentDeviceOwner() async throws {
        let harness = try makeHarness()
        _ = try harness.journal.enqueue(
            acceptedCallback(harness.fixture, threshold: 5),
            now: referenceDate
        )
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        XCTAssertNotNil(try harness.journal.applyLocal(
            claim,
            source: "device_activity_monitor",
            appliedAt: referenceDate
        ) { _ in })
        try replaceWithClear(harness.fixture, token: 8)
        let transport = UsageTransportStub(
            statusCode: 200,
            response: .accepted(
                ruleID: harness.fixture.rule.id,
                usageDate: harness.fixture.usageDate,
                usedMinutes: 5,
                currentOrderingToken: 8
            )
        )

        let receipt = try await harness.journal.submitUsage(
            claim,
            baseURL: URL(string: "https://example.invalid")!,
            deviceID: UUID(uuidString: "20000000-0000-0000-0000-000000000099")!,
            transport: transport,
            appliedAt: referenceDate
        )
        let requestBodyData = await transport.requestBodyData

        XCTAssertNil(receipt)
        XCTAssertNil(requestBodyData)
    }

    func testUsageRequestCarriesOrderingTokenAndAcceptedBodyCommitsAfterCAS() async throws {
        let harness = try makeHarness()
        let callback = try acceptedCallback(harness.fixture, threshold: 5)
        _ = try harness.journal.enqueue(callback, now: referenceDate)
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        let transport = UsageTransportStub(
            statusCode: 200,
            response: .accepted(
                ruleID: harness.fixture.rule.id,
                usageDate: harness.fixture.usageDate,
                usedMinutes: 5,
                currentOrderingToken: 7
            )
        )

        let receipt = try await harness.journal.submitUsage(
            claim,
            baseURL: URL(string: "https://example.invalid")!,
            deviceID: harness.fixture.owner,
            transport: transport,
            appliedAt: referenceDate
        )

        let capturedBodyData = await transport.requestBodyData
        let bodyData = try XCTUnwrap(capturedBodyData)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(body["ordering_token"] as? Int64, 7)
        XCTAssertEqual(body["rule_id"] as? String, harness.fixture.rule.id.uuidString.lowercased())
        XCTAssertEqual(
            body["client_sample_id"] as? String,
            AppLimitUsageReporter.clientSampleID(for: callback)
        )
        XCTAssertEqual(receipt?.currentOrderingToken, 7)
        XCTAssertEqual(
            try harness.journal.effect(for: claim.effect.key)?.usageReceipt,
            receipt
        )
    }

    func testUsageSampleIdentitySeparatesArmsAndOrderingTokensWithinBackendLimit() throws {
        let harness = try makeHarness()
        let original = try acceptedCallback(harness.fixture, threshold: 5)
        let differentArm = callback(
            original,
            orderingToken: original.provenance.ruleRevision,
            armID: UUID(uuidString: "30000000-0000-0000-0000-000000000099")!
        )
        let differentRevision = callback(
            original,
            orderingToken: original.provenance.ruleRevision + 1,
            armID: original.provenance.armID
        )

        let originalID = AppLimitUsageReporter.clientSampleID(for: original)
        let differentArmID = AppLimitUsageReporter.clientSampleID(for: differentArm)
        let differentRevisionID = AppLimitUsageReporter.clientSampleID(for: differentRevision)

        XCTAssertNotEqual(originalID, differentArmID)
        XCTAssertNotEqual(originalID, differentRevisionID)
        XCTAssertTrue(originalID.contains(":r\(original.provenance.ruleRevision):"))
        XCTAssertTrue(originalID.contains(":a\(original.provenance.armID.uuidString.lowercased()):"))
        XCTAssertLessThanOrEqual(originalID.utf8.count, 255)
        XCTAssertLessThanOrEqual(differentArmID.utf8.count, 255)
        XCTAssertLessThanOrEqual(differentRevisionID.utf8.count, 255)
    }

    func testHTTP200AcceptedFalseDoesNotCommitUsageReceipt() async throws {
        let harness = try makeHarness()
        _ = try harness.journal.enqueue(
            acceptedCallback(harness.fixture, threshold: 5),
            now: referenceDate
        )
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        let transport = UsageTransportStub(
            statusCode: 200,
            response: .rejected(
                ruleID: harness.fixture.rule.id,
                usageDate: harness.fixture.usageDate,
                currentOrderingToken: 8,
                reason: "stale_ordering_token"
            )
        )

        let receipt = try await harness.journal.submitUsage(
            claim,
            baseURL: URL(string: "https://example.invalid")!,
            deviceID: harness.fixture.owner,
            transport: transport,
            appliedAt: referenceDate
        )

        XCTAssertNil(receipt)
        let persisted = try XCTUnwrap(harness.journal.effect(for: claim.effect.key))
        XCTAssertNil(persisted.usageReceipt)
        XCTAssertEqual(persisted.backendRejection?.reason, "stale_ordering_token")
        XCTAssertEqual(persisted.backendRejection?.currentOrderingToken, 8)
    }

    func testFutureOrderingTokenReleasesLeaseAndBacksOffWithoutBusyLoop() async throws {
        let harness = try makeHarness()
        _ = try harness.journal.enqueue(
            acceptedCallback(harness.fixture, threshold: 5),
            now: referenceDate
        )
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        let transport = UsageTransportStub(
            statusCode: 200,
            response: .rejected(
                ruleID: harness.fixture.rule.id,
                usageDate: harness.fixture.usageDate,
                currentOrderingToken: 6,
                reason: "future_ordering_token"
            )
        )

        let receipt = try await harness.journal.submitUsage(
            claim,
            baseURL: URL(string: "https://example.invalid")!,
            deviceID: harness.fixture.owner,
            transport: transport,
            appliedAt: referenceDate
        )
        XCTAssertNil(receipt)

        let retained = try XCTUnwrap(harness.journal.effect(for: claim.effect.key))
        XCTAssertNil(retained.backendRejection)
        XCTAssertNil(retained.lease)
        let retryNotBefore = try XCTUnwrap(retained.retryNotBefore)
        XCTAssertGreaterThan(retryNotBefore, referenceDate)
        XCTAssertLessThanOrEqual(retryNotBefore, referenceDate.addingTimeInterval(300))
        XCTAssertNil(try harness.journal.claimNext(
            workerID: workerB,
            now: retryNotBefore.addingTimeInterval(-0.001),
            leaseDuration: 30
        ))
        XCTAssertNotNil(try harness.journal.claimNext(
            workerID: workerB,
            now: retryNotBefore,
            leaseDuration: 30
        ))
    }

    func testAuthoritativeTerminalRejectionsNeverBecomeChargeableAgain() async throws {
        for reason in [
            "stale_ordering_token",
            "rule_cleared",
            "usage_counting_not_allowed",
            "unrecognized_authoritative_rejection",
        ] {
            let harness = try makeHarness()
            _ = try harness.journal.enqueue(
                acceptedCallback(harness.fixture, threshold: 5),
                now: referenceDate
            )
            let claim = try XCTUnwrap(harness.journal.claimNext(
                workerID: workerA,
                now: referenceDate,
                leaseDuration: 30
            ))
            let transport = UsageTransportStub(
                statusCode: 200,
                response: .rejected(
                    ruleID: harness.fixture.rule.id,
                    usageDate: harness.fixture.usageDate,
                    currentOrderingToken: 8,
                    reason: reason
                )
            )

            let receipt = try await harness.journal.submitUsage(
                claim,
                baseURL: URL(string: "https://example.invalid")!,
                deviceID: harness.fixture.owner,
                transport: transport,
                appliedAt: referenceDate
            )
            XCTAssertNil(receipt)
            let terminal = try XCTUnwrap(harness.journal.effect(for: claim.effect.key))
            XCTAssertEqual(terminal.backendRejection?.reason, reason)
            XCTAssertNil(terminal.usageReceipt)
            XCTAssertNil(try harness.journal.claimNext(
                workerID: workerB,
                now: referenceDate.addingTimeInterval(3_600),
                leaseDuration: 30
            ))
        }
    }

    func testTransportHTTPAndDecodeFailuresRemainRetryable() async throws {
        let failures: [RawUsageTransportStub.Mode] = [
            .throwing,
            .response(statusCode: 503, data: Data()),
            .response(statusCode: 200, data: Data("not-json".utf8)),
        ]
        for failure in failures {
            let harness = try makeHarness()
            _ = try harness.journal.enqueue(
                acceptedCallback(harness.fixture, threshold: 5),
                now: referenceDate
            )
            let claim = try XCTUnwrap(harness.journal.claimNext(
                workerID: workerA,
                now: referenceDate,
                leaseDuration: 30
            ))

            do {
                _ = try await harness.journal.submitUsage(
                    claim,
                    baseURL: URL(string: "https://example.invalid")!,
                    deviceID: harness.fixture.owner,
                    transport: RawUsageTransportStub(mode: failure),
                    appliedAt: referenceDate
                )
                XCTFail("expected retryable transport failure")
            } catch {}

            let retained = try XCTUnwrap(harness.journal.effect(for: claim.effect.key))
            XCTAssertNil(retained.backendRejection)
            XCTAssertNil(retained.usageReceipt)
            XCTAssertNotNil(try harness.journal.claimNext(
                workerID: workerB,
                now: referenceDate.addingTimeInterval(31),
                leaseDuration: 30
            ))
        }
    }

    func testNewerSetDuringTransportPreventsOldUsageCommitAfterResponse() async throws {
        let harness = try makeHarness()
        _ = try harness.journal.enqueue(
            acceptedCallback(harness.fixture, threshold: 5),
            now: referenceDate
        )
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        let transport = UsageTransportStub(
            statusCode: 200,
            response: .accepted(
                ruleID: harness.fixture.rule.id,
                usageDate: harness.fixture.usageDate,
                usedMinutes: 5,
                currentOrderingToken: 7
            ),
            beforeResponse: {
                try self.replaceWithSet(harness.fixture, token: 8)
            }
        )

        let receipt = try await harness.journal.submitUsage(
            claim,
            baseURL: URL(string: "https://example.invalid")!,
            deviceID: harness.fixture.owner,
            transport: transport,
            appliedAt: referenceDate
        )

        XCTAssertNil(receipt)
        XCTAssertNil(try harness.journal.effect(for: claim.effect.key))
    }

    func testPerAppIsolationClaimsAndMutatesOnlyNamedRule() throws {
        let otherRule = AppLimitCallbackFixture.makeRule(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            budgetMinutes: 30,
            bundleID: "com.example.other"
        )
        let harness = try makeHarness(additionalRule: otherRule)
        let otherSlotBefore = try harness.fixture.store.read().slots[otherRule.id]
        _ = try harness.journal.enqueue(
            acceptedCallback(harness.fixture, threshold: 5),
            now: referenceDate
        )
        let claim = try XCTUnwrap(harness.journal.claimNext(
            workerID: workerA,
            now: referenceDate,
            leaseDuration: 30
        ))
        var mutatedRuleIDs: [UUID] = []

        _ = try harness.journal.applyLocal(
            claim,
            source: "device_activity_monitor",
            appliedAt: referenceDate
        ) { callback in
            mutatedRuleIDs.append(callback.rule.id)
        }

        XCTAssertEqual(mutatedRuleIDs, [harness.fixture.rule.id])
        XCTAssertEqual(try harness.fixture.store.read().slots[otherRule.id], otherSlotBefore)
        XCTAssertEqual(try harness.journal.pendingEffects().map(\.key.ruleID), [harness.fixture.rule.id])
    }

    func testAppliedReceiptReadbackRequiresCurrentTokenAndArm() throws {
        let harness = try makeHarness()
        let receipt = AppLimitApplyReceipt(
            ruleID: harness.fixture.rule.id,
            orderingToken: 7,
            commandKind: .set,
            armID: harness.fixture.provenance.armID,
            source: "app_owner",
            appliedAt: referenceDate,
            storeRevision: 2
        )
        _ = try harness.fixture.store.transaction(
            source: .wakeRecovery,
            expectedOwner: harness.fixture.owner
        ) { state in
            var slot = state.slots[harness.fixture.rule.id]!
            slot.appliedReceipt = receipt
            state.slots[harness.fixture.rule.id] = slot
        }

        XCTAssertEqual(
            try AppLimitProductionComposition.currentAppliedReceipt(
                ruleID: harness.fixture.rule.id,
                store: harness.fixture.store
            ),
            receipt
        )
        try replaceWithSet(harness.fixture, token: 8)
        XCTAssertNil(try AppLimitProductionComposition.currentAppliedReceipt(
            ruleID: harness.fixture.rule.id,
            store: harness.fixture.store
        ))
    }

    func testProductionLocalPersistenceCommitsUsageAndShieldBeforeProjection() throws {
        let harness = try makeHarness()
        let callback = try acceptedCallback(
            harness.fixture,
            kind: .enforcement,
            threshold: harness.fixture.rule.budgetMinutes
        )
        let usageStore = EarnedTimeStore(suiteName: harness.suiteName)
        let shieldPersistence = AppLimitShieldPersistence(
            store: harness.defaults,
            storageKey: shieldStorageKey
        )

        try AppLimitEffectLocalPersistence.persist(
            callback,
            usageStore: usageStore,
            shieldPersistence: shieldPersistence,
            now: referenceDate
        )

        XCTAssertEqual(
            usageStore.appLimitReportedMinutes(
                ruleID: callback.rule.id,
                usageDate: callback.provenance.usageDate
            ),
            callback.adjustedEstimateMinutes
        )
        XCTAssertNotNil(
            try shieldPersistence.load()[LimitShieldLogic.recordKey(for: callback.rule)]
        )
    }

    private func makeHarness(
        additionalRule: AppLimitRule? = nil
    ) throws -> JournalHarness {
        let fixture = try AppLimitCallbackFixture(
            budgetMinutes: 20,
            additionalRule: additionalRule
        )
        let suiteName = "AppLimitEffectJournalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return JournalHarness(
            fixture: fixture,
            suiteName: suiteName,
            defaults: defaults,
            journal: AppLimitEffectJournal(defaults: defaults, epochStore: fixture.store)
        )
    }

    private func applyDurableLocalEffects(
        _ callback: AppLimitValidatedCallback,
        usageStore: EarnedTimeStore,
        shieldPersistence: AppLimitShieldPersistence
    ) throws {
        try AppLimitEffectLocalPersistence.persist(
            callback,
            usageStore: usageStore,
            shieldPersistence: shieldPersistence,
            now: referenceDate
        )
    }

    private func acceptedCallback(
        _ fixture: AppLimitCallbackFixture,
        kind: AppLimitCallbackEffectKind = .measurement,
        threshold: Int
    ) throws -> AppLimitValidatedCallback {
        let eventName = kind == .measurement
            ? fixture.measurementEventName(threshold)
            : fixture.enforcementEventName
        let decision = try fixture.validator.validate(
            activityName: fixture.provenance.activityName,
            eventName: eventName,
            canonicalUsageDate: fixture.usageDate,
            observedAt: fixture.observedAt(minutes: threshold),
            usageCountingAllowed: true
        )
        guard case .accepted(let callback) = decision else {
            throw JournalTestError.callbackNotAccepted
        }
        return callback
    }

    private func callback(
        _ callback: AppLimitValidatedCallback,
        orderingToken: Int64,
        armID: UUID
    ) -> AppLimitValidatedCallback {
        let original = callback.provenance
        return AppLimitValidatedCallback(
            rule: callback.rule,
            provenance: AppLimitArmProvenance(
                ruleID: original.ruleID,
                ruleRevision: orderingToken,
                childDeviceID: original.childDeviceID,
                usageDate: original.usageDate,
                timezone: original.timezone,
                scheduleWindow: original.scheduleWindow,
                tokenDigest: original.tokenDigest,
                budgetMinutes: original.budgetMinutes,
                startedAt: original.startedAt,
                baseAcceptedMinutes: original.baseAcceptedMinutes,
                lastRawThresholdMinutes: original.lastRawThresholdMinutes,
                ignoredWhilePausedMinutes: original.ignoredWhilePausedMinutes,
                activityName: AppLimitPlanner.v2ActivityName(armID: armID),
                armID: armID
            ),
            effectKind: callback.effectKind,
            rawThresholdMinutes: callback.rawThresholdMinutes,
            adjustedEstimateMinutes: callback.adjustedEstimateMinutes
        )
    }

    private func replaceWithClear(_ fixture: AppLimitCallbackFixture, token: Int64) throws {
        _ = try fixture.store.transaction(source: .poll, expectedOwner: fixture.owner) { state in
            state.slots[fixture.rule.id] = AppLimitVersionSlot(
                ruleID: fixture.rule.id,
                latestOrderingToken: token,
                latestKind: .clear,
                latestPayloadDigest: "clear-\(token)",
                activeRule: nil,
                clearTombstone: AppLimitClearTombstone(
                    ruleID: fixture.rule.id,
                    orderingToken: token,
                    payloadDigest: "clear-\(token)",
                    source: .poll,
                    clearedAt: referenceDate
                ),
                pendingOwnerWork: nil,
                appliedReceipt: nil,
                armProvenance: nil
            )
        }
    }

    private func replaceWithSet(_ fixture: AppLimitCallbackFixture, token: Int64) throws {
        _ = try fixture.store.transaction(source: .poll, expectedOwner: fixture.owner) { state in
            state.slots[fixture.rule.id] = AppLimitCallbackFixture.makeSlot(
                rule: fixture.rule,
                revision: token,
                provenance: AppLimitArmProvenance(
                    ruleID: fixture.rule.id,
                    ruleRevision: token,
                    childDeviceID: fixture.owner,
                    usageDate: fixture.usageDate,
                    timezone: fixture.provenance.timezone,
                    scheduleWindow: fixture.rule.window,
                    tokenDigest: fixture.provenance.tokenDigest,
                    budgetMinutes: fixture.rule.budgetMinutes,
                    startedAt: referenceDate,
                    baseAcceptedMinutes: 0,
                    lastRawThresholdMinutes: 0,
                    ignoredWhilePausedMinutes: 0,
                    activityName: AppLimitPlanner.v2ActivityName(armID: UUID()),
                    armID: UUID()
                )
            )
        }
    }
}

private struct JournalHarness {
    let fixture: AppLimitCallbackFixture
    let suiteName: String
    let defaults: UserDefaults
    let journal: AppLimitEffectJournal
}

private enum JournalTestError: Error {
    case callbackNotAccepted
    case simulatedCrash
    case transportFailure
}

private enum LocalLedgerFailure: CaseIterable {
    case unavailable
    case staleReadback
}

private final class FalseSynchronizeUserDefaults: UserDefaults {
    override func synchronize() -> Bool {
        _ = super.synchronize()
        return false
    }
}

private final class ShieldPersistenceStoreStub: AppLimitShieldPersistenceStore {
    var synchronizeResult = true
    var serveStaleReadback = false
    private var persisted: [String: Data] = [:]

    func data(forKey defaultName: String) -> Data? {
        serveStaleReadback ? nil : persisted[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        persisted[defaultName] = value as? Data
    }

    func synchronize() -> Bool {
        synchronizeResult
    }
}

private actor UsageTransportStub: MeteringHTTPTransport {
    let statusCode: Int
    let response: AppLimitUsageServerResponse
    let beforeResponse: @Sendable () throws -> Void
    private(set) var requestBodyData: Data?

    init(
        statusCode: Int,
        response: AppLimitUsageServerResponse,
        beforeResponse: @escaping @Sendable () throws -> Void = {}
    ) {
        self.statusCode = statusCode
        self.response = response
        self.beforeResponse = beforeResponse
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let data = request.httpBody {
            requestBodyData = data
        }
        try beforeResponse()
        let data = try JSONEncoder().encode(response)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, http)
    }
}

private actor RawUsageTransportStub: MeteringHTTPTransport {
    enum Mode {
        case throwing
        case response(statusCode: Int, data: Data)
    }

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        switch mode {
        case .throwing:
            throw JournalTestError.transportFailure
        case .response(let statusCode, let data):
            return (
                data,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    }
}

private let workerA = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
private let workerB = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
private let referenceDate = Date(timeIntervalSince1970: 1_721_174_400)
private let fractionalDate = Date(
    timeIntervalSinceReferenceDate: Double(bitPattern: 4_740_046_264_882_201_161)
)
private let shieldStorageKey = "evlin.shieldRecords"
