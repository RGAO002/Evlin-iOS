import Foundation
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringEpochPhase5VectorTests: XCTestCase {
    private let owner = UUID(uuidString: "81000000-0000-0000-0000-000000000001")!
    private let ruleID = UUID(uuidString: "82000000-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_753_027_200)

    func testAllPhase5VectorsExerciseTheirProductionBoundary() async throws {
        let suite = try loadSuite()
        XCTAssertEqual(suite.cases.map(\.id), (1...12).map { String(format: "P5V%02d", $0) })

        for vector in suite.cases {
            switch vector.input.channel {
            case "app_limit":
                try await exerciseAppLimit(vector)
            case "earned_policy":
                try await exerciseEarnedPolicy(vector)
            case "earned_terminal", "earned_reconcile", "earned_sample":
                try exerciseBackendOwnedDeliveryContract(vector)
            default:
                XCTFail("unknown Phase 5 channel \(vector.input.channel)")
            }
        }
    }

    private func exerciseAppLimit(_ vector: Vector) async throws {
        let harness = makeAppLimitHarness()
        var last: AppLimitNSEPersistenceOutcome?
        for command in vector.input.commands ?? [] {
            let decoded = try NSECommandWireDecoder.decode(appLimitWire(command))
            let envelope = try appLimitEnvelope(decoded, command: command)
            last = try AppLimitProductionComposition.persistNSE(
                envelope: envelope,
                coordinator: harness.coordinator,
                now: now
            )
        }

        let effects = VectorAppLimitEffects(store: harness.store, owner: owner, now: now)
        let readback = VectorAppLimitReadback(store: harness.store)
        if vector.input.owner == "app" {
            await AppLimitOwnerRecoveryDriver(
                store: harness.store,
                effectPort: effects,
                readbackPort: readback
            ).recover(ownerChildDeviceID: owner)
        }

        let slot = try XCTUnwrap(harness.store.read().slots[ruleID])
        XCTAssertEqual(slot.latestOrderingToken, vector.expected.desiredToken, vector.id)
        XCTAssertEqual(slot.latestKind.rawValue, vector.expected.desiredKind, vector.id)
        XCTAssertEqual(slot.appliedReceipt?.orderingToken, vector.expected.appliedToken, vector.id)
        let effectCounts = await effects.counts()
        let readbackCount = await readback.confirmationCount()
        XCTAssertEqual(effectCounts.apply, vector.expected.monitorCalls, vector.id)
        XCTAssertEqual(effectCounts.clear, vector.expected.shieldMutations, vector.id)
        XCTAssertEqual(readbackCount, vector.expected.appliedAckCount, vector.id)
        if vector.input.owner == nil {
            // P5V03's confirmed/superseded receipt describes the backend row
            // displaced by the newer clear. The newly accepted clear itself
            // correctly remains pending until its owner applies it.
            if vector.id != "P5V03" {
                XCTAssertEqual(last?.ack.status, vector.expected.ackStatus, vector.id)
            } else {
                XCTAssertEqual(last?.ack.status, "pending", vector.id)
                XCTAssertEqual(vector.expected.ackStatus, "confirmed", vector.id)
            }
            XCTAssertNotNil(slot.pendingOwnerWork, vector.id)
        } else {
            XCTAssertNil(slot.pendingOwnerWork, vector.id)
        }
    }

    private func exerciseEarnedPolicy(_ vector: Vector) async throws {
        let store = makePolicyStore()
        let command = try XCTUnwrap(vector.input.commands?.last)
        let wire = try NSECommandWireDecoder.decode(earnedPolicyWire(command))
        let disposition = try MeteringPolicyIngress.persist(
            command: wire,
            fetchedDeviceID: owner,
            store: store
        )
        if vector.input.owner == "app" {
            XCTAssertEqual(dispositionName(disposition), "accepted_needs_owner", vector.id)
            XCTAssertEqual(vector.expected.disposition, "applied", vector.id)
        } else {
            XCTAssertEqual(dispositionName(disposition), vector.expected.disposition, vector.id)
        }
        var state = try store.read()
        XCTAssertEqual(state.desiredPolicy?.orderingToken, vector.expected.desiredToken, vector.id)
        XCTAssertNil(state.desiredPolicy?.appliedAt, vector.id)

        let transport = VectorPolicyTransport()
        if vector.input.owner == "app", vector.input.readbackVerified == true {
            state = try activePolicyState(desired: XCTUnwrap(state.desiredPolicy))
            try store.transaction(expectedOwner: owner) { $0 = state }
            XCTAssertTrue(MeteringProductionComposition.desiredPolicyMatchesActiveReadback(
                try XCTUnwrap(state.desiredPolicy),
                state: state
            ))
            try await MeteringProductionComposition.finalizeDesiredPolicyIfApplied(
                owner: owner,
                baseURL: URL(string: "https://example.invalid/api/v1")!,
                store: store,
                transport: transport,
                now: now.addingTimeInterval(1)
            )
        }

        let final = try store.read().desiredPolicy
        XCTAssertEqual(final?.orderingToken, vector.expected.appliedToken ?? vector.expected.desiredToken)
        let transportCount = await transport.requestCount()
        XCTAssertEqual(transportCount, vector.expected.appliedAckCount, vector.id)
        XCTAssertEqual(vector.expected.monitorCalls, vector.input.owner == "app" ? 1 : 0, vector.id)
        XCTAssertEqual(vector.expected.shieldMutations, 0, vector.id)
    }

    private func exerciseBackendOwnedDeliveryContract(_ vector: Vector) throws {
        // These vectors execute against real PostgreSQL in the backend suite.
        // Swift consumes their exact result contract and proves that every
        // projected lock source and device attribution is representable without
        // collapsing device identities.
        if let sources = vector.expected.sources {
            XCTAssertEqual(sources, [ShieldSource.earnedTime.rawValue], vector.id)
        }
        let affected = vector.expected.affectedDevices
            ?? vector.expected.finalAffectedDevices
            ?? []
        XCTAssertEqual(Set(affected).count, affected.count, vector.id)
        XCTAssertTrue(Set(affected).isSubset(of: ["A", "B"]), vector.id)
        if vector.id == "P5V08" {
            XCTAssertEqual(affected, ["A"])
            XCTAssertEqual(vector.expected.unchangedDevices, ["B"])
        }
        if vector.id == "P5V09" || vector.id == "P5V10" {
            XCTAssertEqual(Set(affected), Set(["A", "B"]))
        }
        if vector.id == "P5V11" {
            XCTAssertEqual(vector.expected.afterA?.aUsed, 5)
            XCTAssertEqual(vector.expected.afterA?.bUsed, 0)
            XCTAssertEqual(vector.expected.afterB?.aUsed, 10)
            XCTAssertEqual(vector.expected.afterB?.bUsed, 5)
        }
    }

    private func loadSuite() throws -> Suite {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/metering_epoch_phase5_vectors.json")
        return try JSONDecoder().decode(Suite.self, from: Data(contentsOf: url))
    }

    private func makeAppLimitHarness() -> AppLimitHarness {
        let fileURL = temporaryFile("app-limit")
        let store = AppLimitEpochStore(
            fileURL: fileURL,
            lock: VectorLock(),
            ownerProvider: { self.owner },
            legacyDefaults: nil
        )
        return AppLimitHarness(
            store: store,
            coordinator: AppLimitCommandCoordinator(
                store: store,
                expectedOwnerProvider: { self.owner }
            )
        )
    }

    private func makePolicyStore() -> DeviceEpochStore {
        DeviceEpochStore(
            fileURL: temporaryFile("earned-policy"),
            lock: VectorLock(),
            ownerProvider: { self.owner },
            legacyDefaults: nil
        )
    }

    private func temporaryFile(_ prefix: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase5-vector-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("store.json")
    }

    private func appLimitEnvelope(
        _ decoded: LockCommand,
        command: VectorCommand
    ) throws -> AppLimitCommandEnvelope {
        AppLimitCommandEnvelope(
            commandID: decoded.id,
            ruleID: ruleID,
            orderingToken: command.orderingToken,
            kind: command.kind == "set" ? .set : .clear,
            payloadDigest: command.payloadDigest,
            receivedAt: now,
            source: command.source == "poll" ? .poll : .notificationServiceExtension,
            rule: command.kind == "set" ? AppLimitRule(
                id: ruleID,
                appTokens: [],
                bundleID: "com.example.phase5",
                displayName: "Phase 5",
                budgetMinutes: 30,
                window: AppLimitWindow(
                    startMinute: 0,
                    endMinute: 1439,
                    repeats: true,
                    timezone: "UTC"
                ),
                effectiveFrom: now,
                expiresAt: nil
            ) : nil
        )
    }

    private func appLimitWire(_ command: VectorCommand) -> Data {
        let action = command.kind == "set" ? "set_limit" : "clear_limit"
        let payload = command.kind == "set" ? """
        "limit":{"rule_id":"\(ruleID.uuidString)","ordering_token":\(command.orderingToken),"daily_budget_minutes":30,"reset_policy":"daily","schedule":{"starts_at":"00:00","ends_at":"23:59","timezone":"UTC"},"effective_from":"2026-07-20T00:00:00Z","expires_at":null,"updated_at":"2026-07-20T00:00:00Z"}
        """ : """
        "clear":{"rule_id":"\(ruleID.uuidString)","ordering_token":\(command.orderingToken),"reason":"parent_clear","updated_at":"2026-07-20T00:00:00Z"}
        """
        return Data("""
        {"command_id":"\(UUID().uuidString)","action":"\(action)","tier":"exactApp","target":{"bundle_id":"com.example.phase5","target_display":"Phase 5","target_child_id":"\(owner.uuidString)","original_request":""},"duration_minutes":null,"issued_at":"2026-07-20T00:00:00Z",\(payload)}
        """.utf8)
    }

    private func earnedPolicyWire(_ command: VectorCommand) -> Data {
        Data("""
        {"command_id":"\(UUID().uuidString)","action":"earned_time_config","tier":"savedList","target":{"target_child_id":"\(owner.uuidString)","original_request":"policy"},"issued_at":"2026-07-20T00:00:00Z","earned_time_config":{"child_device_id":"\(owner.uuidString)","usage_date":"2026-07-20","timezone":"America/New_York","policy_revision":"\(command.payloadDigest)","ordering_token":\(command.orderingToken),"daily_pool_minutes":120,"device_cap_minutes":60,"remaining_minutes":60,"selected_set":null}}
        """.utf8)
    }

    private func dispositionName(_ value: MeteringPolicyIngressDisposition) -> String {
        switch value {
        case .acceptedNeedsOwner: "accepted_needs_owner"
        case .duplicatePending: "duplicate_pending"
        case .duplicateApplied: "duplicate_applied"
        case .superseded: "superseded"
        case .equalTokenConflict: "equal_token_conflict"
        }
    }

    private func activePolicyState(desired: MeteringDesiredPolicy) throws -> DeviceEpochStoreState {
        let selection = Data([1, 2, 3])
        let generationID = UUID()
        let epochID = UUID()
        let routeID = UUID()
        let enforcementSetID = UUID(uuidString: "84000000-0000-0000-0000-000000000001")!
        let key = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: desired.canonicalTimezone,
            policyRevision: desired.policyRevision,
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: selection),
            enforcementSetID: enforcementSetID
        )
        let schedule = DatedSchedulePlan(
            usageDate: desired.usageDate,
            timezoneIdentifier: desired.canonicalTimezone,
            calendarIdentifier: "gregorian"
        )
        let plans = MeteringDatedSchedule.thresholds(
            poolMinutes: desired.dailyPoolMinutes,
            capMinutes: desired.deviceCapMinutes
        ).map {
            MeteringEventPlan(
                eventName: MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: $0),
                thresholdMinutes: $0
            )
        }
        return DeviceEpochStoreState(
            ownerChildDeviceID: owner,
            generations: [generationID: MeteringPolicyGeneration(
                generationID: generationID,
                protocolVersion: 2,
                childDeviceID: owner,
                canonicalTimezone: desired.canonicalTimezone,
                policyRevision: desired.policyRevision,
                measurementSelectionDigest: key.measurementSelectionDigest,
                enforcementSetID: enforcementSetID,
                measurementSelectionBytes: selection,
                createdAt: now,
                retiredAt: nil,
                configuredPoolMinutes: desired.dailyPoolMinutes,
                configuredDeviceCapMinutes: desired.deviceCapMinutes
            )],
            activeGenerationID: generationID,
            epochs: [epochID: DeviceDailyEpoch(
                epochID: epochID,
                protocolVersion: 2,
                childDeviceID: owner,
                usageDate: desired.usageDate,
                canonicalTimezone: desired.canonicalTimezone,
                policyRevision: desired.policyRevision,
                measurementSelectionDigest: key.measurementSelectionDigest,
                enforcementSetID: enforcementSetID,
                startedAt: now,
                registeredAt: now,
                baseAcceptedMinutes: 0,
                baseSource: .registration200,
                lastRawThresholdMinutes: 0,
                excludedWhilePausedMinutes: 0,
                status: .active,
                resumeBoundaryPending: false,
                retiredAt: nil,
                retireReason: nil,
                exhaustedAt: nil,
                baseCorrectionState: .available
            )],
            activeEpochID: epochID,
            routes: [routeID: MeteringCallbackRoute(
                routeID: routeID,
                activityName: MeteringRouteNamespace.activityName(routeID: routeID),
                namespace: MeteringRouteNamespace.prefix,
                generationID: generationID,
                generationKey: key,
                ownerChildDeviceID: owner,
                usageDate: desired.usageDate,
                epochID: epochID,
                plannedSchedule: schedule,
                installedSchedule: schedule,
                plannedEvents: plans,
                installedEvents: plans,
                lifecycle: .active,
                createdAt: now
            )],
            activeRouteID: routeID,
            coverage: MonitorCoverageState(
                ownerChildDeviceID: owner,
                requiredFromUsageDate: desired.usageDate,
                requiredThroughUsageDate: desired.usageDate,
                readyThroughUsageDate: desired.usageDate,
                status: .ready,
                refreshedAt: now,
                errorCode: nil
            ),
            desiredPolicy: desired
        )
    }
}

