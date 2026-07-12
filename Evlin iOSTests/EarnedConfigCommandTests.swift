import XCTest
import FamilyControls
@testable import Evlin_iOS

/// A4 merge-blocker fix — hermetic tests for the `earned_time_config` command path.
///
/// Three assertions:
///   T1 — `PollCommandDTO` decodes the nested `earned_time_config` payload correctly.
///   T2 — `CommandAction.earnedTimeConfig` has the right raw value and round-trips.
///   T3 — `CommandPoller` routes the command to the inline handler (NOT executeShield):
///          arm() and saveLockedSetID() are called with the correct values; no new
///          shield record is added to ActiveLockStore.
@MainActor
final class EarnedConfigCommandTests: XCTestCase {

    // MARK: - Fixture

    private func makeConfigJSON(
        commandID: String = "11111111-0000-0000-0000-000000000001",
        poolMinutes: Int = 90,
        capMinutes: Int = 60,
        listID: String = "AAAAAAAA-0000-0000-0000-000000000001",
        remainingMinutes: Int? = nil
    ) -> Data {
        let remainingField = remainingMinutes.map { ",\n            \"remaining_minutes\": \($0)" } ?? ""
        let raw = """
        {
          "command_id": "\(commandID)",
          "action": "earned_time_config",
          "tier": "earnedTime",
          "target": {
            "target_type": "earnedTime",
            "original_request": ""
          },
          "issued_at": "2026-06-23T10:00:00.000000+00:00",
          "earned_time_config": {
            "child_profile_id": "BBBBBBBB-0000-0000-0000-000000000001",
            "child_device_id": "CCCCCCCC-0000-0000-0000-000000000001",
            "effective_date": "2026-06-23",
            "usage_date": "2026-06-23",
            "timezone": "America/New_York",
            "daily_pool_minutes": \(poolMinutes),
            "device_cap_minutes": \(capMinutes),
            "earned_bucket_minutes": 10\(remainingField),
            "selected_set": {
              "list_id": "\(listID)",
              "recordKey": "savedList:\(listID)",
              "targetKey": "\(listID)",
              "has_tokens": true
            }
          }
        }
        """
        return Data(raw.utf8)
    }

    // MARK: - T1: Decode

    func test_pollCommandDTO_decodesEarnedTimeConfigPayload() throws {
        let data = makeConfigJSON(poolMinutes: 90, capMinutes: 60,
                                  listID: "AAAAAAAA-0000-0000-0000-000000000001")
        let dto = try JSONDecoder().decode(PollCommandDTO.self, from: data)

        XCTAssertEqual(dto.action, "earned_time_config")
        let cfg = try XCTUnwrap(dto.earned_time_config,
                                "PollCommandDTO.earned_time_config must not be nil")
        XCTAssertEqual(cfg.daily_pool_minutes, 90)
        XCTAssertEqual(cfg.device_cap_minutes, 60)
        XCTAssertNil(cfg.remaining_minutes,
                     "old-shape payloads (no remaining_minutes) must still decode")

        let sel = try XCTUnwrap(cfg.selected_set,
                                "earned_time_config.selected_set must not be nil")
        XCTAssertEqual(sel.list_id, "AAAAAAAA-0000-0000-0000-000000000001")
    }

    // Wave-2 Task 1 veto-staleness fix: DTO must decode the new optional
    // `remaining_minutes` field when the backend includes it on the wire.
    func test_pollCommandDTO_decodesRemainingMinutesWhenPresent() throws {
        let data = makeConfigJSON(poolMinutes: 90, capMinutes: 60, remainingMinutes: 37)
        let dto = try JSONDecoder().decode(PollCommandDTO.self, from: data)
        let cfg = try XCTUnwrap(dto.earned_time_config)
        XCTAssertEqual(cfg.remaining_minutes, 37)
    }

    // MARK: - T2: CommandAction enum

    func test_commandAction_earnedTimeConfig_rawValue() {
        XCTAssertEqual(CommandAction.earnedTimeConfig.rawValue, "earned_time_config",
                       "earnedTimeConfig.rawValue must be the wire string")
        XCTAssertEqual(CommandAction(rawValue: "earned_time_config"), .earnedTimeConfig,
                       "CommandAction must initialise from the wire string")
    }

    // MARK: - T3: Routing — config command must NOT reach executeShield

