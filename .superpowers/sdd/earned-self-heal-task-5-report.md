# Earned-Time Poll Self-Heal Task 5 Report

## Status

- Implemented and committed as `d951e8a` (`fix: self-heal earned policy from child state`).
- Commit contains only Task 5 changes in the four owned source/test files.
- Existing unrelated dirty edits remain untouched.

## Pre-Edit Production Diff

Captured before any edit as `/tmp/earned-task5-pre-edit.diff`.

- SHA-256: `20dbc4fb158f15987a7470fa3be91aa8ea23d911808b1911cc8b6e2c1e772c11`
- Length: 99 lines

```diff
diff --git a/Evlin iOS/Services/BigKidStatePoller.swift b/Evlin iOS/Services/BigKidStatePoller.swift
index f7eb9f5..47b1cb9 100644
--- a/Evlin iOS/Services/BigKidStatePoller.swift
+++ b/Evlin iOS/Services/BigKidStatePoller.swift
@@ -235,14 +235,29 @@ final class BigKidStatePoller: ObservableObject {
         if store.isEarnedTimeReady, let selection = store.measurementSelection {
             let inputs = Self.earnedRearmInputs(store: store)
             store.earnedUsageOffsetMinutes = inputs.offset
-            // Arm at the REAL pool/cap; the offset is applied by the extension
-            // (adjustedN = offset + rawN), so the ladder itself keeps real budgets.
-            if min(inputs.poolMinutes, inputs.capMinutes) - inputs.offset > 0 {
-                EarnedBudgetScheduler.shared.armFromNow(
-                    poolMinutes: inputs.poolMinutes,
-                    capMinutes: inputs.capMinutes,
+            // Arm only the uncounted raw window; the extension adds the offset
+            // back when reporting cumulative usage.
+            if let remainingPolicy = EarnedBudgetScheduler.remainingPolicy(
+                poolMinutes: inputs.poolMinutes,
+                capMinutes: inputs.capMinutes,
+                offsetMinutes: inputs.offset
+            ) {
+                let armed = EarnedBudgetScheduler.shared.armFromNow(
+                    poolMinutes: remainingPolicy.poolMinutes,
+                    capMinutes: remainingPolicy.capMinutes,
                     selection: selection
                 )
+                if armed {
+                    let currentDeviceID = UserDefaults.standard.string(
+                        forKey: CommandPoller.childDeviceIDDefaultsKey
+                    ) ?? ""
+                    EarnedBudgetArming.rememberCurrentArmSignature(
+                        deviceID: currentDeviceID,
+                        poolMinutes: inputs.poolMinutes,
+                        capMinutes: inputs.capMinutes,
+                        selection: selection
+                    )
+                }
             } else {
                 CommandDeliveryDiagnostics.record(
                     CommandDeliveryDiagnostics.keyEarnedArmAttempt,
diff --git a/Evlin iOS/Services/CommandPoller.swift b/Evlin iOS/Services/CommandPoller.swift
index 0f886a0..56d8f18 100644
--- a/Evlin iOS/Services/CommandPoller.swift
+++ b/Evlin iOS/Services/CommandPoller.swift
@@ -678,26 +678,49 @@ final class CommandPoller {
                 EarnedTimeStore.shared.latestDeviceEstimate ?? 0,
                 EarnedTimeStore.shared.earnedUsageOffsetMinutes
             )
+            let offset = EarnedTimeStore.shared.earnedUsageOffsetMinutes
             guard EarnedTimeStore.shared.usageCountingAllowed else {
                 EarnedBudgetScheduler.shared.stop()
                 return await ackEarnedTimeConfig(commandID: commandID, api: api)
             }
+            guard let remainingPolicy = EarnedBudgetScheduler.remainingPolicy(
+                poolMinutes: poolMinutes,
+                capMinutes: capMinutes,
+                offsetMinutes: offset
+            ) else {
+                CommandDeliveryDiagnostics.record(
+                    CommandDeliveryDiagnostics.keyEarnedArmAttempt,
+                    "skipped config-no-remaining pool=\(poolMinutes) cap=\(capMinutes) offset=\(offset)"
+                )
+                return await ackEarnedTimeConfig(commandID: commandID, api: api)
+            }
             if let armOverride = armBudgetOverride, EarnedTimeStore.shared.hasMeasurableSelection {
                 // Test seam: provide the real selection (or empty) to the override
                 // so tests can verify pool/cap values without DeviceActivity.
                 let selection = EarnedTimeStore.shared.measurementSelection!
                 CommandDeliveryDiagnostics.record(
                     CommandDeliveryDiagnostics.keyEarnedArmAttempt,
-                    "test-arm-override pool=\(poolMinutes) cap=\(capMinutes) \(EarnedBudgetScheduler.selectionSummary(selection))"
+                    "test-arm-override pool=\(remainingPolicy.poolMinutes) cap=\(remainingPolicy.capMinutes) offset=\(offset) \(EarnedBudgetScheduler.selectionSummary(selection))"
                 )
-                armOverride(poolMinutes, capMinutes, selection)
+                armOverride(remainingPolicy.poolMinutes, remainingPolicy.capMinutes, selection)
             } else if EarnedTimeStore.shared.hasMeasurableSelection,
                       let selection = EarnedTimeStore.shared.measurementSelection {
-                EarnedBudgetScheduler.shared.armFromNow(
-                    poolMinutes: poolMinutes,
-                    capMinutes: capMinutes,
+                let armed = EarnedBudgetScheduler.shared.armFromNow(
+                    poolMinutes: remainingPolicy.poolMinutes,
+                    capMinutes: remainingPolicy.capMinutes,
                     selection: selection
                 )
+                if armed {
+                    let currentDeviceID = UserDefaults.standard.string(
+                        forKey: CommandPoller.childDeviceIDDefaultsKey
+                    ) ?? ""
+                    EarnedBudgetArming.rememberCurrentArmSignature(
+                        deviceID: currentDeviceID,
+                        poolMinutes: poolMinutes,
+                        capMinutes: capMinutes,
+                        selection: selection
+                    )
+                }
             } else {
                 let selection = EarnedTimeStore.shared.measurementSelection
                 let summary = selection.map(EarnedBudgetScheduler.selectionSummary) ?? "(missing)"
```