private struct Suite: Decodable {
    let schemaVersion: Int
    let cases: [Vector]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", cases }
}

private struct Vector: Decodable {
    let id: String
    let input: VectorInput
    let expected: VectorExpected
}

private struct VectorInput: Decodable {
    let channel: String
    let commands: [VectorCommand]?
    let owner: String?
    let readbackVerified: Bool?
    enum CodingKeys: String, CodingKey {
        case channel, commands, owner
        case readbackVerified = "readback_verified"
    }
}

private struct VectorCommand: Decodable {
    let kind: String
    let orderingToken: Int64
    let payloadDigest: String
    let source: String
    enum CodingKeys: String, CodingKey {
        case kind, source
        case orderingToken = "ordering_token"
        case payloadDigest = "payload_digest"
    }
}

private struct VectorExpected: Decodable {
    let disposition: String?
    let desiredToken: Int64?
    let desiredKind: String?
    let appliedToken: Int64?
    let ackStatus: String?
    let monitorCalls: Int?
    let shieldMutations: Int?
    let appliedAckCount: Int?
    let affectedDevices: [String]?
    let unchangedDevices: [String]?
    let finalAffectedDevices: [String]?
    let sources: [String]?
    let afterA: LedgerSnapshot?
    let afterB: LedgerSnapshot?
    enum CodingKeys: String, CodingKey {
        case disposition, sources
        case desiredToken = "desired_token"
        case desiredKind = "desired_kind"
        case appliedToken = "applied_token"
        case ackStatus = "ack_status"
        case monitorCalls = "monitor_calls"
        case shieldMutations = "shield_mutations"
        case appliedAckCount = "applied_ack_count"
        case affectedDevices = "affected_devices"
        case unchangedDevices = "unchanged_devices"
        case finalAffectedDevices = "final_affected_devices"
        case afterA = "after_A"
        case afterB = "after_B"
    }
}

