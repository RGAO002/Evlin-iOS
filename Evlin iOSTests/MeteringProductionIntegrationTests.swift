import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringProductionIntegrationTests: XCTestCase {
    func testAppRecoveryFactoryLinks() async throws {
        let fixture = try makeFixture(seedPendingStart: true)
        let driver = MeteringProductionComposition.makeRecoveryDriverForTesting(
            baseURL: fixture.baseURL,
            role: .app,
            instanceID: UUID(),
            store: fixture.store,
            center: fixture.center,
            transport: ProductionLinkTransport(),
            clock: ProductionLinkClock(),
            releaseIdentityShield: { _, _ in }
        )
        try await driver.recover(ownerChildDeviceID: fixture.owner)
        XCTAssertEqual(fixture.center.startCalls.count, 1)
    }

    func testMonitorRecoveryFactoryDefersFreshCurrentDayStartToApp() async throws {
        let fixture = try makeFixture(seedPendingStart: true)
        let driver = MeteringProductionComposition.makeRecoveryDriverForTesting(
            baseURL: fixture.baseURL,
            role: .deviceActivityMonitor,
            instanceID: UUID(),
            store: fixture.store,
            center: fixture.center,
            transport: ProductionLinkTransport(),
            clock: ProductionLinkClock(),
            releaseIdentityShield: { _, _ in }
        )
        try await driver.recover(ownerChildDeviceID: fixture.owner)
        XCTAssertTrue(fixture.center.startCalls.isEmpty)

        let appDriver = MeteringProductionComposition.makeRecoveryDriverForTesting(
            baseURL: fixture.baseURL,
            role: .app,
            instanceID: UUID(),
            store: fixture.store,
            center: fixture.center,
            transport: ProductionLinkTransport(),
            clock: ProductionLinkClock(),
            releaseIdentityShield: { _, _ in }
        )
        try await appDriver.recover(ownerChildDeviceID: fixture.owner)
        XCTAssertEqual(fixture.center.startCalls.count, 1)
    }

    func testCallbackFactoryLinks() throws {
        let fixture = try makeFixture(seedPendingStart: false)
        let callback = MeteringProductionComposition.makeCallback(store: fixture.store)
        withExtendedLifetime(callback) {}
    }

    func testProductionRolloverResetAdvancesAcceptedUsageDateWithoutDaemonMutation() throws {
        let owner = UUID()
        let suiteName = "metering-rollover-reset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            owner.uuidString.lowercased(),
            forKey: MeteringProductionComposition.ownerKey
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let earnedStore = EarnedTimeStore(suiteName: suiteName)
        XCTAssertEqual(
            earnedStore.reconcileAcceptedUsage(
                usageDate: "2026-09-13",
                serverEstimatedMinutes: 37
            ),
            37
        )
        let resetter = MeteringRolloverEffectResetter(earnedStore: earnedStore)
        let work = RolloverEffectsWork(
            workID: UUID(),
            ownerChildDeviceID: owner,
            fromUsageDate: "2026-09-13",
            toUsageDate: "2026-09-14",
            oldEpochID: UUID(),
            newEpochID: UUID(),
            oldRouteID: UUID(),
            newRouteID: UUID(),
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: Date(),
                lastErrorCode: nil,
                terminal: .pending
            ),
            earnedSourceResetAcknowledged: false,
            perAppResetAcknowledged: false,
            taskStateResetAcknowledged: false,
            bypassExpiryAcknowledged: false,
            registrationAcknowledged: false,
            installAcknowledged: false,
            activationAcknowledged: false,
            oldStopAcknowledged: false,
            createdAt: Date()
        )

        for effect in MeteringRolloverLocalEffect.allCases {
            try resetter.apply(effect, work: work)
        }

        XCTAssertEqual(earnedStore.acceptedUsageDate, "2026-09-14")
        XCTAssertEqual(earnedStore.acceptedEstimateMinutes, 0)
        XCTAssertEqual(earnedStore.latestDeviceEstimate, 0)
    }

    func testSameOwnerCleanupFinishesBeforeCurrentPolicyIsPlanned() async throws {
        let owner = UUID()
        let baseURL = URL(string: "https://example.invalid/api/v1")!
        let now = Date(timeIntervalSince1970: 1_785_657_600)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-same-owner-repair-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: MeteringProductionComposition.appGroupSuiteName)
        )
        let savedKeys = [
            MeteringProductionComposition.baseURLKey,
            MeteringProductionComposition.ownerKey,
            MeteringProductionComposition.selectionKey,
            MeteringProductionComposition.lockedSetIDKey,
        ].reduce(into: [String: Any]()) { saved, key in
            saved[key] = defaults.object(forKey: key)
        }
        defer {
            for key in [
                MeteringProductionComposition.baseURLKey,
                MeteringProductionComposition.ownerKey,
                MeteringProductionComposition.selectionKey,
                MeteringProductionComposition.lockedSetIDKey,
            ] {
                if let value = savedKeys[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        var selection = FamilyActivitySelection()
        selection.applicationTokens.insert(try syntheticApplicationToken(byte: 41))
        let selectionBytes = try JSONEncoder().encode(selection)
        let enforcementSetID = UUID()
        defaults.set(baseURL.absoluteString, forKey: MeteringProductionComposition.baseURLKey)
        defaults.set(owner.uuidString, forKey: MeteringProductionComposition.ownerKey)
        defaults.set(selectionBytes, forKey: MeteringProductionComposition.selectionKey)
        defaults.set(enforcementSetID.uuidString, forKey: MeteringProductionComposition.lockedSetIDKey)

        _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-08-02",
            generationKey: MeteringGenerationKey(
                protocolVersion: 2,
                childDeviceID: owner,
                canonicalTimezone: "America/New_York",
                policyRevision: "before-repair",
                measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                    persistedBytes: selectionBytes
                ),
                enforcementSetID: enforcementSetID
            ),
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 180,
            deviceCapMinutes: 180,
            authoritativeBaseAcceptedMinutes: 135,
            now: now.addingTimeInterval(-60)
        ))
        let cleanupID = try store.prepareIdentityCleanup(
            oldOwner: owner,
            newOwner: owner,
            oldFallbackKeys: [],
            now: now
        )
        try store.identityCleanupTransaction(workID: cleanupID) { _, cleanup in
            cleanup.clearedUsageDates = Set(cleanup.oldUsageDates)
            cleanup.ownerMirrorTransitionAcknowledged = true
        }

        let runtime = EarnedTimeRuntime(
            usageDate: "2026-08-02",
            timezone: "America/New_York",
            policyRevision: "after-repair",
            dailyPoolMinutes: 180,
            deviceCapMinutes: 180,
            remainingMinutes: 45,
            estimatedMinutes: 135
        )
        do {
            _ = try await MeteringProductionComposition.recoverFromSharedConfiguration(
                role: .app,
                runtime: runtime,
                usageCountingAllowed: true,
                expectedOwner: owner,
                expectedBaseURL: baseURL,
                store: store,
                clock: FixedProductionLinkClock(now: now),
                transport: ProductionLinkTransport()
            )
        } catch {
            // The fixture intentionally has no network. Planning must survive
            // the later delivery failure in the fresh post-cleanup root.
        }

        let state = try store.read()
        XCTAssertNil(state.identityCleanupWork)
        let todayRoute = try XCTUnwrap(state.routes.values.first(where: {
            $0.ownerChildDeviceID == owner && $0.usageDate == "2026-08-02"
        }))
        XCTAssertEqual(state.epochs[todayRoute.epochID]?.baseAcceptedMinutes, 135)
        XCTAssertEqual(todayRoute.lifecycle, .planned)
        let registration = try XCTUnwrap(state.registrationWork.values.first(where: {
            $0.ownerChildDeviceID == owner
                && $0.epochID == todayRoute.epochID
                && $0.routeID == todayRoute.routeID
        }))
        XCTAssertEqual(registration.request.reason, .identityRecovery)
        XCTAssertNil(state.pendingRegistrationRecovery)
    }

    func testStaleDesiredPolicyCannotRecreateYesterdayHorizonAfterMidnight() async throws {
        let owner = UUID()
        let baseURL = URL(string: "https://example.invalid/api/v1")!
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-03T05:10:00Z")
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-stale-policy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: MeteringProductionComposition.appGroupSuiteName)
        )
        let keys = [
            MeteringProductionComposition.baseURLKey,
            MeteringProductionComposition.ownerKey,
            MeteringProductionComposition.selectionKey,
            MeteringProductionComposition.lockedSetIDKey,
        ]
        let savedKeys = keys.reduce(into: [String: Any]()) { saved, key in
            saved[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = savedKeys[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        var selection = FamilyActivitySelection()
        selection.applicationTokens.insert(try syntheticApplicationToken(byte: 42))
        let selectionBytes = try JSONEncoder().encode(selection)
        let enforcementSetID = UUID()
        defaults.set(baseURL.absoluteString, forKey: MeteringProductionComposition.baseURLKey)
        defaults.set(owner.uuidString, forKey: MeteringProductionComposition.ownerKey)
        defaults.set(selectionBytes, forKey: MeteringProductionComposition.selectionKey)
        defaults.set(enforcementSetID.uuidString, forKey: MeteringProductionComposition.lockedSetIDKey)

        _ = try store.ingestDesiredPolicy(MeteringDesiredPolicy(
            commandID: UUID(),
            ownerChildDeviceID: owner,
            orderingToken: 1,
            policyRevision: "stale-policy",
            usageDate: "2026-08-02",
            canonicalTimezone: "America/New_York",
            dailyPoolMinutes: 180,
            deviceCapMinutes: 180,
            remainingMinutes: 180,
            enforcementSetID: enforcementSetID,
            receivedAt: now.addingTimeInterval(-300),
            appliedAt: nil,
            ackedAt: nil
        ))

        do {
            _ = try await MeteringProductionComposition.recoverFromSharedConfiguration(
                role: .app,
                expectedOwner: owner,
                expectedBaseURL: baseURL,
                store: store,
                clock: FixedProductionLinkClock(now: now),
                transport: ProductionLinkTransport()
            )
        } catch {
            // This transport is intentionally offline. The assertion concerns
            // whether stale policy was allowed to create yesterday's routes.
        }

        let state = try store.read()
        XCTAssertTrue(state.generations.isEmpty)
        XCTAssertTrue(state.epochs.isEmpty)
        XCTAssertTrue(state.routes.isEmpty)
        XCTAssertTrue(state.registrationWork.isEmpty)
    }

    private func makeFixture(seedPendingStart: Bool) throws -> ProductionLinkFixture {
        let baseURL = URL(string: "https://example.invalid/api/v1")!
        let owner = UUID()
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-composition-\(UUID().uuidString).json")
        let ownerProvider: @Sendable () -> UUID?
        if seedPendingStart {
            ownerProvider = { owner }
        } else {
            ownerProvider = { nil }
        }
        let store = DeviceEpochStore(
            fileURL: storeURL,
            ownerProvider: ownerProvider
        )
        let center = ProductionLinkCenter()
        if seedPendingStart {
            let now = ProductionLinkClock().now
            let selectionBytes = try JSONEncoder().encode(FamilyActivitySelection())
            let generationKey = MeteringGenerationKey(
                protocolVersion: 2,
                childDeviceID: owner,
                canonicalTimezone: "America/New_York",
                policyRevision: "production-link-r1",
                measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                    persistedBytes: selectionBytes
                ),
                enforcementSetID: UUID()
            )
            _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
                ownerChildDeviceID: owner,
                today: "2026-09-13",
                generationKey: generationKey,
                persistedSelectionBytes: selectionBytes,
                poolMinutes: 20,
                deviceCapMinutes: 10,
                authoritativeBaseAcceptedMinutes: 0,
                now: now
            ))
            try store.transaction(expectedOwner: owner) { state in
                for workID in state.registrationWork.keys {
                    guard var work = state.registrationWork[workID] else { continue }
                    work.retry.terminal = MeteringWorkTerminal.succeeded
                    state.registrationWork[workID] = work
                    state.epochs[work.epochID]?.registeredAt = now
                }
                for workID in state.installWork.keys {
                    if state.routes[state.installWork[workID]!.routeID]?.usageDate == "2026-09-13" {
                        state.installWork[workID]?.authorization = .registered
                    } else {
                        state.installWork[workID]?.phase = .verified
                    }
                }
            }
        }
        return ProductionLinkFixture(owner: owner, baseURL: baseURL, storeURL: storeURL, store: store, center: center)
    }

    private func syntheticApplicationToken(byte: UInt8) throws -> ApplicationToken {
        let data = Data(repeating: byte, count: 128).base64EncodedString()
        return try JSONDecoder().decode(
            ApplicationToken.self,
            from: Data(#"{"data":"\#(data)"}"#.utf8)
        )
    }
}

