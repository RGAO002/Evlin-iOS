import DeviceActivity
import FamilyControls
import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringTerminalShieldCompositionTests: XCTestCase {
    func testTrustedTerminalPersistsSampleReceiptShieldAndProjectsOnce() throws {
        let fixture = try TerminalShieldFixture()
        defer { fixture.cleanUp() }

        let outcome = try fixture.entry.handle(
            activityName: fixture.activityName,
            eventName: fixture.eventName,
            observedAt: fixture.terminalAt,
            projectShields: fixture.project
        )

        guard case .queued = outcome else { return XCTFail("expected queued terminal sample") }
        let state = try fixture.store.read()
        let reference = try XCTUnwrap(state.shieldReferences[fixture.routeID])
        let envelope = try XCTUnwrap(fixture.envelopes()[fixture.routeID])
        XCTAssertEqual(state.sampleWork.count, 1)
        XCTAssertEqual(reference.operationID, envelope.operationID)
        XCTAssertEqual(reference.ownerChildDeviceID, fixture.owner)
        XCTAssertEqual(reference.generationID, fixture.generationID)
        XCTAssertEqual(reference.epochID, fixture.epochID)
        XCTAssertEqual(reference.routeID, fixture.routeID)
        XCTAssertEqual(reference.recordKey, envelope.recordKey)
        XCTAssertEqual(reference, try fixture.effectStore.reference(for: envelope))
        XCTAssertEqual(envelope.phase, .applied)
        XCTAssertEqual(try fixture.shields()[envelope.recordKey], envelope.intendedAfterRecord)
        XCTAssertEqual(fixture.projected.count, 1)
        XCTAssertEqual(fixture.projected.first, try fixture.shields())
    }

    func testUntrustedTerminalLeavesNoSampleReceiptEnvelopeShieldOrProjection() throws {
        for mutation in [TerminalMutation.tooEarly, .wrongRoute] {
            let fixture = try TerminalShieldFixture()
            defer { fixture.cleanUp() }

            let outcome = try fixture.entry.handle(
                activityName: mutation == .wrongRoute
                    ? MeteringRouteNamespace.activityName(routeID: UUID())
                    : fixture.activityName,
                eventName: mutation == .wrongRoute
                    ? MeteringRouteNamespace.eventName(routeID: UUID(), thresholdMinutes: 5)
                    : fixture.eventName,
                observedAt: mutation == .tooEarly
                    ? fixture.terminalAt.addingTimeInterval(-61)
                    : fixture.terminalAt,
                projectShields: fixture.project
            )

            guard case .discarded = outcome else { return XCTFail("untrusted terminal must discard") }
            XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)
            XCTAssertTrue(try fixture.store.read().shieldReferences.isEmpty)
            XCTAssertTrue(try fixture.envelopes().isEmpty)
            XCTAssertTrue(try fixture.shields().isEmpty)
            XCTAssertTrue(fixture.projected.isEmpty)
        }
    }

    func testCanonicalDayOverrideCountsSampleWithoutLocalShieldEffects() throws {
        let fixture = try TerminalShieldFixture()
        defer { fixture.cleanUp() }
        fixture.earnedStore.setOverride(true, forUsageDate: fixture.usageDate)

        let outcome = try fixture.entry.handle(
            activityName: fixture.activityName,
            eventName: fixture.eventName,
            observedAt: fixture.terminalAt,
            projectShields: fixture.project
        )

        guard case .queued = outcome else { return XCTFail("override must not suppress accounting") }
        XCTAssertEqual(try fixture.store.read().sampleWork.count, 1)
        XCTAssertTrue(try fixture.store.read().shieldReferences.isEmpty)
        XCTAssertTrue(try fixture.envelopes().isEmpty)
        XCTAssertTrue(try fixture.shields().isEmpty)
        XCTAssertTrue(fixture.projected.isEmpty)
    }

    func testPausedGateCreatesNoLocalShieldEffects() throws {
        let fixture = try TerminalShieldFixture()
        defer { fixture.cleanUp() }
        fixture.earnedStore.usageCountingAllowed = false
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state.epochs[fixture.epochID]?.status = .paused
        }

        _ = try fixture.entry.handle(
            activityName: fixture.activityName,
            eventName: fixture.eventName,
            observedAt: fixture.terminalAt,
            projectShields: fixture.project
        )

        XCTAssertTrue(try fixture.store.read().shieldReferences.isEmpty)
        XCTAssertTrue(try fixture.envelopes().isEmpty)
        XCTAssertTrue(try fixture.shields().isEmpty)
        XCTAssertTrue(fixture.projected.isEmpty)
    }

    func testRecoveryDiscardsPreparedEnvelopeWithoutAuthorizedReference() throws {
        let fixture = try TerminalShieldFixture()
        defer { fixture.cleanUp() }
        let candidate = try XCTUnwrap(fixture.callback.terminalCandidate(
            fixture.appleCallback,
            expectedOwnerChildDeviceID: fixture.owner
        ))
        XCTAssertNotNil(try fixture.effectStore.prepareTerminal(
            candidate,
            selection: FamilyActivitySelection(),
            appliesToAll: true,
            isSuppressed: { false }
        ))

        try fixture.entry.recoverShieldEffects(
            expectedOwner: fixture.owner,
            projectShields: fixture.project
        )

        XCTAssertTrue(try fixture.envelopes().isEmpty)
        XCTAssertTrue(try fixture.store.read().shieldReferences.isEmpty)
        XCTAssertTrue(try fixture.shields().isEmpty)
        XCTAssertTrue(fixture.projected.isEmpty)
    }

    func testRecoveryAppliesPreparedEnvelopeAfterAtomicSampleReferenceCommitExactlyOnce() throws {
        let fixture = try TerminalShieldFixture()
        defer { fixture.cleanUp() }
        let candidate = try XCTUnwrap(fixture.callback.terminalCandidate(
            fixture.appleCallback,
            expectedOwnerChildDeviceID: fixture.owner
        ))
        let envelope = try XCTUnwrap(fixture.effectStore.prepareTerminal(
            candidate,
            selection: FamilyActivitySelection(),
            appliesToAll: true,
            isSuppressed: { false }
        ))
        guard case .queued = try fixture.callback.handle(
            fixture.appleCallback,
            expectedOwnerChildDeviceID: fixture.owner,
            preparedShieldReference: try fixture.effectStore.reference(for: envelope)
        ) else { return XCTFail("expected atomic sample/reference commit") }

        try fixture.entry.recoverShieldEffects(
            expectedOwner: fixture.owner,
            projectShields: fixture.project
        )
        try fixture.entry.recoverShieldEffects(
            expectedOwner: fixture.owner,
            projectShields: fixture.project
        )

        XCTAssertEqual(try fixture.store.read().sampleWork.count, 1)
        XCTAssertEqual(try fixture.store.read().shieldReferences.count, 1)
        XCTAssertEqual(try fixture.envelopes()[fixture.routeID]?.phase, .applied)
        XCTAssertEqual(try fixture.shields()[envelope.recordKey], envelope.intendedAfterRecord)
        XCTAssertEqual(fixture.projected.count, 1)
    }

    @MainActor
    func testOfflineSampleDeliveryDoesNotBlockLocalPreparedShieldRecovery() async throws {
        let fixture = try TerminalShieldFixture()
        defer { fixture.cleanUp() }
        let candidate = try XCTUnwrap(fixture.callback.terminalCandidate(
            fixture.appleCallback,
            expectedOwnerChildDeviceID: fixture.owner
        ))
        let envelope = try XCTUnwrap(fixture.effectStore.prepareTerminal(
            candidate,
            selection: FamilyActivitySelection(),
            appliesToAll: true,
            isSuppressed: { false }
        ))
        guard case .queued = try fixture.callback.handle(
            fixture.appleCallback,
            expectedOwnerChildDeviceID: fixture.owner,
            preparedShieldReference: try fixture.effectStore.reference(for: envelope)
        ) else { return XCTFail("expected atomic sample/reference commit") }

        let recoveringEntry = DAMMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: TerminalCenter(),
            transport: TerminalOfflineTransport(),
            clock: TerminalClock(now: fixture.terminalAt),
            instanceID: UUID(),
            earnedStore: fixture.earnedStore,
            effectStore: fixture.effectStore,
            selectionProvider: { FamilyActivitySelection() }
        )

        await recoveringEntry.recoverIfConfigured(projectShields: fixture.project)

        XCTAssertEqual(try fixture.envelopes()[fixture.routeID]?.phase, .applied)
        XCTAssertEqual(try fixture.shields()[envelope.recordKey], envelope.intendedAfterRecord)
        XCTAssertEqual(fixture.projected.count, 1)
    }
}