## RED/GREEN Evidence

- RED command: focused serial `xcodebuild test` for `BigKidStatePollerTests` and `EarnedConfigCommandTests`.
- RED result: exit 65. Compilation failed on the intentionally absent `syncEarnedRuntime`, `ensureEarnedArmed`, and observable three-counter stop seams.
- First GREEN attempt exposed an actor-isolation compile error in default closure arguments; the seam was corrected to retain a private no-argument production wrapper.
- Final GREEN result: `** TEST SUCCEEDED **`; 21 tests executed, 0 failures.
- Simulator build result: `** BUILD SUCCEEDED **` for iPhone 17 simulator.

## Runtime and Gate Evidence

- `test_refresh_appliesRuntimeBeforeAuthoritativeGateAndEarnedArm` asserts `apply -> runtime -> gate -> arm`.
- `test_refresh_persistsValidRuntimeAndMonotonicAcceptedEstimate` verifies exact pool, cap, backend remaining, sync timestamp, usage date, and same-day monotonic accepted estimate.
- `test_refresh_ignoresZeroPoolRuntimeAndPreservesStoredPolicy` verifies the current 0 pool/cap compatibility behavior.
- `test_refresh_usesAuthoritativeGateInsteadOfDerivedTaskState` verifies the response gate overrides locally derived task state.
- Existing skipped-event and transition tests remain green.

## Poll Self-Heal Evidence

- `test_refresh_retriesEarnedArmOnEveryStableAllowedPoll` verifies two stable true polls invoke earned arming twice while transition recovery stays idle.
- `test_refresh_stopsCountersOnEveryStableFalsePoll` verifies two stable false polls invoke the stop path twice.
- Production true polls invoke `EarnedBudgetArming.armIfReady()` and rely on its signature idempotence.

## Three-Counter Evidence

- `test_stopUsageCountersForTaskPause_stopsAllThreeCounterSystems` observes the production helper call order: earned, device-total, per-app.
- The production wrapper supplies `EarnedBudgetScheduler.shared.stop()`, `BigKidActivityScheduler.shared.stop()`, and `AppLimitPlanner().arm(rules: [])`.

## Config Baseline Evidence

- `test_poller_earnedTimeConfigUsesAcceptedEstimateInsteadOfRawPhantom` seeds raw latest estimate 25, accepted estimate 0, and offset 0.
- After config processing, pool/cap are 120/120 and offset remains 0.
- `CommandPoller` now computes config offset from `acceptedEstimateMinutes` and `earnedUsageOffsetMinutes` only.

## Staging Boundaries

- Generated baseline index: `HEAD` plus `/tmp/earned-task5-pre-edit.diff`.
- Generated Task 5 patch: `/tmp/earned-task5-only.patch`, SHA-256 `d5e47d54b24b0d98ea71cb4cc63bba9865d1acaf8909bf262a291c80ad15f420`.
- The normal-context patch needed prerequisite context in `CommandPoller` and did not apply to the real `HEAD` index. A generated zero-context version was applied with `git apply --cached --unidiff-zero`.
- Cached files were exactly the four owned production/test files.
- Cached scan contained no `remainingPolicy`, `rememberCurrentArmSignature`, `Arm only the uncounted raw window`, or `test-arm-override` prerequisite content.
- Unstaged production scan retained all prerequisite `remainingPolicy` and `rememberCurrentArmSignature` hunks.
- No changed prerequisite line was inseparable or included in the commit; only patch context required narrowing.
- `git diff --cached --check` passed before commit.

## Commit

- SHA: `d951e8a`
- Subject: `fix: self-heal earned policy from child state`
- Stat: 4 files changed, 251 insertions, 17 deletions.

## Concerns

- No Task 5 correctness concern identified by focused tests or simulator build.
- Existing project-wide Swift concurrency and run-script warnings remain; they predate and are outside Task 5 ownership.
- Simulator test logs include expected Family Controls authorization and simulator IOHID/network warnings; all selected tests passed.

## Review Fix

### Pre-Edit Baseline

- Owned tracked diff: `/tmp/earned-task5-review-fix-pre-edit.diff`, 346 lines, SHA-256 `2d96a6df0b623164410f211fbdd38c480f2823cd03165f0d06b6274c3ded48e8`.
- Untracked prerequisite `EarnedBudgetArmingTests.swift`: 55 lines, SHA-256 `93cec44a756644c7a42217332f71c85601c2b4fe4dcf4f0388be0ffdd38bba91`.
- Unrelated dirty and untracked files were preserved without staging.

### Red/Green Evidence

- Signature/offset RED: focused arming and poller compilation failed because `makeArmSignature` did not accept `offsetMinutes`; GREEN: 18 tests passed after threading offset through current/remember call sites and removing the duplicate earned recovery arm.
- Runtime/overlap RED: compilation failed on the absent `reconcileRuntimePolicy` API and identity-transition seam; GREEN: the combined poller/runtime/config run passed 22 tests.
- Config measurable-path RED: compilation failed on the intentionally absent `hasMeasurableSelectionOverride`; accepted-zero and non-bucket tests then passed with exact armed policies `120/120` and `113/113`.
- Accepted fallback RED: expected 53 but observed 35 from raw estimate 25; GREEN after deriving the fallback from accepted offset 7.
- Required final serial run: `BigKidStatePollerTests`, `EarnedConfigCommandTests`, `EarnedBudgetSchedulerTests`, `EarnedBudgetArmingTests`, and the three named runtime-policy tests passed, 48 tests, 0 failures.
- Simulator build: `** BUILD SUCCEEDED **` for `iPhone 17 Pro`.

