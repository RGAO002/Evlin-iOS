# Profile Multi-Device Lock Implementation Plan

> **SUPERSEDED (2026-07-15) - DO NOT EXECUTE:** The aggregate "any lock source
> means Unlock" behavior and automatic-source removal in this plan conflict
> with the approved
> [Metering Epoch Reliability Design](../specs/2026-07-15-metering-epoch-design.md),
> Section 3.6 and Phase 0. This file is retained only as implementation history.
> The Profile CTA now adds/removes `manual` only; automatic locks and their
> bypass/override actions remain separate.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the child Profile lock/unlock CTA target every enrolled device for that child, including devices paired before the most recent one.

**Architecture:** Add a small, testable `ProfileDeviceLockCoordinator` that owns target resolution, aggregate lock truth, submission ordering, and batch result counts. `ProfileView` keeps presentation state and uses the coordinator with closures backed by the existing single-device `APIClient` endpoints, then polls every accepted device round-by-round for acknowledged state.

**Tech Stack:** Swift 6, SwiftUI, Foundation concurrency, XCTest, existing `APIClient` and `FamilyStore` DTOs.

## Global Constraints

- Keep the existing `Lock/Unlock <child>'s devices` user-facing copy unchanged.
- Use the selected child's complete live `ChildDTO.devices` collection; do not narrow this CTA through `evlin.childDeviceID`.
- Keep backend endpoints unchanged; fan out the existing single-device calls from iOS.
- Any non-empty `covering_sources` from the identity-safe Locked Set response counts as shielded, including manual, earned-time, and task-pause sources.
- Mixed state means the next CTA action is unlock, and unlock targets every valid device.
- Exhausted unlock performs one profile-level override and then still sends one `unlock-selected` request per device.
- One device request failure must not prevent attempts for other devices.
- Do not call global `applyListIDIfNeeded` from multi-device refresh, submission, or ACK polling; the current storage is not keyed by device.
- Preserve unrelated working-tree changes. Execute in an isolated worktree created from commit `4491e60` or its descendant.

---

### Task 1: Multi-Device Lock Coordinator

**Files:**
- Create: `Evlin iOS/Models/ProfileDeviceLockCoordinator.swift`
- Create: `Evlin iOSTests/ProfileDeviceLockCoordinatorTests.swift`

**Interfaces:**
- Consumes: `EnrolledDeviceDTO.device_id`, per-device `covering_sources` and `exhausted` values, and async closures supplied by `ProfileView`.
- Produces: `ProfileDeviceLockCoordinator.deviceIDs(from:)`, `aggregate(_:)`, `submit(...)`, and `BatchResult` for Task 2.

- [ ] **Step 1: Write failing target-resolution and aggregate-state tests**

Create `Evlin iOSTests/ProfileDeviceLockCoordinatorTests.swift` with:

```swift
import XCTest
@testable import Evlin_iOS

final class ProfileDeviceLockCoordinatorTests: XCTestCase {
    private let phoneID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let tabletID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!

    func test_deviceIDs_includesEveryValidUniqueChildDevice() {
        let ids = ProfileDeviceLockCoordinator.deviceIDs(from: [
            phoneID.uuidString,
            tabletID.uuidString,
            phoneID.uuidString,
            "not-a-uuid"
        ])

        XCTAssertEqual(ids, [phoneID, tabletID])
    }

    func test_aggregate_isPendingWithoutFetchedState() {
        XCTAssertEqual(ProfileDeviceLockCoordinator.aggregate([]), .pending)
    }

    func test_aggregate_isClearWhenEveryFetchedDeviceIsClear() {
        let states = [
            ProfileDeviceLockCoordinator.DeviceState(
                deviceID: phoneID, coveringSources: [], exhausted: false),
            ProfileDeviceLockCoordinator.DeviceState(
                deviceID: tabletID, coveringSources: [], exhausted: false)
        ]

        XCTAssertEqual(ProfileDeviceLockCoordinator.aggregate(states), .clear)
    }

    func test_aggregate_isShieldedWhenMixed() {
        let states = [
            ProfileDeviceLockCoordinator.DeviceState(
                deviceID: phoneID, coveringSources: [], exhausted: false),
            ProfileDeviceLockCoordinator.DeviceState(
                deviceID: tabletID, coveringSources: ["manual"], exhausted: false)
        ]

        XCTAssertTrue(ProfileDeviceLockCoordinator.aggregate(states).isShielded)
    }

    func test_aggregate_countsEveryLockedSetSourceAsShielded() {
        for source in ["manual", "earnedTime", "taskPause"] {
            let state = ProfileDeviceLockCoordinator.DeviceState(
                deviceID: phoneID, coveringSources: [source], exhausted: source == "earnedTime")
            XCTAssertTrue(ProfileDeviceLockCoordinator.aggregate([state]).isShielded, source)
        }
    }

    func test_shouldOverride_whenUnlockingAndAnyDeviceIsExhausted() {
        let states = [
            ProfileDeviceLockCoordinator.DeviceState(
                deviceID: phoneID, coveringSources: ["earnedTime"], exhausted: true),
            ProfileDeviceLockCoordinator.DeviceState(
                deviceID: tabletID, coveringSources: [], exhausted: false)
        ]

        XCTAssertTrue(ProfileDeviceLockCoordinator.shouldOverride(action: .unlock, states: states))
        XCTAssertFalse(ProfileDeviceLockCoordinator.shouldOverride(action: .lock, states: states))
    }
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
xcodebuild test -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:'Evlin iOSTests/ProfileDeviceLockCoordinatorTests'
```