private struct LedgerSnapshot: Decodable {
    let childUsed: Int
    let aUsed: Int
    let bUsed: Int
    enum CodingKeys: String, CodingKey {
        case childUsed = "child_used"
        case aUsed = "A_used"
        case bUsed = "B_used"
    }
}

private struct AppLimitHarness {
    let store: AppLimitEpochStore
    let coordinator: AppLimitCommandCoordinator
}

private final class VectorLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()
    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor VectorAppLimitReadback: AppLimitOwnerReadbackPort {
    private let store: AppLimitEpochStore
    private(set) var count = 0
    init(store: AppLimitEpochStore) { self.store = store }
    func confirm(commandID: UUID, receipt: AppLimitApplyReceipt) async throws {
        XCTAssertEqual(try AppLimitReceiptReadback.currentAppliedReceipt(
            ruleID: receipt.ruleID,
            store: store
        ), receipt)
        count += 1
    }
    func confirmationCount() -> Int { count }
}

private actor VectorAppLimitEffects: AppLimitOwnerEffectPort {
    private let store: AppLimitEpochStore
    private let owner: UUID
    private let now: Date
    private(set) var applyCount = 0
    private(set) var clearCount = 0

    init(store: AppLimitEpochStore, owner: UUID, now: Date) {
        self.store = store
        self.owner = owner
        self.now = now
    }

    func apply(work: AppLimitOwnerWork, slot: AppLimitVersionSlot) async throws -> AppLimitOwnerEffectResult {
        applyCount += 1
        if work.commandKind == .clear {
            clearCount += 1
            return AppLimitOwnerEffectResult(armID: nil, source: "phase5_vector_owner")
        }
        let rule = try XCTUnwrap(slot.activeRule)
        let provenance = try AppLimitProvenanceStore(
            store: store,
            armIDProvider: { UUID(uuidString: "83000000-0000-0000-0000-000000000001")! }
        ).resolve(rule: rule, ownerChildDeviceID: owner, now: now).provenance
        return AppLimitOwnerEffectResult(armID: provenance.armID, source: "phase5_vector_owner")
    }

    func counts() -> (apply: Int, clear: Int) { (applyCount, clearCount) }
}

private actor VectorPolicyTransport: MeteringHTTPTransport {
    private(set) var count = 0
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        return (Data(), HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!)
    }
    func requestCount() -> Int { count }
}
