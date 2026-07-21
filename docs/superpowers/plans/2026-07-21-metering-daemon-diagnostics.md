# Metering Daemon Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a DEBUG-only evidence harness that proves what Evlin asked DeviceActivity to monitor, what the daemon retained, and whether legacy or v2 per-app topology produces the physical callback.

**Architecture:** A bounded App Group journal records immutable diagnostic events. Pure configuration summaries make expected-vs-actual comparison deterministic without exposing opaque tokens. A DEBUG scheduler decorator records per-app calls and schedules coalesced, off-main daemon readback; the existing probe then runs a single-token legacy/v2 A/B without modifying production policy behavior.

**Tech Stack:** Swift 6, DeviceActivity, FamilyControls, CryptoKit, XCTest, Xcode build/test, local FastAPI backend for the later v2 physical run.

## Global Constraints

- Follow `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/specs/2026-07-21-metering-daemon-diagnostics-design.md` exactly.
- All new diagnostic production symbols and hooks must be enclosed in `#if DEBUG`.
- Do not change `includesPastActivity`, arm identity, policy math, gates, shields, acknowledgements, reset behavior, or protocol selection.
- Do not add a production-readable feature flag or any new no-argument `stopMonitoring()` call.
- Do not modify or stage the beta/onboarding WIP files.
- Claude C1 has uncommitted hunks in `MeteringDeviceActivityCenter.swift`, `DatedRouteInstaller.swift`, `EarnedMeteringRecoveryDriver.swift`, and metering tests. Preserve them byte-for-byte; stage only diagnostic hunks if a shared file becomes unavoidable.
- Every DeviceActivity readback must execute off the main actor and automatic audit frequency is at most once per five minutes.
- A production behavior mismatch discovered by a RED test is reported; the assertion must not be weakened to match current behavior.
- No Render push, TestFlight upload, or production configuration change.

---

### Task 1: Bounded diagnostic journal

**Files:**
- Create: `Evlin iOS/Services/MeteringDaemonDiagnostics.swift`
- Create: `Evlin iOSTests/MeteringDaemonDiagnosticJournalTests.swift`

**Interfaces:**
- Produces: `MeteringDaemonDiagnosticEntry`, `MeteringDaemonDiagnosticJournal`, `MeteringDiagnosticOperation`, and `MeteringDiagnosticResult`, all inside `#if DEBUG`.
- Storage interface: injected `UserDefaults` plus `maximumEntries: Int = 400`; production default suite is `group.com.evlin.ios`.

- [ ] **Step 1: Write RED tests for ordering, bounding, clearing, and privacy**

Create tests that use a unique `UserDefaults` suite and assert:

```swift
let journal = MeteringDaemonDiagnosticJournal(defaults: defaults, maximumEntries: 3)
journal.append(.fixture(sequence: 1, activityName: "evlin.limit.v2.one"))
journal.append(.fixture(sequence: 2, activityName: "evlin.limit.v2.two"))
journal.append(.fixture(sequence: 3, activityName: "evlin.limit.v2.three"))
journal.append(.fixture(sequence: 4, activityName: "evlin.limit.v2.four"))
XCTAssertEqual(journal.read().map(\.sequence), [2, 3, 4])
XCTAssertFalse(try XCTUnwrap(String(data: journal.exportData(), encoding: .utf8)).contains("raw-token-fixture"))
journal.clear()
XCTAssertTrue(journal.read().isEmpty)
```

Also assert concurrent appends allocate unique increasing sequences and decode after creating a second journal instance.

- [ ] **Step 2: Run RED**

