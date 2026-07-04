# Screen-Time Wave-2: Pool Reliability — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **IMPLEMENTER IRON RULE (binding):** You implement this yourself. Do NOT use the Agent/Task tool. Do NOT delegate any task, sub-step, test-write, or verification to another agent. No spawning parallel workers. Each task is written to be executed directly by one implementer in one session, TDD-first, with the exact commands given.

**Goal:** Stop the active harm proven by the 2026-07-03 tracer (`a67c6e8b`): the extension self-locks at every threshold fire because the exhaustion gate is a tautology, and stale-generation ladder fires re-lock after an unshield. Then harden the reliability surface around it — honest lower-path timeline events, NSE config-mirror + observability + tests, the real Apply-Tomorrow option, catch-up day reset, and multi-device pool-exhaustion fanout.

**Order matters — Task 1 (Fix 4) first; it is the live harm.**

**Architecture:**
- iOS (`Evlin-iOS`, branch `calendar-in-chat`, incl. `EvlinDeviceActivityMonitor` + `EvlinPushApplier`): rewrite the earned-shield gate to `adjustedN >= min(poolMinutes, capMinutes)` read fresh at fire time (drop the `latestEstimate + backendRemaining` tautology); add an arm-generation marker to the ladder event names; centralize the App-Group config mirror; add NSE per-stage timestamps + NSE pure-logic tests; wire Apply-Tomorrow; add the catch-up day-reset.
- Backend (`Evlin-Backend`, same branch): give `_maybe_queue_auto_lock` a "did it actually queue" signal so the lower-path stops emitting a `policy_lowered_lock` white lie; fan the earned lock out to all of the child's devices on child-day exhaustion; delete the dead `apns_alert_nag_enabled` flag.

**Tech Stack:** Swift, XCTest; FastAPI, SQLAlchemy async, asyncpg, pytest(+asyncio, DB-gated).

---

## Global Constraints

- iOS repo: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS` (Tasks 1, 2, 4, 5, 6). Backend repo: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend` (Tasks 3, 4d, 7). Both on branch `calendar-in-chat`.
- **iOS tests:** `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' test`, filtered via `-only-testing:`.
- **Backend DB tests** require `EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test` (they skip without it) and the venv: `source .venv/bin/activate`.
- Commits include ONLY the files named in each task. Never stage `.env`, `xcuserstate`, or `.DS_Store`. Never stage unrelated `project.pbxproj` churn beyond target-membership additions. **Do NOT push either repo** — the user controls pushes (backend push auto-deploys to Render).
- **Backend whole-suite check:** after each backend task run `python -m pytest -q` and confirm no NEW reds vs the pre-task baseline (there are known pre-existing unrelated reds in the app_control/fastpath/catalog/saved_list suite — those are baseline, not regressions).
- **W1 + PL regression gates (must stay green):**
  - Backend five suites: `test_config_change_commands.py`, `test_earned_time_policy_summary.py`, `test_earned_time_remaining_recompute.py`, `test_screen_time_events_api.py`, `test_earned_time_auto_lock.py`.
  - PL suites: `test_catalog_list_routes.py`, `test_selected_set_lock.py`.
  - iOS six classes: `CommandPollerEffectiveStateTests`, `CurrentRestrictionsReaderTests`, `DeviceIdentityTests`, `ScreenTimeEventUploaderTests`, `EarnedSampleReporterTests`, `LockedSetFullCoverageTests`.
- **Concurrent-session caution:** a second session may share the `ale_test` DB AND the `.superpowers/sdd/*brief*.md` filenames. Prefix any scratch brief you create with `wave2-`. If a whole-suite run shows reds you did not cause, diff against the baseline before assuming regression.

### Semantic rules (binding — carried from W1, user review 2026-07-01)
1. **Manual locks survive raises/unlocks.** Earned-time reconciliation strips ONLY the `earned_time` source (`unlock_sources=["earned_time"]`); a `.manual` shield is never touched.
2. **R20 override suppresses auto-lock.** A `child_day_state == "override_unlocked"` day suppresses auto-lock even after a lower. `_maybe_queue_auto_lock` enforces this at `earned_time_service.py:125` — reusing it inherits the rule.
3. **Local usage never regresses within a `day_key`.** The device's local estimate may only be reset on day reset, **catch-up reset (Task 6)**, or explicit override. "Display alignment" is never "roll back counters / re-unlock."

### Precedence (design spec Part C)
`manual > account/admin-disabled > earned-pool-exhausted > device-cap-exhausted > per-app-exhausted > task-pause`. Shields union; the reason shown is the highest-precedence hit.

---

## File Structure

**iOS (Evlin-iOS):**
- **Modify** `Evlin iOS/Services/EarnedSampleReporter.swift` — Task 1 (gate rewrite; `bucketMinutes` default 10→5).
- **Modify** `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` — Task 1 (call new gate), Task 2 (parse generation, drop superseded fires), Task 6 (catch-up reset in `intervalDidStart` + `handleEarnedThreshold`).
- **Modify** `Evlin iOS/Services/EarnedTimeStore.swift` — Task 1 (`lastBackendRemaining`/`lastBackendSyncAt` writer support), Task 2 (`armGeneration` accessor), Task 6 (`storedDayKey` accessor).
- **Modify** `Evlin iOS/Services/EarnedBudgetScheduler.swift` — Task 2 (embed generation in event names + explicit `stop()` before re-arm).
- **Modify** `Evlin iOS/Services/BigKidStatePoller.swift` — Task 1 (`rearmUsageCountersFromStoredPolicy` pass real pool/cap, not pool=cap=remaining).
- **Modify** `Evlin iOS/Services/CommandPoller.swift` — Task 1 (write `backendRemaining` + `lastBackendSyncAt` at earned_time_config sync).
- **Modify** `Evlin iOS/Views/Child/BigKid/BigKidRootView.swift` + **new** `Evlin iOS/Services/ExtensionConfigMirror.swift` — Task 4a (centralized mirror writer).
- **Modify** `EvlinPushApplier/NotificationService.swift` — Task 4b (per-stage nseLog timestamps).
- **Modify** `Evlin iOS/Views/Profile/ProfileView.swift` + `Evlin iOS/Views/Profile/DeviceAppsSheet.swift` — Task 5 (Apply-Tomorrow wiring + honest copy).
- **Create** `Evlin iOSTests/EarnedGateTautologyTests.swift` — Task 1.
- **Create** `Evlin iOSTests/ArmGenerationTests.swift` — Task 2.
- **Create** `Evlin iOSTests/NSELockApplierLogicTests.swift` — Task 4c.
- **Create** `Evlin iOSTests/CatchUpResetTests.swift` — Task 6.
- **Add** an iOS test asserting the Apply-Tomorrow callback passes `"tomorrow"` — Task 5 (append to a ProfileView-adjacent test or a small new `ApplyTomorrowWiringTests.swift`).

**Backend (Evlin-Backend):**
- **Modify** `app/services/earned_time_service.py` — Task 3 (`_maybe_queue_auto_lock` queued signal + gated lower-path emits), Task 7 (multi-device fanout in ingest).
- **Modify** `app/core/settings.py` + `app/services/apns_sender.py` — Task 4d (delete dead flag + the stale comment).
- **Modify** `tests/test_config_change_commands.py` — Task 3 (append gated-emit tests).
- **Create** `tests/test_multi_device_exhaustion_fanout.py` — Task 7.

---

## Task 1: iOS — Fix 4: kill the tautology (the active harm)

**Root cause (tracer `a67c6e8b`, CONVICTED):** `EarnedSampleReporter.effectiveCapThreshold` computes `rounded = latestEstimate + backendRemaining`, then returns `min(rounded, ceiling)`. `EarnedTimeStore.backendRemainingAtLastSync` has NO production writer (verified: only readers at `Evlin_iOSApp.swift:202`, `CommandDeliveryDiagnosticsView.swift:72`, `DeviceActivityMonitorExtension.swift:377`, `BigKidStatePoller.swift:206` — zero writers), so `backendRemaining == 0` always ⇒ `rounded ≈ latestEstimate ≈ adjustedN` ⇒ `effectiveCap ≤ adjustedN` ⇒ `shouldApplyEarnedShield(thresholdN: adjustedN, effectiveCap:)` is `adjustedN >= effectiveCap` = **always true** at every threshold fire (`DeviceActivityMonitorExtension.swift:389-409`).

