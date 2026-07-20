# Metering Phase 4 Task 14 Implementation Report

## Outcome

- Status: DONE
- Branch: `calendar-in-chat`
- Base: `ff161c5a1625375c92f94e97be43e17cd89f6862`
- Commit: `49414119f0bdb222b30cbc08b384fbc2ab9fd521`
- Subject: `feat: journal app limit effects with receipts`

## TDD RED

Tests were added first in `AppLimitEffectJournalTests.swift` and
`LimitShieldLogicTests.swift`. They cover durable enqueue and duplicate
callbacks, lease recovery after a crash boundary, idempotent local mutation and
receipt readback, clear-before-shield CAS, set-during-transport CAS, HTTP 200
`accepted:false`, versioned request bodies, current applied-receipt readback,
shield provenance, and per-app isolation.

Command:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test \
  -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  IPHONEOS_DEPLOYMENT_TARGET=17.6 \
  TARGETED_DEVICE_FAMILY='1,2' \
  -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' \
  -only-testing:'Evlin iOSTests/LimitShieldLogicTests'
```

Result: expected RED, exit 65. After clearing a stale DerivedData signing
artifact and correcting one test-local fixture reference, the production
failure was the missing provenance-aware Task 14 shield adapter:

```text
incorrect argument label in call (have 'to:callback:now:', expected 'to:rule:now:')
cannot convert value of type 'AppLimitValidatedCallback' to expected argument type 'AppLimitRule'
** TEST FAILED **
```

RED log: `/tmp/metering-phase4-task14-red.log`.

## Minimal GREEN

- Added a durable callback effect journal keyed by rule, ordering token, arm,
  callback kind, and raw threshold.
- Added persisted worker leases with expiry/reclaim behavior.
- Kept `ActiveLockPersistenceLock` held from the final epoch/arm/lease check
  through synchronous local mutation and durable receipt write/readback.
- Released the lock for async transport, included `ordering_token`, decoded the
  authoritative response body, and re-entered the lock for an exact
  slot/token/arm/lease CAS.
- Treated HTTP 200 `accepted:false` as rejected and never wrote a usage receipt.
- Routed the Task 13 validator's accepted callback solely into journal enqueue.
- Kept per-app ledger mutation isolated from earned, device-total, cap, and
  shared-pool ledgers.
- Added `.limit` shield provenance for rule ID, ordering token, arm ID, and
  child owner.
- Added current-token/current-arm durable `AppLimitApplyReceipt` readback.
- Did not broaden notification service extension ownership.

Focused GREEN command: the same two-class RED command above.

Result: `AppLimitEffectJournalTests` 9/9 and `LimitShieldLogicTests` 16/16;
25 tests passed. Log: `/tmp/metering-phase4-task14-green.log`.

## Exact Verification

iOS command:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test \
  -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  IPHONEOS_DEPLOYMENT_TARGET=17.6 \
  TARGETED_DEVICE_FAMILY='1,2' \
  -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' \
  -only-testing:'Evlin iOSTests/AppLimitCallbackNoEffectsTests' \
  -only-testing:'Evlin iOSTests/LimitShieldLogicTests' \
  -only-testing:'Evlin iOSTests/ShieldSourceSetTests' \
  -only-testing:'Evlin iOSTests/AppLimitMeasurementTests'
```

Result: `TEST SUCCEEDED`, 57/57 tests:

- `AppLimitEffectJournalTests`: 9
- `AppLimitCallbackNoEffectsTests`: 5
- `LimitShieldLogicTests`: 16
- `ShieldSourceSetTests`: 19
- `AppLimitMeasurementTests`: 8

Log: `/tmp/metering-phase4-task14-ios-verify.log`.

Backend command:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python \
  scripts/run_limits_db_regression.py tests/test_app_limit_usage.py
```

Result: 13/13 passed in 9.98 seconds against an isolated local test database;
the test database was dropped afterward. No remote or production service was
used. Log: `/tmp/metering-phase4-task14-backend-verify.log`.

Focused regressions:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test \
  -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  IPHONEOS_DEPLOYMENT_TARGET=17.6 \
  TARGETED_DEVICE_FAMILY='1,2' \
  -only-testing:'Evlin iOSTests/AppLimitCallbackValidatorTests' \
  -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests' \
  -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests' \
  -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests'
```