### Prerequisite Integration

- Formally integrated the arm signature key, SHA-256 selection fingerprint, identity/date/timezone/policy/selection/offset signature, successful-arm signature persistence, and identity-transition signature clearing.
- Corrected the prerequisite signature so accepted offset changes re-arm the remaining raw window while unchanged inputs skip.
- Formally integrated `EarnedBudgetScheduler.remainingPolicy` and its scheduler tests.
- Included the corrected formerly-untracked `EarnedBudgetArmingTests.swift`; its offset expectation now requires a changed offset to re-arm.
- Excluded unrelated `EarnedSampleReporter.clearRetryQueue` cleanup.

### Review Behavior Evidence

- Poll order is identity teardown, fetch, reflection reconciliation, UI snapshot, validated runtime reconciliation, authoritative gate, then the sole earned arm path.
- An in-flight guard suppresses overlapping refreshes. Identity transition does not arm before runtime and gate.
- Stable false polls call the production stop path every time; its observed order covers earned, device-total, and per-app counters.
- Stable true polls call `armIfReady`; transition/skipped recovery re-arms only device-total and per-app.
- Runtime policy validation requires exact Gregorian `yyyy-MM-dd`, a valid timezone, pool/cap `1...1440`, and remaining/estimate `0...1440`. Zero pool/cap is intentionally ignored for compatibility.
- Runtime policy writes and accepted-baseline reconciliation share the Task 4 lock. A stale date returns before any pool, cap, remaining, sync-time, or accepted-usage write.
- Neither `BigKidStatePoller` nor `CommandPoller` references `latestDeviceEstimate`; accepted estimate plus stored accepted offset is the only config/re-arm baseline.

### Staging And Clean-Checkout Coherence

- Cached patch: `/tmp/earned-task5-review-fix-cached.diff`, SHA-256 `e513b4bb7421a1b6447b34fd72db56548c538e68f62364cd16f9a2c9a103135c`.
- Cached tree: `5c5b0d4483f8886d9fdd9db27cee763f31c958e4`.
- Cached paths were exactly the ten expanded-ownership files; `git diff --cached --check` passed.
- No owned changes remained unstaged. Cached scans found no retry-queue cleanup or unrelated file paths.
- The cached tree contains definitions and all call sites for `remainingPolicy`, offset-bearing `makeArmSignature`/`rememberCurrentArmSignature`, measurable config seam, and `reconcileRuntimePolicy`; no correctness dependency remains only in the dirty working tree.

### Commit

- SHA: `c097c50`
- Subject: `fix: close earned self-heal review gaps`
- Stat: 10 files changed, 656 insertions, 70 deletions.

### Concerns

- No Task 5 correctness concern remains in the requested verification surface.
- Existing project run-script warnings and simulator Family Controls, IOHID, and network warnings remain; tests and build succeeded.

## Review Fix 2 — Historical Replay

### Root Cause

- Accepted sample/runtime reconciliation rewrote the offset owned by the running raw ladder, so accepted usage advancement changed the arm signature and triggered replacement polling.
- Replacements reused the fixed `evlin.earned.budget` activity, allowing DeviceActivity to replay usage accumulated before the new iPad identity and policy were installed.
- Overlapping child-state refreshes were dropped instead of scheduling one follow-up reconciliation.

### RED Evidence

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests/test_countedT5LeavesRunningOffsetZeroSoRawT10AdjustsToTen' \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests/test_generatedActivityNamesAreDistinctAndRecognized' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests/test_failedReplacementPreservesOffsetSignatureAndGeneration' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests/test_refresh_coalescesMultipleOverlapsIntoOneFollowUpFetch'
```

- Result: exit 65, as expected. Compilation failed on the intentionally absent adjusted-threshold, generation, replacement-persistence, and centralized-stop APIs.
- The overlap test also changed the expected behavior from one dropped overlap to exactly one coalesced follow-up fetch.

### GREEN Evidence

Focused historical-replay run:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests/test_countedT5LeavesRunningOffsetZeroSoRawT10AdjustsToTen' \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests/test_generatedActivityNamesAreDistinctAndRecognized' \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests/test_failedGenerationInstallPreservesPriorGenerationAndStopsNothing' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests/test_failedReplacementPreservesOffsetSignatureAndGeneration' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests/test_stopInvalidatesSignatureSoFalseToTrueReinstallsExactlyOnce' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests/test_refresh_coalescesMultipleOverlapsIntoOneFollowUpFetch'
```

- Result: `** TEST SUCCEEDED **`; 6 tests executed, 0 failures.

Required serial suites plus directly affected offset suites:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedConfigCommandTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterResponseTests' \
  -only-testing:'Evlin iOSTests/EarnedGateTautologyTests'
```

- Result: `** TEST SUCCEEDED **`; 119 tests executed, 0 failures.

Simulator app and embedded extension build:

```bash
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

- Result: `** BUILD SUCCEEDED **`; `EvlinDeviceActivityMonitor.appex` compiled, signed, embedded, and validated.

### Commit

- SHA: `e101151`
- Subject: `fix: prevent earned historical replay`
- Stat: 13 files changed, 477 insertions, 148 deletions.
- The ignored report was updated after the code commit so it can record that commit's immutable SHA.

### Concerns

- No Task 5 correctness concern remains in the requested verification surface.
- Existing unrelated dirty files remain preserved, including the unstaged reporter retry-filter test and its production changes.
- Existing Xcode run-script, simulator Family Controls authorization, IOHID, and network warnings remain; the serial tests and extension-validating build succeeded.

## Review Fix 3 — Generation Lifecycle Hardening

### Finding Validation And Design

