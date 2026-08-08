import Foundation
import XCTest
@testable import Evlin_iOS

/// A3 flight recorder — wire safety + the judgement points that used to be
/// silent (guard verdicts, sample enqueue, canonical rollover throws).
final class MeteringFlightRecorderTests: XCTestCase {

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

    private func events(kind: ScreenTimeEvent.Kind) -> [ScreenTimeEvent] {
        captured.filter { $0.kind == kind }
    }

    // MARK: - Wire safety

    /// The backend column is `String(16)` and the pydantic schema rejects
    /// longer values with a 422 for the WHOLE batch — which would stall the
    /// uploader watermark for every other event on the device.
    func testEveryEventKindFitsTheBackendColumn() {
        let kinds: [ScreenTimeEvent.Kind] = [
            .lock, .unlock, .sample, .decision, .cascade, .reset, .drop,
            .commandEmit, .commandAck,
            .meteringCallback, .meteringGuard, .meteringReplay, .meteringSample,
            .meteringRearm, .meteringCover, .meteringDay, .meteringWork,
            .meteringError, .meteringWatch, .meteringRepair,
        ]
        for kind in kinds {
            XCTAssertLessThanOrEqual(
                kind.rawValue.count, 16,
                "kind '\(kind.rawValue)' exceeds the backend's 16-char column"
            )
        }
    }

    func testEmittedStringsAreClampedToTheBackendColumnWidths() throws {
        MeteringFlightRecorder.emit(
            kind: .meteringGuard,
            site: String(repeating: "s", count: 400),
            verdict: String(repeating: "v", count: 400),
            detail: String(repeating: "d", count: 400)
        )
        let event = try XCTUnwrap(captured.first)
        XCTAssertEqual(event.reason?.count, MeteringFlightRecorder.reasonLimit)
        XCTAssertEqual(event.app?.count, MeteringFlightRecorder.detailLimit)
        // Truncation must be visible, not silent.
        XCTAssertEqual(event.reason?.last, "~")
        XCTAssertEqual(event.app?.last, "~")
    }

    func testDetailDropsEmptyValuesAndKeepsKeyValueShape() {
        let detail = MeteringFlightRecorder.detail([
            ("trigger", "install"),
            ("empty", ""),
            ("base", "12"),
        ])
        XCTAssertEqual(detail, "trigger=install base=12")
    }

    // MARK: - Converted silent catches

    func testEmitErrorProducesAMeteringErrorEventCarryingSiteAndError() {
        struct Boom: Error, CustomStringConvertible {
            var description: String { "boom_reason" }
        }
        MeteringFlightRecorder.emitError(
            site: "poller.meteringRecover",
            error: Boom(),
            detail: MeteringFlightRecorder.detail([("allowed", "true")])
        )

        let event = events(kind: .meteringError).first
        XCTAssertEqual(event?.reason, "error")
        XCTAssertEqual(event?.app?.hasPrefix("poller.meteringRecover"), true)
        XCTAssertEqual(event?.app?.contains("allowed=true"), true)
        XCTAssertEqual(event?.app?.contains("err=boom_reason"), true)
    }

    // MARK: - Guard verdicts

    func testTooEarlyCallbackEmitsGuardVerdictWithTheNumbersItJudgedOn() throws {
        let fixture = try RecorderFixture.active()
        defer { fixture.cleanup() }

        // Threshold 5 needs 5 minutes of wall clock since the epoch started.
        // Observed 2 minutes in: past FIX-Q's 90-second arm-calibration grace
        // (a bell inside it is an Apple back-fire, absorbed rather than judged),
        // so this is the genuine anti-cheat rejection.
        let outcome = try fixture.store.enqueueAuthorizedV2Callback(
            fixture.input(
                threshold: 5,
                observedAt: fixture.start.addingTimeInterval(120)
            ),
            owner: fixture.owner
        )
        XCTAssertEqual(outcome, .discarded(reason: "too_early"))

        let guardEvent = try XCTUnwrap(events(kind: .meteringGuard).first)
        XCTAssertEqual(guardEvent.reason, "too_early")
        XCTAssertEqual(guardEvent.app?.hasPrefix("store.callback"), true)
        // The numbers the decision was actually made on — the whole point.
        XCTAssertEqual(guardEvent.nums?.base, 12)
        XCTAssertEqual(guardEvent.nums?.raw, 0)
        XCTAssertEqual(guardEvent.nums?.threshold, 5)
        XCTAssertEqual(guardEvent.nums?.excluded, 0)
        XCTAssertEqual(guardEvent.corrID, fixture.routeID.uuidString)
        XCTAssertEqual(guardEvent.app?.contains("life=active"), true)
        XCTAssertEqual(guardEvent.app?.contains("status=active"), true)
        // No sample was created, so no sample event may claim one was.
        XCTAssertTrue(events(kind: .meteringSample).isEmpty)
    }