Result: `TEST SUCCEEDED`, 48/48 tests: validator 4, wake recovery 9, epoch
store 22, and target membership 13. Log:
`/tmp/metering-phase4-task14-focused-regressions.log`.

## Changed Files

Exactly the eight declared Task 14 paths were committed:

1. `Evlin iOS/Services/AppLimitEffectJournal.swift`
2. `Evlin iOS/Services/AppLimitUsageReporter.swift`
3. `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
4. `Evlin iOS/Services/AppLimitProductionComposition.swift`
5. `Evlin iOS/Services/AppLimitEpochTypes.swift`
6. `Evlin iOS.xcodeproj/project.pbxproj`
7. `Evlin iOSTests/AppLimitEffectJournalTests.swift`
8. `Evlin iOSTests/LimitShieldLogicTests.swift`

## Staging And WIP Safeguards

- The seven ordinary paths were staged explicitly.
- `project.pbxproj` was staged only through an index patch adding:
  `Services/AppLimitEffectJournal.swift,`.
- Cached names were exactly the eight paths above.
- `git diff --cached --check` was clean.
- Cached diff contained no beta, agreement, or onboarding identifiers.
- Cached project diff had exactly one addition and zero removals.
- Pre-task project worktree hash: `6557cfdfa60d69fb5aac65e02791314c6948c411`.
- Post-task project worktree hash: `22b77510924afe32a7592f971f7ba570aa0bdb53`.
- Removing the one Task 14 membership line from the post-task worktree produced
  the exact pre-task hash, proving the existing reorder WIP remained intact.
- Post-commit project index hash: `92a4a5591d10c719f74b324844359c159ac7db41`.
- Post-commit project worktree diff contains only the pre-existing ordering WIP.
- Protected user WIP remained unstaged and byte-identical. Recorded hashes:
  `ContentView.swift` `29f11a31fdffa0eecabbd462cd4146c464b32c3c`,
  `APIClient.swift` `f7124cb9fdf20dce5cf1a53fb6fa4ebac646d376`,
  `OnboardingCoordinator.swift` `5765173eb559a97c50a19f6239abd97fcb3cd1b3`,
  `ParentBetaAgreementStep.swift` `22d177473e8ddb76938184137cbd8f2966a6e704`,
  and workspace UI state `e41bad29de958352e13c82b8eb8883bc6de66659`.
- The index was empty after commit. No push, deploy, credentials, TestFlight,
  Render, or production database operation occurred.

## Self-Review

- The Task 13 validator remains the sole callback effect input; accepted work
  only enqueues the durable journal.
- Duplicate callbacks cannot create duplicate journal entries.
- Expired leases are reclaimable; exact lease identity prevents an old worker
  from committing after another worker reclaims work.
- Newer set/clear state removes stale journal work before local or transport
  receipts can commit.
- Completed or rejected entries are pruned once their arm is no longer current,
  preventing cross-arm accumulation.
- Local ledger and shield mutations are idempotent under replay.
- Backend response acceptance requires both a 2xx status and decoded
  `accepted:true` with the same current ordering token.
- Shield records retain `.limit` source and exact rule/token/arm/owner
  provenance without altering unrelated shield records.
- Current applied-receipt readback rejects a stale token or arm.

## Concerns

No Task 14 correctness blocker remains. The build continues to emit existing
Swift 6 isolation/sendability warnings in unrelated legacy tests and model
types; all requested and focused suites pass under the current Swift 5 mode.

---

## Adjudicated Review Fix

### Outcome

- Status: DONE
- Review-fix base: `49414119f0bdb222b30cbc08b384fbc2ab9fd521`
- Commit: `cff658ceb28b4279d225c596c88b8a7b12d61b1b`
- Subject: `fix: close app limit effect recovery gaps`
- Branch: `calendar-in-chat`

### TDD RED And GREEN

All iOS builds/tests below used the local iPhone 17 Pro simulator, unsigned
test execution, serial test selection, and `SENTRY_SKIP_DSYM_UPLOAD=1` after
the initial build-script issue documented under Concerns.

Common command shape:

```bash
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild build-for-testing CODE_SIGNING_ALLOWED=NO \
  -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14ReviewFix -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/<focused suite or test>'

SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild test-without-building CODE_SIGNING_ALLOWED=NO \
  -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14ReviewFix -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/<focused suite or test>'