- Confirmed the extension accepted every `evlin.earned.budget.` prefix before estimate, POST, and shield handling. It now authorizes only the active generation in one App Group lifecycle record. Legacy callbacks require that the active record itself names `evlin.earned.budget`; pending, retiring, stale, stopped, and malformed state are fail-closed.
- Confirmed accepted/runtime reconciliation used only one process-local `NSLock`. Production instances now derive the same `earned-runtime.lock` path from the App Group container and hold both an in-process lock and BSD `flock` across refresh, read, compare, and all related writes. Custom test suites use the process fallback because no App Group container exists.
- Confirmed start success could precede all generation metadata persistence. One Codable lifecycle value now binds activity name, running offset, arm signature, canonical usage date, and timezone. Pending is durable before start; promotion atomically replaces active and records retiring names before old monitors stop. Interrupted pending, promotion cleanup, and stop tombstones are recoverable on the next arm/stop.
- Confirmed runtime timezone was validated but discarded. The store now persists it and supplies backend-authoritative arm signatures, usage-date fallback, extension sample/override dates, and policy schedule components. `DeviceActivitySchedule` receives Gregorian `DateComponents` carrying the policy timezone; iOS resolves those components to the corresponding absolute interval boundaries.
- `UserDefaults` does not provide a multi-key transaction. The lifecycle is therefore one atomic Codable value and is authoritative; offset/signature scalar keys are compatibility mirrors healed from active metadata. Runtime multi-key reconciliation is serialized by the shared file lock and remains validation/staleness atomic, but not power-loss transactional at the preferences-file level.
- The concurrency test uses two independently constructed stores in one test process. It verifies shared-lock integration semantics and does not claim to launch two OS processes. The production lock-path selection is covered separately.

### RED Evidence

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests'
```

- Result: exit 65, `** TEST FAILED **`, as expected. Compilation failed on absent `Generation`/`Lifecycle` authorization and persistence APIs, production lock selection/runtime timezone APIs, and the timezone-aware schedule parameter.

During final tombstone verification, the first complete serial rerun intentionally caught a new assertion:

- Result: 158 tests executed, 1 failure. `test_stopPersistedGenerationStopsActiveAndLegacyThenRemovesPersistence` observed no tombstone during stop.
- Root cause: the lifecycle writer treated no active/pending as empty even when retiring cleanup names were present. The writer now retains retiring-only tombstones; the focused test and complete serial rerun pass.

### GREEN Evidence

Focused lifecycle/store/schedule run:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests'
```

- Result: `** TEST SUCCEEDED **`; 85 tests executed, 0 failures at the focused checkpoint.

Non-crashing lock failure coverage:

```bash
xcodebuild test -quiet -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests/test_lockOpenFailureIsDiagnosticAndFailClosedWithoutRuntimeWrites'
```

- Result: exit 0. Forced lock-file open failure returned typed `.lockUnavailable`, preserved accepted/runtime fields, returned the prior accepted value from the legacy integer API, and persisted a `stage=open` diagnostic. No production `preconditionFailure` or unlocked billing write remains.

Final required serial suites:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedConfigCommandTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterResponseTests' \
  -only-testing:'Evlin iOSTests/EarnedGateTautologyTests'
```

- Result: `** TEST SUCCEEDED **`; 158 tests executed serially, 0 failures.

Simulator app and embedded extension build:

```bash
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

- Result: `** BUILD SUCCEEDED **`; `EvlinDeviceActivityMonitor.appex` compiled, signed, embedded, and passed `ValidateEmbeddedBinary`.

### Preserved Invariants

- `CommandPoller` still enters production arming only through `EarnedBudgetArming.armIfReady()`.
- Accepted/latest advancement does not mutate the running offset. Real replacement offset authority remains accepted usage, never `latestDeviceEstimate`.
- Stable signatures use active running offset; failed starts preserve prior active generation, offset, and signature.
- False polls, paused config, identity teardown, and no-remaining policy still use centralized stop/signature invalidation.
- Child-state refresh coalescing and device-total/per-app-only transition recovery are unchanged.

### Commit

- SHA: `64d4f5a8f3ab5183e6904455f7544a47d98136d6`
- Subject: `fix: harden earned generation lifecycle`

### Concerns

- No Task 5 correctness concern remains in the requested verification surface.
- A lock-file open/flock failure deliberately skips reconciliation and records a diagnostic; later poll/sample reconciliation is required to apply that backend snapshot.
- Existing unrelated dirty production and retry-filter test hunks were preserved and excluded. Task 6 display files and docs were not staged.
- Existing Xcode run-script and simulator framework/network warnings remain; tests and extension-validating build succeeded.

## Final Review Fix — Teardown And Lock Gaps

### Finding Validation And Design

- Stop now writes a durable stopped lifecycle before stopping monitors and retains that tombstone after cleanup. A stale scalar arm signature cannot authorize legacy callbacks or suppress the next generated install.
- Production App Group stores select the shared file lock or explicit `.unavailable`; only custom suites use the in-process fallback. Lock open/flock failures remain typed, diagnostic, fail-closed results rather than crashes or unlocked billing writes.
- Polling stops all counters and returns before gate/arming/heartbeat on `.lockUnavailable`. A backend-accepted sample returns `.deferred` without entering the network retry queue, allowing a later authoritative poll to reconcile it.
- Active callback authorization now binds the generation name to the canonical child UUID mirrored in the App Group. Kid sign-out, account/family reset, family-gone fail-open, and identity re-pair synchronously stop/invalidate earned state before clearing or replacing that mirror.
- Threshold ladders retain at most 48 events while preserving an exact terminal ceiling above the 240-minute intermediate range.
- Lifecycle version, active, pending, retiring names, stopped proof, offset, signature, usage date, timezone, and device UUID are stored coherently. Separate name breadcrumbs allow corrupt lifecycle recovery to stop all known monitors. Pending durability is synchronized and read back before `startMonitoring`.
- Older lifecycle envelopes default missing version/stopped/retiring fields explicitly. A pre-device-binding generation that cannot decode is intentionally treated as corrupt and recovered fail-closed through breadcrumbs rather than silently authorized.
- The explicit file-lock test disables the process lock and demonstrates real `flock` exclusion using two independently constructed stores. It runs in one simulator test process; it does not claim to test a second OS process or cross-process `UserDefaults` cache behavior.

