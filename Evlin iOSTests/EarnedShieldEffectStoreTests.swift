import Foundation
import XCTest
@testable import Evlin_iOS

final class EarnedShieldEffectStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var storeURL: URL!
    private let owner = UUID(uuidString: "81000000-0000-4000-8000-000000000001")!
    private let operationID = UUID(uuidString: "81000000-0000-4000-8000-000000000005")!
    private let now = Date(timeIntervalSince1970: 1_784_419_200)

    override func setUpWithError() throws {
        suiteName = "EarnedShieldEffectStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-shield-effect-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storeURL)
        defaults = nil
        storeURL = nil
    }

    func testApplyPersistsReferenceAndSameOperationIsIdempotentButWrongTupleFailsClosed() throws {
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)

        try effectStore.apply(envelope)
        try effectStore.apply(envelope)

        XCTAssertEqual(try shields()[envelope.recordKey], envelope.intendedAfterRecord)
        XCTAssertEqual(try fixture.store.read().shieldReferences[operationID]?.routeID, fixture.routeID)
        XCTAssertEqual(try envelopes()[operationID]?.phase, .applied)

        let changed = makeEnvelope(fixture: fixture, recordKey: "allApps:wrong")
        XCTAssertThrowsError(try effectStore.apply(changed)) { error in
            XCTAssertEqual(error as? EarnedShieldEffectError, .authorizationChanged)
        }
        XCTAssertEqual(try shields()[envelope.recordKey], envelope.intendedAfterRecord)
        XCTAssertEqual(try envelopes()[operationID]?.phase, .applied)
    }

    func testAuthorizationFailureLeavesNoEnvelopeOrShieldMutation() throws {
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        let unauthorized = makeEnvelope(fixture: fixture, routeID: UUID())

        XCTAssertThrowsError(try effectStore.apply(unauthorized)) { error in
            XCTAssertEqual(error as? EarnedShieldEffectError, .authorizationChanged)
        }

        XCTAssertNil(defaults.data(forKey: EarnedShieldEffectStore.envelopeKey))
        XCTAssertNil(defaults.data(forKey: EarnedShieldEffectStore.shieldsKey))
        XCTAssertTrue(try fixture.store.read().shieldReferences.isEmpty)
    }

    func testAppliedOperationRepairsItsMissingReferenceBeforeReturningIdempotently() throws {
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)
        try effectStore.apply(envelope)
        try fixture.store.transaction(expectedOwner: owner) { state in
            state.shieldReferences.removeValue(forKey: operationID)
        }

        try effectStore.apply(envelope)

        XCTAssertNotNil(try fixture.store.read().shieldReferences[operationID])
        XCTAssertEqual(try envelopes()[operationID]?.phase, .applied)
        XCTAssertEqual(try shields()[envelope.recordKey], envelope.intendedAfterRecord)
    }

    func testAppliedOperationWithExactReferenceRemainsIdempotentAfterEpochRetires() throws {
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)
        try effectStore.apply(envelope)
        try fixture.store.transaction(expectedOwner: owner) { state in
            state.epochs[fixture.epochID]?.status = .retired
            state.epochs[fixture.epochID]?.retiredAt = now
            state.epochs[fixture.epochID]?.retireReason = .authoritativeBaseMismatch
        }

        try effectStore.apply(envelope)

        XCTAssertNotNil(try fixture.store.read().shieldReferences[operationID])
        XCTAssertEqual(try envelopes()[operationID]?.phase, .applied)
        XCTAssertEqual(try shields()[envelope.recordKey], envelope.intendedAfterRecord)
    }

    func testPreparedEnvelopeRecoversAndAuthorizedReleasePreservesOtherSources() throws {
        let fixture = try makeActiveEpochStore()
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)
        try persistEnvelopes([operationID: envelope])
        XCTAssertTrue(
            try fixture.store.createOrVerifyEarnedShieldReference(
                try EarnedShieldEffectStore(
                    defaults: defaults,
                    epochStore: fixture.store
                ).reference(for: envelope)
            )
        )

        let reopened = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        try reopened.recover(expectedOwner: owner)
        XCTAssertEqual(try envelopes()[operationID]?.phase, .applied)
        XCTAssertEqual(try shields()[envelope.recordKey], envelope.intendedAfterRecord)

        try fixture.store.transaction(expectedOwner: owner) { state in
            state.epochs[fixture.epochID]?.status = .retired
            state.epochs[fixture.epochID]?.retiredAt = now
            state.epochs[fixture.epochID]?.retireReason = .authoritativeBaseMismatch
        }
        try reopened.release(operationID: operationID, expectedOwner: owner)

        let released = try XCTUnwrap(try shields()[envelope.recordKey])
        XCTAssertEqual(released.sources.map(\.rawValue).sorted(), ["future-source", "manual"])
        XCTAssertEqual(try envelopes()[operationID]?.phase, .released)
    }

    func testIdentityCleanupRetiresPreparedEnvelopeWithoutApplyingEarnedSource() throws {
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)
        try persistEnvelopes([operationID: envelope])
        XCTAssertTrue(
            try fixture.store.createOrVerifyEarnedShieldReference(
                try effectStore.reference(for: envelope)
            )
        )
        _ = try fixture.store.prepareIdentityCleanup(
            oldOwner: owner,
            newOwner: UUID(),
            oldFallbackKeys: [],
            now: now
        )

        try effectStore.retireForIdentityCleanup(
            operationID: operationID,
            expectedOwner: owner
        )

        XCTAssertEqual(try shields()[envelope.recordKey], envelope.beforeRecord)
        XCTAssertEqual(try envelopes()[operationID]?.phase, .released)
    }

    func testIdentityCleanupAcceptsFalseSynchronizeWhenExactBytesReadBack() throws {
        let falseSyncDefaults = try XCTUnwrap(
            FalseSynchronizeEarnedShieldDefaults(suiteName: suiteName)
        )
        defaults = falseSyncDefaults
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(
            defaults: falseSyncDefaults,
            epochStore: fixture.store
        )
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)
        try persistEnvelopes([operationID: envelope])
        XCTAssertTrue(
            try fixture.store.createOrVerifyEarnedShieldReference(
                try effectStore.reference(for: envelope)
            )
        )
        _ = try fixture.store.prepareIdentityCleanup(
            oldOwner: owner,
            newOwner: UUID(),
            oldFallbackKeys: [],
            now: now
        )

        try effectStore.retireForIdentityCleanup(
            operationID: operationID,
            expectedOwner: owner
        )

        XCTAssertEqual(try shields()[envelope.recordKey], envelope.beforeRecord)
        XCTAssertEqual(try envelopes()[operationID]?.phase, .released)
    }

    func testRecoverMarksAppliedWhenShieldWriteWonButAppliedMarkerWasLost() throws {
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)
        try effectStore.apply(envelope)
        try persistEnvelopes([operationID: copy(envelope, phase: .prepared)])

        try EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
            .recover(expectedOwner: owner)

        XCTAssertEqual(try shields()[envelope.recordKey], envelope.intendedAfterRecord)
        XCTAssertEqual(try envelopes()[operationID]?.phase, .applied)
        XCTAssertNotNil(try fixture.store.read().shieldReferences[operationID])
    }

    func testRecoverCompletesReleasePendingBeforeShieldCAS() throws {
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)
        try effectStore.apply(envelope)
        try authorizeRelease(fixture)
        try persistEnvelopes([operationID: copy(envelope, phase: .releasePending)])

        try EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
            .recover(expectedOwner: owner)

        let released = try XCTUnwrap(try shields()[envelope.recordKey])
        XCTAssertEqual(released.sources.map(\.rawValue).sorted(), ["future-source", "manual"])
        XCTAssertEqual(try envelopes()[operationID]?.phase, .released)
    }

    func testRecoverMarksReleasedWhenShieldCASWonButReleasedMarkerWasLost() throws {
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)
        try effectStore.apply(envelope)
        try authorizeRelease(fixture)
        var released = try XCTUnwrap(envelope.intendedAfterRecord)
        released.sources.remove(.earnedTime)
        try persistShields([envelope.recordKey: released])
        try persistEnvelopes([operationID: copy(envelope, phase: .releasePending)])

        try EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
            .recover(expectedOwner: owner)

        XCTAssertEqual(try shields()[envelope.recordKey], released)
        XCTAssertEqual(try envelopes()[operationID]?.phase, .released)
    }

    func testReleaseCASConflictKeepsNewerRecordAndMarksEnvelopeConflicted() throws {
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)
        try effectStore.apply(envelope)

        var newer = try XCTUnwrap(envelope.intendedAfterRecord)
        newer.displayName = "newer durable writer"
        try persistShields([envelope.recordKey: newer])
        try fixture.store.transaction(expectedOwner: owner) { state in
            state.epochs[fixture.epochID]?.status = .retired
            state.epochs[fixture.epochID]?.retiredAt = now
            state.epochs[fixture.epochID]?.retireReason = .authoritativeBaseMismatch
        }

        XCTAssertThrowsError(try effectStore.release(operationID: operationID, expectedOwner: owner)) { error in
            XCTAssertEqual(error as? EarnedShieldEffectError, .casConflict(operationID))
        }
        XCTAssertEqual(try shields()[envelope.recordKey], newer)
        XCTAssertEqual(try envelopes()[operationID]?.phase, .conflicted)
    }

    func testReleaseRejectsTamperedEnvelopeTupleWithoutChangingShield() throws {
        let fixture = try makeActiveEpochStore()
        let effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: fixture.store)
        let envelope = makeEnvelope(fixture: fixture)
        try seedBefore(envelope)
        try effectStore.apply(envelope)
        try fixture.store.transaction(expectedOwner: owner) { state in
            state.epochs[fixture.epochID]?.status = .retired
            state.epochs[fixture.epochID]?.retiredAt = now
            state.epochs[fixture.epochID]?.retireReason = .authoritativeBaseMismatch
        }

        var tamperedAfter = try XCTUnwrap(envelope.intendedAfterRecord)
        tamperedAfter.displayName = "tampered"
        let tampered = EarnedShieldEffectEnvelope(
            operationID: envelope.operationID,
            ownerChildDeviceID: envelope.ownerChildDeviceID,
            generationID: envelope.generationID,
            epochID: envelope.epochID,
            routeID: envelope.routeID,
            recordKey: envelope.recordKey,
            beforeRecord: envelope.beforeRecord,
            intendedAfterRecord: tamperedAfter,
            phase: .applied,
            retry: envelope.retry,
            createdAt: envelope.createdAt
        )
        try persistEnvelopes([operationID: tampered])

        XCTAssertThrowsError(try effectStore.release(operationID: operationID, expectedOwner: owner)) { error in
            XCTAssertEqual(error as? EarnedShieldEffectError, .authorizationChanged)
        }
        XCTAssertEqual(try shields()[envelope.recordKey], envelope.intendedAfterRecord)
        XCTAssertEqual(try envelopes()[operationID]?.phase, .applied)
    }

    private func makeActiveEpochStore() throws -> EffectFixture {
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { self.owner })
        let selection = Data([0x01, 0x02, 0x03])
        let generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "effect-test",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: selection),
            enforcementSetID: UUID(uuidString: "81000000-0000-4000-8000-000000000006")!
        )
        let horizon = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-18",
            generationKey: generationKey,
            persistedSelectionBytes: selection,
            poolMinutes: 120,
            deviceCapMinutes: 120,
            authoritativeBaseAcceptedMinutes: 0,
            now: now
        ))
        let todayRouteID = try XCTUnwrap(horizon.routeIDsByUsageDate["2026-07-18"])
        try store.transaction(expectedOwner: owner) { state in
            guard var route = state.routes[todayRouteID] else { throw EffectStoreTestError.missingRoute }
            route.lifecycle = .active
            route.installedSchedule = route.plannedSchedule
            route.installedEvents = route.plannedEvents
            state.routes[todayRouteID] = route
            state.activeGenerationID = route.generationID
            state.activeEpochID = route.epochID
            state.activeRouteID = todayRouteID
            state.generations[route.generationID]?.retiredAt = nil
            state.epochs[route.epochID]?.status = .active
        }
        let state = try store.read()
        return EffectFixture(
            store: store,
            generationID: try XCTUnwrap(state.activeGenerationID),
            epochID: try XCTUnwrap(state.activeEpochID),
            routeID: try XCTUnwrap(state.activeRouteID)
        )
    }

    private func makeEnvelope(
        fixture: EffectFixture,
        recordKey: String = "all",
        routeID: UUID? = nil
    ) -> EarnedShieldEffectEnvelope {
        let effectiveRouteID = routeID ?? fixture.routeID
        let before = ShieldRecord(
            recordKey: recordKey,
            tier: .all,
            targetKey: "all",
            displayName: "All Apps",
            lastCommandID: UUID(uuidString: "81000000-0000-4000-8000-000000000007")!,
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: now,
            expiresAt: nil,
            originalRequest: "manual",
            targetChildID: owner,
            sources: [.manual, ShieldSource(rawValue: "future-source")]
        )
        var after = before
        after.sources.insert(.earnedTime)
        return EarnedShieldEffectEnvelope(
            operationID: operationID,
            ownerChildDeviceID: owner,
            generationID: fixture.generationID,
            epochID: fixture.epochID,
            routeID: effectiveRouteID,
            recordKey: recordKey,
            beforeRecord: before,
            intendedAfterRecord: after,
            phase: .prepared,
            retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: now, lastErrorCode: nil, terminal: .pending),
            createdAt: now
        )
    }

    private func envelopes() throws -> [UUID: EarnedShieldEffectEnvelope] {
        try decode([UUID: EarnedShieldEffectEnvelope].self, key: EarnedShieldEffectStore.envelopeKey)
    }

    private func shields() throws -> [String: ShieldRecord] {
        try decode([String: ShieldRecord].self, key: EarnedShieldEffectStore.shieldsKey)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        let data = try XCTUnwrap(defaults.data(forKey: key))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func persistEnvelopes(_ values: [UUID: EarnedShieldEffectEnvelope]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(values), forKey: EarnedShieldEffectStore.envelopeKey)
    }

    private func persistShields(_ values: [String: ShieldRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(values), forKey: EarnedShieldEffectStore.shieldsKey)
    }

    private func authorizeRelease(_ fixture: EffectFixture) throws {
        try fixture.store.transaction(expectedOwner: owner) { state in
            state.epochs[fixture.epochID]?.status = .retired
            state.epochs[fixture.epochID]?.retiredAt = now
            state.epochs[fixture.epochID]?.retireReason = .authoritativeBaseMismatch
        }
    }

    private func copy(
        _ envelope: EarnedShieldEffectEnvelope,
        phase: EarnedShieldEffectPhase
    ) -> EarnedShieldEffectEnvelope {
        EarnedShieldEffectEnvelope(
            operationID: envelope.operationID,
            ownerChildDeviceID: envelope.ownerChildDeviceID,
            generationID: envelope.generationID,
            epochID: envelope.epochID,
            routeID: envelope.routeID,
            recordKey: envelope.recordKey,
            beforeRecord: envelope.beforeRecord,
            intendedAfterRecord: envelope.intendedAfterRecord,
            phase: phase,
            retry: envelope.retry,
            createdAt: envelope.createdAt
        )
    }

    private func seedBefore(_ envelope: EarnedShieldEffectEnvelope) throws {
        try persistShields([envelope.recordKey: try XCTUnwrap(envelope.beforeRecord)])
    }
}

private final class FalseSynchronizeEarnedShieldDefaults: UserDefaults {
    override func synchronize() -> Bool {
        _ = super.synchronize()
        return false
    }
}

private struct EffectFixture {
    let store: DeviceEpochStore
    let generationID: UUID
    let epochID: UUID
    let routeID: UUID
}

private enum EffectStoreTestError: Error {
    case missingRoute
}