    func testQueuedCallbackEmitsGuardAndSampleEnqueuedWithReportedMinutes() throws {
        let fixture = try RecorderFixture.active()
        defer { fixture.cleanup() }

        let outcome = try fixture.store.enqueueAuthorizedV2Callback(
            fixture.input(threshold: 5, observedAt: fixture.start.addingTimeInterval(5 * 60)),
            owner: fixture.owner
        )
        guard case .queued = outcome else {
            return XCTFail("expected queued, got \(outcome)")
        }

        let guardEvent = try XCTUnwrap(events(kind: .meteringGuard).first)
        XCTAssertEqual(guardEvent.reason, "queued")

        let sampleEvent = try XCTUnwrap(events(kind: .meteringSample).first)
        XCTAssertEqual(sampleEvent.reason, "enqueued")
        // base(12) + threshold(5) is what the backend will be told.
        XCTAssertEqual(sampleEvent.nums?.used, 17)
        XCTAssertEqual(sampleEvent.nums?.threshold, 5)
        XCTAssertEqual(sampleEvent.app?.contains("date=2026-07-18"), true)
        XCTAssertEqual(sampleEvent.corrID, fixture.routeID.uuidString)
    }

    func testUnknownRouteCallbackStillEmitsAVerdictInsteadOfVanishing() throws {
        let fixture = try RecorderFixture.active()
        defer { fixture.cleanup() }

        let strangerRoute = UUID()
        let outcome = try fixture.store.enqueueAuthorizedV2Callback(
            MeteringAuthorizedCallbackInput(
                routeID: strangerRoute,
                activityName: MeteringRouteNamespace.activityName(routeID: strangerRoute),
                eventName: MeteringRouteNamespace.eventName(
                    routeID: strangerRoute,
                    thresholdMinutes: 5
                ),
                namespace: MeteringRouteNamespace.prefix,
                thresholdMinutes: 5,
                observedAt: fixture.start,
                now: fixture.start,
                jitterSeconds: EarnedMeteringCallback.defaultJitterSeconds
            ),
            owner: fixture.owner
        )
        XCTAssertEqual(outcome, .discarded(reason: "unknown_route"))

        let guardEvent = try XCTUnwrap(events(kind: .meteringGuard).first)
        XCTAssertEqual(guardEvent.reason, "unknown_route")
        XCTAssertEqual(guardEvent.app?.contains("life=no_route"), true)
    }

    // MARK: - Canonical rollover

    /// The exact failure that stranded devices on yesterday: the throw used to
    /// reach only a `print` in `BigKidStatePoller`.
    func testFailedCanonicalRolloverEmitsTheInvariantReason() throws {
        let fixture = try RecorderFixture.active()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try fixture.store.prepareCanonicalRollover(
                owner: fixture.owner,
                toUsageDate: "2026-07-19",
                now: fixture.start
            )
        )
        let dayEvent = try XCTUnwrap(events(kind: .meteringDay).first)
        XCTAssertEqual(dayEvent.reason, "prepare_failed")
        XCTAssertEqual(dayEvent.app?.contains("to=2026-07-19"), true)
        XCTAssertEqual(dayEvent.app?.contains("err="), true)
        XCTAssertEqual(dayEvent.transition?.after, "2026-07-19")
    }

    // MARK: - Re-arm absorption

    func testAbsorbEmitsTheTriggerAndTheBaseTransition() throws {
        let fixture = try RecorderFixture.active()
        defer { fixture.cleanup() }
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state.epochs[fixture.epochID]?.lastRawThresholdMinutes = 10
        }

        let absorbed = try fixture.store.absorbCreditedProgressForRearm(
            routeID: fixture.routeID,
            owner: fixture.owner,
            trigger: "rekick:watchdog"
        )
        XCTAssertTrue(absorbed)

        let event = try XCTUnwrap(events(kind: .meteringRearm).first)
        XCTAssertEqual(event.reason, "absorbed")
        XCTAssertEqual(event.app?.contains("trigger=rekick:watchdog"), true)
        XCTAssertEqual(event.transition?.before, "base:12+raw:10")
        // The raw high-water is only an OBSERVATION — this fixture has no
        // succeeded sample work, so the backend never accepted those 10
        // minutes and the absorb must drop them instead of promoting them into
        // the base. (Carrying raw blindly is the poison that inflated bases
        // past the pool; `testAbsorbCarriesOnlyBackendAcceptedProgress...`
        // covers the accepted case.)
        XCTAssertEqual(event.transition?.after, "base:12+raw:0")
        XCTAssertEqual(event.nums?.base, 12)
    }
}

