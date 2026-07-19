import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringT8DemolitionTests: XCTestCase {
    func testDuplicateEarnedLifecycleAuthorityIsAbsent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = [
            "Evlin iOS",
            "EvlinDeviceActivityMonitor",
            "EvlinPushApplier",
            "Evlin iOSTests",
        ]
        let forbidden = [
            ["Earned", "Activity", "Generation"].joined(),
            ["evlin", "earned", "activityLifecycle"].joined(separator: "."),
            ["evlin", "earned", "activityBreadcrumbs"].joined(separator: "."),
            ["evlin", "earned", "activeActivityName"].joined(separator: "."),
        ]

        for relativeRoot in roots {
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
                        "duplicate T8 authority \(token) remains in \(fileURL.path)"
                    )
                }
            }
        }
    }

    func testV1ReplacementPersistsNewAuthorityBeforeStoppingPriorMonitor() throws {
        let owner = UUID()
        let store = makeStore(owner: owner)
        let prior = generation(owner: owner, suffix: "prior", offset: 5)
        let next = generation(owner: owner, suffix: "next", offset: 10)
        try seed(store: store, owner: owner, active: prior)
        var activeWhenStopped: LegacyGenerationProvenance?
        var stopped: [String] = []

        let installed = LegacyMeteringActivity.installReplacement(
            next,
            store: store,
            owner: owner,
            startMonitoring: { XCTAssertEqual($0, next.activityName) },
            stopMonitoring: { names in
                activeWhenStopped = try? store.read().legacy?.active
                stopped = names
            }
        )

        XCTAssertTrue(installed)
        XCTAssertEqual(activeWhenStopped, next)
        XCTAssertEqual(try store.read().legacy?.active, next)
        XCTAssertTrue(stopped.contains(prior.activityName))
        XCTAssertTrue(stopped.contains(LegacyMeteringActivity.legacyActivityName))
    }

    func testFailedV1ReplacementPreservesPriorAuthorityAndStopsCandidate() throws {
        enum StartFailure: Error { case injected }
        let owner = UUID()
        let store = makeStore(owner: owner)
        let prior = generation(owner: owner, suffix: "prior", offset: 5)
        let candidate = generation(owner: owner, suffix: "candidate", offset: 10)
        try seed(store: store, owner: owner, active: prior)
        var stopped: [String] = []

        let installed = LegacyMeteringActivity.installReplacement(
            candidate,
            store: store,
            owner: owner,
            startMonitoring: { _ in throw StartFailure.injected },
            stopMonitoring: { stopped += $0 }
        )

        XCTAssertFalse(installed)
        XCTAssertEqual(try store.read().legacy?.active, prior)
        XCTAssertEqual(stopped, [candidate.activityName])
    }

    func testRestartRecoveryStopsInterruptedCandidateWithoutStoppingActiveV1() throws {
        let owner = UUID()
        let store = makeStore(owner: owner)
        let active = generation(owner: owner, suffix: "active", offset: 5)
        let pending = generation(owner: owner, suffix: "pending", offset: 10)
        try seed(store: store, owner: owner, active: active, pending: pending)
        var stopped: [String] = []

        LegacyMeteringActivity.recoverInterruptedTransition(
            store: store,
            owner: owner,
            stopMonitoring: { stopped = $0 }
        )

        XCTAssertTrue(stopped.contains(pending.activityName))
        XCTAssertFalse(stopped.contains(active.activityName))
        XCTAssertEqual(try store.read().legacy?.active, active)
        XCTAssertNil(try store.read().legacy?.pending)
        XCTAssertEqual(try store.read().legacy?.phase, .activeV1)
    }

    func testCallbackMutationRollsBackOnlyItsOwnWriteAfterAuthorityChanges() throws {
        let owner = UUID()
        let store = makeStore(owner: owner)
        let active = generation(owner: owner, suffix: "active", offset: 5)
        try seed(store: store, owner: owner, active: active)
        let suiteName = "MeteringT8DemolitionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "test.t8.callback-write"
        defaults.set("prior", forKey: key)

        let authorized = LegacyMeteringActivity.performIfAuthorized(
            generation: active,
            store: store,
            defaults: defaults,
            mutationKeys: [key],
            beforeFinalAuthorizationCheck: {
                try? store.transaction(expectedOwner: owner) { state in
                    state.legacy?.phase = .stoppedV1
                }
            }
        ) {
            defaults.set("stale-write", forKey: key)
        }

        XCTAssertFalse(authorized)
        XCTAssertEqual(defaults.string(forKey: key), "prior")
    }

    private func makeStore(owner: UUID) -> DeviceEpochStore {
        DeviceEpochStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("metering-t8-\(UUID().uuidString).json"),
            lock: MeteringT8Lock(),
            ownerProvider: { owner },
            legacyDefaults: nil
        )
    }

    private func generation(
        owner: UUID,
        suffix: String,
        offset: Int
    ) -> LegacyGenerationProvenance {
        LegacyGenerationProvenance(
            activityName: "\(LegacyMeteringActivity.generatedActivityPrefix)\(suffix)",
            deviceID: owner.uuidString,
            offsetMinutes: offset,
            usageDate: "2026-07-18",
            timezoneIdentifier: "America/New_York",
            armedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func seed(
        store: DeviceEpochStore,
        owner: UUID,
        active: LegacyGenerationProvenance,
        pending: LegacyGenerationProvenance? = nil
    ) throws {
        try store.transaction(expectedOwner: owner) { state in
            state.legacy = LegacyCompatibilityMonitorState(
                ownerChildDeviceID: owner,
                lifecycleVersion: 2,
                active: active,
                pending: pending,
                retiringActivityNames: [],
                breadcrumbActivityNames: [],
                scalarActiveActivityName: active.activityName,
                isStopped: false,
                phase: pending == nil ? .activeV1 : .dualLanePreparingV2,
                stopAcknowledgedAt: nil
            )
        }
    }
}

private final class MeteringT8Lock: DeviceEpochStoreLocking, @unchecked Sendable {
    func withLock<T>(_ body: () -> T) -> T? { body() }
}
