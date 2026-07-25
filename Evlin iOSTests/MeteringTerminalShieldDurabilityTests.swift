import DeviceActivity
import FamilyControls
import Foundation
import XCTest
@testable import Evlin_iOS

/// FIX-E / BUG 2 — the terminal rung is the one that locks the device, and Apple
/// delivers it exactly once.
///
/// Field evidence (kid_extension, 2026-07-25 13:37:28):
/// `metering_error dam.terminalShield err=durableReadbackMismatch` — the child's
/// pool ran out and nothing locked.
final class MeteringTerminalShieldDurabilityTests: XCTestCase {

    private var captured: [ScreenTimeEvent] = []

    override func setUp() {
        super.setUp()
        captured = []
        MeteringFlightRecorder.testSink = { [weak self] event in
            self?.captured.append(event)
        }
    }

    override func tearDown() {
        MeteringFlightRecorder.testSink = nil
        captured = []
        super.tearDown()
    }

    // MARK: - The readback mismatch itself

    /// The proximate cause. `evlin.shieldRecords` is written by four components
    /// and read by four; three of the readers accept a PropertyList payload and
    /// normalize the schema. `EarnedShieldEffectStore` was the only one that did
    /// not, so a blob the rest of the app considers perfectly valid made the
    /// terminal lock throw.
    func testLegacyPropertyListShieldBlobNoLongerBreaksTheTerminalLock() throws {
        let fixture = try TerminalDurabilityFixture()
        defer { fixture.cleanUp() }
        try fixture.seedLegacyPropertyListShields()

        let candidate = try XCTUnwrap(fixture.terminalCandidate())
        let envelope = try fixture.effectStore.prepareTerminal(
            candidate,
            selection: FamilyActivitySelection(),
            appliesToAll: true,
            isSuppressed: { false }
        )
        XCTAssertNotNil(envelope, "a legacy payload must not block the lock")
    }

    /// The same store must still refuse genuinely unreadable bytes rather than
    /// silently treating them as "no shields" and wiping a parent's locks.
    func testUnreadableShieldBlobStillFailsLoudly() throws {
        let fixture = try TerminalDurabilityFixture()
        defer { fixture.cleanUp() }
        fixture.seedCorruptShields()

        let candidate = try XCTUnwrap(fixture.terminalCandidate())
        XCTAssertThrowsError(try fixture.effectStore.prepareTerminal(
            candidate,
            selection: FamilyActivitySelection(),
            appliesToAll: true,
            isSuppressed: { false }
        )) { error in
            XCTAssertEqual(
                error as? EarnedShieldEffectError,
                .durableReadbackMismatch
            )
        }
    }

    // MARK: - The structural failure: a one-shot rung consumed with no lock