```

1. Local crash boundary and durable readback

   RED: `AppLimitEffectJournalTests` plus `LimitShieldLogicTests` failed to
   compile because `AppLimitShieldPersistence` and
   `AppLimitShieldPersistenceStore` did not exist. Log:
   `/private/tmp/task14-fix-finding1-red.log`.

   GREEN: crash-after-local-mutation reopen/reclaim, durable shield encoding,
   synchronize/write/readback failure, receipt readback, and idempotent replay
   tests passed. Log: `/private/tmp/task14-fix-finding1-green.log`.

2. Authoritative rejection classification

   RED: `AppLimitEffectJournalTests` failed to compile because the persisted
   effect had no `retryNotBefore`; the future-token retry test could not build.
   Log: `/private/tmp/task14-fix-finding2-red.log`.

   GREEN: future-token bounded backoff/release, stale/rule-cleared terminal,
   usage-gate terminal/no-charge, unknown terminal, and transport/decode retry
   tests passed. Log: `/private/tmp/task14-fix-finding2-green.log`.

3. Production retry liveness

   RED: the lifecycle recovery test failed before implementation because the
   effect recovery driver/entry and launch/foreground/silent/poll triggers were
   absent.

   GREEN: `AppLimitWakeRecoveryTests` passed 10/10, including recovery after a
   final callback plus failed transport and a later lifecycle entry. Log:
   `/private/tmp/task14-finding3-green-test.log`.

4. Live applied-receipt readback

   RED: wake/poll/action tests failed to compile because
   `appLimitReceiptReadbackOverride` and the live owner readback path were
   absent. Log: `/private/tmp/task14-finding4-red.log`.

   GREEN: final focused counts were wake recovery 10/10, command poller 16/16,
   and action executor 18/18. Set receipts carry the current arm; clear receipts
   carry nil; pending or stale readback cannot confirm. Logs:
   `/private/tmp/task14-finding4-wake-green.log`,
   `/private/tmp/task14-single-test.log`, and
   `/private/tmp/task14-action-isolation-green.log`.

5. Preserve same-key shield sources

   RED command selected the two new source-union/removal tests in
   `LimitShieldLogicTests`; both failed because applying `.limit` replaced the
   prior source set and stripping then removed the record. Log:
   `/private/tmp/task14-finding5-red.log`.

   GREEN: both tests passed after unioning existing sources before persistence.
   Log: `/private/tmp/task14-finding5-green.log`.

6. Stable idempotency identity

   RED: the focused reporter test failed to compile because
   `AppLimitUsageReporter.clientSampleID` did not exist. Log:
   `/private/tmp/task14-finding6-red.log`.

   GREEN: the focused request test passed with rule ID, ordering token, arm ID,
   usage date, and threshold/budget identity in a backend-compatible value under
   255 characters. Log: `/private/tmp/task14-finding6-green.log`.

7. Clock injection

   RED: the source-contract test failed while the callback-specific pure shield
   transform still supplied a direct `Date()` default. Log:
   `/private/tmp/task14-finding7-red.log`.

   GREEN: 1/1 passed after requiring every caller to supply operation time.
   Log: `/private/tmp/task14-finding7-green.log`.

8. Combined-suite state/readback regression found during verification

   The first exact combined run executed 163 tests with 12 failures, all in
   `ActionExecutorLimitTests`, because legacy fixtures still used the unsigned
   App Group-backed shared rule store. Log:
   `/private/tmp/task14-review-fix-ios-verify.log`.

   After isolating that suite with per-test epoch/rule stores, ActionExecutor was
   18/18, but repeated combined runs exposed intermittent quota rollback and V2
   provenance `readbackMismatch` failures (one failure, then three failures).
   Logs: `/private/tmp/task14-review-fix-ios-verify-green.log` and
   `/private/tmp/task14-review-fix-ios-verify-final.log`.

   A 10-iteration diagnostic reproduced the two affected paths 12 times in 20
   executions. The persisted bytes matched; decoding `.secondsSince1970`
   canonicalized a live fractional `Date` by one ULP in
   `timeIntervalSinceReferenceDate`, so the final candidate-vs-decoded structural
   equality rejected valid durable state.

   Deterministic RED:

```bash
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild test-without-building CODE_SIGNING_ALLOWED=NO \
  -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14ReviewFix -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests/testTransactionAcceptsByteExactReadbackWhenDateCanonicalizesByOneULP'
