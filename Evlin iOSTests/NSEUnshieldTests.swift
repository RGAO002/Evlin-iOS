import XCTest
@testable import Evlin_iOS

@MainActor
final class NSEUnshieldTests: XCTestCase {
    private let suiteName = "group.com.evlin.ios"
    private let shieldsKey = "evlin.shieldRecords"
    private let blocksKey = "evlin.blockRecords"

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.removeObject(forKey: shieldsKey)
        defaults?.removeObject(forKey: blocksKey)
    }

    override func tearDown() async throws {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.removeObject(forKey: shieldsKey)
        defaults?.removeObject(forKey: blocksKey)
    }

    func test_resolvedUnlockSources_prefersTopLevelAndFallsBackToTarget() {
        XCTAssertEqual(
            NSECommandSourceResolver.unlockSources(
                topLevel: ["manual"],
                target: ["earned_time"]
            ),
            ["manual"]
        )
        XCTAssertEqual(
            NSECommandSourceResolver.unlockSources(
                topLevel: nil,
                target: ["task_pause"]
            ),
            ["task_pause"]
        )
        XCTAssertNil(NSECommandSourceResolver.unlockSources(topLevel: nil, target: nil))
    }

    func test_resolvedLockSource_prefersTopLevelAndFallsBackToTarget() {
        XCTAssertEqual(
            NSECommandSourceResolver.lockSource(
                topLevel: "earned_time",
                target: "task_pause"
            ),
            "earned_time"
        )
        XCTAssertEqual(
            NSECommandSourceResolver.lockSource(
                topLevel: nil,
                target: "task_pause"
            ),
            "task_pause"
        )
        XCTAssertNil(NSECommandSourceResolver.lockSource(topLevel: nil, target: nil))
    }

    func test_earnedTimeShieldThenManualUnshield_keepsAutomaticProvenance() async throws {
        try await assertAutomaticNSEShieldSurvivesManualUnshield(
            wireSource: "earned_time",
            expectedSource: .earnedTime
        )
    }

    func test_taskPauseShieldThenManualUnshield_keepsAutomaticProvenance() async throws {
        try await assertAutomaticNSEShieldSurvivesManualUnshield(
            wireSource: "task_pause",
            expectedSource: .taskPause
        )
    }

    func test_manualUnshield_keepsAutomaticSourcesAndConfirmsOutcome() async throws {
        let store = ActiveLockStore()
        let listID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let recordKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: listID.uuidString)
        let record = ShieldRecord(
            recordKey: recordKey,
            tier: .savedList,
            targetKey: listID.uuidString,
            displayName: "Locked set",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "lock Locked set",
            targetChildID: UUID(),
            sources: [.manual, .earnedTime, .taskPause]
        )
        _ = await store.addShield(record)
        let command = LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Locked set",
                listID: listID,
                originalRequest: "unlock Locked set",
                targetDisplay: "Locked set",
                unlockSources: ["manual"]
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )

        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: recordKey,
            store: store
        )

        XCTAssertEqual(outcome, .confirmed)
        let current = await store.allCurrent().shields
        let remaining = try XCTUnwrap(current.first(where: { $0.recordKey == recordKey }))
        XCTAssertEqual(remaining.sources, [.earnedTime, .taskPause])
    }

    func test_legacyUnshieldWithoutSources_removesWholeRecord() async {
        let store = ActiveLockStore()
        let listID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        let recordKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: listID.uuidString)
        let record = ShieldRecord(
            recordKey: recordKey,
            tier: .savedList,
            targetKey: listID.uuidString,
            displayName: "Locked set",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "lock Locked set",
            targetChildID: UUID(),
            sources: [.manual, .earnedTime]
        )
        _ = await store.addShield(record)
        let command = LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Locked set",
                listID: listID,
                originalRequest: "unlock Locked set",
                targetDisplay: "Locked set"
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )

        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: recordKey,
            store: store
        )

        XCTAssertEqual(outcome, .confirmed)
        let remaining = await store.allCurrent().shields
        XCTAssertFalse(remaining.contains(where: { $0.recordKey == recordKey }))
    }

    func test_nseWireAndApply_persistsOverrideThenRemovesEarnedOnly() async throws {
        let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
            usageDate: "2026-07-15"
        ))
        XCTAssertEqual(command.target.earnedOverrideUsageDate, "2026-07-15")

        let activeStore = ActiveLockStore()
        let earnedStore = makeEarnedStore()
        let record = makeMixedRecord()
        _ = await activeStore.addShield(record)
        var sourceMutationCheckpoints = 0
        var overrideWasSetBeforeRemoval = false
        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: record.recordKey,
            store: activeStore,
            earnedTimeStore: earnedStore,
            fetchedDeviceID: overrideDeviceID,
            currentDeviceID: overrideDeviceID,
            currentUsageDate: "2026-07-15",
            beforeSourceMutation: {
                sourceMutationCheckpoints += 1
                overrideWasSetBeforeRemoval = earnedStore.isOverridden(
                    forUsageDate: "2026-07-15"
                )
            }
        )

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(sourceMutationCheckpoints, 1)
        XCTAssertTrue(overrideWasSetBeforeRemoval)
        XCTAssertTrue(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
        let snapshot = await activeStore.allCurrent()
        let remaining = try XCTUnwrap(snapshot.shields.first {
            $0.recordKey == record.recordKey
        })
        XCTAssertEqual(remaining.sources, [.manual])
        earnedStore.removeAll()
    }

    func test_nseInvalidOverrideDate_failsBeforeRemovingSource() async throws {
        let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
            usageDate: "not-a-date"
        ))
        let activeStore = ActiveLockStore()
        let earnedStore = makeEarnedStore()
        let record = makeMixedRecord()
        _ = await activeStore.addShield(record)

        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: record.recordKey,
            store: activeStore,
            earnedTimeStore: earnedStore,
            fetchedDeviceID: overrideDeviceID,
            currentDeviceID: overrideDeviceID,
            currentUsageDate: "2026-07-15"
        )

        XCTAssertNil(outcome)
        XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "not-a-date"))
        let snapshot = await activeStore.allCurrent()
        let unchanged = try XCTUnwrap(snapshot.shields.first {
            $0.recordKey == record.recordKey
        })
        XCTAssertEqual(unchanged.sources, [.manual, .earnedTime])
        earnedStore.removeAll()
    }

    func test_nseMarkerOnlyOverride_persistsWithoutListIdentity() async throws {
        let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
            usageDate: "2026-07-15",
            listID: nil
        ))
        XCTAssertNil(command.target.listID)
        let activeStore = ActiveLockStore()
        let earnedStore = makeEarnedStore()

        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: ShieldRecord.makeRecordKey(
                tier: .savedList,
                targetKey: "?"
            ),
            store: activeStore,
            earnedTimeStore: earnedStore,
            fetchedDeviceID: overrideDeviceID,
            currentDeviceID: overrideDeviceID,
            currentUsageDate: "2026-07-15"
        )

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertTrue(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
        let snapshot = await activeStore.allCurrent()
        XCTAssertTrue(snapshot.shields.isEmpty)
        earnedStore.removeAll()
    }

    func test_nsePriorDayOverride_failsBeforeMarkerOrSourceRemoval() async throws {
        let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
            usageDate: "2026-07-14"
        ))
        let activeStore = ActiveLockStore()
        let earnedStore = makeEarnedStore()
        let record = makeMixedRecord()
        _ = await activeStore.addShield(record)

        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: record.recordKey,
            store: activeStore,
            earnedTimeStore: earnedStore,
            fetchedDeviceID: overrideDeviceID,
            currentDeviceID: overrideDeviceID,
            currentUsageDate: "2026-07-15"
        )

        XCTAssertNil(outcome)
        XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-14"))
        let staleDaySnapshot = await activeStore.allCurrent()
        let unchanged = try XCTUnwrap(staleDaySnapshot.shields.first {
            $0.recordKey == record.recordKey
        })
        XCTAssertEqual(unchanged.sources, [.manual, .earnedTime])
        earnedStore.removeAll()
    }

    func test_nseMissingCanonicalTimezone_failsBeforeMarkerOrSourceRemoval() async throws {
        let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
            usageDate: "2026-07-15"
        ))
        let activeStore = ActiveLockStore()
        let earnedStore = makeEarnedStore()
        let record = makeMixedRecord()
        _ = await activeStore.addShield(record)

        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: record.recordKey,
            store: activeStore,
            earnedTimeStore: earnedStore,
            fetchedDeviceID: overrideDeviceID,
            currentDeviceID: overrideDeviceID,
            currentUsageDate: nil
        )

        XCTAssertNil(outcome)
        XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
        let missingTimezoneSnapshot = await activeStore.allCurrent()
        let unchanged = try XCTUnwrap(missingTimezoneSnapshot.shields.first {
            $0.recordKey == record.recordKey
        })
        XCTAssertEqual(unchanged.sources, [.manual, .earnedTime])
        earnedStore.removeAll()
    }

    func test_nseIdentitySwitch_failsBeforeMarkerOrSourceRemoval() async throws {
        let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
            usageDate: "2026-07-15"
        ))
        let activeStore = ActiveLockStore()
        let earnedStore = makeEarnedStore()
        let record = makeMixedRecord()
        _ = await activeStore.addShield(record)
        let switchedDeviceID =
            UUID(uuidString: "00000000-0000-0000-0000-000000000499")!

        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: record.recordKey,
            store: activeStore,
            earnedTimeStore: earnedStore,
            fetchedDeviceID: overrideDeviceID,
            currentDeviceID: switchedDeviceID,
            currentUsageDate: "2026-07-15"
        )

        XCTAssertNil(outcome)
        XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
        let switchedIdentitySnapshot = await activeStore.allCurrent()
        let unchanged = try XCTUnwrap(switchedIdentitySnapshot.shields.first {
            $0.recordKey == record.recordKey
        })
        XCTAssertEqual(unchanged.sources, [.manual, .earnedTime])
        earnedStore.removeAll()
    }

    func test_nseEarnedReleaseWithoutOverrideMetadata_doesNotSuppressFutureLocks() async throws {
        let activeStore = ActiveLockStore()
        let earnedStore = makeEarnedStore()
        let record = makeMixedRecord()
        _ = await activeStore.addShield(record)
        let command = LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Locked set",
                listID: overrideListID,
                originalRequest: "pool raised",
                targetDisplay: "Locked set",
                unlockSources: ["earned_time"],
                earnedOverrideUsageDate: nil
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )

        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: record.recordKey,
            store: activeStore,
            earnedTimeStore: earnedStore
        )

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
        let snapshot = await activeStore.allCurrent()
        let remaining = try XCTUnwrap(snapshot.shields.first {
            $0.recordKey == record.recordKey
        })
        XCTAssertEqual(remaining.sources, [.manual])
        earnedStore.removeAll()
    }

    func test_nseMetadataUnshieldAll_preservesSeededState() async {
        await assertNSEFirewallPreservesSeededState(
            command: makeOverrideCommand(action: .unshieldAll),
            record: makeSeededRecord(
                tier: .savedList,
                targetKey: overrideListID.uuidString
            )
        )
    }

    func test_nseMetadataWrongTier_preservesSeededState() async {
        await assertNSEFirewallPreservesSeededState(
            command: makeOverrideCommand(
                tier: .category,
                categoryHint: "social"
            ),
            record: makeSeededRecord(tier: .category, targetKey: "social")
        )
    }

    func test_nseMetadataWrongAction_preservesSeededState() async {
        await assertNSEFirewallPreservesSeededState(
            command: makeOverrideCommand(
                action: .block,
                bundleID: "com.example.blocked"
            ),
            record: makeSeededRecord(
                tier: .savedList,
                targetKey: overrideListID.uuidString
            )
        )
    }

    func test_nseMetadataWrongSource_preservesSeededState() async {
        await assertNSEFirewallPreservesSeededState(
            command: makeOverrideCommand(unlockSources: ["manual"]),
            record: makeSeededRecord(
                tier: .savedList,
                targetKey: overrideListID.uuidString
            )
        )
    }

    private func assertAutomaticNSEShieldSurvivesManualUnshield(
        wireSource: String,
        expectedSource: ShieldSource
    ) async throws {
        let store = ActiveLockStore()
        let listID = UUID()
        let shield = LockCommand(
            id: UUID(),
            action: .shield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Locked set",
                listID: listID,
                originalRequest: "automatic lock",
                targetDisplay: "Locked set",
                targetChildID: UUID(),
                lockSource: wireSource
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )
        let record = NSEShieldRecordFactory.make(
            command: shield,
            tier: .savedList,
            targetKey: listID.uuidString,
            displayName: "Locked set",
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            expiresAt: nil
        )
        XCTAssertEqual(record.sources, [expectedSource])
        _ = await store.addShield(record)

        let manualUnshield = LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Locked set",
                listID: listID,
                originalRequest: "manual unlock",
                targetDisplay: "Locked set",
                unlockSources: ["manual"]
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )
        let outcome = await NSEUnshieldCommandApplier.apply(
            manualUnshield,
            recordKey: record.recordKey,
            store: store
        )

        XCTAssertEqual(outcome, .confirmed)
        let current = await store.allCurrent().shields
        let remaining = try XCTUnwrap(current.first(where: { $0.recordKey == record.recordKey }))
        XCTAssertEqual(remaining.sources, [expectedSource])
    }

    private func makeEarnedStore() -> EarnedTimeStore {
        EarnedTimeStore(
            suiteName: "test.override.nse.\(UUID().uuidString)",
            useInProcessLock: true
        )
    }

    private func makeMixedRecord() -> ShieldRecord {
        ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(
                tier: .savedList,
                targetKey: overrideListID.uuidString
            ),
            tier: .savedList,
            targetKey: overrideListID.uuidString,
            displayName: "Locked set",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "mixed lock",
            targetChildID: overrideDeviceID,
            sources: [.manual, .earnedTime]
        )
    }

    private func assertNSEFirewallPreservesSeededState(
        command: LockCommand,
        record: ShieldRecord
    ) async {
        let activeStore = ActiveLockStore()
        let earnedStore = makeEarnedStore()
        _ = await activeStore.addShield(record)

        _ = await NSELockMutationDispatcher.apply(
            command,
            recordKey: record.recordKey,
            store: activeStore,
            earnedTimeStore: earnedStore,
            fetchedDeviceID: overrideDeviceID,
            currentDeviceID: overrideDeviceID,
            currentUsageDate: "2026-07-15"
        )

        XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
        let snapshot = await activeStore.allCurrent()
        XCTAssertEqual(snapshot.shields.count, 1)
        XCTAssertEqual(snapshot.shields.first?.recordKey, record.recordKey)
        XCTAssertEqual(snapshot.shields.first?.sources, [.manual, .earnedTime])
        XCTAssertTrue(snapshot.blocks.isEmpty)
        earnedStore.removeAll()
    }

    private func makeOverrideCommand(
        action: CommandAction = .unshield,
        tier: ShieldTier = .savedList,
        unlockSources: [String] = ["earned_time"],
        bundleID: String? = nil,
        categoryHint: String? = nil
    ) -> LockCommand {
        LockCommand(
            id: UUID(),
            action: action,
            tier: tier,
            target: CommandTarget(
                bundleID: bundleID,
                listName: "Locked set",
                listID: overrideListID,
                categoryHint: categoryHint,
                originalRequest: "override today's screen time",
                targetDisplay: "Locked set",
                targetChildID: overrideDeviceID,
                unlockSources: unlockSources,
                earnedOverrideUsageDate: "2026-07-15"
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )
    }

    private func makeSeededRecord(
        tier: ShieldTier,
        targetKey: String
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey),
            tier: tier,
            targetKey: targetKey,
            displayName: "Seeded lock",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "seeded lock",
            targetChildID: overrideDeviceID,
            sources: [.manual, .earnedTime]
        )
    }

    private func overrideCommandJSON(
        usageDate: String,
        listID: UUID? = overrideListID
    ) -> Data {
        let listIDJSON = listID.map { "\"\($0.uuidString)\"" } ?? "null"
        return Data("""
        {
          "command_id": "00000000-0000-0000-0000-000000000403",
          "action": "unshield",
          "tier": "savedList",
          "duration_minutes": null,
          "issued_at": "2026-07-15T12:00:00Z",
          "unlock_sources": ["earned_time"],
          "target": {
            "list_id": \(listIDJSON),
            "list_name": "Locked set",
            "original_request": "override today's screen time",
            "target_display": "Locked set",
            "target_child_id": "\(overrideDeviceID.uuidString)",
            "unlock_sources": ["earned_time"],
            "earned_override_usage_date": "\(usageDate)"
          }
        }
        """.utf8)
    }
}

private let overrideListID =
    UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
private let overrideDeviceID =
    UUID(uuidString: "00000000-0000-0000-0000-000000000404")!
