# Earned Threshold Plausibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent iPadOS historical-activity and callback bursts from falsely exhausting earned-time pools or locking a child device.

**Architecture:** Stage 1.1 implements G-20/R-15 before stage 2. New earned generations carry an arm timestamp and explicitly exclude past activity; the extension rejects physically impossible thresholds before local reconciliation, queueing, or shielding, while the backend repeats the same validation for metadata-bearing samples. Rejections fail open and return the existing authoritative snapshot without a database write.

**Tech Stack:** Swift 5, DeviceActivity, FamilyControls, XCTest, FastAPI, Pydantic v2, SQLAlchemy async, pytest, PostgreSQL 17.

## Global Constraints

- `LOCK_BEHAVIOR_BOUNDARIES.md` G-20/R-15 is authoritative; R-15 runs before R-3.
- Maximum trusted estimate is `offset + floor(max(0, callbackAt - armedAt) / 60 seconds) + 5`.
- An implausible callback must not mutate the local estimate, enqueue/POST a sample, apply a shield, insert a backend row, advance a ledger, or queue an auto-lock.
- Missing generation metadata remains accepted only for legacy clients; partial metadata is uncounted.
- Per-app limit behavior and files remain unchanged except for regression verification.
- Preserve unrelated beta-agreement worktree changes; stage exact files only.
- Do not push or deploy Render.

---

### Task 1: Backend Plausibility Boundary

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/schemas/earned_time.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/earned_time.py`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_sample.py`

**Interfaces:**
- Consumes: existing `SampleIngestRequest`, `current_device_day_snapshot`, and `DeviceDaySnapshot.counted/warning`.
- Produces: optional `generation_armed_at: datetime`, optional `generation_offset_minutes: int`, and pure `_sample_is_plausible(body) -> bool | None`; `None` means legacy metadata absent.

- [ ] **Step 1: Write failing route tests**

Add tests proving: a metadata-bearing t10 after five elapsed minutes is counted; t120 five seconds after arm returns HTTP 200 with `counted=false` and `warning="implausible_threshold"`; partial metadata is uncounted; no sample/device-day/lock-command row is created; a legacy body remains counted.

- [ ] **Step 2: Run the focused backend tests and verify RED**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  .venv/bin/pytest tests/test_earned_time_sample.py -q
```

Expected: new metadata assertions fail because the DTO and route guard do not exist.

- [ ] **Step 3: Add optional DTO fields and pure validation**

Implement:

```python
generation_armed_at: datetime | None = None
generation_offset_minutes: int | None = Field(default=None, ge=0, le=1440)
```

The pure helper returns `None` when both fields are absent, `False` for partial metadata or negative elapsed time, and otherwise checks both threshold and estimate against the five-minute-slack ceiling.

- [ ] **Step 4: Reject before ingestion**

After identity, device, and usage-counting-gate checks, evaluate plausibility. For `False`, project `observed_at` through the child's canonical timezone, fetch `current_device_day_snapshot`, and return `model_copy(update={"counted": False, "warning": "implausible_threshold"})`. Do not call `ingest_sample` or commit a sample mutation.

- [ ] **Step 5: Run backend regression**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  .venv/bin/pytest \
  tests/test_earned_time_sample.py \
  tests/test_metering_gate.py \
  tests/test_earned_time_auto_lock.py -q
```

Expected: focused tests pass with no new failures.

- [ ] **Step 6: Commit exact backend files**

```bash
git add app/schemas/earned_time.py app/api/routes/earned_time.py tests/test_earned_time_sample.py
git diff --cached --check
git commit -m "fix: reject implausible earned-time samples"
```

---

### Task 2: Generation Time And Past-Activity Exclusion

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetScheduler.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetSchedulerTests.swift`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetArmingTests.swift`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`

**Interfaces:**
- Produces: backward-compatible `Generation.armedAt: Date?`, `EarnedThresholdPlausibility.evaluate(...)`, and `EarnedBudgetScheduler.makeEvent(...)` with `includesPastActivity=false`.

- [ ] **Step 1: Write failing pure tests**

Cover legacy generation decoding with no timestamp, timestamp round-trip, exact-ceiling acceptance, above-ceiling rejection, callback-before-arm rejection, old active generation requiring replacement, and `makeEvent(...).includesPastActivity == false`.

- [ ] **Step 2: Run iOS focused tests and verify RED**

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests'
```

Expected: compile/test failure for missing timestamp, helper, and event factory.

- [ ] **Step 3: Implement generation timestamp and pure ceiling**

Add an optional `armedAt` with a default of `nil` so existing call sites and stored v1/v2 lifecycle JSON remain compatible. The pure evaluator returns a structured result containing `isPlausible` and `maximumTrusted`; new generations pass `Date()`.

- [ ] **Step 4: Explicitly exclude past activity**