```

   Result: 1/1 failed with `AppLimitEpochStoreError.readbackMismatch`. Log:
   `/private/tmp/task14-date-red.log`.

   Minimal GREEN retained byte-for-byte immediate readback, decode, state
   invariant validation, and owner validation, and removed only the redundant
   non-canonical in-memory state equality. The deterministic test plus both
   formerly flaky paths passed 30/30 over ten iterations. Log:
   `/private/tmp/task14-date-green.log`.

### Final Verification

Final staged-tree build:

```bash
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild build-for-testing CODE_SIGNING_ALLOWED=NO \
  -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14ReviewFix -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/LimitShieldLogicTests'
```

Result: `TEST BUILD SUCCEEDED`. Log: `/private/tmp/task14-final-staged-build.log`.

Final exact combined command selected these 12 suites in one serial process:

```text
AppLimitEffectJournalTests
AppLimitCallbackNoEffectsTests
LimitShieldLogicTests
ShieldSourceSetTests
AppLimitMeasurementTests
AppLimitWakeRecoveryTests
CommandPollerTests
AppLimitCommandCoordinatorTests
ActionExecutorLimitTests
AppLimitCallbackValidatorTests
AppLimitEpochStoreTests
MeteringTargetMembershipTests
```

Result: `TEST EXECUTE SUCCEEDED`, 164/164 with zero failures:

- `ActionExecutorLimitTests`: 18
- `AppLimitCallbackNoEffectsTests`: 5
- `AppLimitCallbackValidatorTests`: 5
- `AppLimitCommandCoordinatorTests`: 12
- `AppLimitEffectJournalTests`: 15
- `AppLimitEpochStoreTests`: 23
- `AppLimitMeasurementTests`: 9
- `AppLimitWakeRecoveryTests`: 10
- `CommandPollerTests`: 16
- `LimitShieldLogicTests`: 19
- `MeteringTargetMembershipTests`: 13
- `ShieldSourceSetTests`: 19

Log: `/private/tmp/task14-final-staged-ios.log`.

Local backend command:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py tests/test_app_limit_usage.py
```

Result: 13/13 passed in 9.99 seconds. The isolated local test database was
dropped afterward. No production or remote database was used. Log:
`/private/tmp/task14-review-fix-backend-final.log`.

### Changed Paths

The review-fix commit contains exactly these 15 narrowly authorized paths:

