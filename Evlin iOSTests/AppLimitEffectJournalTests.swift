import Foundation
import XCTest
@testable import Evlin_iOS

final class AppLimitEffectJournalTests: XCTestCase {
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

    func testUsageRequestCarriesOrderingTokenAndAcceptedBodyCommitsAfterCAS() async throws {
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
        XCTAssertEqual(receipt?.currentOrderingToken, 7)
        XCTAssertEqual(
            try harness.journal.effect(for: claim.effect.key)?.usageReceipt,
            receipt
        )
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
            defaults: defaults,
            journal: AppLimitEffectJournal(defaults: defaults, epochStore: fixture.store)
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
    let defaults: UserDefaults
    let journal: AppLimitEffectJournal
}

private enum JournalTestError: Error { case callbackNotAccepted }

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

private let workerA = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
private let workerB = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
private let referenceDate = Date(timeIntervalSince1970: 1_721_174_400)
