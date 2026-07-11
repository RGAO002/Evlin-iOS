# Earned-Time Poll Self-Heal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Total Pool and Device Limit use the backend's authoritative metering gate, reconcile paused samples honestly, and self-heal their exact policy from the existing child-state poll.

**Architecture:** The backend adds an additive `counted` marker to earned-time sample snapshots and returns authoritative earned-time runtime state from `/child/state`. iOS keeps a canonical-date-scoped accepted estimate separate from raw extension observations, reconciles every successful sample and poll into that baseline, and retries idempotent arming on every allowed poll. A final operational task resets only the affected local test account after both code paths pass automated verification.

**Tech Stack:** Python 3.12, FastAPI, Pydantic v2, SQLAlchemy async, pytest; Swift 5, SwiftUI, DeviceActivity, ManagedSettings, XCTest, App Group `UserDefaults`.

## Global Constraints

- Preserve the product rule: usage during unfinished tasks or an active reflection counts toward none of Total Pool, Device Limit, or Per-App Limit.
- The backend `app.services.bigkid_usage_gate.usage_counting_allowed(session, store, child_device_id)` is the only authoritative metering gate.
- Pass the child **device UUID**, never the child-profile UUID, to the authoritative gate.
- Keep paused sample responses at HTTP 200; distinguish them with `counted: false` and never retry them.
- Treat `estimated_minutes` as the maximum threshold accepted by the backend for one device and canonical usage date, not as remaining time.
- Same-date accepted usage is monotonic except for an explicit `counted: false` response; a canonical usage-date change resets the accepted baseline to the server value.
- Missing optional runtime fields must preserve stored policy and use the compatibility gate: all tasks complete and no active reflection request.
- A false gate must stop all three counter systems: earned-time ladder, device-total activity, and per-app activities.
- Do not change five-minute threshold granularity, per-app daily semantics, lock precedence, task-lock behavior, or reflection UX.
- Do not add an automatic historical correction or migration feature.
- Do not modify Render data. The recovery target is the local backend used by `gruoping@gmail.com` at `http://192.168.1.175:8000/api/v1`.
- Preserve all pre-existing dirty-worktree changes. Inspect diffs before editing; stage only named paths and, where a target file already contains unrelated edits, stage only this plan's hunks with `git add -p`.
- Run iOS focused tests serially with `-parallel-testing-enabled NO`; do not rely on the broad `EarnedTimeStoreTests` suite running in parallel because existing extra store instances can trigger a double-free.
- Execute Tasks 1-5 sequentially in the existing main working directories. Do not create a worktree: required prerequisite edits exist only as uncommitted changes in those directories.
- Before Task 1, record `git stash create` recovery SHAs for both repositories without applying or clearing the worktrees.
- Implementer and reviewer subagents must not delegate. They may touch only the task's named files in the existing main working directory.
- For dirty target files, derive an exact patch from the task diff and stage it with `git apply --cached`, or use scripted `git add -p`; every review gate must inspect `git diff --cached` and reject unrelated pre-existing hunks.
- Task 6 is controller-only. No subagent may restart services, modify the local database, copy App Group data, install on a physical device, or run the physical acceptance test.
- In Task 6, stop before the recovery transaction's `COMMIT` and require the user to confirm the printed family, child profile, child device, timezone, usage date, and affected row counts.

---

## File Map

### Backend repository: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend`

- `app/schemas/earned_time.py`: additive sample response marker.
- `app/schemas/bigkid.py`: child-state runtime wire DTOs.
- `app/api/routes/earned_time.py`: mark gate-paused snapshots as not counted.
- `app/api/routes/bigkid_child.py`: compute the authoritative gate and runtime for the same child device.
- `app/services/earned_time_service.py`: existing summary/snapshot source; reuse its output rather than duplicate ledger arithmetic.
- `tests/test_earned_time_sample.py`: sample persistence and paused-response contract.
- `tests/test_bigkid_endpoints.py`: child-state gate/runtime contract and device-ID consistency.

### iOS repository: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS`

- `Evlin iOS/Models/BigKid/BigKidModels.swift`: optional child-state runtime fields and compatibility gate.
- `Evlin iOS/Services/EarnedTimeStore.swift`: canonical-date-scoped accepted baseline and runtime reconciliation.
- `Evlin iOS/Services/EarnedSampleReporter.swift`: decode successful snapshots and reconcile counted versus paused responses.
- `Evlin iOS/Services/BigKidStatePoller.swift`: apply runtime before gate decisions and retry idempotent arming.
- `Evlin iOS/Services/CommandPoller.swift`: derive config re-arm offset from accepted usage, not raw observations.
- `Evlin iOSTests/BigKidModelsTests.swift`: wire decoding and fallback behavior.
- `Evlin iOSTests/EarnedTimeStoreTests.swift`: same-date monotonic and cross-date reset rules.
- `Evlin iOSTests/EarnedSampleReporterTests.swift`: response classification, no-retry pause, and retry-drain behavior.
- `Evlin iOSTests/BigKidStatePollerTests.swift`: runtime ordering, three-counter stop, and allowed-poll self-heal.
- `Evlin iOSTests/EarnedConfigCommandTests.swift`: config handler uses accepted baseline.

---

### Task 1: Make Paused Sample Success Explicit

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/schemas/earned_time.py:31-44`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/earned_time.py:98-116`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_gate.py:312-360`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_sample.py:114-166`

**Interfaces:**
- Consumes: `earned_time_service.current_device_day_snapshot(...) -> DeviceDaySnapshot` and the existing shared gate.
- Produces: `DeviceDaySnapshot.counted: bool`, defaulting to `True`; paused route responses override it to `False`.