Expected: FAIL because `ProfileDeviceLockCoordinator` does not exist.

- [ ] **Step 3: Implement target resolution and aggregate policy**

Create `Evlin iOS/Models/ProfileDeviceLockCoordinator.swift`:

```swift
import Foundation

struct ProfileDeviceLockCoordinator {
    enum Action: Equatable {
        case lock
        case unlock
    }

    struct DeviceState: Equatable {
        let deviceID: UUID
        let coveringSources: [String]?
        let exhausted: Bool

        var buttonState: LockButtonState {
            LockButtonState.from(
                coveringSources: coveringSources,
                exhausted: exhausted
            )
        }
    }

    struct BatchResult: Equatable {
        let acceptedDeviceIDs: [UUID]
        let failedDeviceIDs: [UUID]
        let overrideFailed: Bool

        var failureCount: Int { failedDeviceIDs.count }
    }

    static func deviceIDs(from rawIDs: [String]) -> [UUID] {
        var seen = Set<UUID>()
        return rawIDs.compactMap(UUID.init(uuidString:)).filter { seen.insert($0).inserted }
    }

    static func aggregate(_ states: [DeviceState]) -> LockButtonState {
        guard !states.isEmpty else { return .pending }
        let sources = states.flatMap { $0.coveringSources ?? [] }
        return sources.isEmpty ? .clear : .shielded(who: Array(Set(sources)).sorted())
    }

    static func action(for states: [DeviceState]) -> Action {
        aggregate(states).isShielded ? .unlock : .lock
    }

    static func shouldOverride(action: Action, states: [DeviceState]) -> Bool {
        action == .unlock && states.contains(where: \.exhausted)
    }
}
```

- [ ] **Step 4: Run the tests and verify GREEN**

Run the Step 2 command.

Expected: all coordinator policy tests PASS.

- [ ] **Step 5: Add failing submission-order and partial-failure tests**

Append to `ProfileDeviceLockCoordinatorTests`:

```swift
func test_submit_exhaustedUnlock_overridesOnceThenAttemptsEveryDevice() async {
    var events: [String] = []

    let result = await ProfileDeviceLockCoordinator.submit(
        action: .unlock,
        deviceIDs: [phoneID, tabletID],
        needsOverride: true,
        performOverride: { events.append("override") },
        send: { id, action in events.append("\(action)-\(id.uuidString)") }
    )

    XCTAssertEqual(events, [
        "override",
        "unlock-\(phoneID.uuidString)",
        "unlock-\(tabletID.uuidString)"
    ])
    XCTAssertEqual(result.acceptedDeviceIDs, [phoneID, tabletID])
    XCTAssertTrue(result.failedDeviceIDs.isEmpty)
    XCTAssertFalse(result.overrideFailed)
}

func test_submit_continuesAfterOneDeviceFails() async {
    enum Failure: Error { case rejected }
    var attempted: [UUID] = []

    let result = await ProfileDeviceLockCoordinator.submit(
        action: .lock,
        deviceIDs: [phoneID, tabletID],
        needsOverride: false,
        performOverride: {},
        send: { id, _ in
            attempted.append(id)
            if id == phoneID { throw Failure.rejected }
        }
    )

    XCTAssertEqual(attempted, [phoneID, tabletID])
    XCTAssertEqual(result.acceptedDeviceIDs, [tabletID])
    XCTAssertEqual(result.failedDeviceIDs, [phoneID])
}

func test_submit_stopsBeforeDeviceCommandsWhenOverrideFails() async {
    enum Failure: Error { case rejected }
    var attempted: [UUID] = []

    let result = await ProfileDeviceLockCoordinator.submit(
        action: .unlock,
        deviceIDs: [phoneID, tabletID],
        needsOverride: true,
        performOverride: { throw Failure.rejected },
        send: { id, _ in attempted.append(id) }
    )

    XCTAssertTrue(attempted.isEmpty)
    XCTAssertTrue(result.acceptedDeviceIDs.isEmpty)
    XCTAssertEqual(result.failedDeviceIDs, [phoneID, tabletID])
    XCTAssertTrue(result.overrideFailed)
}
```