### RED Evidence

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterResponseTests' \
  -only-testing:'Evlin iOSTests/AuthServiceTests' \
  -only-testing:'Evlin iOSTests/FamilyGoneDetectorTests'
```

- Result: exit 65, `** TEST FAILED **`. The first new caller-level test failed to compile because `FamilyGoneDetector.failOpen` did not yet expose synchronous teardown/test seams (`FamilyGoneDetectorTests.swift:20`). The remaining new APIs were likewise absent at the RED checkpoint.

### GREEN Evidence

Focused rerun from scratch:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterResponseTests' \
  -only-testing:'Evlin iOSTests/AuthServiceTests' \
  -only-testing:'Evlin iOSTests/FamilyGoneDetectorTests'
```

- Result: `** TEST SUCCEEDED **`; 136 tests executed serially, 0 failures.

Full required serial Task 5 and teardown suites:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedConfigCommandTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterResponseTests' \
  -only-testing:'Evlin iOSTests/EarnedGateTautologyTests' \
  -only-testing:'Evlin iOSTests/AuthServiceTests' \
  -only-testing:'Evlin iOSTests/FamilyGoneDetectorTests'
```

- Result: `** TEST SUCCEEDED **`; 177 tests executed serially, 0 failures.

Simulator app and embedded extension build:

```bash
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

- Result: `** BUILD SUCCEEDED **`; `EvlinDeviceActivityMonitor.appex` passed `ValidateEmbeddedBinary`.

### Staging Audit

- Base reviewed: `64d4f5a8f3ab5183e6904455f7544a47d98136d6`.
- Commit contains 16 owned Task 5 paths. Cached diff contained no Task 6 display files, docs, onboarding/API/application-shell work, or Xcode user data.
- `EarnedSampleReporter.swift` staged only the `.deferred` disposition and lock-unavailable response branch.
- `EarnedSampleReporterTests.swift` staged only `test_uncountedSuccessWithUnavailableLockIsDeferredWithoutRetry`.
- Existing retry filtering (`sharedSuiteName`, device-filtered drain, stored-config drain, partition helper, and `test_retryQueueFilteringKeepsOnlyCurrentDeviceEligibleForDrain`) remains unstaged and preserved.

### Commit

- SHA: `866accd3f86416965207da606dbcf4ed20f3bb2b`
- Subject: `fix: close earned teardown and lock gaps`
- Stat: 16 files changed, 673 insertions, 74 deletions.

### Concerns

- The file-lock test exercises real `flock` contention from two stores in one simulator process. A true second-process test and cross-process `UserDefaults` cache visibility remain unverified in the simulator suite.
- `UserDefaults` still cannot offer a power-loss transaction across unrelated scalar compatibility keys. The versioned lifecycle record is authoritative and callback authorization remains fail-closed when it is absent or corrupt.
- Existing unrelated dirty application, onboarding, Xcode user-state, and reporter retry-filter work remains unstaged and preserved.

## Final Recovery And Identity-Safety Review

### Root Causes And Fixes

- A runtime lock failure stopped counters but did not remember that device-total and per-app monitoring needed recovery when the persisted gate was already true. `BigKidStatePoller` now records forced recovery, clears authoritative readiness, stops all three counters, and re-arms earned through the sole `armIfReady` path plus device-total/per-app on the next successful allowed poll.
- The extension consumed one-shot earned thresholds in an acquire/release lock preflight. Threshold handling now attempts the local estimate mutation inside the reconciliation transaction, always preserves/reports the event, and defers local estimate/shield work on lock or post-synchronize failure. The terminal `t300` decision is covered explicitly.
- A suspended `/child/state` fetch could apply an old-family snapshot after the global child UUID changed. The poller captures its immutable expected UUID, checks it before fetch and after every suspension, discards mismatched responses, requests one coalesced fresh poll, and mirrors identity through `mirrorChildIdentity` before readiness or arming.
- Reconciliation transactions ignored missing defaults and synchronize failures. Nil defaults and failed pre-read synchronization now skip the body; failed post-write synchronization returns typed lock-unavailable. Local threshold post-sync failure restores the prior estimate before returning deferred.
- Generation promotion failure stopped the new monitor but could leave pending/promoted cache state. Installation now captures the prior lifecycle, breadcrumbs, and active-name state before pending persistence, restores that captured state after post-start readback/promotion failure, and falls back to a stopped tombstone if rollback persistence fails.
- Lifecycle validation accepted arbitrary future versions. Decoding and validation now accept only versions `1...currentLifecycleVersion`; future envelopes recover as corrupt through breadcrumbs and cannot authorize callbacks.
- Retry drains could post old-device entries and successful old-device responses could reconcile into the new mirror. Drains now partition by exact device, durably retain the deferred partition before network work, and response reconciliation checks the expected UUID against the current App Group mirror. The extension passes `onlyDeviceID` for every drain.
- The terminal auth observer only scheduled a later state flip. It now synchronously runs the same family-scoped earned teardown and identity-mirror cleanup before assigning `.signedOut`.
- Policy commands could arm during the post-teardown/pre-state gap. App Group readiness is now bound to one canonical child UUID, cleared on identity/family teardown, written only after identity recheck plus successful runtime reconciliation/compatibility lock probe and authoritative gate application, and required by both config handling and `armIfReady`.

### RED Evidence

- Initial focused serial run failed compilation on the intentionally absent readiness, auth observer, identity, transaction, lifecycle rollback, threshold decision, and response-identity APIs.
- Invalid-runtime readiness RED: `test_refresh_invalidRuntimeFailsClosedBeforeGateReadinessAndArm` failed because `.invalid` still reached gate/readiness/arm.
- Local post-sync rollback RED: `test_localThresholdPostSynchronizeFailureRestoresPriorEstimate` failed because the estimate remained `300` after `.lockUnavailable`.
- Future-version decode RED: `test_futureLifecycleVersionIsCorruptAndCannotAuthorizeCallback` failed because direct `Lifecycle` decoding accepted version `current + 1`.

