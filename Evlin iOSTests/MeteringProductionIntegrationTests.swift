import DeviceActivity
import FamilyControls
import Foundation
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

    func testMonitorRecoveryFactoryLinks() async throws {
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
        XCTAssertEqual(fixture.center.startCalls.count, 1)
    }

    func testCallbackFactoryLinks() throws {
        let fixture = try makeFixture(seedPendingStart: false)
        let callback = MeteringProductionComposition.makeCallback(store: fixture.store)
        withExtendedLifetime(callback) {}
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

@MainActor
private final class ProductionLinkCenter: MeteringDeviceActivityCenter {
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
    let now = Date(timeIntervalSince1970: 1_789_200_000)
}

private struct ProductionLinkTransport: MeteringHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