- [ ] **Step 6: Run the new tests and verify RED**

Run the Step 2 command.

Expected: FAIL because `submit` is not defined.

- [ ] **Step 7: Implement deterministic submission orchestration**

Add inside `ProfileDeviceLockCoordinator`:

```swift
static func submit(
    action: Action,
    deviceIDs: [UUID],
    needsOverride: Bool,
    performOverride: () async throws -> Void,
    send: (UUID, Action) async throws -> Void
) async -> BatchResult {
    if needsOverride {
        do {
            try await performOverride()
        } catch {
            return BatchResult(
                acceptedDeviceIDs: [],
                failedDeviceIDs: deviceIDs,
                overrideFailed: true
            )
        }
    }

    var accepted: [UUID] = []
    var failed: [UUID] = []
    for deviceID in deviceIDs {
        do {
            try await send(deviceID, action)
            accepted.append(deviceID)
        } catch {
            failed.append(deviceID)
        }
    }
    return BatchResult(
        acceptedDeviceIDs: accepted,
        failedDeviceIDs: failed,
        overrideFailed: false
    )
}
```

Sequential request submission is deliberate: it preserves deterministic tests and avoids making the mutable `APIClient` Sendable. ACK polling in Task 2 is batched by round, so this does not multiply the 15-second timeout by device count.

- [ ] **Step 8: Run focused tests and commit Task 1**

Run the Step 2 command and confirm PASS, then:

```bash
git add "Evlin iOS/Models/ProfileDeviceLockCoordinator.swift" \
  "Evlin iOSTests/ProfileDeviceLockCoordinatorTests.swift"
git commit -m "feat: coordinate profile device lock fanout"
```

---

### Task 2: Wire Profile CTA To Every Child Device

**Files:**
- Modify: `Evlin iOS/Views/Profile/ProfileView.swift:113-147`
- Modify: `Evlin iOS/Views/Profile/ProfileView.swift:836-974`
- Modify: `Evlin iOS/Views/Profile/ProfileView.swift:1452-1500`
- Test: `Evlin iOSTests/ProfileDeviceLockCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 1's `ProfileDeviceLockCoordinator`, existing `APIClient.lockSelected`, `unlockSelected`, `unlockOverride`, and `fetchDeviceLockState`.
- Produces: child-level Profile CTA fan-out with aggregate acknowledged state and partial-result messaging.

- [ ] **Step 1: Add failing batch-message tests**

Append to `ProfileDeviceLockCoordinatorTests`:

```swift
func test_statusMessage_isNilWhenEveryDeviceAcknowledged() {
    XCTAssertNil(ProfileDeviceLockCoordinator.statusMessage(
        action: .lock, failedCount: 0, queuedCount: 0))
}

func test_statusMessage_reportsQueuedCount() {
    XCTAssertEqual(ProfileDeviceLockCoordinator.statusMessage(
        action: .unlock, failedCount: 0, queuedCount: 1),
        "Queued — 1 device will unlock when it next checks in.")
}

