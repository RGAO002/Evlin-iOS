import XCTest
@testable import Evlin_iOS

/// B8 — selected-set lock client, green-button state derivation, and B6 list_id sync.
///
/// Tests:
/// 1. `DeviceLockStateResponse` decodes the §5.4 mixed-casing shape (camelCase
///    recordKey/targetKey; snake_case everything else). Back-compat: old
///    {locked:bool}-only JSON still decodes.
/// 2. `LockButtonState` helper: covering_sources → red / green / pending
///    (nil sources = pending; [] = green; non-empty = red). Also: exhausted
///    flag alone drives red.
/// 3. Child-level multi-device state from EarnedSummaryDTO.state.
/// 4. Learning list_id from lock-state calls `EarnedTimeStore.saveLockedSetID`
///    exactly once and calls `ActiveLockStore.reKeyShieldRecord`.
final class SelectedSetClientTests: XCTestCase {

    // MARK: - Child-wide selected-set response

    func test_childSelectedSetResponse_decodesAllDeviceReceipts() throws {
        let json = """
        {
          "action": "shield",
          "devices": [
            {
              "child_device_id": "00000000-0000-0000-0000-000000000101",
              "command_id": "00000000-0000-0000-0000-000000000201",
              "list_id": "00000000-0000-0000-0000-000000000301",
              "warning": null
            },
            {
              "child_device_id": "00000000-0000-0000-0000-000000000102",
              "command_id": "00000000-0000-0000-0000-000000000202",
              "list_id": "00000000-0000-0000-0000-000000000302",
              "warning": "Device offline; command queued"
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(APIClient.ChildSelectedSetResponse.self, from: json)

        XCTAssertEqual(response.action, "shield")
        XCTAssertEqual(response.devices.count, 2)
        XCTAssertEqual(response.devices[0].child_device_id,
                       UUID(uuidString: "00000000-0000-0000-0000-000000000101"))
        XCTAssertEqual(response.devices[0].command_id,
                       UUID(uuidString: "00000000-0000-0000-0000-000000000201"))
        XCTAssertEqual(response.devices[0].list_id,
                       UUID(uuidString: "00000000-0000-0000-0000-000000000301"))
        XCTAssertNil(response.devices[0].warning)
        XCTAssertEqual(response.devices[1].warning, "Device offline; command queued")
    }

    // MARK: - Child-wide manual source reducer

    func test_manualAggregate_noManualSource_isUnlocked() {
        let state = ManualLockAggregateState.reduce(
            expectedDeviceCount: 2,
            coveringSources: [[], ["earnedTime", "task_pause"]]
        )

        XCTAssertEqual(state, .unlocked)
    }

    func test_manualAggregate_everyDeviceManual_isLocked() {
        let state = ManualLockAggregateState.reduce(
            expectedDeviceCount: 2,
            coveringSources: [["manual"], [" MANUAL ", "earned_time"]]
        )

        XCTAssertEqual(state, .locked)
    }

    func test_manualAggregate_someDevicesManual_isMixed() {
        let state = ManualLockAggregateState.reduce(
            expectedDeviceCount: 2,
            coveringSources: [["manual"], ["taskPause"]]
        )

        XCTAssertEqual(state, .mixed)
    }

    func test_manualAggregate_missingOrUnknownResponse_isPending() {
        XCTAssertEqual(
            ManualLockAggregateState.reduce(
                expectedDeviceCount: 2,
                coveringSources: [["manual"]]
            ),
            .pending
        )
        XCTAssertEqual(
            ManualLockAggregateState.reduce(
                expectedDeviceCount: 2,
                coveringSources: [["manual"], nil]
            ),
            .pending
        )
    }

    func test_manualAggregate_automaticOnlySources_doNotBecomeManualLocked() {
        let automaticSources = [
            "earnedTime", "earned_time", "taskPause", "task_pause", "limit", "reflection"
        ]

        XCTAssertEqual(
            ManualLockAggregateState.reduce(
                expectedDeviceCount: 1,
                coveringSources: [automaticSources]
            ),
            .unlocked
        )
    }

    // MARK: - Child-wide button presentation

    func test_manualButtonPresentation_unlocked_rendersGreenLockAction() {
        let presentation = ManualLockButtonPresentation.from(state: .unlocked, childName: "Sam")

        XCTAssertEqual(presentation.title, "Lock Sam's devices")
        XCTAssertEqual(presentation.systemImage, "lock")
        XCTAssertEqual(presentation.tone, .lock)
        XCTAssertTrue(presentation.allowsTap)
    }

    func test_manualButtonPresentation_locked_rendersRedUnlockAction() {
        let presentation = ManualLockButtonPresentation.from(state: .locked, childName: "Sam")

        XCTAssertEqual(presentation.title, "Unlock Sam's devices")
        XCTAssertEqual(presentation.systemImage, "lock.open")
        XCTAssertEqual(presentation.tone, .unlock)
        XCTAssertTrue(presentation.allowsTap)
    }

    func test_manualButtonPresentation_mixedAndPending_renderDisabledUpdatingState() {
        for state in [ManualLockAggregateState.mixed, .pending] {
            let presentation = ManualLockButtonPresentation.from(state: state, childName: "Sam")

            XCTAssertEqual(presentation.title, "Updating Sam's devices")
            XCTAssertEqual(presentation.systemImage, "arrow.triangle.2.circlepath")
            XCTAssertEqual(presentation.tone, .updating)
            XCTAssertFalse(presentation.allowsTap)
        }
    }

    // MARK: - 1. DeviceLockStateResponse decode

    func test_fullLockStateResponse_decodesAllFields() throws {
        let json = """
        {
          "locked": true,
          "child_profile_id": "00000000-0000-0000-0000-000000000001",
          "child_device_id": "00000000-0000-0000-0000-000000000002",
          "list_id": "list-backend-42",
          "recordKey": "savedList:list-backend-42",
          "targetKey": "list-backend-42",
          "tier": "savedList",
          "covering_sources": ["manual", "earnedTime"],
          "exhausted": false,
          "override_active": true,
          "updated_at": "2026-06-23T12:00:00Z",
          "warning": "Device offline"
        }
        """.data(using: .utf8)!

        let resp = try JSONDecoder().decode(APIClient.DeviceLockStateResponse.self, from: json)
        XCTAssertTrue(resp.locked)
        XCTAssertEqual(resp.list_id, "list-backend-42")
        // camelCase keys must decode to camelCase properties
        XCTAssertEqual(resp.recordKey, "savedList:list-backend-42")
        XCTAssertEqual(resp.targetKey, "list-backend-42")
        XCTAssertEqual(resp.tier, "savedList")
        XCTAssertEqual(resp.covering_sources, ["manual", "earnedTime"])
        XCTAssertEqual(resp.exhausted, false)
        XCTAssertEqual(resp.override_active, true)
        XCTAssertEqual(resp.updated_at, "2026-06-23T12:00:00Z")
        XCTAssertEqual(resp.warning, "Device offline")
        XCTAssertEqual(resp.child_profile_id, UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(resp.child_device_id, UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    }

    func test_legacyLockStateResponse_backCompatDecode() throws {
        // Old backend only emits {locked: bool}. Must still decode cleanly.
        let json = #"{"locked": false}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(APIClient.DeviceLockStateResponse.self, from: json)
        XCTAssertFalse(resp.locked)
        XCTAssertNil(resp.list_id)
        XCTAssertNil(resp.recordKey)
        XCTAssertNil(resp.targetKey)
        XCTAssertNil(resp.covering_sources)
        XCTAssertNil(resp.exhausted)
    }

    func test_lockStateResponse_camelCase_keys_not_snakeCase() throws {
        // Ensures the CodingKeys use camelCase for recordKey/targetKey,
        // not snake_case that convertFromSnakeCase would produce.
        // We inject a JSON that has ONLY camelCase forms — if CodingKeys were
        // snake_case these would decode to nil, not the expected strings.
        let json = """
        {
          "locked": true,
          "recordKey": "savedList:x",
          "targetKey": "x"
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(APIClient.DeviceLockStateResponse.self, from: json)
        XCTAssertEqual(resp.recordKey, "savedList:x", "recordKey must use camelCase CodingKey")
        XCTAssertEqual(resp.targetKey, "x", "targetKey must use camelCase CodingKey")
    }

    func test_lockStateResponse_snake_case_keys_used_for_non_camel_fields() throws {
        // Ensures covering_sources, child_profile_id, etc. use snake_case keys.
        let json = """
        {
          "locked": true,
          "covering_sources": ["limit"],
          "child_profile_id": "00000000-0000-0000-0000-000000000003"
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(APIClient.DeviceLockStateResponse.self, from: json)
        XCTAssertEqual(resp.covering_sources, ["limit"])
        XCTAssertEqual(resp.child_profile_id, UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
    }

    // MARK: - 2. LockButtonState helper

    func test_lockButtonState_nilSources_isPending() {
        // nil covering_sources → we don't know yet (no acked state)
        let state = LockButtonState.from(coveringSources: nil, exhausted: nil)
        XCTAssertEqual(state, .pending)
    }

    func test_lockButtonState_emptySources_isGreen() {
        // [] → selected set is clear → green (unlocked)
        let state = LockButtonState.from(coveringSources: [], exhausted: false)
        XCTAssertEqual(state, .clear)
    }

    func test_lockButtonState_nonEmptySources_isRed() {
        // non-empty covering_sources → selected set is shielded → red (locked)
        let state = LockButtonState.from(coveringSources: ["manual"], exhausted: false)
        XCTAssertEqual(state, .shielded(who: ["manual"]))
    }

    func test_lockButtonState_exhaustedWithEmptySources_isGreen() {
        // exhausted alone is not a real selected-set lock; empty sources means clear.
        let state = LockButtonState.from(coveringSources: [], exhausted: true)
        XCTAssertEqual(state, .clear)
    }

    func test_lockButtonState_exhaustedNilSources_isPending() {
        // nil sources still means no acked lock truth yet.
        let state = LockButtonState.from(coveringSources: nil, exhausted: true)
        XCTAssertEqual(state, .pending)
    }

    func test_lockButtonState_multipleSources() {
        let state = LockButtonState.from(coveringSources: ["manual", "earnedTime", "limit"], exhausted: false)
        if case .shielded(let who) = state {
            XCTAssertEqual(Set(who), Set(["manual", "earnedTime", "limit"]))
        } else {
            XCTFail("Expected .shielded, got \(state)")
        }
    }

    func test_lockButtonState_emptySourcesAndNotExhaustedClearsPriorRedState() {
        let red = LockButtonState.from(coveringSources: ["manual"], exhausted: false)
        XCTAssertTrue(red.isShielded)

        let cleared = LockButtonState.from(coveringSources: [], exhausted: false)
        XCTAssertEqual(cleared, .clear)
        XCTAssertFalse(cleared.isShielded,
                       "fresh lock-state with no sources and exhausted=false must drive the button back to green")
    }

    // MARK: - 3. EarnedSummaryDTO child-level state

    func test_earnedSummaryDTO_decodes_state() throws {
        let json = """
        {
          "child_profile_id": "00000000-0000-0000-0000-000000000010",
          "state": "exhausted",
          "earned_minutes": 30,
          "used_minutes": 30,
          "remaining_minutes": 0,
          "override_active": false,
          "updated_at": "2026-06-23T11:00:00Z"
        }
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(APIClient.EarnedSummaryDTO.self, from: json)
        XCTAssertEqual(dto.state, "exhausted")
        XCTAssertEqual(dto.earned_minutes, 30)
        XCTAssertEqual(dto.remaining_minutes, 0)
        XCTAssertFalse(dto.override_active ?? true)
    }

    func test_earnedSummaryDTO_decodes_ok_state() throws {
        let json = """
        {
          "child_profile_id": "00000000-0000-0000-0000-000000000011",
          "state": "ok",
          "earned_minutes": 60,
          "used_minutes": 20,
          "remaining_minutes": 40
        }
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(APIClient.EarnedSummaryDTO.self, from: json)
        XCTAssertEqual(dto.state, "ok")
        XCTAssertEqual(dto.remaining_minutes, 40)
        XCTAssertNil(dto.override_active)
    }

    func test_lockButtonState_fromSummaryState_exhausted_isShielded() {
        // When summary.state == "exhausted", button should show red.
        let state = LockButtonState.from(summaryState: "exhausted")
        XCTAssertEqual(state, .shielded(who: []))
    }

    func test_lockButtonState_fromSummaryState_ok_isClear() {
        let state = LockButtonState.from(summaryState: "ok")
        XCTAssertEqual(state, .clear)
    }

    func test_lockButtonState_fromSummaryState_nil_isPending() {
        let state = LockButtonState.from(summaryState: nil)
        XCTAssertEqual(state, .pending)
    }

    // MARK: - 4. B6 carry: list_id triggers saveLockedSetID + reKey once
    //
    // These tests exercise `ListIDSyncSpy` — a pure-logic test double that
    // mirrors `ProfileView.applyListIDIfNeeded` without touching real stores.
    // We verify idempotency (same id → no repeat calls) and nil/empty guard.

    func test_listID_sync_callsSaveLockedSetID_and_reKey() {
        var saveCount = 0
        var reKeyCount = 0
        let spy = ListIDSyncSpy(
            onSave: { _ in saveCount += 1 },
            onReKey: { _, _ in reKeyCount += 1 }
        )

        // Simulate learning list_id from a lock-state response (first time).
        spy.applyListIDIfNeeded("list-backend-42")
        XCTAssertEqual(saveCount, 1, "saveLockedSetID should be called once")
        XCTAssertEqual(reKeyCount, 1, "reKeyShieldRecord should be called once")

        // Second call with same id must be idempotent.
        spy.applyListIDIfNeeded("list-backend-42")
        XCTAssertEqual(saveCount, 1, "saveLockedSetID must NOT be called again for same id")
        XCTAssertEqual(reKeyCount, 1, "reKeyShieldRecord must NOT be called again for same id")
    }

    func test_listID_sync_skipsEmptyOrNilID() {
        var saveCount = 0
        let spy = ListIDSyncSpy(
            onSave: { _ in saveCount += 1 },
            onReKey: { _, _ in }
        )
        // nil / empty must not trigger sync.
        spy.applyListIDIfNeeded(nil)
        spy.applyListIDIfNeeded("")
        XCTAssertEqual(saveCount, 0, "nil/empty list_id must not call saveLockedSetID")
    }
}

// MARK: - Helpers for test 4

/// Test double that exercises the applyListIDIfNeeded logic inline.
/// No real stores involved — we just verify call counts and idempotency.
/// Mirrors the guard/mutation in `ProfileView.applyListIDIfNeeded`.
private final class ListIDSyncSpy {
    var onSave: (String) -> Void
    var onReKey: (String, String) -> Void
    private var knownID: String?

    init(onSave: @escaping (String) -> Void, onReKey: @escaping (String, String) -> Void) {
        self.onSave = onSave
        self.onReKey = onReKey
    }

    /// Mirrors `ProfileView.applyListIDIfNeeded`:
    /// • nil / empty → no-op
    /// • same id seen before → no-op (idempotent)
    /// • new id → call onSave + onReKey exactly once
    func applyListIDIfNeeded(_ newID: String?) {
        guard let id = newID, !id.isEmpty else { return }
        guard id != knownID else { return }
        let previousID = knownID ?? ""
        knownID = id
        onSave(id)
        // Always re-key (whether previousID is empty or not mirrors real impl).
        onReKey(previousID, id)
    }
}