### GREEN Evidence

- Focused integrated suites: 151 tests passed, 0 failed after correcting three existing reporter fixtures to seed the mirrored device now required for response reconciliation.
- Runtime compatibility checkpoint: invalid runtime, zero-policy compatibility, nil-runtime available, and nil-runtime unavailable tests passed, 4 tests, 0 failures.
- Final required serial command covered `BigKidStatePollerTests`, `EarnedConfigCommandTests`, `EarnedBudgetSchedulerTests`, `EarnedBudgetArmingTests`, `EarnedTimeStoreTests`, both reporter suites, `EarnedGateTautologyTests`, `AuthServiceTests`, `FamilyGoneDetectorTests`, and `CommandPollerTests`.
- Final serial result: 201 tests passed, 0 failures, 0 skips on iPhone 17 simulator.
- Simulator app build exited 0. `EvlinDeviceActivityMonitor.appex` was present under the built app's `PlugIns`, and `codesign --verify --deep --strict` passed for the app bundle.

### Staging And Commit Audit

- Base commit: `866accd3f86416965207da606dbcf4ed20f3bb2b`.
- Cached paths were exactly the 13 owned source/test files. No API client, app shell, chat, onboarding, docs, Task 6 display, or Xcode user-state path was cached.
- The coherent pre-existing reporter device-filter WIP and its test were included. The dirty `Evlin_iOSApp.swift` caller remained unstaged; the index-only app file contains no dependency on that caller.
- `git diff --cached --check` passed. Cached patch SHA-256: `68b24061f4b1990d5faa42e8785958361f715bf279e537c954ffd01cbd1017b5`. Cached tree: `d7d56fb46998014d6b8085ec83a70f8dd38656b4`.
- Commit: `fd44aec` (`fix: make earned recovery identity safe`), 13 files changed, 892 insertions, 56 deletions.

### Residual Risks

- Real `flock` contention is covered with independent stores in one simulator test process; a true app/extension two-process fault-injection test for synchronize failure is not available in the unit-test harness.
- `UserDefaults` cannot provide a power-loss transaction across all compatibility scalar keys. Billing reconciliation reports post-write sync failure as unavailable, lifecycle authorization remains record-based and fail-closed, and local threshold mutation explicitly rolls back its prior estimate.
- Existing project Swift concurrency and run-script warnings predate this review and remain outside Task 5 ownership.

## Remaining Identity And Recovery Review Fixes

### Scope And Baseline

- Base commit: `fd44aec93db2e24c7d7c03ea44a118e0ef6b2bb7` (`fix: make earned recovery identity safe`).
- Work was performed directly in the main repository without a worktree, stash, clean, revert, or delegation.
- Existing dirty app-shell, API client, onboarding, Task 6, Xcode state, and untracked edits were preserved. `Evlin_iOSApp.swift` contained only the intended foreground retry-drain hunk and is included through that exact patch.

### Implemented Review Fixes

- Callback identity: earned threshold processing now derives its immutable UUID from the authorized generation. Local estimate mutation validates the App Group mirror under the reconciliation file lock, diagnostics and shields revalidate generation identity, and retry drain/new sample POSTs remain addressed to the old generation device after a pairing switch.
- State error identity: `BigKidStatePoller` rechecks its captured device UUID before interpreting thrown errors, including terminal 410. An old request failure is discarded and coalesces a fresh poll instead of failing open the replacement pairing.
- Command identity: each command fetch captures its expected device and rechecks identity after suspension, before every command, after pending-blob/action/global-state awaits, and after earned-config re-keying before policy writes, arming, or acknowledgement. Stale work is discarded without acknowledging as the new device.
- Terminal retry recovery: terminal samples remain queued when local reconciliation and network delivery both fail. The app drains the current-device partition on initial child activation and every foreground transition using stored App Group configuration.
- Durable counter recovery: a canonical per-device recovery marker survives poller recreation. Device-total scheduling returns a real Bool, per-app planner outcomes are mapped truthfully, and the marker clears only when both subsystems report success. Identity teardown removes all recovery markers.
- Transaction rollback: accepted/runtime/local-threshold reconciliation snapshots every mutated key and restores only values still matching the failed transaction while the same file lock is held. Nil/zero runtime compatibility probes clear earned readiness without marking partial state ready, while preserving the existing authoritative usage gate behavior.
- Durable retry queue: enqueue/load/clear/remove operations use a shared process plus App Group `flock`, synchronize and read back writes, keep eligible entries queued throughout the network await, and remove one exact accepted entry only after 2xx/409. Concurrent deferred-device entries are retained.
- Auth observer: the terminal observer owns and removes its notification token. A notification posted off-main synchronously writes a stopped lifecycle, clears the generation mirror/readiness signature, and disables counting before post returns; MainActor teardown and UI sign-out follow asynchronously.
- Reflection identity: reconciliation uses its captured expected device across suspension points. If identity changes after an old-family local apply, the owned old-family reflection record is removed before sticky/schedule/post state can land on the new identity.
- Deferred counted-false: lock-unavailable `counted:false` success stores a device/date marker without network retry. The next matching authoritative runtime reconciliation may lower the phantom same-day baseline and consumes the marker; mismatched device/date state is not applied, with old dates discarded only after the runtime date advances.

### RED Evidence

