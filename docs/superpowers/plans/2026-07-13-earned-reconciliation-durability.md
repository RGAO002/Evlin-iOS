# Earned Reconciliation Durability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow authoritative earned-time reconciliation to proceed when `UserDefaults.synchronize()` returns `false`, while retaining file-lock, identity, and write-readback safety.

**Architecture:** `synchronize()` becomes diagnostic-only because its Boolean is not a reliable App Group durability signal on physical devices. Each transaction snapshots the intended writes and verifies them through a fresh `UserDefaults` view for the same suite; a verification mismatch restores only fields that still equal this transaction's writes and returns `lockUnavailable`.

**Tech Stack:** Swift, Foundation `UserDefaults`, XCTest, Xcode 26, iOS App Group preferences.

## Global Constraints

- Modify only `EarnedTimeStore.swift`, `EarnedTimeStoreTests.swift`, and this plan/spec documentation.
- Preserve the interprocess file lock and every pre/post identity check.
- A false `UserDefaults.synchronize()` result is diagnostic-only; a read-back mismatch remains a hard failure.
- Do not modify Per-App Limit rules, schedules, counters, or App Group keys.
- Do not touch the user's beta-agreement worktree changes.
- Do not push Render or reset PostgreSQL as part of this task.

---

### Task 1: Replace synchronize-result gating with verified reconciliation

**Files:**
- Modify: `Evlin iOS/Services/EarnedTimeStore.swift:578-598,1150-1235`
- Test: `Evlin iOSTests/EarnedTimeStoreTests.swift:194-320`

**Interfaces:**
- Consumes: existing `withReconciliationTransaction`, rollback snapshots, file lock, and identity checks.
- Produces: `verificationDefaultsFactory: (String) -> UserDefaults?` initializer seam and transaction behavior where synchronize failure is nonfatal only when written values read back exactly.

- [ ] **Step 1: Replace obsolete synchronize-failure expectations with failing durability tests**

Update the tests so an always-false synchronize closure still executes and commits the transaction:

```swift
func test_falseSynchronizeStillRunsTransactionBody() {
    let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    var bodyRan = false
    let store = EarnedTimeStore(
        suiteName: suiteName,
        synchronizeDefaults: { _ in false }
    )

    let acquired = store.withReconciliationLockForTesting { bodyRan = true }

    XCTAssertTrue(acquired)
    XCTAssertTrue(bodyRan)
}

func test_falseSynchronizeCommitsRuntimeWhenFreshViewMatches() {
    let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let store = EarnedTimeStore(
        suiteName: suiteName,
        synchronizeDefaults: { _ in false }
    )

    XCTAssertEqual(store.reconcileRuntimePolicy(
        usageDate: "2026-07-13",
        timezoneIdentifier: "America/New_York",
        poolMinutes: 120,
        capMinutes: 90,
        remainingMinutes: 75,
        estimatedMinutes: 15,
        syncedAt: Date(timeIntervalSince1970: 200)
    ), .reconciled(15))
    XCTAssertEqual(store.poolMinutes, 120)
    XCTAssertEqual(store.capMinutes, 90)
    XCTAssertEqual(store.acceptedEstimateMinutes, 15)
}
```

Add a hard-failure test using a verification factory whose view omits the written keys:

```swift
func test_readBackMismatchRollsBackRuntimeFields() {
    let suiteName = "EarnedTimeStoreTests.\(UUID().uuidString)"
    let staleSuite = "EarnedTimeStoreTests.stale.\(UUID().uuidString)"
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removePersistentDomain(forName: staleSuite)
    }
    let seeded = EarnedTimeStore(suiteName: suiteName)
    XCTAssertEqual(seeded.reconcileRuntimePolicy(
        usageDate: "2026-07-13",
        timezoneIdentifier: "America/New_York",
        poolMinutes: 90,
        capMinutes: 60,
        remainingMinutes: 40,
        estimatedMinutes: 20
    ), .reconciled(20))
    let failing = EarnedTimeStore(
        suiteName: suiteName,
        verificationDefaultsFactory: { _ in UserDefaults(suiteName: staleSuite) },
        synchronizeDefaults: { _ in false }
    )

    XCTAssertEqual(failing.reconcileRuntimePolicy(
        usageDate: "2026-07-13",
        timezoneIdentifier: "America/Los_Angeles",
        poolMinutes: 30,
        capMinutes: 25,
        remainingMinutes: 5,
        estimatedMinutes: 25
    ), .lockUnavailable)
    XCTAssertEqual(seeded.poolMinutes, 90)
    XCTAssertEqual(seeded.capMinutes, 60)
    XCTAssertEqual(seeded.acceptedEstimateMinutes, 20)
}
```