1. `Evlin iOS/Services/ActionExecutor.swift`
2. `Evlin iOS/Services/AppLimitEffectJournal.swift`
3. `Evlin iOS/Services/AppLimitEpochStore.swift`
4. `Evlin iOS/Services/AppLimitEpochTypes.swift`
5. `Evlin iOS/Services/AppLimitProductionComposition.swift`
6. `Evlin iOS/Services/AppLimitUsageReporter.swift`
7. `Evlin iOS/Services/CommandPoller.swift`
8. `Evlin iOS/Services/MeteringProcessEntries.swift`
9. `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
10. `Evlin iOSTests/ActionExecutorLimitTests.swift`
11. `Evlin iOSTests/AppLimitEffectJournalTests.swift`
12. `Evlin iOSTests/AppLimitEpochStoreTests.swift`
13. `Evlin iOSTests/AppLimitWakeRecoveryTests.swift`
14. `Evlin iOSTests/CommandPollerTests.swift`
15. `Evlin iOSTests/LimitShieldLogicTests.swift`

`AppLimitEpochStore.swift` and its focused test were added only after the exact
combined command deterministically proved the live fractional-date readback
defect in the production V2 provenance transaction.

### Staging And WIP Safeguards

- All 15 paths were staged explicitly; no whole-project or APIClient add was
  used.
- Cached names matched the 15-path list exactly.
- `git diff --cached --check` was clean.
- Cached diff contained zero beta, agreement, or onboarding identifiers,
  including diff context.
- Cached `project.pbxproj` diff was empty; no membership change was required.
- Cached `APIClient.swift` diff was empty; the owner readback adapter uses the
  existing `APIClient.ack` API from `CommandPoller.swift`.
- `project.pbxproj` review-fix start hash:
  `22b77510924afe32a7592f971f7ba570aa0bdb53`.
- `project.pbxproj` pre-commit/post-commit worktree hash:
  `22b77510924afe32a7592f971f7ba570aa0bdb53`.
- The project reorder WIP therefore remained byte-identical throughout this
  review fix and unstaged.
- Protected `APIClient.swift` baseline/current hash:
  `f7124cb9fdf20dce5cf1a53fb6fa4ebac646d376`.
- That API hash is the ignored baseline specifically because it contains the
  user's pre-existing beta-agreement WIP, not because it matches clean HEAD.
  No Task 14 API hunk was added, so stripping the zero Task 14 hunks directly
  yields the exact baseline hash.
- Protected ContentView, onboarding, beta step, xcuserdata, debugger, project,
  and other user WIP remained unstaged. Untracked user files were not modified.
- The index was empty after commit.
- No push, app deploy, Render, TestFlight, production DB, or backend remote
  operation was performed.

### Self-Review

- The Task 13 validator remains the sole callback effect input.
- The shared `ActiveLockPersistenceLock` spans final slot/token/arm/lease CAS,
  local durable mutation, receipt persistence, and receipt readback.
- Crash replay is idempotent across ledger and same-key shield state.
- HTTP 200 `accepted:false` is decoded as authoritative and cannot create an
  applied usage receipt. Future tokens back off; stale/cleared/gated/unknown
  explicit rejections are terminal/no-charge as specified.
- Lifecycle recovery is wired for launch, foreground, silent notification, and
  poll completion; NSE remains persist-only.
- Owner set/clear confirmation requires the exact live durable receipt; set
  requires current arm ID and clear requires nil.
- Same-key `.limit` application preserves manual, earned-time, and task-pause
  sources, and later `.limit` removal preserves those sources.
- `client_sample_id` differentiates ordering revisions and arm IDs within the
  backend 255-character limit.
- The callback shield transform requires explicit operation time.
- Epoch readback still requires exact persisted bytes plus successful decode,
  invariant validation, and owner validation; only an invalid sub-ULP in-memory
  `Date` equality check was removed.
- Temporary diagnostic `NSLog` statements were removed before commit.

### Concerns

- An early ordinary Xcode build, before the skip environment was consistently
  applied, invoked the repository's existing Sentry dSYM script with the local
  workspace credential and appeared to upload simulator symbols. This was not
  an app deployment or backend/production operation, but it was an unintended
  credential/network side effect contrary to the task constraint. Every later
  build explicitly set `SENTRY_SKIP_DSYM_UPLOAD=1`; final logs confirm the skip.
- Existing Swift 6 isolation/sendability warnings and unsigned simulator App
  Group/FamilyControls diagnostics remain outside this review-fix scope. The
  requested suites pass under the repository's current Swift 5 test mode.

## Independent Review Round 2

Binding brief: the `Independent Review Round 2` section of
`.superpowers/sdd/metering-phase4-task14-review.md`.

Base: `cff658ceb28b4279d225c596c88b8a7b12d61b1b` on
`calendar-in-chat`.

Commit: `2cb8832864dd297b03210b91749c7a0d1407db83`
(`fix: harden app limit durable effects`).

Every Round 2 Xcode invocation used `SENTRY_SKIP_DSYM_UPLOAD=1`,
`-disableAutomaticPackageResolution`, `CODE_SIGNING_ALLOWED=NO`, and serial
testing on `iPhone 17 Pro, iOS 26.3.1`.

### Finding 1: Fractional Date Canonicalization

Tests added deterministic fractional dates for shield persistence and journal
enqueue, lease, local receipt, usage receipt, and retry state. The date was
constructed with a fixed `Double(bitPattern:)`, not `Date()`.

RED/GREEN command:

```bash
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild test CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14Round2 -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests'
```

RED: 18 tests executed, 3 failures. All three new tests threw
`durableReadbackMismatch`, confirming structural comparison against the
uncanonicalized fractional `Date`. Log:
`/private/tmp/task14-round2-item1-red.log`.

GREEN: 18/18 passed. Persistence still requires exact immediate bytes,
successful decode, count/key invariants, and current epoch validation; lease
and receipt checks compare stable semantic identity rather than lossy dates.
Log: `/private/tmp/task14-round2-item1-green.log`.

An initial test-only compile mistake used an unsupported dictionary-key
assertion. It was corrected before recording RED; the correction log is
`/private/tmp/task14-round2-item1-test-compile-correction.log`.

### Finding 2: Verified Source-Preserving Clear

Mixed-source RED/GREEN command:

```bash
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild test CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14Round2 -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/ActionExecutorLimitTests/testAuthorizedClearOwnerWorkRemovesOnlyLimitShieldAndCommitsReceipt'
```

RED: 1 test executed, 1 failure. The same-key record was deleted instead of
retaining `.manual`, `.earnedTime`, and `.taskPause`. Log:
`/private/tmp/task14-round2-item2a-red.log`.

GREEN: 1/1 passed after direct and recovery clear were routed through one
verified durable source-removal operation. Log:
`/private/tmp/task14-round2-item2a-green.log`.

Persistence-failure RED command used these two selectors:

```text
Evlin iOSTests/ActionExecutorLimitTests/testAuthorizedClearPersistenceFailuresNeverConfirmOrCommitReceipt
Evlin iOSTests/ActionExecutorLimitTests/testRecoveryClearPersistenceFailureNeverCommitsReceiptOrConfirms
```

RED: build failed as expected because `ActionExecutor` had no injected
`appLimitLockStore` and `ActiveLockStore` had no injected verified shield
persistence. Errors were `extra argument 'shieldPersistence' in call` and
`extra argument 'appLimitLockStore' in call`. Log:
`/private/tmp/task14-round2-item2b-red.log`.

GREEN reran the mixed-source test plus both persistence-failure tests: 3/3
passed. Reload, write, and stale-readback failures retain pending owner work,
create no applied receipt, and produce no confirmed ack. Log:
`/private/tmp/task14-round2-item2b-green.log`.

The first full serial run later exposed that an old `removeLimitShields`
helper test still requires its legacy whole-record contract. Direct/recovery
production paths do not use that helper. Its original behavior was restored;
the 19-test `ShieldSourceSetTests` suite plus the verified production clear
test then passed 20/20. Logs:
`/private/tmp/task14-round2-final-ios-first-failed.log` and
`/private/tmp/task14-round2-legacy-helper-regression-green.log`.

### Finding 3: Verified Per-App Ledger

RED/GREEN command:

```bash
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild test CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14Round2 -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests/testLedgerUnavailableSynchronizeFailureOrStaleReadbackNeverRecordsLocalReceipt'
```

RED: 1 test executed with 6 assertion failures across unavailable,
synchronize-failure, and stale-readback cases. Each branch failed to throw and
incorrectly committed a local receipt. Log:
`/private/tmp/task14-round2-item3-red.log`.

GREEN: 1/1 passed. `AppLimitCallbackLocalLedger.record` now throws unless the
per-app reported-usage key synchronizes and an independently opened defaults
instance returns the exact expected key/value. The existing earned,
device-total, and shared-pool ledgers were not changed. Log:
`/private/tmp/task14-round2-item3-green.log`.

### Finding 4: Silent Wake Without Standard Child ID

RED/GREEN command:

```bash
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild test CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14Round2 -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests/testSilentNotificationRecoversWithoutStandardDefaultsChildID'
```

RED: 1 test executed, 1 failure; poll count was correctly zero but recovery
count was zero instead of one. Log:
`/private/tmp/task14-round2-item4-red.log`.

GREEN: 1/1 passed. The no-child early-return branch now invokes the existing
App Group-backed recovery only for `.silentRemoteNotification`; ordinary
no-child polls retain prior behavior. Log:
`/private/tmp/task14-round2-item4-green.log`.

### Focused And Full Verification

Affected combined suites:

```text
AppLimitEffectJournalTests
AppLimitCallbackNoEffectsTests
ActionExecutorLimitTests
AppLimitWakeRecoveryTests
ActiveLockStoreLimitReconcileTests
```

Result: 63/63 passed serially: Action Executor 20, lock-store reconcile 8,
callback no-effects 5, journal 19, and wake recovery 11. Log:
`/private/tmp/task14-round2-focused-green.log`.

The first complete 12-suite run executed 171 tests with one legacy-helper
failure described above. After restoring that helper's prior contract, the
exact 12-suite serial command was rerun and then repeated with a fresh compile
from the exact staged state:

```bash
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild test CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14Round2 -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' \
  -only-testing:'Evlin iOSTests/AppLimitCallbackNoEffectsTests' \
  -only-testing:'Evlin iOSTests/LimitShieldLogicTests' \
  -only-testing:'Evlin iOSTests/ShieldSourceSetTests' \
  -only-testing:'Evlin iOSTests/AppLimitMeasurementTests' \
  -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests' \
  -only-testing:'Evlin iOSTests/CommandPollerTests' \
  -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests' \
  -only-testing:'Evlin iOSTests/ActionExecutorLimitTests' \
  -only-testing:'Evlin iOSTests/AppLimitCallbackValidatorTests' \
  -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests' \
  -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests'