- [ ] **Step 1: Add failing sample-contract tests**

Extend the existing reflection-gate tests in `test_metering_gate.py`, which already provide `_make_family_device_profile`, `_arm_active_reflection_lock`, and `_sample_body`. Import `EarnedTimeSample` alongside the existing day models and count rows with SQLAlchemy `select(func.count(...))`:

```python
@pytest.mark.asyncio
async def test_earned_time_sample_uncounted_while_reflection_active(client, session):
    store = get_store()
    _fam, _profile, device = await _make_family_device_profile(session)
    await session.commit()
    _arm_active_reflection_lock(store, device.id)
    body = _sample_body(device.id, threshold_minutes=30)

    response = await client.post(
        "/child/earned-time/sample",
        json=body,
        headers={"X-Evlin-Child-Device-ID": str(device.id)},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["counted"] is False
    assert payload["estimated_minutes"] == 0
    assert (await session.execute(select(func.count(EarnedTimeSample.id)))).scalar_one() == 0
    assert (await session.execute(select(func.count(EarnedTimeDay.id)))).scalar_one() == 0
    assert (await session.execute(select(func.count(EarnedTimeDeviceDay.id)))).scalar_one() == 0


@pytest.mark.asyncio
async def test_single_t30_device_day_estimated_minutes(client, session):
    _fam, _profile, device = await _make_family_device_profile(session)
    await session.commit()
    body = _sample_body(device.id, threshold_minutes=30)

    response = await client.post(
        "/child/earned-time/sample",
        json=body,
        headers={"X-Evlin-Child-Device-ID": str(device.id)},
    )

    assert response.status_code == 200
    assert response.json()["counted"] is True
    assert response.json()["estimated_minutes"] == 30
```

- [ ] **Step 2: Run the focused tests and confirm the contract fails**

```bash
EVLIN_TEST_DATABASE_URL='postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test' \
  .venv/bin/python -m pytest \
  tests/test_metering_gate.py::test_earned_time_sample_uncounted_while_reflection_active \
  tests/test_earned_time_sample.py::test_single_t30_device_day_estimated_minutes -q
```

Expected: both fail because `counted` is absent.

- [ ] **Step 3: Add the additive response field and paused override**

In `DeviceDaySnapshot`, add a default so every existing constructor and idempotent path stays counted:

```python
class DeviceDaySnapshot(BaseModel):
    child_device_id: UUID
    usage_date: date
    estimated_minutes: int
    cap_minutes: Optional[int]
    child_day_state: str
    used_minutes: int
    remaining_minutes: int
    counted: bool = True
    warning: Optional[str] = None
```

In the paused branch, preserve the canonical-date snapshot and override only the marker:

```python
snapshot = await earned_time_service.current_device_day_snapshot(
    session,
    child_device=device,
    usage_date=snapshot_date,
)
return snapshot.model_copy(update={"counted": False})
```

- [ ] **Step 4: Run sample tests**

```bash
EVLIN_TEST_DATABASE_URL='postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test' \
  .venv/bin/python -m pytest tests/test_earned_time_sample.py -q
```

Expected: PASS; existing snapshot assertions tolerate the additive field.

- [ ] **Step 5: Commit only Task 1 backend files**

```bash
git add app/schemas/earned_time.py app/api/routes/earned_time.py \
  tests/test_metering_gate.py tests/test_earned_time_sample.py
git diff --cached --check
git commit -m "fix: identify uncounted earned samples"
```

---

### Task 2: Return Authoritative Runtime From Child State

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/schemas/bigkid.py:196-208`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/bigkid_child.py` at the `GET /child/state` handler and its earned-time helper
- Reuse: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/earned_time_service.py:821-900`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_bigkid_endpoints.py`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_sample.py`

**Interfaces:**
- Consumes: `usage_counting_allowed(session, store, child_device_id)` and `earned_time_service.get_summary(db, family_id:, child_profile_id:, date_: None)`.
- Produces: optional `ChildStateResponse.earned_time_runtime` and `usage_counting_allowed: bool = True`.

- [ ] **Step 1: Add failing child-state runtime tests**

Add a runtime assertion covering exact pool, explicit cap, remaining, accepted estimate, canonical date, and timezone:

```python
@pytest.mark.asyncio
async def test_child_state_returns_authoritative_earned_runtime(
    client, session, seeded_bigkid_with_earned_time
):
    device, headers = seeded_bigkid_with_earned_time(
        pool=120, cap=90, estimated=15, timezone="America/New_York"
    )

    response = await client.get("/api/v1/child/state", headers=headers)

    assert response.status_code == 200
    payload = response.json()
    assert payload["usage_counting_allowed"] is True
    assert payload["earned_time_runtime"] == {
        "usage_date": payload["earned_time_runtime"]["usage_date"],
        "timezone": "America/New_York",
        "daily_pool_minutes": 120,
        "device_cap_minutes": 90,
        "remaining_minutes": 75,
        "estimated_minutes": 15,
    }
    assert payload["earned_time_runtime"]["usage_date"] == canonical_today(
        "America/New_York"
    ).isoformat()
```

Add fallback-cap and no-config cases:

```python
assert state_without_explicit_cap["earned_time_runtime"]["device_cap_minutes"] == 120
assert state_without_config["earned_time_runtime"] is None
```

Add the same-device consistency test. Use one seeded child device and compare child state with a sample during reflection, then resolve reflection and compare again:

```python
assert paused_state["usage_counting_allowed"] is False
assert paused_sample["counted"] is False
assert allowed_state["usage_counting_allowed"] is True
assert allowed_sample["counted"] is True
```

- [ ] **Step 2: Run the focused backend tests and verify failure**

```bash
EVLIN_TEST_DATABASE_URL='postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test' \
  .venv/bin/python -m pytest \
  tests/test_bigkid_endpoints.py -k 'earned_runtime or usage_counting' \
  tests/test_earned_time_sample.py -k 'gate_agrees' -q