**Files:**
- Modify `Evlin iOS/Services/EarnedSampleReporter.swift` (`effectiveCapThreshold` :242-263 default `bucketMinutes: 10`→`5`; add new pure gate `shouldApplyEarnedShieldFresh`).
- Modify `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` (`handleEarnedThreshold` :375-416 — replace the tautological gate; `bucketMinutes` local :384 stays 5, already correct).
- Modify `Evlin iOS/Services/EarnedTimeStore.swift` (add `lastBackendSyncAt` timestamp key + keep `backendRemainingAtLastSync` writer usable).
- Modify `Evlin iOS/Services/CommandPoller.swift` (:619-624 — populate `backendRemaining` + `lastBackendSyncAt` at the earned_time_config sync, derived `pool - latestDeviceEstimate`).
- Modify `Evlin iOS/Services/BigKidStatePoller.swift` (`rearmUsageCountersFromStoredPolicy` :200-216 — pass real pool/cap, not `pool=cap=remaining`).
- Create `Evlin iOSTests/EarnedGateTautologyTests.swift`.

**Interfaces:**
- New pure function (add to `EarnedSampleReporter`, alongside `shouldApplyEarnedShield`):
  ```swift
  /// Fresh-at-fire-time earned-shield gate. The tripwire is the parent-set
  /// budget `min(poolMinutes, capMinutes)` read fresh — NOT a function of the
  /// device's own estimate (which made the gate a tautology). Applies the
  /// shield iff usage has reached the budget and no override is set.
  static func shouldApplyEarnedShieldFresh(
      adjustedN: Int,
      poolMinutes: Int,
      capMinutes: Int,
      usageDate: String,
      store: EarnedTimeStore
  ) -> Bool {
      guard !store.isOverridden(forUsageDate: usageDate) else { return false }
      let budget = min(poolMinutes, capMinutes)
      guard budget > 0 else { return false }   // no budget known → do not self-lock
      return adjustedN >= budget
  }

  /// Defense-in-depth: refuse a LOCAL self-lock when the last synced backend
  /// remaining says there is comfortable headroom AND that sync is fresh.
  /// (Prevents the extension locking while the backend same-second reports
  /// `available rem=40`.) A stale or absent sync does NOT suppress — offline
  /// enforcement must still work.
  static func backendVetoesSelfLock(
      lastBackendRemaining: Int?,
      lastBackendSyncAt: Date?,
      now: Date,
      marginMinutes: Int = 5,
      freshnessSeconds: TimeInterval = 600
  ) -> Bool {
      guard let rem = lastBackendRemaining, let at = lastBackendSyncAt else { return false }
      guard now.timeIntervalSince(at) < freshnessSeconds else { return false }
      return rem > marginMinutes
  }
  ```

- [ ] **Step 1: Write the failing tests** — create `Evlin iOSTests/EarnedGateTautologyTests.swift`. Mirror the fixture/`setUp`/`tearDown` idiom of `EarnedSampleReporterTests` (App-Group suite `group.com.evlin.ios`, `EarnedTimeStore.shared.removeAll()`). The 7 regression tests from the conviction, adapted to pure-logic form (the two device-only ones become pure-gate assertions since opaque tokens block a true extension harness):

  ```swift
  import XCTest
  @testable import Evlin_iOS

  final class EarnedGateTautologyTests: XCTestCase {
      private let suiteName = "group.com.evlin.ios"
      override func setUp() { super.setUp(); EarnedTimeStore.shared.removeAll() }
      override func tearDown() { EarnedTimeStore.shared.removeAll(); super.tearDown() }

      // 1. Tautology guard: low usage below budget must NOT lock, regardless of
      //    backendRemaining==0 (the old gate locked here).
      func test_lowUsage_belowBudget_doesNotLock() {
          let store = EarnedTimeStore.shared
          XCTAssertFalse(EarnedSampleReporter.shouldApplyEarnedShieldFresh(
              adjustedN: 5, poolMinutes: 45, capMinutes: 45,
              usageDate: "2026-07-03", store: store))
      }

      // 2. Low-usage no-lock across the whole 5-min ladder up to just under budget.
      func test_ladderBelowBudget_neverLocks() {
          let store = EarnedTimeStore.shared
          for n in stride(from: 5, to: 45, by: 5) {
              XCTAssertFalse(EarnedSampleReporter.shouldApplyEarnedShieldFresh(
                  adjustedN: n, poolMinutes: 45, capMinutes: 45,
                  usageDate: "2026-07-03", store: store), "t\(n) must not lock")
          }
      }

      // 3. Correct-lock still fires AT budget, and the deviceCap label is chosen
      //    when an explicit cap below the pool bound (boundSource logic, pure).
      func test_atBudget_locks_andLabelsDeviceCapWhenCapBinds() {
          let store = EarnedTimeStore.shared
          XCTAssertTrue(EarnedSampleReporter.shouldApplyEarnedShieldFresh(
              adjustedN: 15, poolMinutes: 45, capMinutes: 15,
              usageDate: "2026-07-03", store: store))
          // boundSource is deviceCap when cap<pool AND adjustedN>=cap:
          let cap = 15, pool = 45, adjustedN = 15
          let isDeviceCap = (cap < pool && adjustedN >= cap)
          XCTAssertTrue(isDeviceCap)
      }

      // 4. backendRemaining writer contract: veto only when fresh AND margin.
      func test_backendVeto_freshAndMargin_suppresses() {
          let now = Date()
          XCTAssertTrue(EarnedSampleReporter.backendVetoesSelfLock(
              lastBackendRemaining: 40, lastBackendSyncAt: now.addingTimeInterval(-60), now: now))
          XCTAssertFalse(EarnedSampleReporter.backendVetoesSelfLock(  // stale
              lastBackendRemaining: 40, lastBackendSyncAt: now.addingTimeInterval(-1200), now: now))
          XCTAssertFalse(EarnedSampleReporter.backendVetoesSelfLock(  // no margin
              lastBackendRemaining: 3, lastBackendSyncAt: now, now: now))
          XCTAssertFalse(EarnedSampleReporter.backendVetoesSelfLock(  // absent
              lastBackendRemaining: nil, lastBackendSyncAt: nil, now: now))
      }

      // 5. Override still suppresses (unchanged semantic).
      func test_override_suppressesLockAtBudget() {
          let store = EarnedTimeStore.shared
          store.setOverride(true, forUsageDate: "2026-07-03")
          XCTAssertFalse(EarnedSampleReporter.shouldApplyEarnedShieldFresh(
              adjustedN: 45, poolMinutes: 45, capMinutes: 45,
              usageDate: "2026-07-03", store: store))
      }

      // 6. Re-arm ceiling: BigKidStatePoller must arm with the REAL pool/cap, not
      //    pool=cap=remaining. Pure form: assert the arm inputs the fixed rearm
      //    would pass. (See Step 5 seam.)
      func test_rearm_passesRealPoolAndCap_notRemaining() {
          let store = EarnedTimeStore.shared
          store.poolMinutes = 60
          store.capMinutes = 30
          store.latestDeviceEstimate = 10
          let inputs = BigKidStatePoller.earnedRearmInputs(store: store)   // new pure seam
          XCTAssertEqual(inputs.poolMinutes, 60)
          XCTAssertEqual(inputs.capMinutes, 30)
          XCTAssertEqual(inputs.offset, 10)
      }

      // 7. bucketMinutes default is 5 (matches EarnedBudgetScheduler.earnedBucketMinutes).
      func test_effectiveCapThreshold_defaultBucketIsFive() {
          // latest=8 remaining=0 -> raw=8 -> ceil to next multiple of default bucket.
          // With bucket=5 -> 10; the old default (10) would also give 10, so pin the
          // constant directly:
          XCTAssertEqual(EarnedBudgetScheduler.earnedBucketMinutes, 5)
          // 8 rounded up to bucket=5 == 10; to bucket=10 == 10 (ambiguous) — use 7:
          let r = EarnedSampleReporter.effectiveCapThreshold(
              latestEstimate: 7, backendRemaining: 0, poolMinutes: 60, capMinutes: 60)
          XCTAssertEqual(r, 10, "default bucket 5: 7 -> 10 (bucket 10 would give 10 too; 7->10 holds only for 5)")
          let r2 = EarnedSampleReporter.effectiveCapThreshold(
              latestEstimate: 6, backendRemaining: 0, poolMinutes: 60, capMinutes: 60)
          XCTAssertEqual(r2, 10, "6 -> 10 under bucket 5")  // under bucket 10, 6 -> 10 too; keep as smoke
      }
  }
  ```
  (Note: `effectiveCapThreshold` is retained only for continuity of the existing `EarnedSampleReporterTests`; the live enforcement path no longer calls it. Test 7 primarily pins the default change and the `earnedBucketMinutes == 5` constant.)

  Also add the `BigKidStatePoller.earnedRearmInputs(store:)` pure seam referenced by test 6 (returns `(poolMinutes: Int, capMinutes: Int, offset: Int)` computed exactly as the fixed rearm will use them).