    func test_poller_earnedTimeConfig_doesNotRouteToExecuteShield() async throws {
        let store = EarnedTimeStore.shared
        store.removeAll()
        // Empty measurement selections must not arm; a persisted empty value
        // was the bug that made setup look complete while total/device usage
        // never produced DeviceActivity thresholds.
        store.saveMeasurementSelection(FamilyActivitySelection())

        let poller = CommandPoller.shared
        // Snapshot every mutable seam so tearDown can restore singleton state.
        let savedCommandsOverride  = poller.pollCommandsOverride
        let savedSaveListOverride   = poller.saveLockedSetIDOverride
        let savedArmOverride        = poller.armBudgetOverride
        let savedDeviceIDProvider   = poller.childDeviceIDProvider
        let savedOneShotOverride    = poller.oneShotPollOverride
        defer {
            poller.pollCommandsOverride   = savedCommandsOverride
            poller.saveLockedSetIDOverride = savedSaveListOverride
            poller.armBudgetOverride      = savedArmOverride
            poller.childDeviceIDProvider  = savedDeviceIDProvider
            poller.oneShotPollOverride    = savedOneShotOverride
            store.removeAll()
        }

        let deviceID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!
        poller.childDeviceIDProvider = { deviceID }
        // Clear any oneShotPollOverride so the real pollOnce() runs.
        poller.oneShotPollOverride = nil

        // Spy: record arm() invocations and their arguments.
        // Use MainActor-isolated vars — all closures run on MainActor (CommandPoller is @MainActor).
        var armCallCount = 0
        var armedPool: Int?
        var armedCap: Int?
        poller.armBudgetOverride = { pool, cap, _ in
            armCallCount += 1
            armedPool = pool
            armedCap  = cap
        }

        // Spy: record saveLockedSetID invocations and their argument.
        var saveCallCount = 0
        var savedListID: String?
        poller.saveLockedSetIDOverride = { id, _ in
            saveCallCount += 1
            savedListID = id
        }

        // Return one earned_time_config command from the fake network layer.
        poller.pollCommandsOverride = { _, _ in
            [try JSONDecoder().decode(PollCommandDTO.self,
                from: self.makeConfigJSON(poolMinutes: 90, capMinutes: 60,
                                          listID: "AAAAAAAA-0000-0000-0000-000000000001"))]
        }

        // Snapshot shield count before polling — must not grow.
        let shieldsBefore = await ActiveLockStore.shared.allCurrent().shields.count

        // pollOnceForCurrentDevice() sets currentDeviceID + currentAPIClient then
        // calls pollOnce() — the same path the silent-push handler uses.
        await poller.pollOnceForCurrentDevice()

        let shieldsAfter = await ActiveLockStore.shared.allCurrent().shields.count

        // No new shield records — command was NOT routed to executeShield.
        XCTAssertEqual(shieldsAfter, shieldsBefore,
                       "earned_time_config must not add shield records " +
                       "(command must not reach executeShield)")

        XCTAssertEqual(armCallCount, 0, "empty measurement selection must not arm")
        XCTAssertNil(armedPool)
        XCTAssertNil(armedCap)
        XCTAssertEqual(store.poolMinutes, 90,
                       "pool must persist so task-completion rearming uses the latest policy")
        XCTAssertEqual(store.capMinutes, 60,
                       "cap must persist so task-completion rearming uses the latest policy")

        // saveLockedSetID must be called once with the correct list_id.
        XCTAssertEqual(saveCallCount, 1, "EarnedTimeStore.saveLockedSetID must be called once")
        XCTAssertEqual(savedListID, "AAAAAAAA-0000-0000-0000-000000000001",
                       "saveLockedSetID must receive selected_set.list_id from payload")
    }

