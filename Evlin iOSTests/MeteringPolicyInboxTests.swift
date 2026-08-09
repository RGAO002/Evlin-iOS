import XCTest
@testable import Evlin_iOS

final class MeteringPolicyInboxTests: XCTestCase {
    private let owner = UUID(uuidString: "71000000-0000-0000-0000-000000000008")!

    func testNewestPolicyWinsAndDuplicatesDoNotRewriteBytes() throws {
        let harness = makeHarness()
        XCTAssertEqual(try harness.store.ingestDesiredPolicy(policy(token: 2)), .acceptedNeedsOwner)
        let acceptedBytes = try Data(contentsOf: harness.fileURL)

        XCTAssertEqual(
            try harness.store.ingestDesiredPolicy(policy(token: 1)),
            .superseded(latestOrderingToken: 2)
        )
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), acceptedBytes)
        XCTAssertEqual(try harness.store.ingestDesiredPolicy(policy(token: 2)), .duplicatePending)
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), acceptedBytes)

        XCTAssertEqual(try harness.store.ingestDesiredPolicy(policy(token: 3)), .acceptedNeedsOwner)
        let desired = try XCTUnwrap(harness.store.read().desiredPolicy)
        XCTAssertEqual(desired.orderingToken, 3)
        XCTAssertEqual(desired.policyRevision, "policy-3")
        XCTAssertNil(desired.appliedAt)
        XCTAssertNil(desired.ackedAt)
    }

    func testEqualTokenDifferentPolicyFailsClosedWithoutMutation() throws {
        let harness = makeHarness()
        _ = try harness.store.ingestDesiredPolicy(policy(token: 2))
        let bytes = try Data(contentsOf: harness.fileURL)
        var conflict = policy(token: 2)
        conflict = MeteringDesiredPolicy(
            commandID: conflict.commandID,
            ownerChildDeviceID: conflict.ownerChildDeviceID,
            orderingToken: conflict.orderingToken,
            policyRevision: "different",
            usageDate: conflict.usageDate,
            canonicalTimezone: conflict.canonicalTimezone,
            dailyPoolMinutes: conflict.dailyPoolMinutes,
            deviceCapMinutes: conflict.deviceCapMinutes,
            remainingMinutes: conflict.remainingMinutes,
            enforcementSetID: conflict.enforcementSetID,
            receivedAt: conflict.receivedAt,
            appliedAt: nil,
            ackedAt: nil
        )

        XCTAssertEqual(try harness.store.ingestDesiredPolicy(conflict), .equalTokenConflict)
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), bytes)
    }

    func testOwnerMismatchAndNonPositiveTokenAreRejectedWithoutBytes() throws {
        let harness = makeHarness()
        let other = MeteringDesiredPolicy(
            commandID: UUID(),
            ownerChildDeviceID: UUID(uuidString: "71000000-0000-0000-0000-000000000099")!,
            orderingToken: 1,
            policyRevision: "policy-1",
            usageDate: "2026-07-20",
            canonicalTimezone: "UTC",
            dailyPoolMinutes: 120,
            deviceCapMinutes: 60,
            remainingMinutes: 50,
            enforcementSetID: nil,
            receivedAt: Date(timeIntervalSince1970: 1_753_027_200),
            appliedAt: nil,
            ackedAt: nil
        )
        XCTAssertThrowsError(try harness.store.ingestDesiredPolicy(other))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.fileURL.path))

        var invalid = policy(token: 1)
        invalid = MeteringDesiredPolicy(
            commandID: invalid.commandID,
            ownerChildDeviceID: invalid.ownerChildDeviceID,
            orderingToken: 0,
            policyRevision: invalid.policyRevision,
            usageDate: invalid.usageDate,
            canonicalTimezone: invalid.canonicalTimezone,
            dailyPoolMinutes: invalid.dailyPoolMinutes,
            deviceCapMinutes: invalid.deviceCapMinutes,
            remainingMinutes: invalid.remainingMinutes,
            enforcementSetID: invalid.enforcementSetID,
            receivedAt: invalid.receivedAt,
            appliedAt: nil,
            ackedAt: nil
        )
        XCTAssertThrowsError(try harness.store.ingestDesiredPolicy(invalid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.fileURL.path))
    }

    func testAppliedAndAcknowledgedTransitionsRequireExactCurrentPolicy() throws {
        let harness = makeHarness()
        let desired = policy(token: 2)
        _ = try harness.store.ingestDesiredPolicy(desired)
        let appliedAt = desired.receivedAt.addingTimeInterval(10)
        try harness.store.markDesiredPolicyApplied(
            commandID: desired.commandID,
            orderingToken: 2,
            policyRevision: desired.policyRevision,
            appliedAt: appliedAt
        )
        XCTAssertEqual(try harness.store.read().desiredPolicy?.appliedAt, appliedAt)
        XCTAssertEqual(try harness.store.ingestDesiredPolicy(desired), .duplicateApplied)

        let ackedAt = appliedAt.addingTimeInterval(5)
        try harness.store.markDesiredPolicyAcknowledged(
            commandID: desired.commandID,
            orderingToken: 2,
            policyRevision: desired.policyRevision,
            ackedAt: ackedAt
        )
        XCTAssertEqual(try harness.store.read().desiredPolicy?.ackedAt, ackedAt)
        XCTAssertThrowsError(try harness.store.markDesiredPolicyApplied(
            commandID: UUID(),
            orderingToken: 2,
            policyRevision: desired.policyRevision,
            appliedAt: ackedAt
        ))
    }

    func testSharedWireIngressRequiresExactFetchedOwnerAndPersistsPolicy() throws {
        let harness = makeHarness()
        let command = wireCommand(owner: owner, token: 7)

        XCTAssertEqual(
            try MeteringPolicyIngress.persist(
                command: command,
                fetchedDeviceID: owner,
                store: harness.store
            ),
            .acceptedNeedsOwner
        )
        let desired = try XCTUnwrap(harness.store.read().desiredPolicy)
        XCTAssertEqual(desired.commandID, command.id)
        XCTAssertEqual(desired.orderingToken, 7)
        XCTAssertEqual(desired.dailyPoolMinutes, 120)
        XCTAssertEqual(desired.deviceCapMinutes, 60)
        XCTAssertEqual(desired.enforcementSetID?.uuidString.lowercased(), "73000000-0000-0000-0000-000000000008")

        XCTAssertThrowsError(try MeteringPolicyIngress.persist(
            command: command,
            fetchedDeviceID: UUID(),
            store: harness.store
        ))
    }

    // MARK: - Override retirement (server-authoritative, 2026-08-08)

    func testServerSayingOverrideRetiredClearsTheLocalFlag() throws {
        let harness = makeHarness()
        let earned = makeEarnedStore()
        earned.setOverride(true, forUsageDate: "2026-07-20")

        XCTAssertEqual(
            try MeteringPolicyIngress.persist(
                command: wireCommand(owner: owner, token: 8, overrideActive: false),
                fetchedDeviceID: owner,
                store: harness.store,
                earnedStore: earned
            ),
            .acceptedNeedsOwner
        )
        XCTAssertFalse(
            earned.isOverridden(forUsageDate: "2026-07-20"),
            "a flag nobody clears means no locking for the rest of the day"
        )
    }

    /// The crash window. The policy persists before the flag is cleared, so a
    /// process death in between makes the replay a duplicate — and a clear gated
    /// on the disposition never ran, leaving the override alive until midnight.
    func testDuplicateDeliveryStillClearsTheLocalFlag() throws {
        let harness = makeHarness()
        let earned = makeEarnedStore()
        let command = wireCommand(owner: owner, token: 8, overrideActive: false)

        _ = try MeteringPolicyIngress.persist(
            command: command,
            fetchedDeviceID: owner,
            store: harness.store,
            earnedStore: earned
        )
        // Stand in for "died before clearing": the policy is on disk, the flag
        // is not yet cleared, and the same command is delivered again.
        earned.setOverride(true, forUsageDate: "2026-07-20")
        let replay = try MeteringPolicyIngress.persist(
            command: command,
            fetchedDeviceID: owner,
            store: harness.store,
            earnedStore: earned
        )
        XCTAssertNotEqual(replay, .acceptedNeedsOwner, "must be a duplicate")
        XCTAssertFalse(
            earned.isOverridden(forUsageDate: "2026-07-20"),
            "the clear must not be gated on the disposition"
        )
    }

    func testServerSayingOverrideStandsLeavesTheFlagAlone() throws {
        let harness = makeHarness()
        let earned = makeEarnedStore()
        earned.setOverride(true, forUsageDate: "2026-07-20")

        _ = try MeteringPolicyIngress.persist(
            command: wireCommand(owner: owner, token: 8, overrideActive: true),
            fetchedDeviceID: owner,
            store: harness.store,
            earnedStore: earned
        )
        XCTAssertTrue(earned.isOverridden(forUsageDate: "2026-07-20"))
    }

    /// Older payloads carry no answer; inventing one in either direction would
    /// be worse than leaving the flag where the override command put it.
    func testMissingOverrideFieldLeavesTheFlagAlone() throws {
        let harness = makeHarness()
        let earned = makeEarnedStore()
        earned.setOverride(true, forUsageDate: "2026-07-20")

        _ = try MeteringPolicyIngress.persist(
            command: wireCommand(owner: owner, token: 8),
            fetchedDeviceID: owner,
            store: harness.store,
            earnedStore: earned
        )
        XCTAssertTrue(earned.isOverridden(forUsageDate: "2026-07-20"))
    }

    func testOverrideForAnotherDayIsUntouched() throws {
        let harness = makeHarness()
        let earned = makeEarnedStore()
        earned.setOverride(true, forUsageDate: "2026-07-19")

        _ = try MeteringPolicyIngress.persist(
            command: wireCommand(owner: owner, token: 8, overrideActive: false),
            fetchedDeviceID: owner,
            store: harness.store,
            earnedStore: earned
        )
        XCTAssertTrue(earned.isOverridden(forUsageDate: "2026-07-19"))
    }

    private func makeEarnedStore() -> EarnedTimeStore {
        EarnedTimeStore(suiteName: "evlin.policy-inbox.\(UUID().uuidString)")
    }

    private func makeHarness() -> PolicyInboxHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-policy-inbox-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("epoch.json")
        return PolicyInboxHarness(
            fileURL: fileURL,
            store: DeviceEpochStore(
                fileURL: fileURL,
                lock: PolicyInboxLock(),
                ownerProvider: { self.owner },
                legacyDefaults: nil
            )
        )
    }

    private func policy(token: Int64) -> MeteringDesiredPolicy {
        MeteringDesiredPolicy(
            commandID: UUID(uuidString: String(format: "72000000-0000-0000-0000-%012lld", token))!,
            ownerChildDeviceID: owner,
            orderingToken: token,
            policyRevision: "policy-\(token)",
            usageDate: "2026-07-20",
            canonicalTimezone: "America/New_York",
            dailyPoolMinutes: 120,
            deviceCapMinutes: 60,
            remainingMinutes: 50,
            enforcementSetID: UUID(uuidString: "73000000-0000-0000-0000-000000000008"),
            receivedAt: Date(timeIntervalSince1970: 1_753_027_200 + Double(token)),
            appliedAt: nil,
            ackedAt: nil
        )
    }

    private func wireCommand(
        owner: UUID,
        token: Int64,
        dailyPoolMinutes: Int = 120,
        overrideActive: Bool? = nil
    ) -> LockCommand {
        let payload = """
        {
          "child_device_id":"\(owner.uuidString)",
          "usage_date":"2026-07-20",
          "timezone":"America/New_York",
          "policy_revision":"policy-\(token)",
          "ordering_token":\(token),
          "daily_pool_minutes":\(dailyPoolMinutes),
          \(overrideActive.map { "\"override_active\":\($0)," } ?? "")
          "device_cap_minutes":60,
          "remaining_minutes":50,
          "selected_set":{"list_id":"73000000-0000-0000-0000-000000000008"}
        }
        """.data(using: .utf8)!
        let config = try! JSONDecoder().decode(EarnedTimeConfigCommand.self, from: payload)
        return LockCommand(
            id: UUID(uuidString: "74000000-0000-0000-0000-0000000000\(String(format: "%02d", token))")!,
            action: .earnedTimeConfig,
            tier: nil,
            target: CommandTarget(originalRequest: "policy"),
            durationMinutes: nil,
            issuedAt: Date(timeIntervalSince1970: 1_753_027_200),
            earnedTimeConfig: config
        )
    }
}

private struct PolicyInboxHarness {
    let fileURL: URL
    let store: DeviceEpochStore
}

private final class PolicyInboxLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()
    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