// MARK: - Fixture

/// Minimal active v2 route, mirroring the shape `EarnedMeteringCallbackTests`
/// builds (its own fixture is file-private).
private final class RecorderFixture {
    let owner = UUID()
    let generationID = UUID()
    let epochID = UUID()
    let routeID = UUID()
    let installID = UUID()
    let start = Date(timeIntervalSince1970: 1_784_937_600)
    let storeURL: URL
    let store: DeviceEpochStore

    init() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-flight-recorder-\(UUID().uuidString).json")
        let owner = self.owner
        store = DeviceEpochStore(
            fileURL: storeURL,
            lock: RecorderLock(),
            ownerProvider: { owner }
        )
    }

    static func active(usageDate: String = "2026-07-18") throws -> RecorderFixture {
        let fixture = RecorderFixture()
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state = fixture.activeState(usageDate: usageDate)
        }
        return fixture
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    func input(threshold: Int, observedAt: Date) -> MeteringAuthorizedCallbackInput {
        MeteringAuthorizedCallbackInput(
            routeID: routeID,
            activityName: MeteringRouteNamespace.activityName(routeID: routeID),
            eventName: MeteringRouteNamespace.eventName(
                routeID: routeID,
                thresholdMinutes: threshold
            ),
            namespace: MeteringRouteNamespace.prefix,
            thresholdMinutes: threshold,
            observedAt: observedAt,
            now: observedAt,
            jitterSeconds: EarnedMeteringCallback.defaultJitterSeconds
        )
    }

    private func activeState(usageDate: String) -> DeviceEpochStoreState {
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: Data([1])
            ),
            enforcementSetID: UUID(),
            measurementSelectionBytes: Data([1]),
            createdAt: start,
            retiredAt: nil
        )
        let epoch = DeviceDailyEpoch(
            epochID: epochID,
            protocolVersion: 2,
            childDeviceID: owner,
            usageDate: usageDate,
            canonicalTimezone: generation.canonicalTimezone,
            policyRevision: generation.policyRevision,
            measurementSelectionDigest: generation.measurementSelectionDigest,
            enforcementSetID: generation.enforcementSetID,
            startedAt: start,
            registeredAt: start,
            baseAcceptedMinutes: 12,
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
            usageDate: epoch.usageDate,
            timezoneIdentifier: generation.canonicalTimezone,
            calendarIdentifier: "gregorian"
        )
        let plan = MeteringEventPlan(
            eventName: MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 5),
            thresholdMinutes: 5
        )
        let route = MeteringCallbackRoute(
            routeID: routeID,
            activityName: MeteringRouteNamespace.activityName(routeID: routeID),
            namespace: MeteringRouteNamespace.prefix,
            generationID: generationID,
            generationKey: MeteringGenerationKey(
                protocolVersion: 2,
                childDeviceID: owner,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID
            ),
            ownerChildDeviceID: owner,
            usageDate: epoch.usageDate,
            epochID: epochID,
            plannedSchedule: schedule,
            installedSchedule: schedule,
            plannedEvents: [plan],
            installedEvents: [plan],
            lifecycle: .active,
            createdAt: start
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
                nextAttemptAt: start,
                lastErrorCode: nil,
                terminal: .succeeded
            ),
            createdAt: start
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
                registeredV2At: start,
                dualActiveAt: start,
                activatedV2At: start
            )]
        )
    }
}

private final class RecorderLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