@MainActor
private final class ProductionLinkFixture {
    let owner: UUID
    let baseURL: URL
    let storeURL: URL
    let store: DeviceEpochStore
    let center: ProductionLinkCenter

    init(owner: UUID, baseURL: URL, storeURL: URL, store: DeviceEpochStore, center: ProductionLinkCenter) {
        self.owner = owner
        self.baseURL = baseURL
        self.storeURL = storeURL
        self.store = store
        self.center = center
    }

    deinit {
        try? FileManager.default.removeItem(at: storeURL)
    }
}

private nonisolated final class ProductionLinkCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    private var records: [DeviceActivityName: (DeviceActivitySchedule, [DeviceActivityEvent.Name: DeviceActivityEvent])] = [:]
    var startCalls: [DeviceActivityName] = []
    var activities: [DeviceActivityName] { Array(records.keys) }
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { records[activity]?.0 }
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        records[activity]?.1 ?? [:]
    }
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startCalls.append(activity)
        records[activity] = (schedule, events)
    }
    func stopMonitoring(_ activities: [DeviceActivityName]) {
        for activity in activities { records.removeValue(forKey: activity) }
    }
}

private struct ProductionLinkClock: MeteringClock {
    let now = Date(timeIntervalSince1970: 1_789_286_400)
}

private struct FixedProductionLinkClock: MeteringClock {
    let now: Date
}

private struct ProductionLinkTransport: MeteringHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