```

Final result: `TEST SUCCEEDED`, 171/171 with zero failures:

- `ActionExecutorLimitTests`: 20
- `AppLimitCallbackNoEffectsTests`: 5
- `AppLimitCallbackValidatorTests`: 5
- `AppLimitCommandCoordinatorTests`: 12
- `AppLimitEffectJournalTests`: 19
- `AppLimitEpochStoreTests`: 23
- `AppLimitMeasurementTests`: 9
- `AppLimitWakeRecoveryTests`: 11
- `CommandPollerTests`: 16
- `LimitShieldLogicTests`: 19
- `MeteringTargetMembershipTests`: 13
- `ShieldSourceSetTests`: 19

Definitive staged-state log:
`/private/tmp/task14-round2-final-staged-ios.log`.

Local backend command:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py tests/test_app_limit_usage.py
```

Result: 13/13 passed in 9.07 seconds. The isolated local PostgreSQL database
`ale_db_limits_test_1784530791_59453` was dropped afterward. No production or
remote database was used. Log: `/private/tmp/task14-round2-backend-final.log`.

### Changed Paths

The Round 2 commit contains exactly these 12 narrowly necessary paths:

1. `Evlin iOS/Services/ActionExecutor.swift`
2. `Evlin iOS/Services/ActiveLockStore.swift`
3. `Evlin iOS/Services/AppLimitCallbackValidator.swift`
4. `Evlin iOS/Services/AppLimitEffectJournal.swift`
5. `Evlin iOS/Services/CommandPoller.swift`
6. `Evlin iOS/Services/EarnedTimeStore.swift`
7. `Evlin iOS/Services/MeteringProcessEntries.swift`
8. `Evlin iOSTests/ActionExecutorLimitTests.swift`
9. `Evlin iOSTests/AppLimitCallbackNoEffectsTests.swift`
10. `Evlin iOSTests/AppLimitEffectJournalTests.swift`
11. `Evlin iOSTests/AppLimitWakeRecoveryTests.swift`
12. `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`

