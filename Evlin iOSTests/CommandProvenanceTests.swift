import XCTest
import FamilyControls
@testable import Evlin_iOS

/// Task B2 — lock_source / unlock_sources provenance end-to-end.
///
/// Covers the full wire path:
///   raw poll JSON → PollCommandDTO → CommandPoller.lockCommand(from:) → LockCommand
///   → ActionExecutor.shieldSources(fromWireLockSource:) → ShieldRecord.sources
///   → ActiveLockStore.removeSource (unshield path)
///
/// All tests are pure-logic: no device features, no real shields applied.
/// @MainActor because CommandPoller.lockCommand(from:) is main-actor isolated.
@MainActor
final class CommandProvenanceTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal valid PollCommandDTO JSON. Caller injects optional lock_source /
    /// target-level lock_source / unlock_sources fields.
    private func pollJSON(
        topLevelLockSource: String? = nil,
        targetLockSource: String? = nil,
        unlockSources: [String]? = nil,
        earnedOverrideUsageDate: String? = nil
    ) -> Data {
        var topLevel = ""
        if let s = topLevelLockSource {
            topLevel = #","lock_source":"\#(s)""#
        }
        if let us = unlockSources {
            let arr = us.map { #""\#($0)""# }.joined(separator: ",")
            topLevel += #","unlock_sources":[\#(arr)]"#
        }

        var targetExtra = ""
        if let s = targetLockSource {
            targetExtra += #","lock_source":"\#(s)""#
        }
        if let earnedOverrideUsageDate {
            targetExtra += #","earned_override_usage_date":"\#(earnedOverrideUsageDate)""#
        }

        let action = unlockSources == nil ? "shield" : "unshield"
        let request = unlockSources == nil ? "lock games" : "unlock games"

        let json = """
        {
          "command_id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "action": "\(action)",
          "tier": "savedList",
          "issued_at": "2026-01-01T00:00:00Z",
          "target": {
            "list_id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            "list_name": "Games",
            "original_request": "\(request)"\(targetExtra)
          }\(topLevel)
        }
        """
        return Data(json.utf8)
    }

    private func decode(_ data: Data) throws -> PollCommandDTO {
        try JSONDecoder().decode(PollCommandDTO.self, from: data)
    }

    private func earnedConfigJSON(
        deviceID: UUID,
        newListID: UUID,
        earnedOverrideUsageDate: String
    ) -> Data {
        Data("""
        {
          "command_id": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
          "action": "earned_time_config",
          "tier": "earnedTime",
          "issued_at": "2026-07-15T12:00:00Z",
          "target": {
            "target_type": "earnedTime",
            "target_child_id": "\(deviceID.uuidString)",
            "original_request": "sync earned policy",
            "earned_override_usage_date": "\(earnedOverrideUsageDate)"
          },
          "earned_time_config": {
            "child_device_id": "\(deviceID.uuidString)",
            "effective_date": "2026-07-15",
            "usage_date": "2026-07-15",
            "timezone": "America/New_York",
            "daily_pool_minutes": 90,
            "device_cap_minutes": 60,
            "earned_bucket_minutes": 10,
            "remaining_minutes": 41,
            "selected_set": {
              "list_id": "\(newListID.uuidString)",
              "recordKey": "savedList:\(newListID.uuidString)",
              "targetKey": "\(newListID.uuidString)",
              "has_tokens": true
            }
          }
        }
        """.utf8)
    }

    private func makeRecord(
        recordKey: String = "savedList:BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
        targetKey: String = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
        sources: Set<ShieldSource>
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: recordKey,
            tier: .savedList,
            targetKey: targetKey,
            displayName: "Games",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_750_000_000),
            expiresAt: nil,
            originalRequest: "lock games",
            targetChildID: UUID(),
            sources: sources
        )
    }

    // MARK: - DTO decode: top-level lock_source

    func test_dto_topLevel_lockSource_earnedTime_decodesCorrectly() throws {
        let dto = try decode(pollJSON(topLevelLockSource: "earned_time"))
        XCTAssertEqual(dto.lock_source, "earned_time",
                       "Top-level lock_source must decode from PollCommandDTO")
    }

    func test_dto_topLevel_lockSource_manual_decodesCorrectly() throws {
        let dto = try decode(pollJSON(topLevelLockSource: "manual"))
        XCTAssertEqual(dto.lock_source, "manual")
    }

    func test_dto_absent_lockSource_isNil() throws {
        let dto = try decode(pollJSON())
        XCTAssertNil(dto.lock_source, "Absent lock_source must decode as nil")
    }

    // MARK: - DTO decode: target-level lock_source

    func test_dto_targetLevel_lockSource_decodesCorrectly() throws {
        let dto = try decode(pollJSON(targetLockSource: "earned_time"))
        XCTAssertEqual(dto.target.lock_source, "earned_time",
                       "target.lock_source must decode from PollTargetDTO")
    }

    // MARK: - CommandPoller.lockCommand: top-level takes precedence

    func test_lockCommand_topLevel_earnedTime_isCarriedThrough() throws {
        let dto = try decode(pollJSON(topLevelLockSource: "earned_time", targetLockSource: "manual"))
        let cmd = CommandPoller.lockCommand(from: dto)
        XCTAssertEqual(cmd.target.lockSource, "earned_time",
                       "Top-level lock_source must shadow target.lock_source (spec §5.4)")
    }

    func test_lockCommand_onlyTargetLevel_lockSource_fallbackMapped() throws {
        let dto = try decode(pollJSON(targetLockSource: "earned_time"))
        let cmd = CommandPoller.lockCommand(from: dto)
        XCTAssertEqual(cmd.target.lockSource, "earned_time",
                       "target.lock_source fallback must be used when top-level is absent")
    }

    func test_lockCommand_bothAbsent_lockSourceIsNil() throws {
        let dto = try decode(pollJSON())
        let cmd = CommandPoller.lockCommand(from: dto)
        XCTAssertNil(cmd.target.lockSource, "Both absent → lockSource must be nil")
    }

    // MARK: - CommandPoller.lockCommand: unlock_sources

    func test_lockCommand_unlockSources_areCarriedThrough() throws {
        let dto = try decode(pollJSON(unlockSources: ["manual", "earned_time"]))
        let cmd = CommandPoller.lockCommand(from: dto)
        XCTAssertEqual(
            cmd.target.unlockSources?.sorted(),
            ["earned_time", "manual"],
            "unlock_sources must be threaded through to LockCommand"
        )
    }

    func test_lockCommand_absent_unlockSources_isNil() throws {
        let dto = try decode(pollJSON())
        let cmd = CommandPoller.lockCommand(from: dto)
        XCTAssertNil(cmd.target.unlockSources, "Absent unlock_sources must be nil")
    }

    func test_overrideUsageDate_survivesPollDTOAndLockCommandMapping() throws {
        let dto = try decode(pollJSON(
            unlockSources: ["earned_time"],
            earnedOverrideUsageDate: "2026-07-15"
        ))
        let command = CommandPoller.lockCommand(from: dto)
        XCTAssertEqual(command.target.earnedOverrideUsageDate, "2026-07-15")
    }

    func test_absentOverrideUsageDate_staysNilForPolicyRaiseCompatibility() throws {
        let dto = try decode(pollJSON(unlockSources: ["earned_time"]))
        XCTAssertNil(CommandPoller.lockCommand(from: dto).target.earnedOverrideUsageDate)
    }

    func test_poller_metadataBearingEarnedConfig_failsMalformedWithoutMutation() async throws {
        let deviceID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let oldListID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let newListID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let command = try decode(earnedConfigJSON(
            deviceID: deviceID,
            newListID: newListID,
            earnedOverrideUsageDate: "2026-07-15"
        ))
        let store = EarnedTimeStore.shared
        let poller = CommandPoller.shared

        let savedCommands = poller.pollCommandsOverride
        let savedSaveList = poller.saveLockedSetIDOverride
        let savedRekey = poller.afterRekeyShieldRecord
        let savedArm = poller.armBudgetOverride
        let savedStop = poller.stopEarnedBudgetOverride
        let savedConfirmedAck = poller.ackEarnedTimeConfigOverride
        let savedMalformedAck = poller.ackMalformedPollOverride
        let savedMeasurable = poller.hasMeasurableSelectionOverride
        let savedDeviceProvider = poller.childDeviceIDProvider
        let savedOneShot = poller.oneShotPollOverride
        defer {
            poller.pollCommandsOverride = savedCommands
            poller.saveLockedSetIDOverride = savedSaveList
            poller.afterRekeyShieldRecord = savedRekey
            poller.armBudgetOverride = savedArm
            poller.stopEarnedBudgetOverride = savedStop
            poller.ackEarnedTimeConfigOverride = savedConfirmedAck
            poller.ackMalformedPollOverride = savedMalformedAck
            poller.hasMeasurableSelectionOverride = savedMeasurable
            poller.childDeviceIDProvider = savedDeviceProvider
            poller.oneShotPollOverride = savedOneShot
            store.removeAll()
        }

        store.removeAll()
        store.saveLockedSetID(oldListID.uuidString, tokenData: nil)
        store.poolMinutes = 31
        store.capMinutes = 29
        store.backendRemainingAtLastSync = 23
        let seededSyncAt = Date(timeIntervalSince1970: 1_752_580_800)
        store.lastBackendSyncAt = seededSyncAt
        store.latestDeviceEstimate = 19
        store.acceptedUsageDate = "2026-07-15"
        store.acceptedEstimateMinutes = 17
        store.earnedUsageOffsetMinutes = 13
        store.usageCountingAllowed = false
        store.saveMeasurementSelection(FamilyActivitySelection())

        _ = await ActiveLockStore.shared.unshieldAll()
        let record = makeRecord(
            recordKey: ShieldRecord.makeRecordKey(
                tier: .savedList,
                targetKey: oldListID.uuidString
            ),
            targetKey: oldListID.uuidString,
            sources: [.manual, .earnedTime]
        )
        _ = await ActiveLockStore.shared.addShield(record)

        var rekeyCount = 0
        var armCount = 0
        var stopCount = 0
        var confirmedAckCount = 0
        var malformedAckCount = 0
        var malformedAckStatus: String?
        var malformedAckReason: String?
        var malformedAckCommandID: UUID?
        poller.childDeviceIDProvider = { deviceID }
        poller.oneShotPollOverride = nil
        poller.pollCommandsOverride = { _, _ in [command] }
        poller.saveLockedSetIDOverride = nil
        poller.afterRekeyShieldRecord = { _, _ in rekeyCount += 1 }
        poller.armBudgetOverride = { _, _, _ in armCount += 1 }
        poller.stopEarnedBudgetOverride = { stopCount += 1 }
        poller.hasMeasurableSelectionOverride = { true }
        poller.ackEarnedTimeConfigOverride = { _, _ in confirmedAckCount += 1 }
        poller.ackMalformedPollOverride = { commandID, status, detail, _ in
            malformedAckCount += 1
            malformedAckCommandID = commandID
            malformedAckStatus = status
            malformedAckReason = detail?["reason"] as? String
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(rekeyCount, 0)
        XCTAssertEqual(store.lockedSetID, oldListID.uuidString)
        XCTAssertEqual(store.poolMinutes, 31)
        XCTAssertEqual(store.capMinutes, 29)
        XCTAssertEqual(store.backendRemainingAtLastSync, 23)
        XCTAssertEqual(store.lastBackendSyncAt, seededSyncAt)
        XCTAssertEqual(store.latestDeviceEstimate, 19)
        XCTAssertEqual(store.acceptedUsageDate, "2026-07-15")
        XCTAssertEqual(store.acceptedEstimateMinutes, 17)
        XCTAssertEqual(store.earnedUsageOffsetMinutes, 13)
        XCTAssertFalse(store.usageCountingAllowed)
        XCTAssertFalse(store.isOverridden(forUsageDate: "2026-07-15"))
        XCTAssertEqual(armCount, 0)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(confirmedAckCount, 0)
        XCTAssertEqual(malformedAckCount, 1)
        XCTAssertEqual(malformedAckCommandID, command.command_id)
        XCTAssertEqual(malformedAckStatus, "failed")
        XCTAssertEqual(malformedAckReason, "malformed")

        let snapshot = await ActiveLockStore.shared.allCurrent()
        XCTAssertEqual(snapshot.shields.count, 1)
        XCTAssertEqual(snapshot.shields.first?.recordKey, record.recordKey)
        XCTAssertEqual(snapshot.shields.first?.sources, [.manual, .earnedTime])
        XCTAssertTrue(snapshot.blocks.isEmpty)
        _ = await ActiveLockStore.shared.unshieldAll()
    }

    // MARK: - ActionExecutor.shieldSources mapping

    func test_shieldSources_earnedTime_returnsEarnedTimeSet() {
        let sources = ActionExecutor.shieldSources(fromWireLockSource: "earned_time")
        XCTAssertEqual(sources, [.earnedTime],
                       "\"earned_time\" wire value must map to [.earnedTime]")
    }

    func test_shieldSources_manual_returnsManualSet() {
        let sources = ActionExecutor.shieldSources(fromWireLockSource: "manual")
        XCTAssertEqual(sources, [.manual],
                       "\"manual\" wire value must map to [.manual]")
    }

    func test_shieldSources_nil_defaultsToManual() {
        let sources = ActionExecutor.shieldSources(fromWireLockSource: nil)
        XCTAssertEqual(sources, [.manual],
                       "nil lock_source must default to [.manual]")
    }

    func test_shieldSources_unknownValue_defaultsToManual() {
        let sources = ActionExecutor.shieldSources(fromWireLockSource: "future_unknown")
        XCTAssertEqual(sources, [.manual],
                       "Unknown wire values must default to [.manual] for forward-compat")
    }

    // MARK: - Full decode path: JSON → LockCommand lockSource field

    func test_fullPath_earnedTime_lockSourceCarriedFromTopLevelJSON() throws {
        // Tests the complete stack: raw JSON bytes → PollCommandDTO → LockCommand.
        let dto = try decode(pollJSON(topLevelLockSource: "earned_time"))
        let cmd = CommandPoller.lockCommand(from: dto)
        // lockSource is a computed accessor on LockCommand that reads target.lockSource.
        XCTAssertEqual(cmd.lockSource, "earned_time",
                       "Full path: top-level earned_time must appear on LockCommand.lockSource")
    }

    func test_fullPath_earnedTime_shieldSourcesContainsEarnedTime() throws {
        let dto = try decode(pollJSON(topLevelLockSource: "earned_time"))
        let cmd = CommandPoller.lockCommand(from: dto)
        let sources = ActionExecutor.shieldSources(fromWireLockSource: cmd.lockSource)
        XCTAssertTrue(sources.contains(.earnedTime),
                      "Full path: earned_time JSON → shieldSources must contain .earnedTime")
    }

    func test_fullPath_manual_shieldSourcesContainsManual() throws {
        let dto = try decode(pollJSON(topLevelLockSource: "manual"))
        let cmd = CommandPoller.lockCommand(from: dto)
        let sources = ActionExecutor.shieldSources(fromWireLockSource: cmd.lockSource)
        XCTAssertEqual(sources, [.manual],
                       "Full path: manual JSON → shieldSources must be [.manual]")
    }

    func test_fullPath_missingLockSource_shieldSourcesIsManual() throws {
        let dto = try decode(pollJSON())
        let cmd = CommandPoller.lockCommand(from: dto)
        let sources = ActionExecutor.shieldSources(fromWireLockSource: cmd.lockSource)
        XCTAssertEqual(sources, [.manual],
                       "Full path: absent lock_source → shieldSources defaults to [.manual]")
    }

    // MARK: - Unshield: unlock_sources removes only named sources

    func test_unshield_unlockSourcesManual_onMixedRecord_leavesEarnedTime() async {
        let store = ActiveLockStore()
        let key = "savedList:BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        // Seed a record with both .manual and .earnedTime.
        let record = makeRecord(recordKey: key, sources: [.manual, .earnedTime])
        _ = await store.addShield(record)

        // Simulate unshield with unlock_sources:["manual"] — removes only .manual.
        await store.removeSource(.manual, fromRecordKey: key)

        let shields = await store.allCurrent().shields
        let remaining = shields.first(where: { $0.recordKey == key })
        XCTAssertNotNil(remaining, "Record must survive when .earnedTime source remains")
        XCTAssertEqual(remaining?.sources, [.earnedTime],
                       "After removing .manual, only .earnedTime must remain")
    }

    func test_unshield_unlockSourcesEarnedTime_onMixedRecord_leavesManual() async {
        let store = ActiveLockStore()
        let key = "savedList:BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        let record = makeRecord(recordKey: key, sources: [.manual, .earnedTime])
        _ = await store.addShield(record)

        await store.removeSource(.earnedTime, fromRecordKey: key)

        let shields = await store.allCurrent().shields
        let remaining = shields.first(where: { $0.recordKey == key })
        XCTAssertNotNil(remaining, "Record must survive when .manual source remains")
        XCTAssertEqual(remaining?.sources, [.manual],
                       "After removing .earnedTime, only .manual must remain")
    }

    func test_unshield_noUnlockSources_removesWholeRecord_legacy() async {
        let store = ActiveLockStore()
        let key = "savedList:BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        let record = makeRecord(recordKey: key, sources: [.manual, .earnedTime])
        _ = await store.addShield(record)

        // Legacy unshield: no unlock_sources → whole-record removeShield.
        let removed = await store.removeShield(recordKey: key)
        XCTAssertNotNil(removed, "removeShield must return the removed record")

        let shields = await store.allCurrent().shields
        XCTAssertFalse(
            shields.contains(where: { $0.recordKey == key }),
            "Legacy unshield (no unlock_sources) must remove the entire record"
        )
    }

    // MARK: - unlock_sources wire decode

    func test_dto_unlockSources_earnedTime_decodesCorrectly() throws {
        let dto = try decode(pollJSON(unlockSources: ["earned_time"]))
        XCTAssertEqual(dto.unlock_sources, ["earned_time"])
    }

    func test_dto_unlockSources_multipleValues_decodesCorrectly() throws {
        let dto = try decode(pollJSON(unlockSources: ["manual", "earned_time"]))
        XCTAssertEqual(dto.unlock_sources?.sorted(), ["earned_time", "manual"])
    }
}