- [ ] **Step 2: Verify it fails** —
  ```bash
  cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS"
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:"Evlin iOSTests/EarnedGateTautologyTests" test 2>&1 | tail -8
  ```
  Expected: BUILD FAIL / TEST FAIL (new symbols `shouldApplyEarnedShieldFresh`, `backendVetoesSelfLock`, `earnedRearmInputs` do not exist yet).

- [ ] **Step 3: Add the pure gate + fix the bucket default** — in `EarnedSampleReporter.swift`: change `effectiveCapThreshold(..., bucketMinutes: Int = 10)` → `= 5` (:247); append the two new pure functions above (`shouldApplyEarnedShieldFresh`, `backendVetoesSelfLock`). Leave the legacy `effectiveCapThreshold`/`shouldApplyEarnedShield` in place (still referenced by `EarnedSampleReporterTests`), but they are no longer on the enforcement path.

- [ ] **Step 4: Rewire the extension gate** — in `DeviceActivityMonitorExtension.swift` `handleEarnedThreshold`, replace the block `:375-416` (from `// Tripwire check` through the `applyEarnedTimeShield(...)` call). New logic:
  ```swift
          // Fresh-at-fire-time gate (Fix 4). The tripwire is the parent-set budget
          // read fresh from the store — NOT latestEstimate+backendRemaining (which
          // was a tautology: no writer for backendRemaining ⇒ effectiveCap ≤ adjustedN
          // ⇒ always fired). See EarnedGateTautologyTests.
          let poolMinutes = earnedStore.poolMinutes ?? 240
          let capMinutes  = earnedStore.capMinutes  ?? 240
          let usageDateForOverride = todayISODate()

          guard EarnedSampleReporter.shouldApplyEarnedShieldFresh(
              adjustedN: adjustedN,
              poolMinutes: poolMinutes,
              capMinutes: capMinutes,
              usageDate: usageDateForOverride,
              store: earnedStore
          ) else {
              emitEvent(kind: .decision, source: .earnedPool, app: "device-wide",
                        reason: "pool_under_cap")
              return
          }

          // Defense-in-depth: a fresh backend sync with comfortable headroom vetoes
          // a LOCAL self-lock (the "backend same-second says rem=40" incident).
          if EarnedSampleReporter.backendVetoesSelfLock(
              lastBackendRemaining: earnedStore.backendRemainingAtLastSync,
              lastBackendSyncAt: earnedStore.lastBackendSyncAt,
              now: Date()
          ) {
              emitEvent(kind: .drop, source: .earnedPool, app: "device-wide",
                        reason: "backend_headroom_veto")
              return
          }

          let boundSource: ScreenTimeEvent.Source =
              (capMinutes < poolMinutes && adjustedN >= capMinutes) ? .deviceCap : .earnedPool
          applyEarnedTimeShield(earnedStore: earnedStore, thresholdN: adjustedN, source: boundSource)
  ```
  Remove the now-dead `latestEstimate`/`backendRemaining`/`effectiveCap`/`bucketMinutes` locals (:376-395) that fed the old gate.

- [ ] **Step 5: Add the store timestamp key + the backend-remaining writer** —
  - In `EarnedTimeStore.swift`: add `private let lastBackendSyncAtKey = "earned.lastBackendSyncAt"` and a `var lastBackendSyncAt: Date? { get/set }` accessor (store as epoch `Double`, mirror the `backendRemainingAtLastSync` optional idiom). Add `lastBackendSyncAtKey` to the `removeAll()` sweep list (:286-289).
  - In `CommandPoller.swift`, inside the earned_time_config handler where pool/cap are written (:622-624), add:
    ```swift
                EarnedTimeStore.shared.poolMinutes = poolMinutes
                EarnedTimeStore.shared.capMinutes = capMinutes
                // Fix 4 writer: derive backend remaining from the freshly-synced
                // budget minus the device's own latest estimate, and stamp the sync
                // time so the extension's backend-headroom veto can trust freshness.
                let est = EarnedTimeStore.shared.latestDeviceEstimate ?? 0
                EarnedTimeStore.shared.backendRemainingAtLastSync = max(0, min(poolMinutes, capMinutes) - est)
                EarnedTimeStore.shared.lastBackendSyncAt = Date()
    ```
    (ANCHOR NOTE — see the explicit callout at the end: the `earned_time_config` wire payload carries no `remaining_minutes`; this derives remaining from `pool/cap − estimate`. If backend later adds a real `remaining_minutes` to the payload/DTO, replace this derivation with the wire value.)
  - In `BigKidStatePoller.swift` `rearmUsageCountersFromStoredPolicy` (:200-216): replace the `pool=cap=remaining` arm with real pool/cap and add the `earnedRearmInputs` pure seam:
    ```swift
        // Pure seam (Fix 4 test 6): the real pool/cap/offset the re-arm uses.
        static func earnedRearmInputs(store: EarnedTimeStore) -> (poolMinutes: Int, capMinutes: Int, offset: Int) {
            let offset = max(store.latestDeviceEstimate ?? 0, store.earnedUsageOffsetMinutes)
            let pool = store.poolMinutes ?? 60
            let cap  = store.capMinutes ?? pool
            return (pool, cap, offset)
        }
    ```
    and rewrite the arm body:
    ```swift
            if store.isEarnedTimeReady, let selection = store.measurementSelection {
                let inputs = Self.earnedRearmInputs(store: store)
                store.earnedUsageOffsetMinutes = inputs.offset
                // Arm at the REAL pool/cap; the offset is applied by the extension
                // (adjustedN = offset + rawN), so the ladder itself keeps real budgets.
                if min(inputs.poolMinutes, inputs.capMinutes) - inputs.offset > 0 {
                    EarnedBudgetScheduler.shared.arm(
                        poolMinutes: inputs.poolMinutes,
                        capMinutes: inputs.capMinutes,
                        selection: selection
                    )
                }
            }
    ```
    (Do not change the app-limit re-arm loop below it.)

- [ ] **Step 6: Run tests + regression gates**
  ```bash
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:"Evlin iOSTests/EarnedGateTautologyTests" \
    -only-testing:"Evlin iOSTests/EarnedSampleReporterTests" \
    -only-testing:"Evlin iOSTests/EarnedBudgetSchedulerTests" \
    -only-testing:"Evlin iOSTests/BigKidStatePollerTests" \
    -only-testing:"Evlin iOSTests/LockedSetFullCoverageTests" test 2>&1 | tail -6
  ```
  Expected: `TEST SUCCEEDED`.

- [ ] **Step 7: Commit**
  ```bash
  git add "Evlin iOS/Services/EarnedSampleReporter.swift" \
          "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift" \
          "Evlin iOS/Services/EarnedTimeStore.swift" \
          "Evlin iOS/Services/CommandPoller.swift" \
          "Evlin iOS/Services/BigKidStatePoller.swift" \
          "Evlin iOSTests/EarnedGateTautologyTests.swift"
  git commit -m "fix(screentime): Fix 4 — earned gate reads min(pool,cap) fresh (kill tautology); backendRemaining writer + freshness veto; bucket 10->5; re-arm real pool/cap"
  ```

---

## Task 2: iOS — Fix 4b: arm-generation marker (drop superseded ladder fires)

