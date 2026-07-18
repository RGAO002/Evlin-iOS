import FamilyControls
import Foundation
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringT4DemolitionTests: XCTestCase {
    func testBackendHeadroomVetoSymbolsAreAbsentFromProduction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionRoots = [
            "Evlin iOS",
            "EvlinDeviceActivityMonitor",
            "EvlinPushApplier",
        ]
        let forbidden = [
            ["backend", "Vetoes", "Self", "Lock"].joined(),
            ["freshness", "Seconds"].joined(),
            ["margin", "Minutes"].joined(),
        ]

        for relativeRoot in productionRoots {
            let directory = root.appendingPathComponent(relativeRoot)
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            )
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                for token in forbidden {
                    XCTAssertFalse(
                        source.contains(token),
                        "forbidden headroom veto symbol \(token) remains in \(fileURL.path)"
                    )
                }
            }
        }
    }

    func testFreshBackendHeadroomCannotVetoTrustedTerminalAndCorrectionReleasesExactSource() throws {
        let fixture = try T4Fixture()
        defer { fixture.cleanUp() }
        fixture.seedFreshBackendHeadroom()
        try fixture.seedShield(sources: [.manual, .taskPause], displayName: "parent state")

        guard case .queued = try fixture.handleTerminal() else {
            return XCTFail("trusted terminal callback must queue")
        }

        XCTAssertEqual(
            try fixture.currentShield()?.sources,
            [.manual, .taskPause, .earnedTime]
        )
        XCTAssertNotNil(try fixture.store.read().shieldReferences[fixture.routeID])

        try fixture.authorizeCorrectionRelease()
        XCTAssertTrue(try fixture.effectStore.recover(expectedOwner: fixture.owner))

        XCTAssertEqual(try fixture.currentShield()?.sources, [.manual, .taskPause])
        XCTAssertEqual(try fixture.currentEnvelope()?.phase, .released)
    }

    func testCorrectionCASConflictPreservesNewerManualTaskPauseBytes() throws {
        let fixture = try T4Fixture()
        defer { fixture.cleanUp() }
        fixture.seedFreshBackendHeadroom()
        try fixture.seedShield(sources: [.manual, .taskPause], displayName: "parent state")
        guard case .queued = try fixture.handleTerminal() else {
            return XCTFail("trusted terminal callback must queue")
        }
        var newer = try XCTUnwrap(try fixture.currentShield())
        newer.displayName = "newer parent mutation"
        newer.lastCommandID = UUID()
        try fixture.persistShield(newer)
        try fixture.authorizeCorrectionRelease()

        XCTAssertThrowsError(
            try fixture.effectStore.recover(expectedOwner: fixture.owner)
        ) { error in
            XCTAssertEqual(error as? EarnedShieldEffectError, .casConflict(fixture.routeID))
        }

        XCTAssertEqual(try fixture.currentShield(), newer)
        XCTAssertEqual(try fixture.currentEnvelope()?.phase, .conflicted)
    }
}

private final class T4Fixture {
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

    private var activityName: String {
        MeteringRouteNamespace.activityName(routeID: routeID)
    }

    private var eventName: String {
        MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 5)
    }

    private var recordKey: String {
        ShieldRecord.makeRecordKey(
            tier: .savedList,
            targetKey: enforcementSetID.uuidString
        )
    }

    init() throws {
        suiteName = "MeteringT4DemolitionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-t4-\(UUID().uuidString).json")
        store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { [owner] in owner })
        earnedStore = EarnedTimeStore(suiteName: suiteName)
        effectStore = EarnedShieldEffectStore(defaults: defaults, epochStore: store)
        entry = DAMMeteringEntry(
            defaults: defaults,
            store: store,
            clock: T4Clock(now: startedAt.addingTimeInterval(300)),
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

    func seedFreshBackendHeadroom() {
        _ = earnedStore.reconcileRuntimePolicy(
            usageDate: usageDate,
            timezoneIdentifier: "America/New_York",
            poolMinutes: 120,
            capMinutes: 120,
            remainingMinutes: 40,
            estimatedMinutes: 0,
            policyRevision: "t4-r1",
            syncedAt: startedAt.addingTimeInterval(240)
        )
    }

    func seedShield(sources: Set<ShieldSource>, displayName: String) throws {
        try persistShield(ShieldRecord(
            recordKey: recordKey,
            tier: .savedList,
            targetKey: enforcementSetID.uuidString,
            displayName: displayName,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: startedAt,
            expiresAt: nil,
            originalRequest: "parent lock",
            targetChildID: owner,
            sources: sources
        ))
    }

    func handleTerminal() throws -> EarnedMeteringCallbackOutcome {
        try entry.handle(
            activityName: activityName,
            eventName: eventName,
            observedAt: startedAt.addingTimeInterval(300),
            projectShields: { _ in }
        )
    }

    func authorizeCorrectionRelease() throws {
        try store.transaction(expectedOwner: owner) { state in
            state.epochs[epochID]?.status = .retired
            state.epochs[epochID]?.retiredAt = startedAt.addingTimeInterval(301)
            state.epochs[epochID]?.retireReason = .authoritativeBaseMismatch
        }
    }

    func currentEnvelope() throws -> EarnedShieldEffectEnvelope? {
        try decode([UUID: EarnedShieldEffectEnvelope].self, key: EarnedShieldEffectStore.envelopeKey)[routeID]
    }

    func currentShield() throws -> ShieldRecord? {
        try decode([String: ShieldRecord].self, key: EarnedShieldEffectStore.shieldsKey)[recordKey]
    }

    func persistShield(_ record: ShieldRecord) throws {
        var shields = (try? decode(
            [String: ShieldRecord].self,
            key: EarnedShieldEffectStore.shieldsKey
        )) ?? [:]
        shields[record.recordKey] = record
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(shields), forKey: EarnedShieldEffectStore.shieldsKey)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        defaults.synchronize()
        guard let data = defaults.data(forKey: key) else {
            if type == [UUID: EarnedShieldEffectEnvelope].self { return [:] as! T }
            if type == [String: ShieldRecord].self { return [:] as! T }
            throw T4FixtureError.missingData
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
            policyRevision: "t4-r1",
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

private struct T4Clock: MeteringClock {
    let now: Date
}

private enum T4FixtureError: Error {
    case missingData
}