func test_statusMessage_reportsFailureAndQueueCounts() {
    XCTAssertEqual(ProfileDeviceLockCoordinator.statusMessage(
        action: .lock, failedCount: 1, queuedCount: 2),
        "Couldn't queue 1 device. 2 devices are still waiting to lock.")
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run the Task 1 Step 2 command.

Expected: FAIL because `statusMessage` is not defined.

- [ ] **Step 3: Implement deterministic batch messaging**

Add to `ProfileDeviceLockCoordinator`:

```swift
static func statusMessage(
    action: Action,
    failedCount: Int,
    queuedCount: Int
) -> String? {
    let verb = action == .lock ? "lock" : "unlock"
    let queuedNoun = queuedCount == 1 ? "device" : "devices"
    let failedNoun = failedCount == 1 ? "device" : "devices"

    if failedCount > 0 && queuedCount > 0 {
        return "Couldn't queue \(failedCount) \(failedNoun). "
            + "\(queuedCount) \(queuedNoun) are still waiting to \(verb)."
    }
    if failedCount > 0 {
        return "Couldn't queue \(failedCount) \(failedNoun) to \(verb)."
    }
    if queuedCount > 0 {
        let pronoun = queuedCount == 1 ? "it" : "they"
        return "Queued — \(queuedCount) \(queuedNoun) will \(verb) when \(pronoun) next checks in."
    }
    return nil
}
```

- [ ] **Step 4: Add multi-device state to `ProfileView`**

Keep `backendChildID` for unrelated single-device task/reflection flows. Add a separate CTA target and snapshots:

```swift
private var lockTargetDeviceIDs: [UUID] {
    let rawIDs = familyStore.child(byId: child.id)?.devices.map(\.device_id) ?? []
    return ProfileDeviceLockCoordinator.deviceIDs(from: rawIDs)
}

@State private var lockStatesByDevice: [UUID: ProfileDeviceLockCoordinator.DeviceState] = [:]

private var lockDeviceStates: [ProfileDeviceLockCoordinator.DeviceState] {
    lockTargetDeviceIDs.compactMap { lockStatesByDevice[$0] }
}
```

Remove `lastFetchedExhausted`; exhaustion is derived with:

```swift
let needsOverride = ProfileDeviceLockCoordinator.shouldOverride(
    action: action,
    states: lockDeviceStates
)
```

- [ ] **Step 5: Replace single-device refresh with aggregate refresh**

Rewrite `refreshLockState()` so it fetches every ID, retains successful state, and never applies a multi-device list-ID carry:

```swift
@MainActor
private func refreshLockState() async {
    guard let famRaw = UserDefaults.standard.string(forKey: "evlin.familyID"),
          let famID = UUID(uuidString: famRaw) else { return }

    let targetIDs = lockTargetDeviceIDs
    guard !targetIDs.isEmpty else {
        ackedLockButtonState = .pending
        lockStatesByDevice = [:]
        return
    }

    var refreshed: [UUID: ProfileDeviceLockCoordinator.DeviceState] = [:]
    for deviceID in targetIDs {
        guard let response = try? await apiClient.fetchDeviceLockState(
            familyID: famID,
            childDeviceID: deviceID
        ) else { continue }
        refreshed[deviceID] = .init(
            deviceID: deviceID,
            coveringSources: response.covering_sources,
            exhausted: response.exhausted == true
        )
    }

    lockStatesByDevice = refreshed
    let aggregate = ProfileDeviceLockCoordinator.aggregate(Array(refreshed.values))
    withAnimation(.easeOut(duration: 0.18)) {
        ackedLockButtonState = aggregate
        localStatus = aggregate.isShielded ? .locked : .unlocked
    }
}
```

Do not call `applyListIDIfNeeded` in this method, even when one response arrives first; this is a child-level multi-device refresh.

- [ ] **Step 6: Replace CTA submission with coordinator fan-out**

In `toggleDeviceLock()` guard `!lockTargetDeviceIDs.isEmpty`, derive the action from the aggregate, and submit all device calls:

```swift
let targetIDs = lockTargetDeviceIDs
let action = ProfileDeviceLockCoordinator.action(for: lockDeviceStates)
let usageDate = todayUsageDate()
let needsOverride = ProfileDeviceLockCoordinator.shouldOverride(
    action: action,
    states: lockDeviceStates
)

if needsOverride {
    EarnedTimeStore.shared.setOverride(true, forUsageDate: usageDate)
}

let result = await ProfileDeviceLockCoordinator.submit(
    action: action,
    deviceIDs: targetIDs,
    needsOverride: needsOverride,
    performOverride: {
        _ = try await apiClient.unlockOverride(
            childProfileID: pid,
            usageDate: usageDate
        )
    },
    send: { deviceID, requestedAction in
        switch requestedAction {
        case .lock:
            _ = try await apiClient.lockSelected(
                familyID: famID,
                childProfileID: pid,
                childDeviceID: deviceID
            )
        case .unlock:
            _ = try await apiClient.unlockSelected(
                familyID: famID,
                childProfileID: pid,
                childDeviceID: deviceID
            )
        }
    }
)
```

If `result.overrideFailed`, clear the just-written local override with `EarnedTimeStore.shared.setOverride(false, forUsageDate: usageDate)`, show `Couldn't unlock — try again.`, and return. Do not call `applyListIDIfNeeded` on any command response in this child-level path.

- [ ] **Step 7: Poll all accepted devices by round**

Replace `waitForLockStateAcked(wantLocked:cid:famID:)` with a set-based method. Sleep once per round, then fetch every still-pending device; this preserves the existing approximately 15-second total deadline regardless of device count:

```swift
@MainActor
private func waitForLockStatesAcked(
    action: ProfileDeviceLockCoordinator.Action,
    deviceIDs: [UUID],
    famID: UUID
) async -> Set<UUID> {
    var waiting = Set(deviceIDs)
    for _ in 0..<6 where !waiting.isEmpty {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        for deviceID in Array(waiting) {
            guard let response = try? await apiClient.fetchDeviceLockState(
                familyID: famID,
                childDeviceID: deviceID
            ) else { continue }
            let state = ProfileDeviceLockCoordinator.DeviceState(
                deviceID: deviceID,
                coveringSources: response.covering_sources,
                exhausted: response.exhausted == true
            )
            lockStatesByDevice[deviceID] = state
            let reachedTarget = action == .lock
                ? state.buttonState.isShielded
                : state.buttonState.isClear
            if reachedTarget { waiting.remove(deviceID) }
        }
        let aggregate = ProfileDeviceLockCoordinator.aggregate(lockDeviceStates)
        ackedLockButtonState = aggregate
        localStatus = aggregate.isShielded ? .locked : .unlocked
    }
    return waiting
}
```

After polling, set `lockError` when `failureCount > 0`; otherwise put the coordinator message in `lockNote`. Always refresh `FamilyStore` after the batch. Do not reuse the single `pendingLockWant` bool; queued count is the source of truth for this operation.

- [ ] **Step 8: Update CTA availability without changing copy**

Change only the disabled/opacity conditions:

```swift
.disabled(lockBusy || lockTargetDeviceIDs.isEmpty || ackedLockButtonState.isPending)
.opacity(lockTargetDeviceIDs.isEmpty ? 0.45
    : (lockBusy || ackedLockButtonState.isPending ? 0.7 : 1))
```

Update the disabled caption condition from `backendChildID == nil` to `lockTargetDeviceIDs.isEmpty`. Leave lines containing `Lock \(displayChild.name)'s devices` and `Unlock \(displayChild.name)'s devices` unchanged.

- [ ] **Step 9: Run focused tests and build**

Run:

```bash
xcodebuild test -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:'Evlin iOSTests/ProfileDeviceLockCoordinatorTests' \
  -only-testing:'Evlin iOSTests/SelectedSetClientTests' \
  -only-testing:'Evlin iOSTests/OverrideSuppressionTests'
```

Expected: all selected tests PASS.

Then run:

```bash
xcodebuild build -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Expected: `** BUILD SUCCEEDED **` with no Swift compile errors.

- [ ] **Step 10: Verify diff scope and commit Task 2**

Run:

```bash
git diff --check
git diff -- "Evlin iOS/Views/Profile/ProfileView.swift" \
  "Evlin iOS/Models/ProfileDeviceLockCoordinator.swift" \
  "Evlin iOSTests/ProfileDeviceLockCoordinatorTests.swift"
```

Confirm no backend files, API endpoint contracts, pairing storage, or CTA copy changed. Then:

```bash
git add "Evlin iOS/Views/Profile/ProfileView.swift" \
  "Evlin iOS/Models/ProfileDeviceLockCoordinator.swift" \
  "Evlin iOSTests/ProfileDeviceLockCoordinatorTests.swift"
git commit -m "fix: fan out profile lock to every child device"
```