- Identity RED: focused compilation exited 65 on the intentionally absent expected-device local-threshold API, state fail-open seam, command re-key/ack seams, and reflection identity suspension seam.
- Retry/counted-false RED: focused compilation exited 65 on absent injectable drain transport, locked queue behavior, and pending uncounted-reconciliation APIs.
- Runtime/counter RED: focused compilation exited 65 on absent runtime-unavailable result, transaction rollback coverage, durable recovery marker, and truthful rearm result seams.
- Auth RED: focused compilation exited 65 on absent observer lifetime wrapper, synchronous persistence operation, and injectable persistence seam.
- Compatibility regression checkpoint: the first broad run executed 194 tests with 10 poller failures because nil runtime suppressed the established usage gate. The implementation was narrowed to clear only earned readiness; the corrected poller suite passed 26 tests.
- Subsystem-result RED: `test_counterRecoveryRequiresDeviceTotalAndPerAppSuccess` exited 65 because the production result combiner did not exist. It passed after routing actual scheduler/planner outcomes through the combiner.

### GREEN Evidence

- Identity focused tests passed, including suspended fetch, thrown-410, delayed command fetch, post-re-key config identity change, reflection post-mutation identity change, and local-threshold mirror-switch rollback.
- Retry/recovery focused tests passed, including concurrent enqueue, entry retention during await, concurrent deferred partition preservation, foreground stored-config 409 drain, counted-false recreation, phantom lowering, and mismatch policy.
- Runtime/counter focused tests passed, including full runtime-field rollback, competing newer-value preservation, nil-runtime readiness, per-device teardown, recreated poller retry, and one-subsystem-failure/both-success mapping.
- Auth focused tests passed: off-main notification persistence was observable before `post` returned and observer deallocation prevented subsequent callbacks.
- Intermediate focused Task 5 matrix: 194 tests, 0 failures.
- Final required serial matrix: 268 tests, 0 failures, 0 skips. It covered `BigKidStatePollerTests`, `EarnedConfigCommandTests`, `EarnedBudgetSchedulerTests`, `EarnedBudgetArmingTests`, `EarnedTimeStoreTests`, both earned reporter suites, `EarnedGateTautologyTests`, `AuthServiceTests`, `FamilyGoneDetectorTests`, `CommandPollerTests`, `ReflectionLockApplierTests`, `AppLimitPlannerTests`, and `EarnedDisplayTests`.
- Final test log: `/tmp/evlin-task5-required-final.log`; result bundle: `/Users/fred/Library/Developer/Xcode/DerivedData/Evlin_iOS-fudwpoudhduvkfducxcstdyqummi/Logs/Test/Test-Evlin iOS-2026.07.12_03-13-45--0400.xcresult`.

### Build Evidence

- Final simulator command targeted iPhone 17 Pro (`F2A09216-2200-49E5-A10E-A36556A44C16`) and returned `** BUILD SUCCEEDED **`.
- `EvlinDeviceActivityMonitor.appex`, `EvlinPushApplier.appex`, `EvlinShieldConfig.appex`, and `EvlinDeviceActivityReport.appex` are present in the app bundle.
- `EvlinDeviceActivityMonitor.appex` passed `ValidateEmbeddedBinary`; `codesign --verify --deep --strict` passed for the complete simulator app.
- Final build log: `/tmp/evlin-task5-build-final.log`.

### Residual Risks

- The retry and reconciliation file-lock tests use independently constructed stores/queues in one simulator process. Production uses App Group lock files across app and extension processes, but forced extension termination and a true two-process fault injection are modeled rather than launched as separate simulator processes.
- `UserDefaults` cannot provide a hardware power-loss transaction across arbitrary compatibility scalar keys. Critical lifecycle authorization remains one record and fail-closed; reconciliation rollback and retry queue writes use synchronization/readback and durable markers.
- Existing simulator Family Controls authorization, IOHID/network, Sentry invalid-object, and run-script output warnings remain non-failing and outside this owned scope.

### Staging Audit

- Cached paths were exactly the 16 owned source/test paths, including only the intended `Evlin_iOSApp.swift` foreground/initial-activation retry-drain patch. No API client, chat, onboarding, docs, Task 6, Xcode state, or untracked path was cached.
- Cached app diff: 9 insertions, 0 deletions; it adds the two activation calls and one child-mode drain helper only.
- `git diff --cached --check` passed.
- Cached patch SHA-256: `ca3a25ab8311b51006062c2b10053df3152efee3289ddf936bf8a23f611bc4a9`.
- Cached tree: `ea17ae73e06c1f89b03b46c377a3583bb86e4d86`.
- Unstaged tracked paths after staging were only Xcode user state, `ContentView.swift`, `APIClient.swift`, and `OnboardingCoordinator.swift`; existing untracked files remained untouched.

### Commit

- SHA: `43b4cb5b408a2114ae0050d5212c9ba424c7f103`.
- Subject: `fix: persist earned recovery across races`.
- Stat: 16 files changed, 1,285 insertions, 115 deletions.

## Task 5 Final Review Fix Wave

### Status And Scope

- Status: `DONE`.
- Base: `13148cd9ae4b105602b21276570012197761ee03` on `calendar-in-chat`.
- Work ran directly in the existing main directory. No worktree, delegation, stash, revert, or clean operation was used.
- Existing dirty `ContentView.swift`, `APIClient.swift`, onboarding, Xcode user-state, and untracked files were preserved and excluded from the index.

### Implemented Fixes

- `ActionExecutor` now fails closed when an expected child UUID has no identity checker. Added shield/block mutation checkpoints and conditional rollback through post-mutation effective-state awaits. Unshield/unblock removals restore their records on a later stale result, and scheduling/cancellation is deferred until the final identity check.
- `clearLimit` rollback now restores the prior rule, limit shield, and planner monitoring state when identity changes after re-arming.
- Earned callback mutations now snapshot their owned App Group keys, post-check generation authorization, and restore only values that still equal the old generation's writes. Managed Settings recomputation runs after conditional rollback without replacing newer identity values.
- Local threshold estimates now validate both expected device UUID and expected generation inside the reconciliation transaction. Conditional snapshot rollback prevents teardown from resurrecting an old estimate.
- Saved-list rekey now returns the exact persisted mutation. A stale command rolls it back only when the migrated record is still unchanged and the original key remains absent.
- Newly fired earned samples are durably queued before request construction, authorization checks, drain, or POST. The queue removes one exact entry only after accepted delivery and remains partitioned by device UUID.