Extract earned event construction into `makeEvent(selection:thresholdMinutes:)` and call the iOS 17.4 initializer with `includesPastActivity: false`. Do not change `AppLimitPlanner`.

- [ ] **Step 5: Force replacement of legacy active generations**

Treat `activeGeneration?.armedAt == nil` as a force condition in `armIfReady`; callbacks from a missing-timestamp generation remain untrusted until replacement.

- [ ] **Step 6: Run focused tests and commit exact files**

Expected: all selected tests pass.

```bash
git add -- \
  'Evlin iOS/Services/EarnedTimeStore.swift' \
  'Evlin iOS/Services/EarnedBudgetScheduler.swift' \
  'Evlin iOS/Services/EarnedBudgetArming.swift' \
  'Evlin iOSTests/EarnedBudgetSchedulerTests.swift' \
  'Evlin iOSTests/EarnedBudgetArmingTests.swift' \
  'Evlin iOSTests/EarnedTimeStoreTests.swift'
git diff --cached --check
git commit -m "fix: timestamp earned activity generations"
```

---

### Task 3: Extension Guard And Sample Metadata

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`

**Interfaces:**
- Consumes: Task 2 `Generation.armedAt` and `EarnedThresholdPlausibility.evaluate`.
- Produces: retry entries and request bodies containing `generation_armed_at` and `generation_offset_minutes`; implausible decisions set all three side-effect flags false.

- [ ] **Step 1: Write failing reporter tests**

Test metadata JSON keys, retry-entry round-trip compatibility with legacy queue JSON, plausible decision behavior, and implausible decision behavior (`shouldReport=false`, `shouldMutateLocalEstimate=false`, `shouldApplyLocalShield=false`).

- [ ] **Step 2: Run reporter tests and verify RED**

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests'
```

- [ ] **Step 3: Extend retry entries and request bodies**

Store optional generation fields in `RetryEntry`, preserve decoding of old queue entries, and include both JSON fields only when both exist. Extension-created entries always contain both.

- [ ] **Step 4: Guard the extension before all side effects**

Immediately after computing `adjustedN`, evaluate R-15 using one captured callback `Date`. On rejection, write `evlin.earned.implausibleThreshold` through the authorized App Group mutation helper and return before `recordLocalThresholdEstimate`, `enqueueRetry`, network work, or shield gates.

- [ ] **Step 5: Run reporter plus earned extension regression**

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests'
```

- [ ] **Step 6: Commit exact iOS files**

```bash
git add -- \
  'Evlin iOS/Services/EarnedSampleReporter.swift' \
  'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' \
  'Evlin iOSTests/EarnedSampleReporterTests.swift'
git diff --cached --check
git commit -m "fix: drop implausible earned thresholds"
```

---

### Task 4: Regression, Recovery, And Physical Acceptance

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/plans/2026-07-13-earned-threshold-plausibility.md` (checkboxes only)
- Preserve: `/Users/fred/Desktop/Evlin/device-backups/2026-07-13-earned-time/before.plist`

- [ ] **Step 1: Run full focused iOS regression**

Run the seven earned/per-app suites used for commit `da8c630`; expected at least 185 tests and zero failures.

- [ ] **Step 2: Run backend focused regression and discipline checks**

Run Task 1 tests plus `scripts/check_time_day_discipline.py`; expect zero new failures.

- [ ] **Step 3: Build the signed iPad target**

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'id=00008101-001675CE3C11A01E' -configuration Debug build
```

- [ ] **Step 4: Back up current evidence and reset local test state**

Copy the current App Group plist to a new timestamped backup. In a PostgreSQL transaction scoped to child `38cc576f-47b3-4df8-b2a3-7b2510af475e`, device `81635fc2-6c2f-4f78-bfbb-9bb5215b00e1`, and usage date `2026-07-13`, delete only earned samples/device-day/child-day and test-generated earned lock state; inspect affected rows before `COMMIT`. Preserve configs and all identity/catalog rows.

On the iPad, retain measurement selection and locked-set tokens, mark the old lifecycle stopped/unauthorized, clear today's accepted estimate, usage offset, cached backend remaining, arm signature, threshold diagnostics, and earned-time shield source. Launch the new build once and verify a fresh generated activity with `armedAt` and `includesPastActivity=false`.

- [ ] **Step 5: Background acceptance**

Use Apple Maps for 6-10 minutes with Evlin backgrounded. Verify the iPad diagnostic advances to t5/t10, backend used minutes match, and the parent summary decreases by the same amount without a burst.

- [ ] **Step 6: Force-quit acceptance**

Force quit Evlin, use Apple Maps for 6-10 minutes, and inspect the backend before reopening Evlin. A normal callback must count; an impossible burst must produce the local diagnostic, no accepted backend row, no ledger jump, and no earned shield.

- [ ] **Step 7: Final scope review**

Verify each repository's staged diff contains only the task files, all unrelated dirty files remain untouched, and no Render deployment occurred.
