import Foundation
import XCTest
@testable import Evlin_iOS

final class AppLimitProductionReorderingTests: XCTestCase {
    func testEveryArrivalPermutationConvergesToNewestClearTombstone() throws {
        let commands = [
            envelope(token: 1, kind: .set, source: .poll),
            envelope(token: 2, kind: .set, source: .notificationServiceExtension),
            envelope(token: 3, kind: .clear, source: .wakeRecovery),
        ]

        var canonicalStates = Set<Data>()
        for order in permutations(commands) {
            let harness = makeHarness()
            for command in order { _ = try harness.coordinator.ingest(command) }
            let state = try harness.store.read()
            let slot = try XCTUnwrap(state.slots[ruleID])
            XCTAssertEqual(slot.latestOrderingToken, 3)
            XCTAssertEqual(slot.latestKind, .clear)
            XCTAssertEqual(slot.clearTombstone?.orderingToken, 3)
            XCTAssertNil(slot.activeRule)
            XCTAssertEqual(slot.pendingOwnerWork?.orderingToken, 3)
            canonicalStates.insert(canonicalSlotData(slot))
        }
        XCTAssertEqual(canonicalStates.count, 1)
    }

    func testExpiredNewestTokenSurvivesRestartAndSupersedesDelayedSet() throws {
        let harness = makeHarness()
        let expired = envelope(
            token: 5,
            kind: .set,
            source: .notificationServiceExtension,
            expiresAt: referenceDate.addingTimeInterval(-1)
        )
        try harness.coordinator.recordExpired(expired)

        let restarted = AppLimitEpochStore(
            fileURL: harness.fileURL,
            lock: ReorderingTestLock(),
            ownerProvider: { ownerID },
            legacyDefaults: nil
        )
        let coordinator = AppLimitCommandCoordinator(
            store: restarted,
            expectedOwnerProvider: { ownerID }
        )
        XCTAssertEqual(
            try coordinator.ingest(envelope(token: 3, kind: .set, source: .poll)),
            .superseded(latestOrderingToken: 5)
        )
        let slot = try XCTUnwrap(restarted.read().slots[ruleID])
        XCTAssertEqual(slot.clearTombstone?.orderingToken, 5)
        XCTAssertNil(slot.activeRule)
        XCTAssertNil(slot.pendingOwnerWork)
    }

    func testProductionSourcesCannotUseLegacyRuleStoreMutationMethods() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for directory in ["Evlin iOS", "EvlinDeviceActivityMonitor", "EvlinPushApplier"] {
            let url = root.appendingPathComponent(directory)
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: nil
            )
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension == "swift",
                      file.lastPathComponent != "AppLimitRuleStore.swift"
                else { continue }
                let source = try String(contentsOf: file)
                XCTAssertFalse(source.contains("ruleStore.upsert("), file.path)
                XCTAssertFalse(source.contains("ruleStore.remove(ruleId:"), file.path)
                XCTAssertFalse(source.contains("AppLimitRuleStore.shared.upsert("), file.path)
                XCTAssertFalse(source.contains("AppLimitRuleStore.shared.remove(ruleId:"), file.path)
            }
        }
    }

    private func makeHarness() -> ReorderingHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-limit-reordering-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("epoch.json")
        let store = AppLimitEpochStore(
            fileURL: fileURL,
            lock: ReorderingTestLock(),
            ownerProvider: { ownerID },
            legacyDefaults: nil
        )
        return ReorderingHarness(
            fileURL: fileURL,
            store: store,
            coordinator: AppLimitCommandCoordinator(
                store: store,
                expectedOwnerProvider: { ownerID }
            )
        )
    }

    private func envelope(
        token: Int64,
        kind: AppLimitCommandKind,
        source: AppLimitCommandSource,
        expiresAt: Date? = nil
    ) -> AppLimitCommandEnvelope {
        AppLimitCommandEnvelope(
            commandID: UUID(uuidString: String(format: "aaaaaaaa-0000-0000-0000-%012lld", token))!,
            ruleID: ruleID,
            orderingToken: token,
            kind: kind,
            payloadDigest: "\(kind.rawValue)-\(token)",
            receivedAt: referenceDate,
            source: source,
            rule: kind == .set ? AppLimitRule(
                id: ruleID,
                appTokens: [],
                bundleID: "com.example.focus",
                displayName: "Focus",
                budgetMinutes: 30,
                window: AppLimitWindow(
                    startMinute: 0,
                    endMinute: 1439,
                    repeats: true,
                    timezone: "UTC"
                ),
                effectiveFrom: referenceDate,
                expiresAt: expiresAt
            ) : nil
        )
    }

    private func permutations<T>(_ values: [T]) -> [[T]] {
        guard values.count > 1 else { return [values] }
        return values.indices.flatMap { index in
            var rest = values
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    private func canonicalSlotData(_ slot: AppLimitVersionSlot) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(slot)
    }
}

private struct ReorderingHarness {
    let fileURL: URL
    let store: AppLimitEpochStore
    let coordinator: AppLimitCommandCoordinator
}

private final class ReorderingTestLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()
    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private let ownerID = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
private let ruleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000400")!
private let referenceDate = Date(timeIntervalSince1970: 1_721_174_400)