Delete or rewrite the old tests whose names assert that pre/post synchronize failure itself causes rollback. Keep the explicit lock-unavailable, nil-defaults, competing-writer, and identity rollback tests.

- [ ] **Step 2: Run the focused tests and verify the new contract fails**

Run:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests'
```

Expected: FAIL because the current transaction returns `lockUnavailable` when `synchronizeDefaults` returns false and the initializer has no `verificationDefaultsFactory` seam.

- [ ] **Step 3: Add a fresh-view verification seam**

Store the suite name and verification factory:

```swift
private let suiteName: String
private let defaults: UserDefaults?
private let verificationDefaultsFactory: (String) -> UserDefaults?
private let reconciliationLock: EarnedReconciliationLock
private let synchronizeDefaults: (UserDefaults) -> Bool

init(
    suiteName: String = EarnedTimeStore.appGroupSuiteName,
    lockSelection: ReconciliationLockSelection? = nil,
    useInProcessLock: Bool = true,
    defaultsFactory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) },
    verificationDefaultsFactory: @escaping (String) -> UserDefaults? = {
        UserDefaults(suiteName: $0)
    },
    synchronizeDefaults: @escaping (UserDefaults) -> Bool = { $0.synchronize() }
) {
    self.suiteName = suiteName
    defaults = defaultsFactory(suiteName)
    self.verificationDefaultsFactory = verificationDefaultsFactory
    self.synchronizeDefaults = synchronizeDefaults
    // Preserve the existing reconciliation-lock selection unchanged.
}
```

Add exact snapshot comparison:

```swift
private func verificationMatches(
    _ written: [DefaultsSnapshotValue]
) -> Bool {
    guard !written.isEmpty else { return true }
    guard let verificationDefaults = verificationDefaultsFactory(suiteName) else {
        return false
    }
    return written.allSatisfy { entry in
        defaultsValuesEqual(
            verificationDefaults.object(forKey: entry.key),
            entry.value
        )
    }
}
```

- [ ] **Step 4: Make synchronize diagnostic-only and read-back mismatch transactional**

In `withReconciliationTransaction`, call `synchronizeDefaults(defaults)` before the body without guarding the result. Record `pre_synchronize_nonfatal` when it returns false, then continue under the existing lock and identity checks.

After `body()` and the existing `beforeCommit`/identity check, call synchronize again. Record `post_synchronize_nonfatal` on false. Then require `verificationMatches(written)`. On mismatch, run the existing compare-and-restore rollback, call synchronize best-effort, and return unavailable with stage `post_write_readback`.

Do not remove either post-await/post-body identity check, and do not change the compare-and-restore logic used to avoid overwriting a competing newer value.

- [ ] **Step 5: Run focused earned-time and per-app regression tests**

Run:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' \
  -only-testing:'Evlin iOSTests/EarnedConfigCommandTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/ActionExecutorLimitTests' \
  -only-testing:'Evlin iOSTests/AppLimitPlannerTests'
```

Expected: all selected suites PASS; Per-App Limit tests show no behavioral regression.

- [ ] **Step 6: Build for the connected iPad**

Run the existing signed `Evlin iOS` device build for destination ID `00008101-001675CE3C11A01E`. Expected: build succeeds with the app and extensions signed.

- [ ] **Step 7: Verify diff scope and commit**

```bash
git diff --check
git diff -- 'Evlin iOS/Services/EarnedTimeStore.swift' \
  'Evlin iOSTests/EarnedTimeStoreTests.swift'
git add 'Evlin iOS/Services/EarnedTimeStore.swift' \
  'Evlin iOSTests/EarnedTimeStoreTests.swift' \
  'docs/superpowers/plans/2026-07-13-earned-reconciliation-durability.md'
git diff --cached --check
git commit -m "fix: tolerate false app-group synchronize results"
```

- [ ] **Step 8: Perform physical acceptance**

Install and launch the build on Ruoping's iPad. Confirm the diagnostics no longer remain at `authoritative-state-not-ready`, the runtime policy is restored, and an earned activity generation is armed. With tasks complete and reflection inactive, keep a measured app open for one full five-minute threshold and verify `counted=true`, Total Pool movement, Device Limit movement, and unchanged Per-App Limit behavior.