private enum TerminalMutation {
    case tooEarly, wrongRoute
}

private final class TerminalShieldFixture {
    let owner = UUID()
    let generationID = UUID()
    let epochID = UUID()
    let routeID = UUID()
    let installID = UUID()
    let enforcementSetID = UUID()
    let usageDate = "2026-07-18"
    let startedAt = Date(timeIntervalSince1970: 1_784_937_600)
    let suiteName: String
    let defaults: UserDefaults
    let storeURL: URL
    let store: DeviceEpochStore
    let earnedStore: EarnedTimeStore
    let effectStore: EarnedShieldEffectStore
    let callback: EarnedMeteringCallback
    let entry: DAMMeteringEntry
    var projected: [[String: ShieldRecord]] = []

    var terminalAt: Date { startedAt.addingTimeInterval(5 * 60) }
    var activityName: String { MeteringRouteNamespace.activityName(routeID: routeID) }
    var eventName: String {
        MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 5)
    }
    var appleCallback: MeteringAppleCallback {
        MeteringAppleCallback(
            activityName: activityName,
            eventName: eventName,
            observedAt: terminalAt
        )
    }
    func project(_ shields: [String: ShieldRecord]) {
        projected.append(shields)
    }

    init() throws {
        let terminalDate = Date(timeIntervalSince1970: 1_784_937_600 + 5 * 60)
        suiteName = "MeteringTerminalShieldCompositionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shield-\(UUID().uuidString).json")
        store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { [owner] in owner })
        earnedStore = EarnedTimeStore(suiteName: suiteName)
        effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: store)
        callback = EarnedMeteringCallback(
            store: store,
            clock: TerminalClock(now: terminalDate)
        )
        entry = DAMMeteringEntry(
            defaults: defaults,
            store: store,
            clock: TerminalClock(now: terminalDate),
            instanceID: UUID(),
            earnedStore: earnedStore,
            effectStore: effectStore,
            selectionProvider: { FamilyActivitySelection() }
        )
        defaults.set("https://example.invalid/api/v1", forKey: MeteringProductionComposition.baseURLKey)
        defaults.set(owner.uuidString, forKey: MeteringProductionComposition.ownerKey)
        earnedStore.saveLockedSetID(enforcementSetID.uuidString, tokenData: nil)
        earnedStore.saveLockedSetAllSelected(true)
        earnedStore.usageCountingAllowed = true
        try store.transaction(expectedOwner: owner) { state in
            state = activeState()
        }
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storeURL)
    }

    func envelopes() throws -> [UUID: EarnedShieldEffectEnvelope] {
        try decode([UUID: EarnedShieldEffectEnvelope].self, key: EarnedShieldEffectStore.envelopeKey)
    }

    func shields() throws -> [String: ShieldRecord] {
        try decode([String: ShieldRecord].self, key: EarnedShieldEffectStore.shieldsKey)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        guard let data = defaults.data(forKey: key) else {
            if type == [UUID: EarnedShieldEffectEnvelope].self { return [:] as! T }
            if type == [String: ShieldRecord].self { return [:] as! T }
            throw TerminalShieldFixtureError.missingData
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func activeState() -> DeviceEpochStoreState {
        let digest = MeteringEpochContract.selectionDigest(persistedBytes: Data([1]))
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "terminal-shield-r1",
            measurementSelectionDigest: digest,
            enforcementSetID: enforcementSetID,
            measurementSelectionBytes: Data([1]),
            createdAt: startedAt,
            retiredAt: nil
        )
        let epoch = DeviceDailyEpoch(
            epochID: epochID,
            protocolVersion: 2,
            childDeviceID: owner,
            usageDate: usageDate,
            canonicalTimezone: generation.canonicalTimezone,
            policyRevision: generation.policyRevision,
            measurementSelectionDigest: digest,
            enforcementSetID: enforcementSetID,
            startedAt: startedAt,
            registeredAt: startedAt,
            baseAcceptedMinutes: 0,
            baseSource: .childState200,
            lastRawThresholdMinutes: 0,
            excludedWhilePausedMinutes: 0,
            status: .active,
            resumeBoundaryPending: false,
            retiredAt: nil,
            retireReason: nil,
            exhaustedAt: nil,
            baseCorrectionState: .available
        )
        let schedule = DatedSchedulePlan(
            usageDate: usageDate,
            timezoneIdentifier: generation.canonicalTimezone,
            calendarIdentifier: "gregorian"
        )
        let event = MeteringEventPlan(eventName: eventName, thresholdMinutes: 5)
        let route = MeteringCallbackRoute(
            routeID: routeID,
            activityName: activityName,
            namespace: MeteringRouteNamespace.prefix,
            generationID: generationID,
            generationKey: MeteringGenerationKey(
                protocolVersion: 2,
                childDeviceID: owner,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: digest,
                enforcementSetID: enforcementSetID
            ),
            ownerChildDeviceID: owner,
            usageDate: usageDate,
            epochID: epochID,
            plannedSchedule: schedule,
            installedSchedule: schedule,
            plannedEvents: [event],
            installedEvents: [event],
            lifecycle: .active,
            createdAt: startedAt
        )
        let install = ActivityInstallWork(
            workID: installID,
            ownerChildDeviceID: owner,
            routeID: routeID,
            authorization: .registered,
            phase: .active,
            claim: nil,
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: startedAt,
                lastErrorCode: nil,
                terminal: .succeeded
            ),
            createdAt: startedAt
        )
        return DeviceEpochStoreState(
            ownerChildDeviceID: owner,
            generations: [generationID: generation],
            activeGenerationID: generationID,
            epochs: [epochID: epoch],
            activeEpochID: epochID,
            routes: [routeID: route],
            activeRouteID: routeID,
            installWork: [installID: install],
            ratchets: [owner: MeteringOwnerRatchet(
                ownerChildDeviceID: owner,
                advertisedVersion: 2,
                localSelection: .v2,
                registeredV2At: startedAt,
                dualActiveAt: startedAt,
                activatedV2At: startedAt
            )]
        )
    }
}

private struct TerminalClock: MeteringClock {
    let now: Date
}

private enum TerminalShieldFixtureError: Error {
    case missingData
}

private nonisolated final class TerminalCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    var activities: [DeviceActivityName] = []

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { nil }
    func events(
        for activity: DeviceActivityName
    ) -> [DeviceActivityEvent.Name: DeviceActivityEvent] { [:] }
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {}
    func stopMonitoring(_ activities: [DeviceActivityName]) {}
}

private struct TerminalOfflineTransport: MeteringHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
