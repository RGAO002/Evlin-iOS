import DeviceActivity
import FamilyControls
import Foundation
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringColdReopenRecoveryTests: XCTestCase {
    func testAppEntryRecoversPendingInstallFromSharedConfiguration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let entry = AppMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenTransport(),
            clock: fixture.clock,
            instanceID: UUID()
        )

        await entry.recoverIfConfigured()

        XCTAssertEqual(fixture.center.startCalls.count, 1)
    }

    func testDAMEntryRecoversPendingInstallFromSharedConfiguration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let entry = DAMMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenTransport(),
            clock: fixture.clock,
            instanceID: UUID()
        )

        await entry.recoverIfConfigured()

        XCTAssertEqual(fixture.center.startCalls.count, 1)
    }

    func testDAMEarnedIntervalEndRunsSharedRecoveryEntry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let entry = DAMMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenTransport(),
            clock: fixture.clock,
            instanceID: UUID()
        )

        await entry.handleIntervalDidEnd(
            activityName: "\(MeteringRouteNamespace.prefix)\(UUID().uuidString.lowercased())"
        )

        XCTAssertEqual(fixture.center.startCalls.count, 1)
    }

    func testProductionCompositionUsesOneStableIdentityPerProcessRole() {
        XCTAssertEqual(
            MeteringProductionComposition.instanceID(for: .app),
            MeteringProductionComposition.instanceID(for: .app)
        )
        XCTAssertEqual(
            MeteringProductionComposition.instanceID(for: .deviceActivityMonitor),
            MeteringProductionComposition.instanceID(for: .deviceActivityMonitor)
        )
        XCTAssertNotEqual(
            MeteringProductionComposition.instanceID(for: .app),
            MeteringProductionComposition.instanceID(for: .deviceActivityMonitor)
        )
    }

    func testMalformedSharedConfigurationDoesNotCreateMonitorWork() async throws {
        let fixture = try makeFixture(configureDefaults: false, seedWork: false)
        defer { fixture.cleanUp() }
        fixture.defaults.set("file:///tmp/not-http", forKey: MeteringProductionComposition.baseURLKey)
        fixture.defaults.set("not-a-uuid", forKey: MeteringProductionComposition.ownerKey)
        let before = try fixture.store.read()
        let app = AppMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenTransport(),
            clock: fixture.clock,
            instanceID: UUID()
        )

        await app.recoverIfConfigured()

        XCTAssertEqual(try fixture.store.read(), before)
        XCTAssertTrue(fixture.center.startCalls.isEmpty)
        XCTAssertTrue(fixture.center.stopCalls.isEmpty)
    }

    func testProductionSourcesWireAppAndDAMButKeepPushNonOwner() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try source(root, "Evlin iOS/Evlin_iOSApp.swift")
        let dam = try source(root, "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift")
        let push = try source(root, "EvlinPushApplier/NotificationService.swift")
        let auth = try source(root, "Evlin iOS/Services/Auth/AuthService.swift")
        let familyGone = try source(root, "Evlin iOS/Services/FamilyGoneDetector.swift")
        let childRoot = try source(root, "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift")

        XCTAssertTrue(app.contains("AppMeteringEntry.shared.recoverIfConfigured"))
        XCTAssertTrue(dam.contains("DAMMeteringEntry.shared.recoverIfConfigured"))
        XCTAssertTrue(dam.contains("DAMMeteringEntry.shared.handle"))
        XCTAssertTrue(dam.contains("DAMMeteringEntry.shared.handleIntervalDidEnd"))
        XCTAssertTrue(dam.contains("projectShields: project"))
        XCTAssertTrue(dam.contains("self?.recomputeAndApplyShields(shields)"))
        let synchronousHandle = try XCTUnwrap(
            dam.range(of: "let outcome = try DAMMeteringEntry.shared.handle")
        )
        let asyncRecovery = try XCTUnwrap(
            dam.range(
                of: "Task { @MainActor in",
                range: synchronousHandle.upperBound..<dam.endIndex
            )
        )
        XCTAssertLessThan(synchronousHandle.lowerBound, asyncRecovery.lowerBound)
        XCTAssertTrue(auth.contains("EarnedBudgetArming.teardownFamilyIdentity"))
        XCTAssertTrue(familyGone.contains("EarnedBudgetArming.teardownFamilyIdentity"))
        XCTAssertTrue(childRoot.contains("EarnedBudgetArming.mirrorChildIdentity"))
        XCTAssertTrue(childRoot.contains("AppMeteringEntry.shared.recoverIfConfigured"))

        for token in [
            "Device" + "ActivityCenter",
            "Dated" + "RouteInstaller",
            "start" + "Monitoring",
            "stop" + "Monitoring",
            "#" + "available",
            "@" + "available",
        ] {
            XCTAssertFalse(push.contains(token), "Push must not contain \(token)")
        }
    }

    private func makeFixture(
        configureDefaults: Bool = true,
        seedWork: Bool = true
    ) throws -> ColdReopenFixture {
        let owner = UUID()
        let suiteName = "metering-cold-reopen-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-cold-reopen-\(UUID().uuidString).json")
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let center = ColdReopenCenter()
        let clock = ColdReopenClock()
        if configureDefaults {
            defaults.set("https://example.invalid/api/v1", forKey: MeteringProductionComposition.baseURLKey)
            defaults.set(owner.uuidString, forKey: MeteringProductionComposition.ownerKey)
        }
        if seedWork {
            let selectionBytes = try JSONEncoder().encode(FamilyActivitySelection())
            let generation = MeteringGenerationKey(
                protocolVersion: 2,
                childDeviceID: owner,
                canonicalTimezone: "America/New_York",
                policyRevision: "cold-reopen-r1",
                measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                    persistedBytes: selectionBytes
                ),
                enforcementSetID: UUID()
            )
            _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
                ownerChildDeviceID: owner,
                today: "2026-09-13",
                generationKey: generation,
                persistedSelectionBytes: selectionBytes,
                poolMinutes: 20,
                deviceCapMinutes: 10,
                authoritativeBaseAcceptedMinutes: 0,
                now: clock.now
            ))
            try store.transaction(expectedOwner: owner) { state in
                for workID in state.registrationWork.keys {
                    guard let work = state.registrationWork[workID] else { continue }
                    state.registrationWork[workID]?.retry.terminal = .succeeded
                    state.epochs[work.epochID]?.registeredAt = clock.now
                }
                for workID in state.installWork.keys {
                    guard let work = state.installWork[workID],
                          let route = state.routes[work.routeID]
                    else { continue }
                    if route.usageDate == "2026-09-13" {
                        state.installWork[workID]?.authorization = .registered
                    } else {
                        state.installWork[workID]?.phase = .verified
                    }
                }
            }
        }
        return ColdReopenFixture(
            owner: owner,
            suiteName: suiteName,
            defaults: defaults,
            storeURL: storeURL,
            store: store,
            center: center,
            clock: clock
        )
    }

    private func source(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

@MainActor
private final class ColdReopenFixture {
    let owner: UUID
    let suiteName: String
    let defaults: UserDefaults
    let storeURL: URL
    let store: DeviceEpochStore
    let center: ColdReopenCenter
    let clock: ColdReopenClock

    init(
        owner: UUID,
        suiteName: String,
        defaults: UserDefaults,
        storeURL: URL,
        store: DeviceEpochStore,
        center: ColdReopenCenter,
        clock: ColdReopenClock
    ) {
        self.owner = owner
        self.suiteName = suiteName
        self.defaults = defaults
        self.storeURL = storeURL
        self.store = store
        self.center = center
        self.clock = clock
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storeURL)
    }

}

private nonisolated final class ColdReopenCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    private var records: [DeviceActivityName: (DeviceActivitySchedule, [DeviceActivityEvent.Name: DeviceActivityEvent])] = [:]
    var startCalls: [DeviceActivityName] = []
    var stopCalls: [[DeviceActivityName]] = []
    var activities: [DeviceActivityName] { Array(records.keys) }

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? {
        records[activity]?.0
    }

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
        stopCalls.append(activities)
        for activity in activities { records.removeValue(forKey: activity) }
    }
}

private struct ColdReopenClock: MeteringClock {
    let now = Date(timeIntervalSince1970: 1_789_200_000)
}

private struct ColdReopenTransport: MeteringHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