```

Expected: FAIL because the new child-state fields do not exist.

- [ ] **Step 3: Define the runtime DTO**

Add to `app/schemas/bigkid.py`:

```python
class EarnedTimeRuntimeState(BaseModel):
    usage_date: date
    timezone: str
    daily_pool_minutes: int = Field(ge=1, le=1440)
    device_cap_minutes: int = Field(ge=1, le=1440)
    remaining_minutes: int = Field(ge=0, le=1440)
    estimated_minutes: int = Field(ge=0, le=1440)


class ChildStateResponse(BaseModel):
    # existing fields remain unchanged
    usage_counting_allowed: bool = True
    earned_time_runtime: Optional[EarnedTimeRuntimeState] = None
```

Import `date` and `Field` only if the module does not already import them.

- [ ] **Step 4: Build child runtime from the existing summary**

Create one route-local helper rather than duplicating SQL:

```python
async def _earned_time_runtime_for_device(
    session: AsyncSession,
    *,
    child_device: Device,
) -> EarnedTimeRuntimeState | None:
    if child_device.child_profile_id is None:
        return None
    try:
        summary = await earned_time_service.get_summary(
            session,
            family_id=child_device.family_id,
            child_profile_id=child_device.child_profile_id,
            date_=None,
        )
    except HTTPException as exc:
        if exc.status_code == 404 and exc.detail == "earned_time_config_not_found":
            return None
        raise

    device_entry = next(
        (item for item in summary.devices if item.child_device_id == child_device.id),
        None,
    )
    explicit_cap = device_entry.cap_minutes if device_entry is not None else None
    cap = explicit_cap if explicit_cap is not None else summary.daily_pool_minutes
    estimate = device_entry.estimated_minutes if device_entry is not None else 0
    remaining_to_cap = max(0, cap - estimate)
    return EarnedTimeRuntimeState(
        usage_date=summary.usage_date,
        timezone=summary.timezone,
        daily_pool_minutes=summary.daily_pool_minutes,
        device_cap_minutes=cap,
        remaining_minutes=min(summary.remaining_minutes, remaining_to_cap),
        estimated_minutes=estimate,
    )
```

Use the actual `SummaryResponse` device collection property name (`devices`) confirmed in the schema. Keep `remaining_minutes` effective for this device by taking the minimum of pool remaining and cap remaining.

- [ ] **Step 5: Populate both fields in the child-state handler**

Resolve the same `Device` represented by the existing `child: UUID = Depends(child_id_dep)` dependency, then call both services with `child_device.id`:

```python
counting_allowed = await usage_counting_allowed(session, store, child_device.id)
runtime = await _earned_time_runtime_for_device(
    session,
    child_device=child_device,
)

return ChildStateResponse(
    # preserve every existing response argument
    usage_counting_allowed=counting_allowed,
    earned_time_runtime=runtime,
)
```

Do not feed `child_device.child_profile_id` to the gate.

- [ ] **Step 6: Run backend gate/runtime regression tests**

```bash
EVLIN_TEST_DATABASE_URL='postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test' \
  .venv/bin/python -m pytest \
  tests/test_bigkid_endpoints.py \
  tests/test_earned_time_sample.py \
  tests/test_metering_gate.py -q
```

Expected: PASS.

- [ ] **Step 7: Commit only Task 2 backend files**

```bash
git add app/schemas/bigkid.py app/api/routes/bigkid_child.py \
  tests/test_bigkid_endpoints.py tests/test_earned_time_sample.py