    /// Before FIX-E this was the whole bug: prepare throws, the throw is logged,
    /// `callback.handle` consumes the rung anyway, and nothing durable is left
    /// for any retry to find. Apple never re-delivers, so the device stays
    /// unlocked until midnight.
    func testTerminalLockFailureIsQueuedDurablyInsteadOfVanishing() throws {
        let fixture = try TerminalDurabilityFixture()
        defer { fixture.cleanUp() }
        fixture.seedCorruptShields()

        let outcome = try fixture.entry.handle(
            activityName: fixture.activityName,
            eventName: fixture.eventName,
            observedAt: fixture.terminalAt,
            projectShields: fixture.project
        )

        // The minutes still count — metering must not be held hostage by the
        // shield leg.
        guard case .queued = outcome else { return XCTFail("expected queued sample") }
        XCTAssertEqual(try fixture.store.read().sampleWork.count, 1)

        // …but the lock is now owed, durably, with the reason recorded.
        let pending = try fixture.effectStore.pendingTerminals(expectedOwner: fixture.owner)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.candidate.routeID, fixture.routeID)
        XCTAssertEqual(pending.first?.attemptCount, 1)
        XCTAssertEqual(
            pending.first?.lastErrorCode, "durableReadbackMismatch",
            "the queue has to carry WHY, or the retry is blind"
        )
        let recorded = try XCTUnwrap(
            captured.first { $0.app?.contains("dam.terminalShield") == true }
        )
        XCTAssertEqual(recorded.kind, .meteringError)
        XCTAssertEqual(recorded.app?.contains("queued=retry"), true)
        XCTAssertTrue(fixture.projected.isEmpty, "nothing locked yet")
    }

    /// And the queued lock actually lands on the next wake, without the daemon
    /// ever re-delivering the rung.
    func testQueuedTerminalLockIsAppliedOnTheNextRecoveryPass() throws {
        let fixture = try TerminalDurabilityFixture()
        defer { fixture.cleanUp() }
        fixture.seedCorruptShields()

        _ = try fixture.entry.handle(
            activityName: fixture.activityName,
            eventName: fixture.eventName,
            observedAt: fixture.terminalAt,
            projectShields: fixture.project
        )
        XCTAssertEqual(
            try fixture.effectStore.pendingTerminals(expectedOwner: fixture.owner).count, 1
        )

        // Whatever made the store unreadable is gone by the next wake.
        fixture.clearShields()
        try fixture.entry.recoverShieldEffects(
            expectedOwner: fixture.owner,
            projectShields: fixture.project
        )

        XCTAssertTrue(
            try fixture.effectStore.pendingTerminals(expectedOwner: fixture.owner).isEmpty,
            "a landed lock must leave the queue"
        )
        let envelope = try XCTUnwrap(fixture.envelopes()[fixture.routeID])
        XCTAssertEqual(envelope.phase, .applied)
        XCTAssertEqual(try fixture.shields()[envelope.recordKey], envelope.intendedAfterRecord)
        XCTAssertEqual(fixture.projected.count, 1, "the lock must be projected exactly once")
        XCTAssertEqual(
            try fixture.store.read().shieldReferences[fixture.routeID]?.routeID,
            fixture.routeID,
            "the retry creates the reference the failed callback never committed"
        )
    }

    /// Repeated drains must not double-lock or re-project — the retry runs on
    /// every wake, so idempotence is not optional.
    func testDrainingTwiceLocksOnceAndDoesNotFlap() throws {
        let fixture = try TerminalDurabilityFixture()
        defer { fixture.cleanUp() }
        fixture.seedCorruptShields()
        _ = try fixture.entry.handle(
            activityName: fixture.activityName,
            eventName: fixture.eventName,
            observedAt: fixture.terminalAt,
            projectShields: fixture.project
        )
        fixture.clearShields()

        try fixture.entry.recoverShieldEffects(
            expectedOwner: fixture.owner,
            projectShields: fixture.project
        )
        let afterFirst = try fixture.shields()
        try fixture.entry.recoverShieldEffects(
            expectedOwner: fixture.owner,
            projectShields: fixture.project
        )

        XCTAssertEqual(try fixture.shields(), afterFirst, "the second drain changed a shield")
        XCTAssertEqual(fixture.projected.count, 1, "projection must not flap")
        XCTAssertEqual(try fixture.envelopes().count, 1)
    }

    /// A failure that persists stays queued, keeps counting attempts, and keeps
    /// leaving records. It is never dropped on the floor.
    func testAPersistentFailureStaysQueuedAndKeepsRecordingAttempts() throws {
        let fixture = try TerminalDurabilityFixture()
        defer { fixture.cleanUp() }
        fixture.seedCorruptShields()
        _ = try fixture.entry.handle(
            activityName: fixture.activityName,
            eventName: fixture.eventName,
            observedAt: fixture.terminalAt,
            projectShields: fixture.project
        )

        // Still broken on the next wake.
        try fixture.entry.recoverShieldEffects(
            expectedOwner: fixture.owner,
            projectShields: fixture.project
        )

        let pending = try fixture.effectStore.pendingTerminals(expectedOwner: fixture.owner)
        XCTAssertEqual(pending.count, 1, "an unfixable lock must stay owed")
        XCTAssertEqual(pending.first?.attemptCount, 2)
        XCTAssertTrue(
            captured.contains { $0.app?.contains("shield.terminalRetry") == true },
            "every failed retry must leave an uploadable record"
        )
    }
}

// MARK: - Fixture

private enum TerminalDurabilityFixtureError: Error { case missingData }

private final class TerminalDurabilityFixture {
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

    func project(_ shields: [String: ShieldRecord]) { projected.append(shields) }