**Root cause (incident #3, `2026-07-03 03:36-03:49`):** backend's last action was an unshield (03:36:15); no lock command exists; yet the device re-applied `savedList d6510f2a` during re-arm. A stale ladder fire from a *prior* arm generation fired after re-arm and self-locked. There is no generation marker on the event names today (`evlin.earned.t<minutes>`), so the extension cannot tell a superseded fire from a current one.

**Files:**
- Modify `Evlin iOS/Services/EarnedBudgetScheduler.swift` (`arm` :84-108, `stop` :111-113 — embed generation; explicit `stop()` before `startMonitoring`).
- Modify `Evlin iOS/Services/EarnedTimeStore.swift` (add `armGeneration` accessor).
- Modify `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` (`handleEarnedThreshold` :334-343 — parse generation, drop superseded).
- Create `Evlin iOSTests/ArmGenerationTests.swift`.

**Event-name scheme:** `evlin.earned.g<gen>.t<minutes>` (e.g. `evlin.earned.g7.t15`). `<gen>` is a monotonically increasing Int persisted in the App Group (`earned.armGeneration`), incremented on each `arm()`. Backward compat: the extension ALSO accepts the legacy un-generationed `evlin.earned.t<minutes>` and treats it as **current generation** during the one-version transition.

- [ ] **Step 1: Write failing tests** — `Evlin iOSTests/ArmGenerationTests.swift`. Test the two pure helpers you will add to `EarnedBudgetScheduler`:
  ```swift
  import XCTest
  @testable import Evlin_iOS

  final class ArmGenerationTests: XCTestCase {
      override func setUp() { super.setUp(); EarnedTimeStore.shared.removeAll() }
      override func tearDown() { EarnedTimeStore.shared.removeAll(); super.tearDown() }

      func test_eventName_embedsGeneration() {
          XCTAssertEqual(EarnedBudgetScheduler.eventName(generation: 7, minutes: 15), "evlin.earned.g7.t15")
      }

      func test_parse_currentGeneration_processed() {
          // gen matches store → not superseded.
          let parsed = EarnedBudgetScheduler.parseEarnedEvent("evlin.earned.g7.t15")
          XCTAssertEqual(parsed?.generation, 7)
          XCTAssertEqual(parsed?.minutes, 15)
          XCTAssertFalse(EarnedBudgetScheduler.isSuperseded(parsed!, currentGeneration: 7))
      }

      func test_parse_staleGeneration_dropped() {
          let parsed = EarnedBudgetScheduler.parseEarnedEvent("evlin.earned.g5.t15")
          XCTAssertTrue(EarnedBudgetScheduler.isSuperseded(parsed!, currentGeneration: 7))
      }

      func test_legacyName_acceptedAsCurrent() {
          let parsed = EarnedBudgetScheduler.parseEarnedEvent("evlin.earned.t15")
          XCTAssertEqual(parsed?.minutes, 15)
          XCTAssertNil(parsed?.generation, "legacy name has no embedded generation")
          // legacy is treated as current (never superseded) during transition:
          XCTAssertFalse(EarnedBudgetScheduler.isSuperseded(parsed!, currentGeneration: 7))
      }
  }
  ```

- [ ] **Step 2: Verify it fails** — `-only-testing:"Evlin iOSTests/ArmGenerationTests"`; expected BUILD FAIL (new symbols absent).

- [ ] **Step 3: Add generation to the scheduler** — in `EarnedBudgetScheduler.swift`:
  - Add `nonisolated static func eventName(generation: Int, minutes: Int) -> String { "evlin.earned.g\(generation).t\(minutes)" }`.
  - Add a parse struct + helpers:
    ```swift
    struct ParsedEarnedEvent { let generation: Int?; let minutes: Int }
    nonisolated static func parseEarnedEvent(_ name: String) -> ParsedEarnedEvent? {
        guard name.hasPrefix("evlin.earned.") else { return nil }
        let rest = name.dropFirst("evlin.earned.".count)   // "g7.t15" or "t15"
        if rest.hasPrefix("g") {
            let parts = rest.dropFirst().split(separator: ".")   // ["7","t15"]
            guard parts.count == 2, let gen = Int(parts[0]),
                  parts[1].hasPrefix("t"), let m = Int(parts[1].dropFirst()) else { return nil }
            return ParsedEarnedEvent(generation: gen, minutes: m)
        }
        guard rest.hasPrefix("t"), let m = Int(rest.dropFirst()) else { return nil }
        return ParsedEarnedEvent(generation: nil, minutes: m)   // legacy
    }
    nonisolated static func isSuperseded(_ e: ParsedEarnedEvent, currentGeneration: Int) -> Bool {
        guard let g = e.generation else { return false }   // legacy = current during transition
        return g != currentGeneration
    }
    ```
  - In `arm(...)`: read+increment the generation from the store, call `stop()` explicitly before `startMonitoring` (belt-and-suspenders over startMonitoring's own stop), and name each event via `Self.eventName(generation:minutes:)`:
    ```swift
        let generation = EarnedTimeStore.shared.bumpArmGeneration()
        stop()   // explicit stop of any prior activity before re-arm
        ...
        for minutes in steps {
            let name = DeviceActivityEvent.Name(Self.eventName(generation: generation, minutes: minutes))
            ...
        }
    ```

- [ ] **Step 4: Add the store accessor** — in `EarnedTimeStore.swift`: `private let armGenerationKey = "earned.armGeneration"`; `var armGeneration: Int { defaults?.integer(forKey: armGenerationKey) ?? 0 }`; `func bumpArmGeneration() -> Int { let next = armGeneration + 1; defaults?.set(next, forKey: armGenerationKey); defaults?.synchronize(); return next }`. Add `armGenerationKey` to `removeAll()`.

- [ ] **Step 5: Parse + drop in the extension** — in `handleEarnedThreshold` (:334-343) replace the current suffix parse:
  ```swift
      guard let parsed = EarnedBudgetScheduler.parseEarnedEvent(eventName) else {
          NSLog("[Evlin/Ext] earned threshold: unparseable '%@'", eventName); return
      }
      let currentGen = EarnedTimeStore.shared.armGeneration
      if EarnedBudgetScheduler.isSuperseded(parsed, currentGeneration: currentGen) {
          emitEvent(kind: .drop, source: .earnedPool, app: "device-wide", reason: "superseded_generation")
          NSLog("[Evlin/Ext] dropped superseded earned fire gen=%@ current=%d",
                String(describing: parsed.generation), currentGen)
          return
      }
      let n = parsed.minutes
  ```
  Keep the rest of the function (offset/adjustedN/report/gate) unchanged.

- [ ] **Step 6: Run tests + build (app + extension)**
  ```bash
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:"Evlin iOSTests/ArmGenerationTests" \
    -only-testing:"Evlin iOSTests/EarnedBudgetSchedulerTests" test 2>&1 | tail -6
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
    -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
  ```
  Expected: `TEST SUCCEEDED`; `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**
  ```bash
  git add "Evlin iOS/Services/EarnedBudgetScheduler.swift" \
          "Evlin iOS/Services/EarnedTimeStore.swift" \
          "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift" \
          "Evlin iOSTests/ArmGenerationTests.swift"
  git commit -m "fix(screentime): Fix 4b — arm-generation marker on earned ladder; drop superseded fires; explicit stop before re-arm; legacy names accepted as current"
  ```

---

## Task 3: Backend — honest lower-path event (`policy_lowered_lock` only when actually queued)

**Root cause (W1 cosmetic defect, 03:36:21):** `put_pool_config`/`put_device_cap` lower-paths emit `policy_lowered_lock` unconditionally, even when `_maybe_queue_auto_lock` returned early (R20 override skip, idempotency guard, or a tokenless/missing warning). Verified: emit at `earned_time_service.py:1305-1313` (pool) and `:1517` (cap) fires regardless of the helper's return. The helper's `Optional[str]` return cannot distinguish "queued" from "skipped-None".

**Files:**
- Modify `app/services/earned_time_service.py` (`_maybe_queue_auto_lock` :97-204; pool lower-path :1293-1313; cap lower-path :1507-1525).
- Modify `tests/test_config_change_commands.py` (append).

**Approach:** give `_maybe_queue_auto_lock` a structured result. Change the return type to a small dataclass/NamedTuple `AutoLockResult(queued: bool, warning: Optional[str])` (queued True only on the success path that sets `selected_lock_command_id`). Update all four existing callers (:450 ingest, :1296 pool lower, :1508 cap lower — and add the new Task-7 fanout caller) to read `.queued`/`.warning`. Then gate each lower-path emit on `result.queued`.

- [ ] **Step 1: Write the failing tests** (append to `tests/test_config_change_commands.py`, same DB-gated `pytestmark` header + seed helpers already in that file):
  ```python
  async def test_override_lower_does_not_emit_policy_lowered_lock(session, monkeypatch): ...
      # child_day.state="override_unlocked"; device estimated >= new pool.
      # put_pool_config(pool below used) -> _maybe_queue_auto_lock skips (R20) ->
      # assert NO screen_time_events row with reason="policy_lowered_lock".

  async def test_idempotent_lower_no_second_policy_lowered_lock(session, monkeypatch): ...
      # device_day.selected_lock_command_id already set; lower again ->
      # helper skips (idempotency) -> assert no NEW policy_lowered_lock row.

  async def test_tokenless_lower_does_not_emit_lock(session, monkeypatch): ...
      # selected set tokenless (fake load/ensure_selected_set returns tokens=0) ->
      # helper returns warning, queued False -> no policy_lowered_lock row.

  async def test_real_lower_still_emits_policy_lowered_lock(session, monkeypatch): ...
      # available day, tokens present, estimate>=new pool -> queued True ->
      # exactly one policy_lowered_lock row (regression guard for the honest path).
  ```
  Query the timeline via the same `ScreenTimeEvent` select the existing W1 tests use.

- [ ] **Step 2: Verify it fails**
  ```bash
  cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
  source .venv/bin/activate
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_config_change_commands.py -k "policy_lowered or tokenless or override_lower" -v
  ```
  Expected: the three "does not emit" tests FAIL (white lie fires today).

- [ ] **Step 3: Add the queued signal** — in `earned_time_service.py`, above `_maybe_queue_auto_lock`, add:
  ```python
  class AutoLockResult(NamedTuple):
      queued: bool
      warning: Optional[str]
  ```
  (add `NamedTuple` to the `typing` import). Change the function signature return to `-> AutoLockResult` and replace every `return None`/`return "..."`:
  - override skip → `return AutoLockResult(False, None)`
  - cap-not-reached → `return AutoLockResult(False, None)`
  - already-queued idempotency → `return AutoLockResult(False, None)`
  - selected-set missing → `return AutoLockResult(False, "selected_set_missing")`
  - tokenless → `return AutoLockResult(False, "selected_set_tokenless")`
  - success (after setting `selected_lock_command_id` + emit) → `return AutoLockResult(True, None)`

- [ ] **Step 4: Update callers + gate the emits** —
  - Ingest (:448-459): `auto_lock_result = await _maybe_queue_auto_lock(...)`; `auto_lock_warning = auto_lock_result.warning` (preserve the `DeviceDaySnapshot.warning` contract).
  - Pool lower-path (:1296-1313): capture `res = await _maybe_queue_auto_lock(...)`; wrap the `screen_time_event_service.emit(... reason="policy_lowered_lock" ...)` in `if res.queued:`.
  - Cap lower-path (:1508-1525): same — capture the result, gate the `policy_lowered_lock` emit on `res.queued`.

- [ ] **Step 5: Run tests + suite**
  ```bash
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_config_change_commands.py tests/test_earned_time_auto_lock.py tests/test_earned_time_remaining_recompute.py -v
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest -q
  ```
  Expected: all Task-3 tests PASS; no new suite reds.

- [ ] **Step 6: Commit**
  ```bash
  git add app/services/earned_time_service.py tests/test_config_change_commands.py
  git commit -m "fix(screentime): emit policy_lowered_lock only when auto-lock actually queued (AutoLockResult.queued); no more override/idempotency/tokenless white lie"
  ```

---

## Task 4: NSE hardening

Four independent sub-tasks; commit each group as noted. 4a+4b+4c are iOS, 4d is backend.

### 4a — mirror `evlin.baseURL`/`evlin.childId` at every pairing/URL/mode change

**Root cause (audit R1-residual):** the sole writer of the App-Group `evlin.baseURL`/`evlin.childId` mirror is `BigKidRootView.init` (verified :47-50). After a reinstall / server-URL change / mode toggle where BigKidRootView isn't reconstructed with fresh values, the NSE (and the DeviceActivity extension) go silently dark. `ChildModeExperienceView.swift:27` is the one instantiation site (`BigKidRootView(baseURL: url, childId: childId)`).

**Files:**
- Create `Evlin iOS/Services/ExtensionConfigMirror.swift` (centralized writer + loud-when-nil diagnostic).
- Modify `Evlin iOS/Views/Child/BigKid/BigKidRootView.swift` (:47-50 → call the mirror).
- Modify `Evlin iOS/Views/Child/ChildModeExperienceView.swift` (:27 area — mirror at mode entry) and any pairing/server-URL write site found by the grep in Step 1.

- [ ] **Step 1: Enumerate all mirror-worthy sites** —
  ```bash
  cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
  grep -rn "childId\|baseURL\|serverURL\|pairing\|DeviceMode\|\.mode ==" "Evlin iOS/Views/Child" "Evlin iOS/Services" | grep -iE "baseURL|childId|paired|serverURL|mode" | grep "\.swift:"
  ```
  Record each site where a child device's baseURL/childId becomes known or changes (pairing completion, server-URL edit, parent↔child mode toggle). At minimum: `BigKidRootView.init`, `ChildModeExperienceView` (mode entry).

- [ ] **Step 2: Create the centralized mirror** — `ExtensionConfigMirror.swift`:
  ```swift
  import Foundation
  /// Single writer of the App-Group config the DeviceActivity extension AND the
  /// EvlinPushApplier NSE read (`evlin.baseURL`, `evlin.childId`). Call at EVERY
  /// point the child device's server URL or identity becomes known or changes —
  /// pairing, server-URL edit, parent↔child mode entry. A nil value is a loud
  /// diagnostic (the NSE goes dark silently otherwise).
  enum ExtensionConfigMirror {
      private static var group: UserDefaults? { UserDefaults(suiteName: "group.com.evlin.ios") }
      static func write(baseURL: URL?, childId: UUID?) {
          guard let g = group else { return }
          if let b = baseURL { g.set(b.absoluteString, forKey: "evlin.baseURL") }
          else { CommandDeliveryDiagnostics.record("evlin.baseURL", "NIL at mirror write — NSE will be dark") }
          if let c = childId { g.set(c.uuidString, forKey: "evlin.childId") }
          else { CommandDeliveryDiagnostics.record("evlin.childId", "NIL at mirror write — NSE will be dark") }
          g.synchronize()
      }
  }
  ```
  (Confirm `CommandDeliveryDiagnostics.record(_:_:)` signature against the live type before use; it is already used across the codebase, e.g. `CommandDeliveryDiagnostics.record(CommandDeliveryDiagnostics.keyCommandAck, ...)`.)

- [ ] **Step 3: Route all sites through it** — replace the raw `groupDefaults.set(...)` pair in `BigKidRootView.init` (:47-50) with `ExtensionConfigMirror.write(baseURL: baseURL, childId: childId)`; add the same call at each other site from Step 1.

- [ ] **Step 4: Build + commit**
  ```bash
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
  git add "Evlin iOS/Services/ExtensionConfigMirror.swift" "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift" "Evlin iOS/Views/Child/ChildModeExperienceView.swift"
  git commit -m "fix(screentime): mirror evlin.baseURL/childId at every pairing/URL/mode change (R1-residual) + loud-when-nil diagnostic"
  ```

### 4b — NSE per-stage timestamps in `evlin.spike.nseLog`

`NSEConfig.log` (verified `NotificationService.swift:486-494`) already appends to `evlin.spike.nseLog`. Add explicit per-stage timestamped entries in `applyLock` (:79-96) at fetch / apply / ack:

- [ ] **Step 1:** In `NotificationService.applyLock`, replace the coarse logs with staged ones (keep the same `NSEConfig.log` sink):
  ```swift
      NSEConfig.log("stage=fetch_start cmd=\(commandID)")
      guard let command = await NSENetwork.fetchCommand(...) else {
          NSEConfig.log("stage=fetch_fail cmd=\(commandID)"); return
      }
      NSEConfig.log("stage=fetch_ok cmd=\(commandID) action=\(command.action.rawValue)")
      guard let outcome = await NSELockApplier.apply(command) else {
          NSEConfig.log("stage=apply_skip cmd=\(commandID) action=\(command.action.rawValue)"); return
      }
      NSEConfig.log("stage=apply_ok cmd=\(commandID) verb=\(outcome.verb)")
      await NSENetwork.ack(...)
      NSEConfig.log("stage=ack_ok cmd=\(commandID) verb=\(outcome.verb) name=\(outcome.displayName)")
  ```
  (`NSEConfig.log` already prefixes each entry with an ISO8601 timestamp — the per-stage split is the added observability.)

- [ ] **Step 2: Build + commit**
  ```bash
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
  git add "EvlinPushApplier/NotificationService.swift"
  git commit -m "obs(screentime): NSE writes per-stage (fetch/apply/ack) timestamps to evlin.spike.nseLog"
  ```

### 4c — unit tests for NSELockApplier record-building / token-decode

`NSELockApplier`, `NSEConfig`, `NSENetwork`, `NSEWireCommand` are `private`/`fileprivate`-ish inside `NotificationService.swift`, compiled into the `EvlinPushApplier` target — which has NO XCTest host. Two options; **prefer extraction**:

- [ ] **Step 1: Extract the pure logic** — move the pure, entitlement-free helpers (`unshieldRecordKey(from:)`, `exactAppTargetKey`, `categoryLookupName`, `decodeToken`/`decodeApplicationToken`/`decodeCategoryToken`, and the `NSEWireCommand.lockCommand(from:)` mapping) into a new file that is a member of BOTH `EvlinPushApplier` and `Evlin iOSTests`, mirroring how `EarnedSampleReporter.swift` is shared (project.pbxproj membershipExceptions). Name it `NSELockApplierLogic.swift`, keep it `enum`-namespaced, and have `NotificationService.swift` call into it. Do NOT move `ActiveLockStore`-touching methods (`apply`, `buildShieldRecord`'s `addShield`) — those need the store; instead expose the record-*building* portion of `buildShieldRecord` as a pure function returning `ShieldRecord?` from a decoded `LockCommand`, and have `apply` call it then hand the record to `ActiveLockStore`.

- [ ] **Step 2: Write tests** — `Evlin iOSTests/NSELockApplierLogicTests.swift`:
  - `unshieldRecordKey` for each tier produces the same key `ShieldRecord.makeRecordKey` would (savedList lowercased, category lowercased, exactApp bundle lowercased, all→"all").
  - `decodeToken` returns nil for empty/garbage base64, decodes a valid property-list/JSON token blob (use a round-tripped fixture token if the test target can construct one; otherwise assert the nil/garbage branches only — opaque tokens may block a positive decode, note it in the test).
  - `buildShieldRecord`-pure: a `savedList` command with inline application token base64s yields a record whose `recordKey == "savedList:<lowercased-uuid>"`, `sources`/`appliesToAll` set from `all_selected`; a command with NO tokens from any source returns nil (the "leave to poller" contract).

- [ ] **Step 3: Run + build (both targets)**
  ```bash
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:"Evlin iOSTests/NSELockApplierLogicTests" test 2>&1 | tail -6
  ```
  Expected: `TEST SUCCEEDED`.

- [ ] **Step 4: Commit**
  ```bash
  git add "EvlinPushApplier/NotificationService.swift" \
          "EvlinPushApplier/NSELockApplierLogic.swift" \
          "Evlin iOSTests/NSELockApplierLogicTests.swift" \
          "Evlin iOS.xcodeproj/project.pbxproj"
  git commit -m "test(screentime): extract NSELockApplier pure logic + unit tests (record-build, token-decode, unshield key)"
  ```
  (project.pbxproj churn here is target-membership only — the shared-file exceptions. Do not stage other pbxproj drift.)

### 4d — remove dead `settings.apns_alert_nag_enabled` (backend)

Verified: defined at `app/core/settings.py:125` (`apns_alert_nag_enabled: bool = False`); referenced ONLY in the docstring at `app/services/apns_sender.py:180` ("Gated by `apns_alert_nag_enabled` at the call site, not here") — no actual call site gates on it. `send_alert_nag` is called internally (`apns_sender.py:224`) unconditionally.

- [ ] **Step 1: Grep proof** —
  ```bash
  cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
  grep -rn "apns_alert_nag_enabled" app/ tests/
  ```
  Expected: exactly the two lines (settings.py:125 def, apns_sender.py:180 comment). If any real gate appears, STOP and re-scope.

- [ ] **Step 2: Delete** the `apns_alert_nag_enabled` line in `settings.py:125` and fix the stale sentence in the `apns_sender.py:180` docstring (drop the "Gated by `apns_alert_nag_enabled`…" clause; state the nag is sent unconditionally when configured).

- [ ] **Step 3: Verify + commit**
  ```bash
  grep -rn "apns_alert_nag_enabled" app/ tests/   # expect: no matches
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test python -m pytest -q
  git add app/core/settings.py app/services/apns_sender.py
  git commit -m "chore(apns): remove dead apns_alert_nag_enabled flag (gated nothing) + fix stale docstring"
  ```

---

## Task 5: iOS — Apply Tomorrow real option

**Discovery (W1 follow-up f):** the "Apply Tomorrow" callbacks exist but never pass `effective`. Verified:
- `ProfileView.confirmPoolSave` (:1463-1466) calls `savePool(newMinutes:confirmedCascade:true)` — no `effective`, defaults to `"today"`. `savePool` already has `effective: String = "today"` (:1475) and forwards it to `putEarnedConfig(..., effective:)` (:1500-1503).
- `DeviceAppsSheet` cascade `onApplyTomorrow` (:235-240) calls `saveDeviceCap(cap, confirmedCascade:true)` — no `effective`. `saveDeviceCap` has `effective: String = "today"` (:749) forwarded to `putDeviceCap(..., effective:)` (:789-793).
- W1 Task 4 changed the chip copy to `"· applies immediately"` (:558) — now a LIE once tomorrow is real.
- The `PoolCascadeConfirmSheet`/`CascadeConfirmSheet` copy "The changes take effect at midnight…" (`ProfileView.swift:1801`) is honest and stays.

Backend note (by design): the tomorrow-row read-side filter (`effective_date <= as_of`, W1 commit `7ca59b1`, verified live at `earned_time_service.py:573,603`) means a `tomorrow` config writes a future-dated row that emits NO immediate command and activates lazily at midnight. A DB-gated backend read-side test already exists (`test_earned_time_policy_summary.py`). This task adds only the iOS callback assertion.

**Files:**
- Modify `Evlin iOS/Views/Profile/ProfileView.swift` (`confirmPoolSave` :1463-1466).
- Modify `Evlin iOS/Views/Profile/DeviceAppsSheet.swift` (`onApplyTomorrow` :235-240; chip copy :558 → honest; stale doc comments :533, :551).
- Create `Evlin iOSTests/ApplyTomorrowWiringTests.swift`.

- [ ] **Step 1: Write the failing test** — the callbacks call private methods, so assert at the smallest testable seam. Extract a tiny pure helper used by both callbacks and test it:
  ```swift
  // In ProfileView.swift and DeviceAppsSheet.swift (or a shared small enum):
  enum ApplyTomorrowIntent { static let effective = "tomorrow" }
  ```
  Test:
  ```swift
  import XCTest
  @testable import Evlin_iOS
  final class ApplyTomorrowWiringTests: XCTestCase {
      func test_applyTomorrowIntent_isTomorrow() {
          XCTAssertEqual(ApplyTomorrowIntent.effective, "tomorrow")
      }
  }
  ```
  (This pins the constant; the wiring itself is verified by the callback edits + build. If a richer seam is feasible — e.g. injecting a capture closure into `savePool` — prefer asserting the forwarded `effective` value directly.)

- [ ] **Step 2: Wire the callbacks** —
  - `confirmPoolSave` (:1465): `savePool(newMinutes: newMinutes, confirmedCascade: true, effective: ApplyTomorrowIntent.effective)`.
  - `DeviceAppsSheet` cascade `onApplyTomorrow` (:239): `saveDeviceCap(cap, confirmedCascade: true, effective: ApplyTomorrowIntent.effective)`.

- [ ] **Step 3: Restore honest copy** — `DeviceAppsSheet.swift:558` `Text("· applies immediately")` → `Text("· takes effect at midnight")`; update the stale doc comments at :533 ("applies immediately" chip) and :551 ("changes tomorrow") to describe the true midnight-activation semantics. (The over-cap chip represents an existing rule that will re-activate at the next day boundary — "takes effect at midnight" is truthful again now that tomorrow rows activate lazily.)

- [ ] **Step 4: Build + test**
  ```bash
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:"Evlin iOSTests/ApplyTomorrowWiringTests" test 2>&1 | tail -5
  ```
  Expected: `** BUILD SUCCEEDED **`; `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**
  ```bash
  git add "Evlin iOS/Views/Profile/ProfileView.swift" "Evlin iOS/Views/Profile/DeviceAppsSheet.swift" \
          "Evlin iOSTests/ApplyTomorrowWiringTests.swift"
  git commit -m "feat(screentime): Apply Tomorrow passes effective:tomorrow through savePool/saveDeviceCap; restore honest 'takes effect at midnight' copy"
  ```

---

## Task 6: iOS — Fix 7: catch-up reset on stale day

**Design spec Fix 7:** on kid-app foreground + extension `intervalDidStart`, compare stored `day_key` vs today (child tz); if stale (midnight `intervalDidStart` was missed because the device was off): clear earned shields for the old day, reset `latestDeviceEstimate`/`earnedUsageOffset`, re-arm, emit a timeline `reason="catch_up_reset"`. Verified: `intervalDidStart` handles `evlin.earned.budget` → `resetEarnedTimeShields` (`DeviceActivityMonitorExtension.swift:68-70`); no `day_key` is stored today (EarnedTimeStore has no such key). `todayISODate()` exists (:526).

**Files:**
- Modify `Evlin iOS/Services/EarnedTimeStore.swift` (add `storedEarnedDayKey` accessor).
- Modify `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` (`intervalDidStart` :68-70 stamp today; `handleEarnedThreshold` early — catch-up compare).
- Add a foreground hook (kid app): call the same compare on scenePhase active. Reuse `BigKidStatePoller.refreshNow()` path or add a call in `BigKidRootView`'s scene-active handler.
- Create `Evlin iOSTests/CatchUpResetTests.swift` (day-compare pure logic).

- [ ] **Step 1: Write failing tests** — pure day-compare helper. Add to `EarnedBudgetScheduler` (or a small `EarnedDayReset` enum shared into the extension + test target):
  ```swift
  enum EarnedDayReset {
      /// True when the stored day-key differs from today's (a missed midnight reset).
      static func isStaleDay(stored: String?, today: String) -> Bool {
          guard let s = stored, !s.isEmpty else { return false }  // no stored day → nothing to catch up
          return s != today
      }
  }
  ```
  Tests:
  ```swift
  final class CatchUpResetTests: XCTestCase {
      func test_sameDay_notStale() { XCTAssertFalse(EarnedDayReset.isStaleDay(stored: "2026-07-03", today: "2026-07-03")) }
      func test_priorDay_isStale() { XCTAssertTrue(EarnedDayReset.isStaleDay(stored: "2026-07-02", today: "2026-07-03")) }
      func test_noStoredDay_notStale() { XCTAssertFalse(EarnedDayReset.isStaleDay(stored: nil, today: "2026-07-03")) }
  }
  ```

- [ ] **Step 2: Verify it fails** — `-only-testing:"Evlin iOSTests/CatchUpResetTests"`; expected BUILD FAIL.

- [ ] **Step 3: Add the stored-day accessor** — in `EarnedTimeStore.swift`: `private let earnedDayKeyKey = "earned.dayKey"`; `var storedEarnedDayKey: String? { get { defaults?.string(forKey: earnedDayKeyKey) } set { ... } }`; add to `removeAll()`.

- [ ] **Step 4: Add `EarnedDayReset` + a catch-up routine** — in the extension, add a private `catchUpResetIfStale()`:
  ```swift
      /// Fix 7: if the stored earned day-key is older than today (child tz), the
      /// midnight intervalDidStart reset was missed (device off). Clear earned
      /// shields for the old day, reset estimate/offset, re-arm, emit catch_up_reset.
      private func catchUpResetIfStale() {
          let store = EarnedTimeStore.shared
          let today = todayISODate()
          guard EarnedDayReset.isStaleDay(stored: store.storedEarnedDayKey, today: today) else { return }
          resetEarnedTimeShields(activity: "evlin.earned.budget")   // strips ONLY .earnedTime
          store.latestDeviceEstimate = nil
          store.earnedUsageOffsetMinutes = 0
          store.storedEarnedDayKey = today
          // Re-arm at the current real pool/cap (Task 1 seam).
          if store.isEarnedTimeReady, let selection = store.measurementSelection {
              let pool = store.poolMinutes ?? 60
              let cap  = store.capMinutes ?? pool
              EarnedBudgetScheduler.shared.arm(poolMinutes: pool, capMinutes: cap, selection: selection)
          }
          emitEvent(kind: .reset, source: .earnedPool, app: "device-wide", reason: "catch_up_reset")
      }
  ```
  Call `catchUpResetIfStale()` at the top of `handleEarnedThreshold` (before parsing), and stamp `store.storedEarnedDayKey = todayISODate()` inside the existing `resetEarnedTimeShields` interval-reset path (so a normal midnight reset also updates the day-key). In `intervalDidStart` for `evlin.earned.budget` (:68-70), set `store.storedEarnedDayKey = todayISODate()` alongside `resetEarnedTimeShields`.

- [ ] **Step 5: Foreground hook (kid app)** — in `BigKidRootView` scene-active handling (near `refreshNow()`), call a lightweight `EarnedBudgetScheduler.shared`-adjacent catch-up. Since the app target cannot call the extension's private method, replicate the compare in the app: if `EarnedDayReset.isStaleDay(stored: EarnedTimeStore.shared.storedEarnedDayKey, today: todayISODate())`, strip earned shields via the app's existing `ActiveLockStore` earned-strip path and re-arm via `EarnedBudgetScheduler.shared.arm(...)`, then stamp the day-key. (Find the app-side earned-strip: reuse whatever `resetEarnedTimeShields` mirrors — the `ShieldSourceLogic.strippingSource(.earnedTime,...)` helper. Confirm the app-side symbol before wiring; if none exists cleanly, the extension hook alone satisfies the spec and this app-foreground call can stamp the day-key + re-arm only.)

- [ ] **Step 6: Run tests + build**
  ```bash
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:"Evlin iOSTests/CatchUpResetTests" test 2>&1 | tail -5
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
  ```
  Expected: `TEST SUCCEEDED`; `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**
  ```bash
  git add "Evlin iOS/Services/EarnedTimeStore.swift" \
          "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift" \
          "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift" \
          "Evlin iOSTests/CatchUpResetTests.swift"
  git commit -m "fix(screentime): Fix 7 — catch-up reset on stale day (foreground + intervalDidStart); clear earned shields, reset estimate/offset, re-arm, emit catch_up_reset"
  ```

---

## Task 7: Backend — Fix 6: multi-device pool-exhaustion fanout

**Design spec Fix 6:** when ingest marks the child-day exhausted, queue the earned lock for ALL of the child's devices (reuse `_maybe_queue_auto_lock` per device incl. its own R20/idempotency guards), not just the reporting device. Verified: ingest currently calls `_maybe_queue_auto_lock` only for the reporting `child_device` (`earned_time_service.py:450`); the device enumeration query (`Device.family_id == family_id, Device.child_profile_id == child_profile_id, Device.mode == DeviceMode.child`) already exists in `put_pool_config` (:585-593) and is the pattern to reuse.

**Files:**
- Modify `app/services/earned_time_service.py` (`ingest_sample` around :448-459 — add fanout on child-day exhaustion; depends on Task 3's `AutoLockResult`).
- Create `tests/test_multi_device_exhaustion_fanout.py`.

**Trigger condition:** fan out only when the child-day transitioned to (or is) `exhausted` on THIS ingest (`new_state == "exhausted"` — computed at :372/:378). For each other child-mode device with a `EarnedTimeDeviceDay` row for `usage_date`, call `_maybe_queue_auto_lock` with that device's own `estimated_minutes`, `effective_cap` (resolve per device), and the shared `child_day_state`. Each device's own guards (R20 via `child_day_state`, idempotency via its own `selected_lock_command_id`, tokenless/missing) apply — so a device that already locked, or an override day, is a natural no-op.

- [ ] **Step 1: Write the failing tests** — `tests/test_multi_device_exhaustion_fanout.py`, DB-gated header + seed helpers cloned from `test_config_change_commands.py`:
  ```python
  async def test_two_devices_one_exhausts_pool_both_get_lock(session, monkeypatch): ...
      # Seed: pool=30, two child-mode devices A and B, each with a device-day row
      # (A estimated=30 exhausts on this ingest; B estimated=10, under its own cap).
      # Monkeypatch load/ensure_selected_set + queue_app_control (SimpleNamespace,
      # executable_tokens_count=1) as the W1 tests do, recording per-device calls.
      # Ingest A's exhausting sample -> assert queue_app_control called for BOTH
      # A.id and B.id; assert each device-day selected_lock_command_id set.

  async def test_override_day_neither_device_locks(session, monkeypatch): ...
      # child_day.state="override_unlocked"; A exhausts -> _maybe_queue_auto_lock
      # skips (R20) for every device -> zero shield calls.

  async def test_device_with_prior_lock_not_double_queued(session, monkeypatch): ...
      # B.selected_lock_command_id already set; A exhausts -> A gets a lock, B does not
      # (idempotency), assert exactly one NEW shield call (for A).

  async def test_non_exhaust_ingest_no_fanout(session, monkeypatch): ...
      # A estimated below pool (new_state stays "available") -> no fanout to B.
  ```

- [ ] **Step 2: Verify it fails**
  ```bash
  cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && source .venv/bin/activate
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_multi_device_exhaustion_fanout.py -v
  ```
  Expected: the "both get lock" test FAILS (only the reporter locks today).

- [ ] **Step 3: Add the fanout** — in `ingest_sample`, after the reporter's own `_maybe_queue_auto_lock` block (:448-459) and its `db.flush()`, add:
  ```python
      # --- Fix 6: multi-device pool-exhaustion fanout. When THIS ingest exhausts
      # the shared child-day, queue the earned lock for every OTHER child device
      # that has reached its own effective cap. Each device's own guards (R20 via
      # child_day_state, idempotency via its selected_lock_command_id, tokenless)
      # apply — reusing _maybe_queue_auto_lock inherits them all.
      if new_state == "exhausted":
          sibling_devices = (
              await db.execute(
                  select(Device).where(
                      Device.family_id == family_id,
                      Device.child_profile_id == child_profile_id,
                      Device.mode == DeviceMode.child,
                      Device.id != child_device_id,
                  )
              )
          ).scalars().all()
          for sib in sibling_devices:
              sib_day = (
                  await db.execute(
                      select(EarnedTimeDeviceDay).where(
                          EarnedTimeDeviceDay.family_id == family_id,
                          EarnedTimeDeviceDay.child_device_id == sib.id,
                          EarnedTimeDeviceDay.usage_date == usage_date,
                      )
                  )
              ).scalar_one_or_none()
              if sib_day is None:
                  continue
              sib_cap = await resolve_effective_cap_for_device(
                  db, family_id=family_id, child_device_id=sib.id,
                  child_profile_id=child_profile_id, as_of=usage_date,
              )
              if sib_cap is None:
                  continue
              await _maybe_queue_auto_lock(
                  db,
                  child_device=sib,
                  device_day_row=sib_day,
                  child_day_state=child_day_row.state,
                  max_estimated=sib_day.estimated_minutes,
                  effective_cap=sib_cap,
                  now_utc=now_utc,
              )
          await db.flush()
  ```
  (Confirm `DeviceMode` is imported — it is used in `put_pool_config`; `resolve_effective_cap_for_device` and `Device` are already imported. Note: a sibling whose `estimated_minutes < sib_cap` will not lock — Fix 6 is about POOL exhaustion; the spec queues the lock to siblings that have themselves reached exhaustion of the shared pool. Since `resolve_effective_cap_for_device` returns the pool as the effective cap when no explicit device cap is set, a sibling at/over the pool will lock; one comfortably under its own explicit cap will not. This matches "each incl. their own guards/R20".)

- [ ] **Step 4: Run tests + suite**
  ```bash
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_multi_device_exhaustion_fanout.py tests/test_config_change_commands.py tests/test_earned_time_auto_lock.py -v
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest -q
  ```
  Expected: all Fix-6 tests PASS; no new suite reds.

- [ ] **Step 5: Commit**
  ```bash
  git add app/services/earned_time_service.py tests/test_multi_device_exhaustion_fanout.py
  git commit -m "feat(screentime): Fix 6 — fan earned lock out to all child devices on shared-pool exhaustion (per-device guards/R20 reused)"
  ```

---

## Full regression gate (run once before declaring the wave complete)

```bash
# Backend
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && source .venv/bin/activate
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test python -m pytest -q \
  tests/test_config_change_commands.py tests/test_earned_time_policy_summary.py \
  tests/test_earned_time_remaining_recompute.py tests/test_screen_time_events_api.py \
  tests/test_earned_time_auto_lock.py tests/test_catalog_list_routes.py \
  tests/test_selected_set_lock.py tests/test_multi_device_exhaustion_fanout.py
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test python -m pytest -q   # whole suite: no NEW reds

# iOS
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS"
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Evlin iOSTests/CommandPollerEffectiveStateTests" \
  -only-testing:"Evlin iOSTests/CurrentRestrictionsReaderTests" \
  -only-testing:"Evlin iOSTests/DeviceIdentityTests" \
  -only-testing:"Evlin iOSTests/ScreenTimeEventUploaderTests" \
  -only-testing:"Evlin iOSTests/EarnedSampleReporterTests" \
  -only-testing:"Evlin iOSTests/LockedSetFullCoverageTests" \
  -only-testing:"Evlin iOSTests/EarnedGateTautologyTests" \
  -only-testing:"Evlin iOSTests/ArmGenerationTests" \
  -only-testing:"Evlin iOSTests/NSELockApplierLogicTests" \
  -only-testing:"Evlin iOSTests/CatchUpResetTests" test 2>&1 | tail -8
```

## End-to-end verification (manual, with the user — two kid devices for Task 7)
1. Kid uses the device to 5 min at pool 45 → NO lock; timeline shows `decision reason=pool_under_cap` (Fix 4 tautology dead). At budget → single labeled lock (`deviceCap` if an explicit cap binds, else `earnedPool`).
2. Unshield, then re-arm → no stale-generation re-lock; timeline shows `drop reason=superseded_generation` if a stale fire arrives (Fix 4b).
3. Lower pool on an override day → NO `policy_lowered_lock` timeline row (Task 3 honest event).
4. Reinstall / change server URL → NSE still applies a lock (mirror at every change); `evlin.spike.nseLog` shows staged fetch/apply/ack timestamps (Task 4a/4b).
5. Apply Tomorrow → future-dated row, no immediate command, activates at midnight; sheet says "takes effect at midnight" (Task 5).
6. Leave device off past midnight, foreground next day → catch-up reset clears yesterday's earned shields, timeline `reset reason=catch_up_reset` (Task 6).
7. Two kid devices under one pool; exhaust the pool on device A → BOTH A and B receive earned lock commands; on an override day neither locks (Task 7).

---

## Per-task one-liners
- **Task 1 (Fix 4, iOS):** Replace the tautological earned gate with `adjustedN >= min(pool,cap)` read fresh, add a real `backendRemaining`+sync-timestamp writer with a freshness veto, fix bucket default 10→5, and make re-arm pass real pool/cap.
- **Task 2 (Fix 4b, iOS):** Embed an arm-generation in ladder event names, drop superseded-generation fires (legacy names accepted as current), explicit `stop()` before re-arm.
- **Task 3 (backend):** Give `_maybe_queue_auto_lock` a `queued` signal and emit `policy_lowered_lock` only when a lock actually queued (no override/idempotency/tokenless white lie).
- **Task 4 (iOS+backend):** Centralize the `evlin.baseURL`/`childId` App-Group mirror at every pairing/URL/mode change; add NSE per-stage timestamps; extract + unit-test NSELockApplier pure logic; delete the dead `apns_alert_nag_enabled` flag.
- **Task 5 (iOS):** Wire the existing Apply-Tomorrow callbacks to pass `effective:"tomorrow"` and restore the honest "takes effect at midnight" copy.
- **Task 6 (Fix 7, iOS):** Catch-up reset on a stale day-key (foreground + `intervalDidStart`): clear earned shields, reset estimate/offset, re-arm, emit `catch_up_reset`.
- **Task 7 (Fix 6, backend):** On child-day exhaustion in ingest, fan the earned lock out to all child devices via `_maybe_queue_auto_lock` (per-device guards/R20 reused).

---

## Anchors I could NOT fully nail (explicit)

1. **No wire field carries backend earned *remaining* to the kid device (Task 1, load-bearing).** I verified: `ChildStateResponse` (`BigKidModels.swift:166-176`) carries only `minutesLeft`/`minutesMax` (the task-reward system, not earned pool); the `earned_time_config` command payload (`APIClient.swift:PollEarnedTimeConfigDTO` :544-554, backend `_build_earned_time_config_command_payload` :1076-1086) has `daily_pool_minutes`/`device_cap_minutes` but **no `remaining_minutes`**. `EarnedTimeStore.backendRemainingAtLastSync` genuinely has zero writers. My plan therefore **derives** backend remaining on the kid device as `min(pool,cap) − latestDeviceEstimate` at the CommandPoller sync (Task 1 Step 5) and stamps a new `earned.lastBackendSyncAt`. This is a pragmatic proxy, not a true server-authoritative remaining. If the team prefers a real value, add `remaining_minutes` to the `earned_time_config` payload (backend `_build_earned_time_config_command_payload`) + the `PollEarnedTimeConfigDTO`, and replace the derivation — that is a small, clean follow-up but is OUT of the current task list, so I did not smuggle it into the plan's required steps.

2. **Task 4c test host for `EvlinPushApplier`.** The NSE types live inside `NotificationService.swift` in the `EvlinPushApplier` target, which has no XCTest host. I could NOT confirm an existing test target that compiles NSE code. The plan handles this by **extracting** the pure logic into a shared file (BOTH `EvlinPushApplier` and `Evlin iOSTests` membership, mirroring `EarnedSampleReporter.swift`). If project.pbxproj membership editing proves infeasible in-session, the fallback is to test only the extracted helper via `@testable import Evlin_iOS` after also adding the shared file to the app target — the implementer must verify the membership edit builds both targets before relying on it.

3. **Task 6 app-side earned-strip symbol.** The extension's `resetEarnedTimeShields` is extension-private. I did not fully verify a clean app-target equivalent for stripping `.earnedTime` from `ActiveLockStore` on foreground; the plan notes the app-side foreground hook may only stamp the day-key + re-arm if no clean app-side strip helper exists (the extension `intervalDidStart`/`handleEarnedThreshold` hooks already satisfy the spec's enforcement requirement). Implementer should grep for an existing `ActiveLockStore` earned-strip before adding one.

4. **Task 4d `send_alert_nag` internal call.** `apns_sender.py:224` calls `send_alert_nag` unconditionally (not gated by the flag). I confirmed the flag gates nothing, but the implementer should re-run the Step-1 grep at edit time in case a concurrent session added a gate.