Commit stat: 672 insertions, 28 deletions.

### Staging And WIP Safeguards

- All 12 paths were staged explicitly; cached names matched this list exactly.
- `git diff --cached --check` was clean before commit.
- Cached diff contained zero beta, agreement, or onboarding identifiers.
- Cached project and APIClient diffs were empty; no target-membership change
  was required.
- `project.pbxproj` start, pre-commit, and post-commit worktree hash:
  `22b77510924afe32a7592f971f7ba570aa0bdb53`.
- Protected `APIClient.swift` beta-WIP start and post-commit hash:
  `f7124cb9fdf20dce5cf1a53fb6fa4ebac646d376`.
- No Round 2 APIClient hunk exists, so removing the zero added hunks yields the
  exact protected baseline directly.
- Project reorder WIP, API beta-agreement WIP, ContentView, onboarding,
  ParentBetaAgreementStep, xcuserdata, debugger files, and user docs remained
  unstaged. The index was empty after commit.
- No worktree, nested agent, push, deploy, Render, TestFlight, production DB,
  credential operation, or NSE authority expansion occurred.

### Self-Review

- Date-bearing journal and shield data use exact persisted bytes plus decode
  and invariant checks without invalid equality against pre-encoding
  fractional dates.
- The new verified clear is the sole direct/recovery production operation. It
  executes under `ActiveLockPersistenceLock`, strips only `.limit`, preserves
  same-record manual/earned/task sources, rereads state, and throws before any
  receipt or confirmation on reload/write/readback failure.
- Per-app ledger persistence is fail-closed through synchronization and exact
  key/value readback; a thrown mutation prevents `applyLocal` receipt commit.
- Silent recovery remains independent of normal standard-defaults child-ID
  configuration and still uses the existing App Group production entry.
- The Task 13 validated callback remains the sole local effect input.
- Usage requests still include `ordering_token`; authoritative HTTP 200
  `accepted:false` bodies cannot create applied usage receipts. Post-transport
  CAS still re-enters the lock and verifies the current slot/token/arm/lease
  identity before receipt or retry-state mutation.
- No temporary `NSLog`, `print`, logger, or other diagnostics were introduced
  by the Round 2 cached diff.

### Concerns

- Existing Swift 6 actor-isolation/sendability warnings and unsigned simulator
  App Group/FamilyControls diagnostics remain outside scope.