    init() throws {
        let clockDate = Date(timeIntervalSince1970: 1_784_937_600 + 5 * 60)
        suiteName = "MeteringTerminalShieldDurabilityTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-durability-\(UUID().uuidString).json")
        store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { [owner] in owner })
        earnedStore = EarnedTimeStore(suiteName: suiteName)
        effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: store)
        callback = EarnedMeteringCallback(
            store: store,
            clock: DurabilityClock(now: clockDate)
        )
        entry = DAMMeteringEntry(
            defaults: defaults,
            store: store,
            clock: DurabilityClock(now: clockDate),
            instanceID: UUID(),
            earnedStore: earnedStore,
            effectStore: effectStore,
            selectionProvider: { FamilyActivitySelection() }
        )
        defaults.set(
            "https://example.invalid/api/v1",
            forKey: MeteringProductionComposition.baseURLKey
        )
        defaults.set(owner.uuidString, forKey: MeteringProductionComposition.ownerKey)
        earnedStore.saveLockedSetID(enforcementSetID.uuidString, tokenData: nil)
        earnedStore.saveLockedSetAllSelected(true)
        earnedStore.usageCountingAllowed = true
        try store.transaction(expectedOwner: owner) { state in
            state = self.activeState()
        }
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storeURL)
    }

    func terminalCandidate() throws -> MeteringTerminalShieldCandidate? {
        try callback.terminalCandidate(
            MeteringAppleCallback(
                activityName: activityName,
                eventName: eventName,
                observedAt: terminalAt
            ),
            expectedOwnerChildDeviceID: owner
        )
    }

    /// The shape `ActiveLockStore`, `AppLimitShieldPersistence` and the
    /// DeviceActivity extension all decode via their PropertyList fallback.
    func seedLegacyPropertyListShields() throws {
        let record = ShieldRecord(
            recordKey: "savedList:legacy",
            tier: .savedList,
            targetKey: "legacy",
            displayName: "Legacy",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: startedAt,
            expiresAt: nil,
            originalRequest: "legacy",
            targetChildID: owner
        )
        let data = try PropertyListEncoder().encode(["savedList:legacy": record])
        defaults.set(data, forKey: EarnedShieldEffectStore.shieldsKey)
    }

    func seedCorruptShields() {
        defaults.set(Data([0x00, 0x01, 0x02, 0x03]), forKey: EarnedShieldEffectStore.shieldsKey)
    }

    func clearShields() {
        defaults.removeObject(forKey: EarnedShieldEffectStore.shieldsKey)
    }

    func envelopes() throws -> [UUID: EarnedShieldEffectEnvelope] {
        try decode(
            [UUID: EarnedShieldEffectEnvelope].self,
            key: EarnedShieldEffectStore.envelopeKey
        )
    }

    func shields() throws -> [String: ShieldRecord] {
        try decode([String: ShieldRecord].self, key: EarnedShieldEffectStore.shieldsKey)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        guard let data = defaults.data(forKey: key) else {
            if type == [UUID: EarnedShieldEffectEnvelope].self { return [:] as! T }
            if type == [String: ShieldRecord].self { return [:] as! T }
            throw TerminalDurabilityFixtureError.missingData
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func activeState() -> DeviceEpochStoreState {
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: Data([1])
            ),
            enforcementSetID: enforcementSetID,
            measurementSelectionBytes: Data([1]),
            createdAt: startedAt,
            retiredAt: nil,
            configuredPoolMinutes: 5,
            configuredDeviceCapMinutes: 5
        )
        let epoch = DeviceDailyEpoch(
            epochID: epochID,
            protocolVersion: 2,
            childDeviceID: owner,
            usageDate: usageDate,
            canonicalTimezone: generation.canonicalTimezone,
            policyRevision: generation.policyRevision,
            measurementSelectionDigest: generation.measurementSelectionDigest,
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
        let plan = MeteringEventPlan(
            eventName: MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 5),
            thresholdMinutes: 5
        )
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
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: enforcementSetID
            ),
            ownerChildDeviceID: owner,
            usageDate: usageDate,
            epochID: epochID,
            plannedSchedule: schedule,
            installedSchedule: schedule,
            plannedEvents: [plan],
            installedEvents: [plan],
            lifecycle: .active,
            createdAt: startedAt,
            ladderBaseMinutes: 0
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
            registrationWork: [:],
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

private struct DurabilityClock: MeteringClock {
    let now: Date
}