### RED Evidence

Focused RED command used the final 11 regression selectors with serial execution on iPhone 17 Pro:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/ActionExecutorTests/testExpectedIdentityWithoutCheckerFailsClosed' \
  -only-testing:'Evlin iOSTests/ActionExecutorTests/testIdentityChangeAfterBlockEffectiveStateReadRollsBackBlockAndSchedule' \
  -only-testing:'Evlin iOSTests/ActionExecutorTests/testIdentityChangeAfterShieldEffectiveStateReadRollsBackShieldAndSchedule' \
  -only-testing:'Evlin iOSTests/ActionExecutorTests/testIdentityChangeAfterUnshieldEffectiveStateReadRestoresRemovedShield' \
  -only-testing:'Evlin iOSTests/ActionExecutorLimitTests/testClearLimitIdentityChangeAfterRearmRestoresRuleShieldAndMonitoringPlan' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests/test_generationMutationRollsBackItsWriteWhenAuthorizationChangesAfterOperation' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests/test_generationRollbackDoesNotOverwriteNewerIdentityWrite' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests/test_localThresholdTeardownAfterWriteDoesNotResurrectOldEstimate' \
  -only-testing:'Evlin iOSTests/CommandPollerTests/testEarnedConfigRollsBackPersistedRekeyWhenIdentityChangesAfterMutation' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests/test_newSampleIsDurablyQueuedBeforeAuthorizationCheckAndKeepsDevicePartition' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests/test_newSampleRemainsQueuedWhenAuthorizationChangesDuringPost'
```

- Result: exit 65, `** TEST FAILED **` at compile time because the production generation mutation API did not accept `mutationKeys` or `beforeFinalAuthorizationCheck` (errors at `EarnedBudgetArmingTests.swift:320` and `:369`).
- RED log: `/tmp/evlin-task5-final-review-red.log` (SHA-256 `9731ae909b22d7bbc0e322606948721cb99f0059733f17a90101b2d0b0efe6e1`).

### GREEN Evidence

- The corrected focused command above executed 11 tests with 0 failures and 0 skips. Log: `/tmp/evlin-task5-final-review-focused-green.log`.
- The full signed serial Task 5 matrix used the established 14 suites plus `ActionExecutorTests`, `ActionExecutorLimitTests`, `RecordKeyMigrationTests`, `CategoryUnshieldFallbackTests`, `TaskPauseShieldMappingTests`, and `CommandPollerEffectiveStateTests`:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedConfigCommandTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterResponseTests' \
  -only-testing:'Evlin iOSTests/EarnedGateTautologyTests' \
  -only-testing:'Evlin iOSTests/AuthServiceTests' \
  -only-testing:'Evlin iOSTests/FamilyGoneDetectorTests' \
  -only-testing:'Evlin iOSTests/CommandPollerTests' \
  -only-testing:'Evlin iOSTests/ReflectionLockApplierTests' \
  -only-testing:'Evlin iOSTests/AppLimitPlannerTests' \
  -only-testing:'Evlin iOSTests/EarnedDisplayTests' \
  -only-testing:'Evlin iOSTests/ActionExecutorTests' \
  -only-testing:'Evlin iOSTests/ActionExecutorLimitTests' \
  -only-testing:'Evlin iOSTests/RecordKeyMigrationTests' \
  -only-testing:'Evlin iOSTests/CategoryUnshieldFallbackTests' \
  -only-testing:'Evlin iOSTests/TaskPauseShieldMappingTests' \
  -only-testing:'Evlin iOSTests/CommandPollerEffectiveStateTests'
```

- Matrix result: `** TEST SUCCEEDED **`; 318 tests, 0 failures, 0 skips. Log: `/tmp/evlin-task5-required-final.log`; result bundle: `/Users/fred/Library/Developer/Xcode/DerivedData/Evlin_iOS-fudwpoudhduvkfducxcstdyqummi/Logs/Test/Test-Evlin iOS-2026.07.12_12-56-24--0400.xcresult`.
- Build command: `xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
- Build result: `** BUILD SUCCEEDED **`. All four extensions are embedded, `EvlinDeviceActivityMonitor.appex` passed `ValidateEmbeddedBinary`, and `codesign --verify --deep --strict` passed for the app. Log: `/tmp/evlin-task5-build-final.log`.

### Changed Files

- `.superpowers/sdd/earned-self-heal-task-5-report.md`
- `Evlin iOS/Services/ActionExecutor.swift`
- `Evlin iOS/Services/ActiveLockStore.swift`
- `Evlin iOS/Services/CommandPoller.swift`
- `Evlin iOS/Services/EarnedSampleReporter.swift`
- `Evlin iOS/Services/EarnedTimeStore.swift`
- `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- `Evlin iOSTests/ActionExecutorLimitTests.swift`
- `Evlin iOSTests/ActionExecutorTests.swift`
- `Evlin iOSTests/CommandPollerTests.swift`
- `Evlin iOSTests/EarnedBudgetArmingTests.swift`
- `Evlin iOSTests/EarnedConfigCommandTests.swift`
- `Evlin iOSTests/EarnedSampleReporterTests.swift`
- `Evlin iOSTests/EarnedTimeStoreTests.swift`

### Residual Risk

- Cross-process races are exercised deterministically through suspension/post-check seams and conditional persisted-value ownership. The simulator unit harness does not launch the app and DeviceActivityMonitor as independently fault-injected processes.
- Existing simulator Family Controls, IOHID/network, Sentry, and run-script warnings remain non-failing and outside this owned scope.

### Commit

- Subject: `fix: make Task 5 identity mutations reversible`.
- Exact SHA is reported after the commit because a commit cannot contain its own final object ID.