Run:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'Evlin iOSTests/MeteringDaemonDiagnosticJournalTests'
```

Expected: compile failure because the journal types do not exist.

- [ ] **Step 3: Implement the minimal journal**

Use `ActiveLockPersistenceLock.shared.withLock` around read-modify-write. Encode a single versioned envelope with `.sortedKeys`; never accept raw token data in the entry model. Generate the next sequence as `last.sequence + 1`, cap to the newest `maximumEntries`, and expose `read()`, `append(_:)`, `clear()`, and `exportData()`.

Required entry fields:

```swift
struct MeteringDaemonDiagnosticEntry: Codable, Equatable, Sendable {
    let sequence: UInt64
    let timestamp: Date
    let process: String
    let operation: MeteringDiagnosticOperation
    let activityName: String?
    let namespace: String?
    let armID: UUID?
    let expected: MeteringDaemonConfigurationSummary?
    let actual: MeteringDaemonConfigurationSummary?
    let result: MeteringDiagnosticResult
    let mismatchReasons: [String]
    let message: String?
}
```

Define `MeteringDaemonConfigurationSummary` as a forward-declared Codable model in this file; Task 2 fills its constructors/comparison.

- [ ] **Step 4: Run GREEN and existing persistence-lock tests**

Run the Task 1 command plus:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'Evlin iOSTests/ActiveLockPersistenceLockTests'
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit only Task 1**

Verify `git diff --cached` contains only the two Task 1 files, then commit:

```bash
git commit -m "test: add bounded metering daemon journal"
```

---

### Task 2: Deterministic exact configuration comparison

**Files:**
- Modify: `Evlin iOS/Services/MeteringDaemonDiagnostics.swift`
- Create: `Evlin iOSTests/MeteringDaemonConfigurationTests.swift`

**Interfaces:**
- Produces: `MeteringDaemonConfigurationSummary.make(schedule:events:)` and `differences(from:) -> [String]`.
- Token identity is represented only by sorted SHA-256 digests of `JSONEncoder(.sortedKeys)` output.

- [ ] **Step 1: Write one RED test per independent mismatch dimension**

Fixtures must prove the comparator independently detects:

1. schedule start/end/repeats;
2. event-name additions/removals;
3. threshold components;
4. `includesPastActivity`;
5. application/category/web token counts;
6. token digest changes;
7. identical Set contents inserted in different order compare equal.

Assert exact reason codes such as:

```swift
XCTAssertEqual(actual.differences(from: expected), ["event.evlin.test.includes_past"])
```

- [ ] **Step 2: Run RED**

Run only `MeteringDaemonConfigurationTests`; expected failure is missing factory/comparator methods.

- [ ] **Step 3: Implement canonical summaries**

Convert schedules and events into sorted value types. Sort event names and token digests. Preserve all relevant `DateComponents` values used by DeviceActivity schedules and thresholds. Do not compare opaque token descriptions or Set iteration order.

- [ ] **Step 4: Run GREEN and per-app planner tests**

Run:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'Evlin iOSTests/MeteringDaemonConfigurationTests' \
  -only-testing:'Evlin iOSTests/AppLimitPlannerTests'
```

Expected: all selected tests pass; planner behavior is unchanged.

- [ ] **Step 5: Commit only Task 2**

```bash
git commit -m "test: compare daemon metering configuration exactly"
```

---

### Task 3: Off-main single-flight inspector

**Files:**
- Modify: `Evlin iOS/Services/MeteringDaemonDiagnostics.swift`
- Create: `Evlin iOSTests/MeteringDaemonInspectorTests.swift`

**Interfaces:**
- Produces: `MeteringDaemonReadbackPort`, `SystemMeteringDaemonReadback`, and actor `MeteringDaemonInspector`.
- Entry point: `request(_ request: MeteringDaemonInspectionRequest) async` where reasons are `.afterArm`, `.configurationChanged`, `.manual`, and `.audit`.

- [ ] **Step 1: Write RED tests with a blocking readback spy**

Tests assert:

- concurrent requests coalesce into one daemon pass;
- two `.audit` requests inside 300 seconds perform one pass;
- `.afterArm` and `.configurationChanged` bypass the audit interval but still coalesce;
- the readback spy observes `Thread.isMainThread == false`;
- missing activity, exact match, mismatch, and thrown readback each append the correct journal result;
- failure does not permanently suppress a later request.

- [ ] **Step 2: Run RED**

Expected: compile failure because inspector/readback types do not exist.

- [ ] **Step 3: Implement the actor and system port**

The actor owns `inFlight`, `lastAuditAt`, a clock injection, and journal. It launches system XPC work via `Task.detached(priority: .utility)` and awaits the result before appending. `SystemMeteringDaemonReadback` uses `DeviceActivityCenter.activities`, `schedule(for:)`, and `events(for:)` and returns immutable summaries.

- [ ] **Step 4: Run GREEN and watchdog-related C1 tests**

Run inspector tests plus:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'Evlin iOSTests/MeteringRuntimeInfrastructureTests' \
  -only-testing:'Evlin iOSTests/MeteringCoverageIntegrationTests'
