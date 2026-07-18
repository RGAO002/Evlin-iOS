import FamilyControls
import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringT3DemolitionTests: XCTestCase {
    func testFreshGateAndLegacyDirectSelfLockAreAbsentFromProduction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let reporter = try String(
            contentsOf: root.appendingPathComponent("Evlin iOS/Services/EarnedSampleReporter.swift"),
            encoding: .utf8
        )
        let monitor = try String(
            contentsOf: root.appendingPathComponent(
                "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift"
            ),
            encoding: .utf8
        )
        let forbiddenGate = ["should", "Apply", "Earned", "Shield", "Fresh"].joined()
        let forbiddenDirectWriter = ["apply", "Earned", "Time", "Shield"].joined()

        XCTAssertFalse(reporter.contains(forbiddenGate))
        XCTAssertFalse(monitor.contains(forbiddenGate))
        XCTAssertFalse(monitor.contains(forbiddenDirectWriter))
        XCTAssertTrue(monitor.contains("EarnedSampleReporter.enqueueRetry"))
        XCTAssertTrue(monitor.contains("DAMMeteringEntry.shared.handle"))
    }

    func testDelayedTrustedTerminalCreatesOneReceiptBackedShield() throws {
        let fixture = try T3Fixture()
        defer { fixture.cleanUp() }

        let outcome = try fixture.handle(observedAt: fixture.startedAt.addingTimeInterval(86_700))

        guard case .queued = outcome else { return XCTFail("delayed trusted terminal must queue") }
        let state = try fixture.store.read()
        XCTAssertEqual(state.sampleWork.count, 1)
        XCTAssertEqual(state.shieldReferences.count, 1)
        XCTAssertEqual(try fixture.envelopes()[fixture.routeID]?.phase, .applied)
        XCTAssertEqual(try fixture.shields().count, 1)
        XCTAssertEqual(fixture.projectionCount, 1)
    }

    func testEarlyTerminalHasNoSampleOrLocalEffect() throws {
        let fixture = try T3Fixture()
        defer { fixture.cleanUp() }

        let outcome = try fixture.handle(observedAt: fixture.startedAt.addingTimeInterval(269))

        XCTAssertEqual(outcome, .discarded(reason: "too_early"))
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)
        XCTAssertTrue(try fixture.store.read().shieldReferences.isEmpty)
        XCTAssertTrue(try fixture.envelopes().isEmpty)
        XCTAssertTrue(try fixture.shields().isEmpty)
        XCTAssertEqual(fixture.projectionCount, 0)
    }

    func testPausedGateAndCanonicalOverrideCreateNoLocalEffect() throws {
        for suppression in [T3Suppression.paused, .override] {
            let fixture = try T3Fixture(suppression: suppression)
            defer { fixture.cleanUp() }

            _ = try fixture.handle(observedAt: fixture.startedAt.addingTimeInterval(300))

            XCTAssertTrue(try fixture.store.read().shieldReferences.isEmpty, "\(suppression)")
            XCTAssertTrue(try fixture.envelopes().isEmpty, "\(suppression)")
            XCTAssertTrue(try fixture.shields().isEmpty, "\(suppression)")
            XCTAssertEqual(fixture.projectionCount, 0, "\(suppression)")
        }
    }
}

private enum T3Suppression: CustomStringConvertible {
    case none, paused, override

    var description: String {
        switch self {
        case .none: "none"
        case .paused: "paused"
        case .override: "override"
        }
    }
}

private final class T3Fixture {
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
    let entry: DAMMeteringEntry
    private(set) var projectionCount = 0

    private var activityName: String {
        MeteringRouteNamespace.activityName(routeID: routeID)
    }
    private var eventName: String {
        MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 5)
    }

    init(suppression: T3Suppression = .none) throws {
        suiteName = "MeteringT3DemolitionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-t3-\(UUID().uuidString).json")
        store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { [owner] in owner })
        earnedStore = EarnedTimeStore(suiteName: suiteName)
        effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: store)
        entry = DAMMeteringEntry(
            defaults: defaults,
            store: store,
            clock: T3Clock(now: startedAt.addingTimeInterval(86_700)),
            instanceID: UUID(),
            earnedStore: earnedStore,
            effectStore: effectStore,
            selectionProvider: { FamilyActivitySelection() }
        )
        defaults.set("https://example.invalid/api/v1", forKey: MeteringProductionComposition.baseURLKey)
        defaults.set(owner.uuidString, forKey: MeteringProductionComposition.ownerKey)
        earnedStore.saveLockedSetID(enforcementSetID.uuidString, tokenData: nil)
        earnedStore.saveLockedSetAllSelected(true)
        earnedStore.usageCountingAllowed = suppression != .paused
        if suppression == .override {
            earnedStore.setOverride(true, forUsageDate: usageDate)
        }
        try store.transaction(expectedOwner: owner) { state in
            state = activeState(paused: suppression == .paused)
        }
    }

    func handle(observedAt: Date) throws -> EarnedMeteringCallbackOutcome {
        try entry.handle(
            activityName: activityName,
            eventName: eventName,
            observedAt: observedAt,
            projectShields: { [weak self] _ in self?.projectionCount += 1 }
        )
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
            throw T3FixtureError.missingData
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func activeState(paused: Bool) -> DeviceEpochStoreState {
        let digest = MeteringEpochContract.selectionDigest(persistedBytes: Data([1]))
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "t3-r1",
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
            status: paused ? .paused : .active,
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

private struct T3Clock: MeteringClock {
    let now: Date
}

private enum T3FixtureError: Error {
    case missingData
}
