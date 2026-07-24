import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringPolicyOwnerReadbackTests: XCTestCase {
    private let owner = UUID(uuidString: "75000000-0000-0000-0000-000000000008")!
    private let enforcement = UUID(uuidString: "76000000-0000-0000-0000-000000000008")!
    private let now = Date(timeIntervalSince1970: 1_753_027_200)

    func testOwnerReadbackRequiresExactActiveGenerationEpochRouteCoverageAndBudget() {
        let fixture = activeFixture()
        XCTAssertTrue(MeteringProductionComposition.desiredPolicyMatchesActiveReadback(
            fixture.policy,
            state: fixture.state
        ))

        let wrong = MeteringDesiredPolicy(
            commandID: fixture.policy.commandID,
            ownerChildDeviceID: fixture.policy.ownerChildDeviceID,
            orderingToken: fixture.policy.orderingToken,
            policyRevision: fixture.policy.policyRevision,
            usageDate: fixture.policy.usageDate,
            canonicalTimezone: fixture.policy.canonicalTimezone,
            dailyPoolMinutes: 121,
            deviceCapMinutes: fixture.policy.deviceCapMinutes,
            remainingMinutes: fixture.policy.remainingMinutes,
            enforcementSetID: fixture.policy.enforcementSetID,
            receivedAt: fixture.policy.receivedAt,
            appliedAt: nil,
            ackedAt: nil
        )
        XCTAssertFalse(MeteringProductionComposition.desiredPolicyMatchesActiveReadback(
            wrong,
            state: fixture.state
        ))
    }

    func testOwnerReadbackPostsTruthfulVerifiedPolicyIdentity() async throws {
        let transport = PolicyReadbackTransport(status: 200)
        let policy = activeFixture().policy
        try await MeteringPolicyOwnerReadbackClient(
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            transport: transport
        ).confirm(policy)

        let captured = await transport.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.path, "/api/v1/child/ack")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["status"] as? String, "confirmed")
        let detail = try XCTUnwrap(object["detail"] as? [String: Any])
        XCTAssertEqual(detail["source"] as? String, "device_epoch_owner_readback")
        XCTAssertEqual(detail["ordering_token"] as? Int64, policy.orderingToken)
        XCTAssertEqual(detail["policy_revision"] as? String, policy.policyRevision)
    }

    func testFailedReadbackIsRetryableAndNeverLooksSuccessful() async {
        let transport = PolicyReadbackTransport(status: 503)
        do {
            try await MeteringPolicyOwnerReadbackClient(
                baseURL: URL(string: "https://example.invalid/api/v1")!,
                transport: transport
            ).confirm(activeFixture().policy)
            XCTFail("expected readback failure")
        } catch {
            XCTAssertEqual(error as? MeteringPolicyOwnerReadbackError, .unexpectedHTTPStatus(503))
        }
    }

    func testCrashAfterActivationKeepsAppliedProofAndRetriesOnlyReadback() async throws {
        let fixture = activeFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("policy-owner-readback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("epoch.json")
        let owner = self.owner
        let store = DeviceEpochStore(
            fileURL: fileURL,
            lock: PolicyReadbackLock(),
            ownerProvider: { owner },
            legacyDefaults: nil
        )
        try store.transaction(expectedOwner: owner) { $0 = fixture.state }
        let transport = PolicyReadbackTransport(statuses: [503, 200])

        do {
            try await MeteringProductionComposition.finalizeDesiredPolicyIfApplied(
                owner: owner,
                baseURL: URL(string: "https://example.invalid/api/v1")!,
                store: store,
                transport: transport,
                now: now.addingTimeInterval(10)
            )
            XCTFail("expected first readback to fail")
        } catch {
            XCTAssertEqual(error as? MeteringPolicyOwnerReadbackError, .unexpectedHTTPStatus(503))
        }
        let afterFailure = try XCTUnwrap(store.read().desiredPolicy)
        XCTAssertEqual(afterFailure.appliedAt, now.addingTimeInterval(10))
        XCTAssertNil(afterFailure.ackedAt)

        try await MeteringProductionComposition.finalizeDesiredPolicyIfApplied(
            owner: owner,
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            store: store,
            transport: transport,
            now: now.addingTimeInterval(20)
        )
        let recovered = try XCTUnwrap(store.read().desiredPolicy)
        XCTAssertEqual(recovered.appliedAt, now.addingTimeInterval(10))
        XCTAssertEqual(recovered.ackedAt, now.addingTimeInterval(20))
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testMissingAppGroupSelectionRecoversFromCurrentOwnersActiveGeneration() throws {
        let fixture = activeFixture()
        let suiteName = "metering-policy-selection-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recovered = try XCTUnwrap(
            MeteringProductionComposition.recoverablePolicyInputs(
                owner: owner,
                desired: fixture.policy,
                state: fixture.state,
                defaults: defaults,
                selectionIsValid: { _ in true }
            )
        )

        XCTAssertEqual(
            recovered.selectionBytes,
            fixture.state.generations[fixture.state.activeGenerationID!]?.measurementSelectionBytes
        )
        XCTAssertEqual(recovered.enforcementSetID, enforcement)
        XCTAssertEqual(
            defaults.data(forKey: MeteringProductionComposition.selectionKey),
            recovered.selectionBytes
        )
        XCTAssertEqual(
            defaults.string(forKey: MeteringProductionComposition.lockedSetIDKey),
            enforcement.uuidString
        )
    }

    func testMissingAppGroupSelectionNeverRecoversFromAnotherOwner() throws {
        let fixture = activeFixture()
        let suiteName = "metering-policy-selection-wrong-owner-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(MeteringProductionComposition.recoverablePolicyInputs(
            owner: UUID(),
            desired: fixture.policy,
            state: fixture.state,
            defaults: defaults,
            selectionIsValid: { _ in true }
        ))
        XCTAssertNil(defaults.data(forKey: MeteringProductionComposition.selectionKey))
        XCTAssertNil(defaults.string(forKey: MeteringProductionComposition.lockedSetIDKey))
    }

    func testAcknowledgedDesiredPolicyStillRepairsMissingAppGroupInputs() throws {
        var fixture = activeFixture()
        fixture.state.desiredPolicy?.ackedAt = Date(timeIntervalSince1970: 1_000)
        let suiteName = "metering-policy-selection-acked-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MeteringProductionComposition.repairPersistedPolicyInputsIfPossible(
            owner: owner,
            state: fixture.state,
            defaults: defaults,
            selectionIsValid: { _ in true }
        ))
        XCTAssertEqual(
            defaults.data(forKey: MeteringProductionComposition.selectionKey),
            fixture.state.generations[fixture.state.activeGenerationID!]?.measurementSelectionBytes
        )
        XCTAssertEqual(
            defaults.string(forKey: MeteringProductionComposition.lockedSetIDKey),
            enforcement.uuidString
        )
    }

    private func activeFixture() -> (policy: MeteringDesiredPolicy, state: DeviceEpochStoreState) {
        let generationID = UUID()
        let epochID = UUID()
        let routeID = UUID()
        let selection = Data([1, 2, 3])
        let key = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-8",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: selection),
            enforcementSetID: enforcement
        )
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: key.canonicalTimezone,
            policyRevision: key.policyRevision,
            measurementSelectionDigest: key.measurementSelectionDigest,
            enforcementSetID: enforcement,
            measurementSelectionBytes: selection,
            createdAt: now,
            retiredAt: nil,
            configuredPoolMinutes: 120,
            configuredDeviceCapMinutes: 60
        )
        let epoch = DeviceDailyEpoch(
            epochID: epochID,
            protocolVersion: 2,
            childDeviceID: owner,
            usageDate: "2026-07-20",
            canonicalTimezone: key.canonicalTimezone,
            policyRevision: key.policyRevision,
            measurementSelectionDigest: key.measurementSelectionDigest,
            enforcementSetID: enforcement,
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
        )
        let schedule = DatedSchedulePlan(
            usageDate: epoch.usageDate,
            timezoneIdentifier: key.canonicalTimezone,
            calendarIdentifier: "gregorian"
        )
        let events = MeteringDatedSchedule.thresholds(poolMinutes: 120, capMinutes: 60).map {
            MeteringEventPlan(
                eventName: MeteringRouteNamespace.eventName(
                    routeID: routeID,
                    thresholdMinutes: $0
                ),
                thresholdMinutes: $0
            )
        }
        let route = MeteringCallbackRoute(
            routeID: routeID,
            activityName: MeteringRouteNamespace.activityName(routeID: routeID),
            namespace: MeteringRouteNamespace.prefix,
            generationID: generationID,
            generationKey: key,
            ownerChildDeviceID: owner,
            usageDate: epoch.usageDate,
            epochID: epochID,
            plannedSchedule: schedule,
            installedSchedule: schedule,
            plannedEvents: events,
            installedEvents: events,
            lifecycle: .active,
            createdAt: now
        )
        let policy = MeteringDesiredPolicy(
            commandID: UUID(),
            ownerChildDeviceID: owner,
            orderingToken: 8,
            policyRevision: key.policyRevision,
            usageDate: epoch.usageDate,
            canonicalTimezone: key.canonicalTimezone,
            dailyPoolMinutes: 120,
            deviceCapMinutes: 60,
            remainingMinutes: 60,
            enforcementSetID: enforcement,
            receivedAt: now,
            appliedAt: nil,
            ackedAt: nil
        )
        let state = DeviceEpochStoreState(
            ownerChildDeviceID: owner,
            generations: [generationID: generation],
            activeGenerationID: generationID,
            epochs: [epochID: epoch],
            activeEpochID: epochID,
            routes: [routeID: route],
            activeRouteID: routeID,
            coverage: MonitorCoverageState(
                ownerChildDeviceID: owner,
                requiredFromUsageDate: epoch.usageDate,
                requiredThroughUsageDate: "2026-07-27",
                readyThroughUsageDate: "2026-07-27",
                status: .ready,
                refreshedAt: now,
                errorCode: nil
            ),
            desiredPolicy: policy
        )
        return (policy, state)
    }
}

private actor PolicyReadbackTransport: MeteringHTTPTransport {
    private var statuses: [Int]
    private var request: URLRequest?
    private var requests = 0

    init(status: Int) { self.statuses = [status] }
    init(statuses: [Int]) { self.statuses = statuses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        requests += 1
        let status = statuses.isEmpty ? 500 : statuses.removeFirst()
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func lastRequest() -> URLRequest? { request }
    func requestCount() -> Int { requests }
}

private final class PolicyReadbackLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()
    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