- Simulator app startup attempted its existing APNs registration and a local
  `192.168.1.175:8000` profile request; both failed in the unsigned/local test
  environment. No remote backend, production DB, deployment, or successful
  network side effect occurred.
- Xcode displayed cached package URLs while resolving the existing package
  graph despite automatic package resolution being disabled; no dependency
  version changed and no package file was staged.

## Independent Review Round 3

Binding brief: the `Independent Review Round 3` section of
`.superpowers/sdd/metering-phase4-task14-review.md`.

Implementation commit: `6d382b4c4645f67e929173399d828e62c6d21fe6`
(`fix: preserve app limit provenance on recovery`). The stopped-agent handoff
already contained this committed implementation and its two focused tests, but
did not append this required report section.

### TDD Baseline And GREEN

The first command run on takeover selected the two existing Round 3 tests:

```bash
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild test CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14Round3 -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/ActionExecutorLimitTests/testRecoveryClearRemovesDirectSetLimitFromHistoricalMixedSourceRecord' \
  -only-testing:'Evlin iOSTests/ActionExecutorLimitTests/testRecoveryClearDoesNotConfirmUnattributedLimitState'
```

Result: GREEN, 2/2 passed. Because the prior agent had already committed the
implementation, this takeover could not reproduce a truthful RED without
altering committed production code; no RED result is claimed. Log:
`/tmp/task14-round3-baseline.log`.

The positive test starts with a direct-set merge into a same-key record whose
`lastCommandID` belongs to historical manual/earned/taskPause ownership. It
then recovers a clear and proves the matching `.limit` is removed while the
three other sources persist, durable readback succeeds, and only then are the
clear receipt and confirmation recorded. The negative test leaves an
unattributed `.limit` record in durable storage and proves recovery retains
pending work, writes no receipt, and sends no confirmation.

### Focused Verification

The full focused command reran every Task 14 suite from Round 2 plus affected
lock/source suites:

```bash
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild test CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath /tmp/EvlinTask14Round3 -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' \
  -only-testing:'Evlin iOSTests/AppLimitCallbackNoEffectsTests' \
  -only-testing:'Evlin iOSTests/LimitShieldLogicTests' \
  -only-testing:'Evlin iOSTests/ShieldSourceSetTests' \
  -only-testing:'Evlin iOSTests/AppLimitMeasurementTests' \
  -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests' \
  -only-testing:'Evlin iOSTests/CommandPollerTests' \
  -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests' \
  -only-testing:'Evlin iOSTests/ActionExecutorLimitTests' \
  -only-testing:'Evlin iOSTests/AppLimitCallbackValidatorTests' \
  -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests' \
  -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests' \
  -only-testing:'Evlin iOSTests/ActiveLockStoreLimitReconcileTests' \
  -only-testing:'Evlin iOSTests/ShieldRecordSourceMigrationTests'
```

Result: `TEST SUCCEEDED`, 188/188 with zero failures. Counts: Action Executor
22, App Limit Effect Journal 19, callback no-effects 5, callback validator 5,
command coordinator 12, epoch store 23, measurement 9, wake recovery 11,
command poller 16, limit shield logic 19, metering target membership 13,
lock-store reconcile 8, shield-record source migration 7, and shield source
set 19. Log: `/tmp/task14-round3-focused-green.log`.

### Changed Paths And Self-Review

The Round 3 implementation commit changed only:

1. `Evlin iOS/Models/ShieldRecord.swift`
2. `Evlin iOS/Services/ActiveLockStore.swift`
3. `Evlin iOS/Services/AppLimitEffectJournal.swift`
4. `Evlin iOS/Services/LimitShieldLogic.swift`
5. `Evlin iOS/Services/ShieldSourceLogic.swift`
6. `Evlin iOSTests/ActionExecutorLimitTests.swift`

`ShieldRecord.limitRuleIDs` is durable per-limit provenance. Direct set and
callback application union this identity with existing same-key source owners;
verified recovery clear matches the target rule ID, strips only that limit
stake, rereads the persisted dictionary, and throws if a target/unattributed
limit remains. The existing `ActiveLockPersistenceLock`, failure behavior,
receipt readback, and NSE persist-only boundary remain unchanged.

Residual concern: unsigned simulator runs continue to emit existing App Group
and ManagedSettings diagnostics. They did not affect the selected tests; no
push, deployment, TestFlight, Render, production database, worktree, or nested
agent was used.