git diff --cached --check
git commit -m "feat: expose earned runtime in child state"
```

---

### Task 3: Add iOS Wire Models And Date-Scoped Accepted Usage

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/BigKid/BigKidModels.swift:166-177`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/BigKid/BigKidState.swift:45-62`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidModelsTests.swift`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`

**Interfaces:**
- Consumes: backend snake-case JSON from Task 2 via `JSONDecoder.bigKid`.
- Produces: `EarnedTimeRuntime`, `ChildStateResponse.effectiveUsageCountingAllowed`, and `EarnedTimeStore.reconcileAcceptedUsage(usageDate:serverEstimatedMinutes:allowSameDayDecrease:) -> Int`.

- [ ] **Step 1: Add failing model decoding and fallback tests**

Add decoding assertions:

```swift
func test_childState_decodesAuthoritativeGateAndRuntime() throws {
    let data = Data(#"{"child_name":"Giannis","minutes_left":0,"minutes_max":0,"tasks":[],"reflection_request":null,"notify_parent_cooldown_ends_at":null,"daily_complete_acknowledged":false,"screen_time_finished_acknowledged":false,"last_resolved_reflection":null,"usage_counting_allowed":false,"earned_time_runtime":{"usage_date":"2026-07-10","timezone":"America/New_York","daily_pool_minutes":120,"device_cap_minutes":90,"remaining_minutes":75,"estimated_minutes":15}}"#.utf8)
    let state = try JSONDecoder.bigKid.decode(ChildStateResponse.self, from: data)

    XCTAssertEqual(state.usageCountingAllowed, false)
    XCTAssertEqual(state.earnedTimeRuntime?.usageDate, "2026-07-10")
    XCTAssertEqual(state.earnedTimeRuntime?.dailyPoolMinutes, 120)
    XCTAssertEqual(state.effectiveUsageCountingAllowed, false)
}
```

Add compatibility assertions using JSON without either new field:

```swift
XCTAssertTrue(noTasksNoReflection.effectiveUsageCountingAllowed)
XCTAssertFalse(unfinishedTask.effectiveUsageCountingAllowed)
XCTAssertFalse(activeReflection.effectiveUsageCountingAllowed)
XCTAssertNil(noTasksNoReflection.earnedTimeRuntime)
```

- [ ] **Step 2: Add failing accepted-baseline store tests**

Use a fresh suite per test and assert all three invariants. A test-created store must not coexist with or access `EarnedTimeStore.shared` in the same test; run these tests serially and release the local store before deleting its suite:

```swift
func test_reconcileAcceptedUsage_isMonotoneWithinUsageDate() {
    XCTAssertEqual(store.reconcileAcceptedUsage(
        usageDate: "2026-07-10", serverEstimatedMinutes: 15,
        allowSameDayDecrease: false
    ), 15)
    XCTAssertEqual(store.reconcileAcceptedUsage(
        usageDate: "2026-07-10", serverEstimatedMinutes: 5,
        allowSameDayDecrease: false
    ), 15)
    XCTAssertEqual(store.acceptedEstimateMinutes, 15)
    XCTAssertEqual(store.earnedUsageOffsetMinutes, 15)
}

func test_reconcileAcceptedUsage_newDateResetsToServer() {
    _ = store.reconcileAcceptedUsage(
        usageDate: "2026-07-10", serverEstimatedMinutes: 40,
        allowSameDayDecrease: false
    )
    XCTAssertEqual(store.reconcileAcceptedUsage(
        usageDate: "2026-07-11", serverEstimatedMinutes: 0,
        allowSameDayDecrease: false
    ), 0)
    XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
}

func test_reconcileAcceptedUsage_pausedResponseMayLowerSameDate() {
    _ = store.reconcileAcceptedUsage(
        usageDate: "2026-07-10", serverEstimatedMinutes: 10,
        allowSameDayDecrease: false
    )
    XCTAssertEqual(store.reconcileAcceptedUsage(
        usageDate: "2026-07-10", serverEstimatedMinutes: 0,
        allowSameDayDecrease: true
    ), 0)
    XCTAssertEqual(store.latestDeviceEstimate, 0)
    XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
}
```

Also extend the existing identity-clear test to assert both new keys are nil.

- [ ] **Step 3: Run focused model/store tests and verify failure**

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/BigKidModelsTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests/test_reconcileAcceptedUsage_isMonotoneWithinUsageDate' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests/test_reconcileAcceptedUsage_newDateResetsToServer' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests/test_reconcileAcceptedUsage_pausedResponseMayLowerSameDate'
```

Expected: compile/test failure because the new types and methods are absent.

- [ ] **Step 4: Add optional wire fields and compatibility gate**

Add:

```swift
struct EarnedTimeRuntime: Codable, Equatable, Sendable {
    let usageDate: String
    let timezone: String
    let dailyPoolMinutes: Int
    let deviceCapMinutes: Int
    let remainingMinutes: Int
    let estimatedMinutes: Int
}

struct ChildStateResponse: Codable, Equatable, Sendable {
    // existing properties
    let usageCountingAllowed: Bool?
    let earnedTimeRuntime: EarnedTimeRuntime?

    var effectiveUsageCountingAllowed: Bool {
        usageCountingAllowed
            ?? (BigKidState.usageCountingAllowed(for: tasks) && reflectionRequest == nil)
    }
}
```

Reuse `BigKidState.usageCountingAllowed(for:)`, whose exact predicate is `task.status == .done || task.bypass?.status == .approved`. Update explicit test/fixture initializers to pass `usageCountingAllowed: nil, earnedTimeRuntime: nil` where memberwise initialization requires it. Change state/poller consumers from the old task-only computed property to `effectiveUsageCountingAllowed`.

- [ ] **Step 5: Implement the accepted baseline in `EarnedTimeStore`**

First change the stored defaults dependency into an explicit test seam while preserving the production default:

```swift
final class EarnedTimeStore: @unchecked Sendable {
    static let shared = EarnedTimeStore()

    private let defaults: UserDefaults?

    init(suiteName: String = "group.com.evlin.ios") {
        defaults = UserDefaults(suiteName: suiteName)
    }
}
```

Production and extension call sites continue using `EarnedTimeStore()` or `.shared`, both of which resolve to the real App Group. Tests create exactly one local `EarnedTimeStore(suiteName:)` at a time, never access `.shared` in that test, run serially, set the local reference to `nil` before `removePersistentDomain(forName:)`, and clean the suite in `tearDown`.

Then add App Group keys and properties:

```swift
private let acceptedUsageDateKey = "earned.acceptedUsageDate"
private let acceptedEstimateKey = "earned.acceptedEstimateMinutes"

var acceptedUsageDate: String? {
    get { defaults?.string(forKey: acceptedUsageDateKey) }
    set { defaults?.set(newValue, forKey: acceptedUsageDateKey) }
}

var acceptedEstimateMinutes: Int? {
    get {
        guard defaults?.object(forKey: acceptedEstimateKey) != nil else { return nil }
        return max(0, defaults?.integer(forKey: acceptedEstimateKey) ?? 0)
    }
    set {
        if let newValue { defaults?.set(max(0, newValue), forKey: acceptedEstimateKey) }
        else { defaults?.removeObject(forKey: acceptedEstimateKey) }
    }
}
```

Implement the single reconciliation method:

```swift
@discardableResult
func reconcileAcceptedUsage(
    usageDate: String,
    serverEstimatedMinutes: Int,
    allowSameDayDecrease: Bool
) -> Int {
    let server = max(0, serverEstimatedMinutes)
    let sameDay = acceptedUsageDate == usageDate
    let accepted: Int
    if !sameDay || allowSameDayDecrease {
        accepted = server
    } else {
        accepted = max(acceptedEstimateMinutes ?? 0, server)
    }
    acceptedUsageDate = usageDate
    acceptedEstimateMinutes = accepted
    if !sameDay || allowSameDayDecrease {
        // An authoritative new-day or paused response deliberately clears a
        // raw extension estimate that the backend did not accept.
        latestDeviceEstimate = accepted
    } else {
        latestDeviceEstimate = max(latestDeviceEstimate ?? 0, accepted)
    }
    earnedUsageOffsetMinutes = accepted
    defaults?.synchronize()
    return accepted
}
```

Add both keys to `clearUsageStateForIdentityChange()`.

- [ ] **Step 6: Run focused iOS model/store tests**

Run the Step 3 command again. Expected: PASS.

- [ ] **Step 7: Stage only Task 3 files and commit**

```bash
git add 'Evlin iOS/Models/BigKid/BigKidModels.swift' \
  'Evlin iOS/Models/BigKid/BigKidState.swift' \
  'Evlin iOS/Services/EarnedTimeStore.swift' \
  'Evlin iOSTests/BigKidModelsTests.swift' \
  'Evlin iOSTests/EarnedTimeStoreTests.swift'
git diff --cached --check
git commit -m "feat: track accepted earned usage by date"
```

---

### Task 4: Reconcile Every Successful Sample Response

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`

**Interfaces:**
- Consumes: Task 1 `DeviceDaySnapshot` JSON and Task 3 `reconcileAcceptedUsage(...)`.
- Produces: `EarnedSampleReporter.SuccessDisposition` and one response handler shared by immediate POST and retry drain.

- [ ] **Step 1: Preserve and inspect pre-existing reporter edits**

```bash
git diff -- 'Evlin iOS/Services/EarnedSampleReporter.swift' \
  'Evlin iOSTests/EarnedSampleReporterTests.swift'
```

Keep the current-device retry partitioning (`onlyDeviceID`, `partitionRetryQueue`, and `drainRetryQueueFromStoredConfig`) intact.

- [ ] **Step 2: Add failing response-disposition tests**

Drive a pure response handler with a temporary suite:

```swift
func test_countedSuccess_preservesSameDayMonotonicAcceptedUsage() throws {
    let store = EarnedTimeStore(suiteName: suiteName)
    _ = store.reconcileAcceptedUsage(
        usageDate: "2026-07-10", serverEstimatedMinutes: 15,
        allowSameDayDecrease: false
    )
    let data = Data(#"{"usage_date":"2026-07-10","estimated_minutes":5,"counted":true}"#.utf8)

    let result = EarnedSampleReporter.processSuccessfulResponse(
        data, store: store, suiteName: suiteName
    )

    XCTAssertEqual(result, .counted)
    XCTAssertEqual(store.acceptedEstimateMinutes, 15)
}

func test_uncountedSuccess_reconcilesPhantomWithoutRetry() throws {
    let store = EarnedTimeStore(suiteName: suiteName)
    _ = store.reconcileAcceptedUsage(
        usageDate: "2026-07-10", serverEstimatedMinutes: 10,
        allowSameDayDecrease: false
    )
    let data = Data(#"{"usage_date":"2026-07-10","estimated_minutes":0,"counted":false}"#.utf8)

    let result = EarnedSampleReporter.processSuccessfulResponse(
        data, store: store, suiteName: suiteName
    )

    XCTAssertEqual(result, .paused)
    XCTAssertEqual(store.acceptedEstimateMinutes, 0)
    XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
    XCTAssertEqual(EarnedSampleReporter.loadRetryQueue(suiteName: suiteName).count, 0)
    XCTAssertTrue(lastDebugValue.contains("backend_counting_paused"))
}
```

Add one test proving malformed 2xx is `.acceptedWithoutReconciliation` and is not enqueued, plus a retry-drain test proving a `counted:false` response is removed rather than requeued.

- [ ] **Step 3: Run focused reporter tests and verify failure**

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests'
```

Expected: compile failure because `processSuccessfulResponse` and dispositions do not exist.

- [ ] **Step 4: Add a minimal response DTO and shared handler**

Inside `EarnedSampleReporter` add:

```swift
private struct SampleSnapshot: Decodable {
    let usageDate: String
    let estimatedMinutes: Int
    let counted: Bool?
}

enum SuccessDisposition: Equatable {
    case counted
    case paused
    case acceptedWithoutReconciliation
}

@discardableResult
static func processSuccessfulResponse(
    _ data: Data,
    store: EarnedTimeStore = .shared,
    suiteName: String = sharedSuiteName
) -> SuccessDisposition {
    guard let snapshot = try? JSONDecoder.bigKid.decode(SampleSnapshot.self, from: data)
    else {
        recordDebug("post success response_decode_failed", suiteName: suiteName)
        return .acceptedWithoutReconciliation
    }
    if snapshot.counted == false {
        store.reconcileAcceptedUsage(
            usageDate: snapshot.usageDate,
            serverEstimatedMinutes: snapshot.estimatedMinutes,
            allowSameDayDecrease: true
        )
        recordDebug("backend_counting_paused date=\(snapshot.usageDate) estimate=\(snapshot.estimatedMinutes)", suiteName: suiteName)
        return .paused
    }
    store.reconcileAcceptedUsage(
        usageDate: snapshot.usageDate,
        serverEstimatedMinutes: snapshot.estimatedMinutes,
        allowSameDayDecrease: false
    )
    return .counted
}
```

If `JSONDecoder.bigKid` cannot be linked into the extension target, use a local decoder with `.convertFromSnakeCase`; keep the DTO and behavior identical.

- [ ] **Step 5: Use the handler in immediate and queued POST paths**

Capture `data` from `URLSession.shared.data(for:)`. For every 2xx/409 success, call `processSuccessfulResponse`; for non-success/network failure, retain existing enqueue behavior. A malformed successful body remains accepted and must not be retried because retransmission could duplicate a server-accepted sample. Apply the same logic in `drainRetryQueue`.

- [ ] **Step 6: Run reporter tests**

Run the Step 3 command again. Expected: PASS, including pre-existing device-filter tests.

- [ ] **Step 7: Interactively stage only this task's reporter hunks and commit**

```bash
git add -p 'Evlin iOS/Services/EarnedSampleReporter.swift'
git add -p 'Evlin iOSTests/EarnedSampleReporterTests.swift'
git diff --cached --check
git diff --cached
git commit -m "fix: reconcile paused earned samples"
```

The cached diff must include the pre-existing retry-filter hunks only if they are intentionally being committed with this task; otherwise leave them unstaged and preserve them in the worktree.

---

### Task 5: Reconcile Runtime Before Gate And Self-Heal Arming

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/CommandPoller.swift`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedConfigCommandTests.swift`

**Interfaces:**
- Consumes: Task 3 runtime model and accepted-baseline store API.
- Produces: ordered poll flow `runtime sync -> authoritative gate -> stop/rearm`, plus config handling that never reintroduces raw phantom usage.

- [ ] **Step 1: Preserve and inspect pre-existing poller/config edits**

```bash
git diff -- 'Evlin iOS/Services/BigKidStatePoller.swift' \
  'Evlin iOS/Services/CommandPoller.swift'
```

Keep the current `remainingPolicy` and arm-signature changes intact. This task layers runtime reconciliation and accepted-baseline selection on top of them.

- [ ] **Step 2: Add failing poll ordering and self-heal tests**

Extend the poller constructor with test closures only as needed, then record an ordered event list:

```swift
func test_poll_appliesRuntimeBeforeGateAndArm() async {
    var events: [String] = []
    let poller = makePoller(
        snapshot: .fixture(
            usageCountingAllowed: true,
            earnedTimeRuntime: .fixture(estimatedMinutes: 15)
        ),
        syncRuntimePolicy: { _ in events.append("runtime") },
        setUsageCountingAllowed: { _ in events.append("gate"); return true },
        ensureEarnedArmed: { events.append("arm") }
    )

    await poller.pollOnce()

    XCTAssertEqual(events, ["runtime", "gate", "arm"])
}
```

Add these assertions:

```swift
// Every allowed stable poll retries idempotent earned arming.
XCTAssertEqual(ensureEarnedArmedCallCount, 2)

// Every false poll stops, even if the previous stored gate was already false.
XCTAssertEqual(stopUsageCountersCallCount, 2)

// Existing stop implementation still stops earned, device-total, and per-app.
XCTAssertEqual(stoppedSystems, [.earned, .deviceTotal, .perApp])
```

The third assertion can use three injected closures if the current single static stop helper cannot be observed without DeviceActivity.

- [ ] **Step 3: Add failing config accepted-baseline test**

Build on existing config command tests:

```swift
func test_configRearm_usesAcceptedEstimateInsteadOfRawPhantom() async {
    store.latestDeviceEstimate = 25
    store.acceptedUsageDate = "2026-07-10"
    store.acceptedEstimateMinutes = 0
    store.earnedUsageOffsetMinutes = 0

    await poller.pollOnce()

    XCTAssertEqual(armedPool, 120)
    XCTAssertEqual(armedCap, 120)
    XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
}
```

- [ ] **Step 4: Run focused poller/config tests and verify failure**

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedConfigCommandTests'
```

Expected: new ordering/self-heal/baseline tests fail.

- [ ] **Step 5: Add runtime reconciliation to the poller**

Add a test seam whose production default writes exact policy and the date-scoped estimate:

```swift
private static func syncEarnedRuntime(_ runtime: EarnedTimeRuntime?) {
    guard let runtime,
          runtime.dailyPoolMinutes > 0,
          runtime.deviceCapMinutes > 0,
          runtime.remainingMinutes >= 0,
          runtime.estimatedMinutes >= 0
    else { return }

    let store = EarnedTimeStore.shared
    store.poolMinutes = runtime.dailyPoolMinutes
    store.capMinutes = runtime.deviceCapMinutes
    store.backendRemainingAtLastSync = runtime.remainingMinutes
    store.lastBackendSyncAt = Date()
    _ = store.reconcileAcceptedUsage(
        usageDate: runtime.usageDate,
        serverEstimatedMinutes: runtime.estimatedMinutes,
        allowSameDayDecrease: false
    )
}
```

Call it after applying snapshot/reflection UI state but before writing the gate or invoking stop/re-arm decisions.

- [ ] **Step 6: Make the authoritative gate and stable self-heal explicit**

Use `snapshot.effectiveUsageCountingAllowed`. Structure the decision so false always stops and true always attempts earned arming:

```swift
let allowed = snapshot.effectiveUsageCountingAllowed
let wasAllowed = setUsageCountingAllowed(allowed)

if !allowed {
    stopUsageCounters()
    return
}

ensureEarnedArmed()
if !wasAllowed || shouldRecoverSkippedUsage {
    rearmOtherUsageCounters()
}
```

Production `ensureEarnedArmed` is `{ EarnedBudgetArming.armIfReady() }`. Preserve existing transition recovery for device-total and per-app counters. The existing earned arm signature is the deduplication boundary; do not add a second poll timestamp throttle.

- [ ] **Step 7: Derive config offset from accepted usage**

In `CommandPoller.handleEarnedTimeConfig`, replace the raw estimate maximum:

```swift
let accepted = EarnedTimeStore.shared.acceptedEstimateMinutes ?? 0
let offset = max(accepted, EarnedTimeStore.shared.earnedUsageOffsetMinutes)
EarnedTimeStore.shared.earnedUsageOffsetMinutes = offset
```

Do not include `latestDeviceEstimate` in config re-arm math. It originates as a raw extension observation, but reconciliation deliberately overwrites it on a new canonical day or `counted:false` response to clear phantom usage. Only `acceptedEstimateMinutes` is the re-arm authority.

- [ ] **Step 8: Run focused iOS tests**

Run the Step 4 command again. Expected: PASS, including existing task-pause transition and remaining-policy tests.

- [ ] **Step 9: Interactively stage only Task 5 hunks and commit**

```bash
git add -p 'Evlin iOS/Services/BigKidStatePoller.swift'
git add -p 'Evlin iOS/Services/CommandPoller.swift'
git add 'Evlin iOSTests/BigKidStatePollerTests.swift' \
  'Evlin iOSTests/EarnedConfigCommandTests.swift'
git diff --cached --check
git diff --cached
git commit -m "fix: self-heal earned policy from child state"
```

---

### Task 6: Cross-Repository Verification And Local Account Recovery

**Files:**
- Verify: both repositories' target files from Tasks 1-5
- Operational data only: local PostgreSQL `ale_db` and K-device App Group `group.com.evlin.ios`
- Do not create or commit a product reset endpoint or migration.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: automated evidence plus a clean, zero-based local test account that preserves selection, Locked tokens, pairing, and per-app rules.

- [ ] **Step 1: Run the complete focused backend regression set**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
EVLIN_TEST_DATABASE_URL='postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test' \
  .venv/bin/python -m pytest \
  tests/test_earned_time_sample.py \
  tests/test_bigkid_endpoints.py \
  tests/test_metering_gate.py -q
```

Expected: PASS.

- [ ] **Step 2: Run the complete focused iOS regression set serially**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/BigKidModelsTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedConfigCommandTests'
```

Expected: PASS. If the known broad store double-free appears despite serial execution, rerun only the newly added store test methods and report the pre-existing suite defect separately; do not weaken assertions.

- [ ] **Step 3: Build the app and extensions**

```bash
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **` for app, DeviceActivity extension, and NSE targets.

- [ ] **Step 4: Verify only intended code is committed**

```bash
git status --short
git log --oneline -8
git diff --check
```

Expected: the user's pre-existing worktree changes may remain, but no generated Xcode state, `.DS_Store`, debugger state, credentials, database dump, or temporary plist is staged or committed.

- [ ] **Step 5: Restart the local backend with the fixed code**

Stop the existing local uvicorn process gracefully, then start from the backend repository with its existing `.env` and bind address:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Expected: health/API requests succeed at `http://192.168.1.175:8000/api/v1`; leave this session running through device verification.

- [ ] **Step 6: Back up and inspect the K-device App Group before reset**

Use the previously identified child device `F5946523-B50E-55D4-9305-4690E89929E0`:

```bash
mkdir -p /tmp/evlin-earned-recovery
xcrun devicectl device copy from \
  --device F5946523-B50E-55D4-9305-4690E89929E0 \
  --domain-type appGroupDataContainer \
  --domain-identifier group.com.evlin.ios \
  --source Library/Preferences/group.com.evlin.ios.plist \
  --destination /tmp/evlin-earned-recovery/before.plist
plutil -p /tmp/evlin-earned-recovery/before.plist
```

Expected preserved keys include measurement selection, Locked set ID/token data, child ID, base URL, and app-control data.

- [ ] **Step 7: Delete only today's local earned-time ledger rows**

First identify the account/family/device again; do not rely only on previously observed UUIDs:

```sql
SELECT a.email, a.family_id, d.id AS child_device_id, d.child_profile_id
FROM evlin_accounts a
JOIN evlin_devices d ON d.family_id = a.family_id
WHERE lower(a.email) = lower('gruoping@gmail.com')
  AND d.mode = 'child';
```

Run this transaction against local `ale_db`. It derives today's date in the active config timezone, refuses to proceed unless exactly one child device matches, prints the target and pre-delete counts, and deletes only the three earned ledger tables:

```sql
BEGIN;

CREATE TEMP TABLE evlin_recovery_target ON COMMIT DROP AS
SELECT
    a.family_id,
    d.id AS child_device_id,
    d.child_profile_id,
    cfg.timezone,
    timezone(cfg.timezone, now())::date AS usage_date
FROM evlin_accounts AS a
JOIN evlin_devices AS d
  ON d.family_id = a.family_id AND d.mode = 'child'
JOIN LATERAL (
    SELECT c.timezone
    FROM evlin_earned_time_configs AS c
    WHERE c.family_id = a.family_id
      AND c.child_profile_id = d.child_profile_id
      AND c.enabled = true
      AND c.superseded_at IS NULL
    ORDER BY c.effective_date DESC
    LIMIT 1
) AS cfg ON true
WHERE lower(a.email) = lower('gruoping@gmail.com');

DO $$
BEGIN
    IF (SELECT count(*) FROM evlin_recovery_target) <> 1 THEN
        RAISE EXCEPTION 'recovery target must contain exactly one child device';
    END IF;
END $$;

TABLE evlin_recovery_target;

SELECT
  (SELECT count(*) FROM evlin_earned_time_samples s, evlin_recovery_target t
    WHERE s.family_id=t.family_id AND s.child_profile_id=t.child_profile_id
      AND s.child_device_id=t.child_device_id AND s.usage_date=t.usage_date) AS samples,
  (SELECT count(*) FROM evlin_earned_time_device_days d, evlin_recovery_target t
    WHERE d.family_id=t.family_id AND d.child_profile_id=t.child_profile_id
      AND d.child_device_id=t.child_device_id AND d.usage_date=t.usage_date) AS device_days,
  (SELECT count(*) FROM evlin_earned_time_days d, evlin_recovery_target t
    WHERE d.family_id=t.family_id AND d.child_profile_id=t.child_profile_id
      AND d.usage_date=t.usage_date) AS child_days;

DELETE FROM evlin_earned_time_samples AS s
USING evlin_recovery_target AS t
WHERE s.family_id=t.family_id AND s.child_profile_id=t.child_profile_id
  AND s.child_device_id=t.child_device_id AND s.usage_date=t.usage_date;

DELETE FROM evlin_earned_time_device_days AS d
USING evlin_recovery_target AS t
WHERE d.family_id=t.family_id AND d.child_profile_id=t.child_profile_id
  AND d.child_device_id=t.child_device_id AND d.usage_date=t.usage_date;

DELETE FROM evlin_earned_time_days AS d
USING evlin_recovery_target AS t
WHERE d.family_id=t.family_id AND d.child_profile_id=t.child_profile_id
  AND d.usage_date=t.usage_date;

COMMIT;
```

Before typing `COMMIT`, verify the temporary table identifies the K device and local account. Use `ROLLBACK` on any mismatch.

- [ ] **Step 8: Clear only earned runtime keys from the backed-up plist**

Copy `before.plist` to `after.plist`, then remove these exact keys if present:

```text
earned.backendRemainingAtLastSync
earned.lastBackendSyncAt
earned.latestDeviceEstimate
earned.acceptedUsageDate
earned.acceptedEstimateMinutes
earned.poolMinutes
earned.capMinutes
earned.usageCountingOffset
evlin.earned.armSignature
evlin.usageCountingAllowed
evlin.earned.lastSamplePost
evlin.earned.lastThreshold
```

Also remove only the current day's earned retry entries after decoding the queue; preserve entries for other device identities for diagnosis. Do not remove keys beginning with `earned.measurementSelection`, `earned.lockedSet`, account pairing keys, App Control list/token keys, or per-app rule definitions.

Terminate the Evlin app process, copy the edited plist back into the same App Group preferences path, restart the child device to flush `cfprefsd`, then copy the plist out again and verify every intended key is absent and every preserved key remains.

- [ ] **Step 9: Install and launch the fixed K build**

Build/run the `Evlin iOS` scheme on Liam's iPhone from Xcode, or install the verified device build with `devicectl`. Confirm the diagnostics page shows:

```text
baseURL = http://192.168.1.175:8000/api/v1
usageCountingAllowed = true (after reflection/tasks are clear)
pool / cap = 120 min / 120 min
usage offset = 0 min
latestDeviceEstimate = 0 or missing before first threshold
measurement selection = non-zero apps/categories/web
locked set id = present
```

- [ ] **Step 10: Perform the physical five-minute acceptance test**

Keep tasks complete and reflection inactive. Open an app covered by the measurement selection for at least one full five-minute threshold. Then verify all layers:

```text
K diagnostics: last earned threshold becomes t5; sample POST is HTTP 200.
Backend response/log: counted=true and estimated_minutes=5.
Local PostgreSQL: one sample plus today's child-day/device-day rows exist.
K UI: Total Pool and Device Limit both decrease from 120 to 115.
Per-App Limit: continues to advance independently for a configured app.
Next 10-second poll: arm signature remains stable and does not replace an already-correct ladder.
```

Then activate a reflection, cross one test threshold, and verify `counted=false`, no ledger increase, no retry entry, and all three counters stop. Resolve reflection and verify the next poll restores/re-arms counters without reinstalling or changing Screen Time selection.

- [ ] **Step 11: Record verification evidence without committing secrets**

Add a concise result note to the task/PR description containing test command outcomes, device diagnostics before/after values, and the local DB row counts. Do not commit the plist backup, database URL, account credentials, device tokens, or raw App Group data.

---

## Final Review Checklist

- [ ] Backend and iOS use the same child device UUID for the shared gate.
- [ ] Every sample success communicates or safely defaults its counted disposition.
- [ ] Same-date stale snapshots cannot lower accepted usage.
- [ ] Canonical date rollover and explicit paused responses can lower/reset accepted usage.
- [ ] Raw `latestDeviceEstimate` cannot enter config re-arm offset math.
- [ ] Runtime policy is persisted before gate/re-arm decisions.
- [ ] False polls stop all three counters even when the previous gate was already false.
- [ ] Allowed stable polls retry earned arming and rely on the existing signature for idempotence.
- [ ] Missing runtime fields preserve old-server compatibility.
- [ ] Local recovery preserves measurement selection, Locked tokens, pairing, and app-control rules.
- [ ] Render data remains untouched.