```

Expected: all selected tests pass and no main-thread readback assertion fires.

- [ ] **Step 5: Commit only Task 3**

```bash
git commit -m "test: inspect DeviceActivity state off main"
```

---

### Task 4: Instrument per-app start/stop without changing behavior

**Files:**
- Modify: `Evlin iOS/Services/ActionExecutor.swift` (only `DeviceActivityCenterScheduler` DEBUG hunks)
- Modify: `Evlin iOS/Services/MeteringDaemonDiagnostics.swift`
- Create: `Evlin iOSTests/DiagnosticDeviceActivitySchedulerTests.swift`

**Interfaces:**
- Produces: DEBUG implementation details in `DeviceActivityCenterScheduler`; the `DeviceActivityScheduling` interface remains unchanged.
- Uses Task 3 inspector after successful event-bearing starts.

- [ ] **Step 1: Write RED delegation and behavior-neutrality tests**

Using an injected center/readback spy, assert each overload delegates exactly once, thrown errors propagate unchanged, named stop delegates exactly once, and global stop is recorded as `.stopAll` severity without being suppressed. Assert a successful per-app start queues one `.afterArm` inspection containing the exact expected summary.

- [ ] **Step 2: Run RED**

Expected: tests fail because the system scheduler has no diagnostic injection seam.

- [ ] **Step 3: Add DEBUG-only injection and recording**

Keep the Release initializer and methods byte-equivalent. Under `#if DEBUG`, allow journal/inspector injection and record before/after outcomes. Do not retry or convert errors. `monitoredActivities()` may record a count but must not trigger full readback.

- [ ] **Step 4: Prove stable poll does not re-arm per-app in automation**

Add or extend a production integration test that performs two poll-completion owner recoveries after the applied receipt is committed and asserts the scheduler received exactly one start with the same arm ID. This test is allowed to disprove the churn hypothesis; do not alter production code if it already passes.

- [ ] **Step 5: Run GREEN and app-limit owner suites**

Run diagnostic scheduler tests plus `AppLimitPlannerTests`, `AppLimitWakeRecoveryTests`, `AppLimitProductionIntegrationTests`, and `CommandPollerAppLimitTests`. Expected: all selected tests pass and the stable-poll start count is one.

- [ ] **Step 6: Stage only diagnostic hunks and commit**

Assert cached diff contains no `beta`, `agreement`, or onboarding identifiers and no change to `includesPastActivity`:

```bash
git diff --cached | rg -n "beta|agreement|ParentBeta|includesPastActivity" && exit 1 || true
git commit -m "test: trace per-app DeviceActivity arming"
```

---

### Task 5: Read-only diagnostic screen

**Files:**
- Create: `Evlin iOS/Views/Debug/MeteringDaemonDiagnosticsView.swift`
- Modify: `Evlin iOS/Views/Home/HomeSettingsSheet.swift` (one DEBUG navigation row only)
- Create: `Evlin iOSTests/MeteringDaemonDiagnosticsViewTests.swift`

**Interfaces:**
- Screen controls: Refresh, Export, Clear.
- The view receives a fixture snapshot under `#if DEBUG` for deterministic tests; production diagnostics read the journal and store state.

- [ ] **Step 1: Write RED structural tests**

Assert the rendered fixture exposes owner readiness, ratchet selection, namespace counts, start/stop totals, latest mismatch reasons, and chronological entries. Add source guards proving the view contains no calls to `startMonitoring`, `stopMonitoring`, reset, lock, unlock, or protocol mutation APIs.

- [ ] **Step 2: Run RED**

Expected: missing view/fixture types.

- [ ] **Step 3: Implement the read-only view**

Use compact `List` sections suitable for diagnostics. Refresh calls inspector `.manual`; Export presents the journal JSON through the existing share pattern; Clear removes journal entries only. Do not add explanatory feature marketing or a mutating probe control to this screen.

- [ ] **Step 4: Run GREEN and build both Debug and Release**

Run view tests, then generic Debug and Release builds. Scan the Release binary/build products for `MeteringDaemonDiagnosticJournal`, `Metering daemon`, and journal key strings; expected zero hits.

- [ ] **Step 5: Stage the exact HomeSettingsSheet hunk and commit**