    func test_poller_earnedTimeConfig_doesNotArmWhileUsageCountingIsPaused() async throws {
        let store = EarnedTimeStore.shared
        store.removeAll()
        store.saveMeasurementSelection(FamilyActivitySelection())
        store.usageCountingAllowed = false

        let poller = CommandPoller.shared
        let savedCommandsOverride  = poller.pollCommandsOverride
        let savedSaveListOverride  = poller.saveLockedSetIDOverride
        let savedArmOverride       = poller.armBudgetOverride
        let savedMeasurableOverride = poller.hasMeasurableSelectionOverride
        let savedDeviceIDProvider  = poller.childDeviceIDProvider
        let savedOneShotOverride   = poller.oneShotPollOverride
        defer {
            poller.pollCommandsOverride   = savedCommandsOverride
            poller.saveLockedSetIDOverride = savedSaveListOverride
            poller.armBudgetOverride      = savedArmOverride
            poller.hasMeasurableSelectionOverride = savedMeasurableOverride
            poller.childDeviceIDProvider  = savedDeviceIDProvider
            poller.oneShotPollOverride    = savedOneShotOverride
            store.removeAll()
        }

        let deviceID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000005")!
        poller.childDeviceIDProvider = { deviceID }
        poller.oneShotPollOverride = nil
        poller.saveLockedSetIDOverride = { _, _ in }

        var armCallCount = 0
        poller.armBudgetOverride = { _, _, _ in armCallCount += 1 }
        poller.pollCommandsOverride = { _, _ in
            [try JSONDecoder().decode(PollCommandDTO.self,
                from: self.makeConfigJSON(poolMinutes: 90, capMinutes: 60))]
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(armCallCount, 0)
        XCTAssertEqual(store.poolMinutes, 90)
        XCTAssertEqual(store.capMinutes, 60)
    }

    func test_poller_earnedTimeConfigPersistsPolicyButDefersArmUntilAuthoritativeStateIsReady() async throws {
        let store = EarnedTimeStore.shared
        store.removeAll()
        store.saveMeasurementSelection(FamilyActivitySelection())

        let poller = CommandPoller.shared
        let savedCommandsOverride = poller.pollCommandsOverride
        let savedSaveListOverride = poller.saveLockedSetIDOverride
        let savedArmOverride = poller.armBudgetOverride
        let savedMeasurableOverride = poller.hasMeasurableSelectionOverride
        let savedDeviceIDProvider = poller.childDeviceIDProvider
        let savedOneShotOverride = poller.oneShotPollOverride
        defer {
            poller.pollCommandsOverride = savedCommandsOverride
            poller.saveLockedSetIDOverride = savedSaveListOverride
            poller.armBudgetOverride = savedArmOverride
            poller.hasMeasurableSelectionOverride = savedMeasurableOverride
            poller.childDeviceIDProvider = savedDeviceIDProvider
            poller.oneShotPollOverride = savedOneShotOverride
            store.removeAll()
        }

        let deviceID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000008")!
        poller.childDeviceIDProvider = { deviceID }
        poller.oneShotPollOverride = nil
        poller.saveLockedSetIDOverride = { _, _ in }
        poller.hasMeasurableSelectionOverride = { true }
        var armCallCount = 0
        poller.armBudgetOverride = { _, _, _ in armCallCount += 1 }
        poller.pollCommandsOverride = { _, _ in
            [try JSONDecoder().decode(PollCommandDTO.self,
                from: self.makeConfigJSON(poolMinutes: 90, capMinutes: 60,
                                          remainingMinutes: 60))]
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(armCallCount, 0)
        XCTAssertEqual(store.poolMinutes, 90)
        XCTAssertEqual(store.capMinutes, 60)
        XCTAssertFalse(store.isAuthoritativeStateReady(deviceID: deviceID))
    }

    func test_poller_consecutiveEarnedTimeConfigsPersistLatestPoolAndCapWithoutEmptyArm() async throws {
        let store = EarnedTimeStore.shared
        store.removeAll()
        store.saveMeasurementSelection(FamilyActivitySelection())

        let poller = CommandPoller.shared
        let savedCommandsOverride  = poller.pollCommandsOverride
        let savedSaveListOverride   = poller.saveLockedSetIDOverride
        let savedArmOverride        = poller.armBudgetOverride
        let savedDeviceIDProvider   = poller.childDeviceIDProvider
        let savedOneShotOverride    = poller.oneShotPollOverride
        defer {
            poller.pollCommandsOverride   = savedCommandsOverride
            poller.saveLockedSetIDOverride = savedSaveListOverride
            poller.armBudgetOverride      = savedArmOverride
            poller.childDeviceIDProvider  = savedDeviceIDProvider
            poller.oneShotPollOverride    = savedOneShotOverride
            store.removeAll()
        }

        let deviceID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000002")!
        poller.childDeviceIDProvider = { deviceID }
        poller.oneShotPollOverride = nil

        var armCalls: [(pool: Int, cap: Int)] = []
        poller.armBudgetOverride = { pool, cap, _ in
            armCalls.append((pool, cap))
        }
        poller.saveLockedSetIDOverride = { _, _ in }

        let first = try JSONDecoder().decode(PollCommandDTO.self, from: makeConfigJSON(
            commandID: "11111111-0000-0000-0000-000000000101",
            poolMinutes: 120,
            capMinutes: 90,
            listID: "AAAAAAAA-0000-0000-0000-000000000101"
        ))
        let second = try JSONDecoder().decode(PollCommandDTO.self, from: makeConfigJSON(
            commandID: "11111111-0000-0000-0000-000000000102",
            poolMinutes: 60,
            capMinutes: 45,
            listID: "AAAAAAAA-0000-0000-0000-000000000102"
        ))
        var responses = [[first], [second]]
        poller.pollCommandsOverride = { _, _ in
            responses.isEmpty ? [] : responses.removeFirst()
        }

        await poller.pollOnceForCurrentDevice()
        await poller.pollOnceForCurrentDevice()

        XCTAssertTrue(armCalls.isEmpty, "empty measurement selection must not arm")
        XCTAssertEqual(store.poolMinutes, 60)
        XCTAssertEqual(store.capMinutes, 45)
    }

    func test_poller_earnedTimeConfigUsesAcceptedEstimateInsteadOfRawPhantom() async throws {
        let store = EarnedTimeStore.shared
        store.removeAll()
        store.saveMeasurementSelection(FamilyActivitySelection())
        store.latestDeviceEstimate = 25
        store.acceptedUsageDate = "2026-07-10"
        store.acceptedEstimateMinutes = 0
        store.earnedUsageOffsetMinutes = 0

        let poller = CommandPoller.shared
        let savedCommandsOverride  = poller.pollCommandsOverride
        let savedSaveListOverride  = poller.saveLockedSetIDOverride
        let savedArmOverride       = poller.armBudgetOverride
        let savedMeasurableOverride = poller.hasMeasurableSelectionOverride
        let savedDeviceIDProvider  = poller.childDeviceIDProvider
        let savedOneShotOverride   = poller.oneShotPollOverride
        defer {
            poller.pollCommandsOverride   = savedCommandsOverride
            poller.saveLockedSetIDOverride = savedSaveListOverride
            poller.armBudgetOverride      = savedArmOverride
            poller.hasMeasurableSelectionOverride = savedMeasurableOverride
            poller.childDeviceIDProvider  = savedDeviceIDProvider
            poller.oneShotPollOverride    = savedOneShotOverride
            store.removeAll()
        }

        let deviceID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000006")!
        poller.childDeviceIDProvider = { deviceID }
        store.markAuthoritativeStateReady(deviceID: deviceID)
        poller.oneShotPollOverride = nil
        poller.saveLockedSetIDOverride = { _, _ in }
        poller.hasMeasurableSelectionOverride = { true }
        var armedPolicy: (pool: Int, cap: Int)?
        poller.armBudgetOverride = { pool, cap, _ in
            armedPolicy = (pool, cap)
        }
        poller.pollCommandsOverride = { _, _ in
            [try JSONDecoder().decode(PollCommandDTO.self,
                from: self.makeConfigJSON(poolMinutes: 120, capMinutes: 120,
                                          remainingMinutes: 115))]
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(store.poolMinutes, 120)
        XCTAssertEqual(store.capMinutes, 120)
        XCTAssertEqual(store.earnedUsageOffsetMinutes, 0,
                       "raw extension usage must not become the config re-arm baseline")
        XCTAssertEqual(armedPolicy?.pool, 120)
        XCTAssertEqual(armedPolicy?.cap, 120)
    }

    func test_poller_earnedTimeConfigArmsFromNonBucketAcceptedOffset() async throws {
        let store = EarnedTimeStore.shared
        store.removeAll()
        store.saveMeasurementSelection(FamilyActivitySelection())
        store.latestDeviceEstimate = 25
        store.acceptedUsageDate = "2026-07-10"
        store.acceptedEstimateMinutes = 7
        store.earnedUsageOffsetMinutes = 3

        let poller = CommandPoller.shared
        let savedCommandsOverride = poller.pollCommandsOverride
        let savedSaveListOverride = poller.saveLockedSetIDOverride
        let savedArmOverride = poller.armBudgetOverride
        let savedMeasurableOverride = poller.hasMeasurableSelectionOverride
        let savedDeviceIDProvider = poller.childDeviceIDProvider
        let savedOneShotOverride = poller.oneShotPollOverride
        defer {
            poller.pollCommandsOverride = savedCommandsOverride
            poller.saveLockedSetIDOverride = savedSaveListOverride
            poller.armBudgetOverride = savedArmOverride
            poller.hasMeasurableSelectionOverride = savedMeasurableOverride
            poller.childDeviceIDProvider = savedDeviceIDProvider
            poller.oneShotPollOverride = savedOneShotOverride
            store.removeAll()
        }

        let deviceID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000007")!
        poller.childDeviceIDProvider = { deviceID }
        store.markAuthoritativeStateReady(deviceID: deviceID)
        poller.oneShotPollOverride = nil
        poller.saveLockedSetIDOverride = { _, _ in }
        poller.hasMeasurableSelectionOverride = { true }
        var armedPolicy: (pool: Int, cap: Int)?
        poller.armBudgetOverride = { pool, cap, _ in
            armedPolicy = (pool, cap)
        }
        poller.pollCommandsOverride = { _, _ in
            [try JSONDecoder().decode(PollCommandDTO.self,
                from: self.makeConfigJSON(poolMinutes: 120, capMinutes: 120,
                                          remainingMinutes: 113))]
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(store.earnedUsageOffsetMinutes, 3,
                       "policy capture is not a successful monitor installation")
        XCTAssertEqual(armedPolicy?.pool, 113)
        XCTAssertEqual(armedPolicy?.cap, 113)
    }

    // MARK: - Wave-2 Task 1 veto-staleness fix: backendRemainingAtLastSync source

    /// When the wire payload carries `remaining_minutes`, it must be preferred
    /// over the on-device-derived `min(pool,cap) - latestDeviceEstimate` value
    /// — that derived formula is what went stale within the freshness window
    /// and could wrongly suppress a legitimate at-budget local self-lock.
    func test_poller_earnedTimeConfig_prefersWireRemainingOverDerived() async throws {
        let store = EarnedTimeStore.shared
        store.removeAll()
        store.saveMeasurementSelection(FamilyActivitySelection())
        // Device's own estimate would derive min(90,60) - 5 = 55 if used — the
        // wire value (12) must win instead.
        store.latestDeviceEstimate = 5

        let poller = CommandPoller.shared
        let savedCommandsOverride  = poller.pollCommandsOverride
        let savedSaveListOverride  = poller.saveLockedSetIDOverride
        let savedArmOverride       = poller.armBudgetOverride
        let savedDeviceIDProvider  = poller.childDeviceIDProvider
        let savedOneShotOverride   = poller.oneShotPollOverride
        defer {
            poller.pollCommandsOverride   = savedCommandsOverride
            poller.saveLockedSetIDOverride = savedSaveListOverride
            poller.armBudgetOverride      = savedArmOverride
            poller.childDeviceIDProvider  = savedDeviceIDProvider
            poller.oneShotPollOverride    = savedOneShotOverride
            store.removeAll()
        }

        let deviceID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000003")!
        poller.childDeviceIDProvider = { deviceID }
        poller.oneShotPollOverride = nil
        poller.armBudgetOverride = { _, _, _ in }
        poller.saveLockedSetIDOverride = { _, _ in }

        poller.pollCommandsOverride = { _, _ in
            [try JSONDecoder().decode(PollCommandDTO.self,
                from: self.makeConfigJSON(poolMinutes: 90, capMinutes: 60,
                                          remainingMinutes: 12))]
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(store.backendRemainingAtLastSync, 12,
                       "wire remaining_minutes must win over the derived estimate")
    }

    /// Old-shape payloads (no `remaining_minutes`) derive remaining from the
    /// accepted baseline, never from an unaccepted raw extension estimate.
    func test_poller_earnedTimeConfig_fallsBackToAcceptedOffsetWhenWireAbsent() async throws {
        let store = EarnedTimeStore.shared
        store.removeAll()
        store.saveMeasurementSelection(FamilyActivitySelection())
        store.latestDeviceEstimate = 25
        store.acceptedEstimateMinutes = 7
        store.earnedUsageOffsetMinutes = 3

        let poller = CommandPoller.shared
        let savedCommandsOverride  = poller.pollCommandsOverride
        let savedSaveListOverride  = poller.saveLockedSetIDOverride
        let savedArmOverride       = poller.armBudgetOverride
        let savedDeviceIDProvider  = poller.childDeviceIDProvider
        let savedOneShotOverride   = poller.oneShotPollOverride
        defer {
            poller.pollCommandsOverride   = savedCommandsOverride
            poller.saveLockedSetIDOverride = savedSaveListOverride
            poller.armBudgetOverride      = savedArmOverride
            poller.childDeviceIDProvider  = savedDeviceIDProvider
            poller.oneShotPollOverride    = savedOneShotOverride
            store.removeAll()
        }

        let deviceID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000004")!
        poller.childDeviceIDProvider = { deviceID }
        poller.oneShotPollOverride = nil
        poller.armBudgetOverride = { _, _, _ in }
        poller.saveLockedSetIDOverride = { _, _ in }

        poller.pollCommandsOverride = { _, _ in
            [try JSONDecoder().decode(PollCommandDTO.self,
                from: self.makeConfigJSON(poolMinutes: 90, capMinutes: 60,
                                          remainingMinutes: nil))]
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(store.backendRemainingAtLastSync, 53,
                       "no wire value present -> min(pool,cap) - accepted offset")
    }
}