Verify the existing unrelated HomeSettingsSheet diff remains unstaged and byte-identical. Commit:

```bash
git commit -m "test: expose read-only daemon diagnostics"
```

---

### Task 6: Controlled legacy/v2 per-app A/B probe

**Files:**
- Modify: `Evlin iOS/Components/Debug/AppLimitOneMinuteProbeView.swift`
- Modify: `Evlin iOS/Services/MeteringDaemonDiagnostics.swift`
- Create: `Evlin iOSTests/AppLimitTopologyProbeTests.swift`

**Interfaces:**
- Produces: pure `AppLimitTopologyProbePlan.make(mode:token:now:timezone:)` for `.legacyWindow` and `.v2PerRule`.
- Both plans expose one named activity, one named event, identical schedule/threshold/token summary, and their topology-specific names.

- [ ] **Step 1: Write RED plan-equivalence tests**

Assert legacy and v2 plans differ only in activity/event topology. Their schedule, threshold, `includesPastActivity`, timezone, and token digests must be equal. Assert each mode stops only the two reserved probe activity names and never a production namespace.

- [ ] **Step 2: Run RED**

Expected: missing probe plan/mode types.

- [ ] **Step 3: Implement the pure plan and mutually exclusive runner**

The runner requires current owner readiness, one selected application token, and no active probe. It clears only prior probe markers, stops only explicit probe names, starts one mode, records expected configuration, requests after-arm readback, and stores run identity. It never writes AppLimitEpochStore or backend policy.

- [ ] **Step 4: Record callbacks in the monitor extension using probe-only names**

Add a DEBUG-only early branch in `DeviceActivityMonitorExtension.eventDidReachThreshold` for the two exact reserved event prefixes. It appends a callback journal entry and returns without shield, sample, or policy effects. Add an extension source guard test proving the branch is `#if DEBUG` and precedes production routing.

- [ ] **Step 5: Run GREEN and extension builds**

Run topology tests and compile the app plus DeviceActivity extension in Debug and Release. Release symbol scan must find zero probe names.

- [ ] **Step 6: Commit only Task 6**

```bash
git commit -m "test: add per-app topology physical probe"
```

---

### Task 7: Whole-device v2 activation evidence and physical runbook

**Files:**
- Modify: `Evlin iOS/Services/MeteringDaemonDiagnostics.swift`
- Modify: `Evlin iOS/Views/Debug/MeteringDaemonDiagnosticsView.swift`
- Create: `docs/superpowers/runbooks/2026-07-21-metering-daemon-physical.md`
- Create: `Evlin iOSTests/MeteringDaemonActivationEvidenceTests.swift`

**Interfaces:**
- Produces a read-only activation timeline derived from `DeviceEpochStore`: advertised protocol, local selection, epoch ID, verification, activation acknowledgement, install phases, and exact daemon coverage.

- [ ] **Step 1: Write RED activation evidence tests**

Fixtures cover v1, dual-active incomplete, dual-active fully installed but unacknowledged, and v2. Assert the summary never labels a device v2 until the ratchet is `.v2` and all active dated routes read back exact.

- [ ] **Step 2: Run RED, implement summary, run GREEN**

The summary is read-only and must not call registration/activation APIs.

- [ ] **Step 3: Write an exact runbook**

Include:

1. local backend command with `METERING_EPOCH_ADVERTISED_VERSION=2`;
2. one-device re-pair and identity checks;
3. commands/diagnostic rows proving each activation stage;
4. per-app A/B timing and evidence capture;
5. v2 gate pause/resume, manual lock/unlock, and controlled reset runs;
6. abort conditions: owner mismatch, missing selection, global stop, main-thread XPC, missing/mismatched daemon config;
7. a result table that records PASS/FAIL/UNKNOWN without causal guesswork.

- [ ] **Step 4: Run the full diagnostic regression and Release scan**

Run all new tests, all app-limit suites, metering coverage/activation suites, generic Debug build, and all five Release product builds. Expected: selected suites green; Release products contain no diagnostic symbols/strings.

- [ ] **Step 5: Commit Task 7 and generate the diagnostic build**

```bash
git commit -m "docs: add metering daemon physical runbook"
```

Do not call the metering feature fixed. Report only that the diagnostic build is ready and list the exact first device action.
