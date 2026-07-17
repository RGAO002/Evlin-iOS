# Metering Epoch Phase 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task-by-task in the existing main workspaces. Use `superpowers:test-driven-development` for every behavior change and `superpowers:verification-before-completion` before every commit and completion claim.

**Status:** READY AS A PLAN; EXECUTION BLOCKED until the Phase 3 prerequisite gate below passes. Phase 4 implementation is NOT STARTED. The DEBUG one-minute physical-device gate is explicitly **PENDING**.

**Goal:** Carry each app-limit rule's monotonic `ordering_token` from the backend through poll, NSE, and wake recovery; converge those delivery paths through one atomic newest-wins transaction; persist clear tombstones and per-rule provenance; and accept DeviceActivity callbacks only when both provenance and physical time are trustworthy.

**Architecture:** The App Group contains one atomic `AppLimitEpochStore` guarded by Phase 3's `ActiveLockPersistenceLock`. Every set/clear delivery first enters `AppLimitCommandCoordinator.ingest` in that transaction. The store retains each rule's highest token independently of active-rule presence, writes clear tombstones, records durable owner work, and treats equal-token duplicates as acknowledgable no-ops. Poll, NSE, and wake use the same coordinator; under the fixed conservative capability branch, NSE may persist desired state and a pending acknowledgement but may never own `DeviceActivityCenter` or claim enforcement. App/DAM side effects are claim-do-recheck operations: the final store transaction must still match rule token, arm identity, provenance, and effect lease before a usage sample, shield, notification, schedule mutation, or applied receipt becomes visible.

**Tech Stack:** Swift language mode 5.0, XCTest, DeviceActivity, FamilyControls, ManagedSettings, CryptoKit, App Group atomic persistence and `flock`, URLSession, FastAPI, Pydantic, SQLAlchemy, PostgreSQL, pytest via the repository Python entry points, Xcode 26.3/iPhoneOS 26.2 SDK, iOS 26.3.1 simulator runtime, deployment target iOS/iPadOS 17.6.

## Authoring Boundary

This plan's authoring commit must add only this file:

```text
/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/plans/2026-07-17-metering-epoch-phase-4.md
```

Do not edit production code, the Phase 3 plan, the design, `/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md`, any existing dirty file, or any untracked file while authoring this plan. Do not create a worktree.

## Global Execution Constraints

- Execute only in `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS` and `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend`, in their existing main workspaces. Do not create or switch to a worktree.
- Preserve every pre-existing dirty or untracked file. If a task declares a file that is already dirty at task start, stop before editing it; record the collision and ask the owner to resolve it. Do not use `git stash`, `git checkout --`, `git restore`, `git reset`, or broad `git add -A`/`git add .`.
- One task equals one independently green commit in the repository named by that task. Never amend, squash, combine, or opportunistically include another task's files.
- Write the named RED test first and run it. A compile error caused only by a deliberately missing new type is an acceptable first RED; unrelated compile or fixture failures are blockers, not RED evidence.
- Implement only the minimum behavior named in the task, run focused GREEN, run the task regression set, inspect the complete staged diff, and commit with the exact subject.
- Pure backend tests use `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest`. Any DB-backed test uses `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/run_limits_db_regression.py`; never invoke bare `pytest` and never point `DATABASE_URL` at a non-local host.
- Every iOS simulator test uses a literal installed destination: `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1` or `platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1`. Device builds use the concrete `generic/platform=iOS` destination.
- Every iOS build/test command sets `IPHONEOS_DEPLOYMENT_TARGET=17.6` and `TARGETED_DEVICE_FAMILY='1,2'`; do not change `SWIFT_VERSION=5.0`.
- Do not push, deploy, invoke Render, upload to TestFlight, alter a production database, use production APNs credentials, or run a migration against any shared database.
- Automated gates run before the DEBUG physical probe is prepared. Simulator success is not physical evidence. Keep physical rows `PENDING` until artifacts from the named device run exist.
- Phase 4 does not close Phase 5 G18. Persisting an NSE command and waking the owner is not force-kill enforcement, and UI/readback must not say that it is.

## Immutable Baseline

Before Task 1, capture state without staging or changing files:

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git status --short --branch)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git status --short --branch)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git rev-parse HEAD)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git rev-parse HEAD)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --binary | shasum -a 256)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git diff --binary | shasum -a 256)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git ls-files --others --exclude-standard -z | shasum -a 256)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git ls-files --others --exclude-standard -z | shasum -a 256)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && shasum -a 256 /Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md)
```

Save the command output in Task 1's preflight report. Re-run the status and dirty-diff hashes before each commit. A new path outside that task's allowlist is a hard stop.

## Phase 3 Hard Prerequisite

Phase 4 may be planned now but must not be implemented on the currently observed Phase 3 state: its planned runtime files and completion evidence are not yet present. The Phase 3 plan's own review status is not an execution gate and is never required to become `PASS`. Phase 3's legal handoff is its Task 30 completion report with automated evidence passed, physical evidence pending, and `releasable: false`, bound to its commit by Task 29 final-mode attestation. A fresh agent must make the hard completion/evidence and behavioral gates pass before writing Task 1's RED test.

### Hard Completion/Evidence Gate

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -s 'docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -q 'AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE' 'docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -q 'releasable:[[:space:]]*false' 'docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -s '.superpowers/evidence/metering-phase3/report-commit-attestation.json')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -f 'scripts/verify_metering_phase3_completion.sh')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && REPORT_PATH='docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md'; REPORT_COMMIT="$(git log --format='%H%x09%s' -- "$REPORT_PATH" | awk -F '\t' '$2 == "docs: record metering phase 3 evidence" { print $1 }')"; test "$(printf '%s\n' "$REPORT_COMMIT" | rg -c '^[0-9a-f]{40}$')" -eq 1; test "$(git diff-tree --no-commit-id --name-only -r "$REPORT_COMMIT")" = "$REPORT_PATH"; REPORT_GIT_BLOB="$(git rev-parse "$REPORT_COMMIT:$REPORT_PATH")"; REPORT_SHA256="$(git show "$REPORT_COMMIT:$REPORT_PATH" | shasum -a 256 | awk '{ print $1 }')"; jq -e --arg commit "$REPORT_COMMIT" --arg git_blob "$REPORT_GIT_BLOB" --arg sha256 "$REPORT_SHA256" '([.. | strings] | index($commit)) != null and ((([.. | strings] | index($git_blob)) != null) or (([.. | strings] | index($sha256)) != null))' '.superpowers/evidence/metering-phase3/report-commit-attestation.json' >/dev/null)
```

### Capability Inventory

Run every probe below and paste its output/exit status into Task 1's preflight report. The current Phase 3 plan pins these exact paths and spellings, so they are the expected result. If a probe misses but the hard completion and behavioral gates pass, locate the final equivalent and use the adjustment matrix below. A path/name/initializer-only difference is recordable; a missing capability or semantic difference blocks Phase 4 and requires a plan revision.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -f 'Evlin iOS/Services/MeteringRuntimeInfrastructure.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -f 'Evlin iOS/Services/MeteringDeviceActivityCenter.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -f 'Evlin iOS/Services/DeviceEpochStore.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -f 'Evlin iOS/Services/EarnedMeteringCallback.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -f 'Evlin iOS/Services/EarnedShieldEffectStore.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -f 'Evlin iOS/Services/MeteringProductionComposition.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -f 'Evlin iOS/Services/MeteringProcessEntries.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -f 'Evlin iOSTests/MeteringProductionIntegrationTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && test -f 'Evlin iOSTests/MeteringPhase3CompletionVerifierTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -U -q 'func transaction<Value>\([[:space:]]*expectedOwner:[[:space:]]*UUID\?' 'Evlin iOS/Services/DeviceEpochStore.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -q 'protocol MeteringDeviceActivityCenter' 'Evlin iOS/Services/MeteringDeviceActivityCenter.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -q 'enum MeteringRuntimeClock' 'Evlin iOS/Services/MeteringRuntimeInfrastructure.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -q 'enum MeteringProcessRole' 'Evlin iOS/Services/MeteringRuntimeInfrastructure.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -q 'enum MeteringProductionComposition' 'Evlin iOS/Services/MeteringProductionComposition.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -q 'final class AppMeteringEntry' 'Evlin iOS/Services/MeteringProcessEntries.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -q 'final class DAMMeteringEntry' 'Evlin iOS/Services/MeteringProcessEntries.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -q 'includesPastActivity: false' 'Evlin iOS/Services/EarnedBudgetScheduler.swift')
```

### Hard Behavioral Gate

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && rg -q 'NSE may persist the newest policy, rule, or tombstone and wake state' docs/superpowers/research/2026-07-15-metering-monitor-capability-results.md)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/MeteringProductionIntegrationTests' -only-testing:'Evlin iOSTests/MeteringPhase3CompletionVerifierTests')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_epoch_registration.py tests/test_metering_epoch_phase2_integration.py)
```

The capability branch is fixed by the iPad K-mode result: NSE is persistence-only; app/DAM own monitor installation. A later iPhone success does not broaden NSE ownership without a separately reviewed physical iPad result and a design revision.

### Required Phase 3 Capabilities

| Capability consumed by Phase 4 | Expected Phase 3 interface | Detection | If final interface differs |
|---|---|---|---|
| Cross-process lock | `ActiveLockPersistenceLock` | Compile a store transaction test in app, DAM, and Push | Rename the dependency adapter only; do not introduce a second lock. Record the final symbol in the preflight report. |
| Atomic App Group state | `DeviceEpochStore.transaction(expectedOwner:)` plus atomic write/readback | Phase 3 crash/readback tests green | Prefer an `appLimits` substate in the final store if it supports Push writes. Otherwise create `AppLimitEpochStore` over the same lock and atomic-file helper; never use UserDefaults as authority. |
| Process roles | `MeteringProcessRole.app` and `.deviceActivityMonitor` | Compile Phase 3 process-entry tests | Add an app-limit-only `.notificationServicePersistence` role or source enum; do not grant it monitor-owner capability. |
| DeviceActivity adapter | `MeteringDeviceActivityCenter` | Compile planner fake and live adapter | Adapt names/signatures at one composition boundary. Keep `startMonitoring` unavailable to Push. |
| Clock | `MeteringClock`/`MeteringRuntimeClock.live` | Phase 3 clock tests green | Inject the final clock into planner, trust validator, store leases, and DEBUG probe. No direct `Date()` in pure logic. |
| Physical predicate | Phase 3 elapsed-time predicate using 30-second jitter | Earned immediate/late callback vectors green | Extract a shared pure helper without changing earned semantics. Default stays 30 seconds; 60 requires physical evidence and design approval. |
| Shield persistence | Phase 3 durable effect/readback helper | Phase 3 shield recovery tests green | Reuse its claim/receipt primitive. Do not add a second receipt file or bypass `ActiveLockPersistenceLock`. |
| Production entry hooks | `AppMeteringEntry`/`DAMMeteringEntry`; Push persist-only hook | Phase 3 process-entry tests green | Update only composition adapters and target membership. Preserve ownership behavior. |
| Backend migration head | Final Phase 3 Alembic head | Local regression runner green | Phase 4 adds no migration. If a migration becomes necessary, stop and revise this plan before code. |

If a final Phase 3 difference changes semantics rather than only a name, file location, initializer, or adapter signature, stop. Add an explicit plan revision and obtain review; do not improvise a second state path.

### Mechanical Cross-Phase Manifest

This manifest is mechanically cross-checked against the current Phase 3 plan. Task 1 records the final implemented spelling; it does not weaken the expected capability.

| Phase 3 producer | Exact consumed artifact | Phase 4 use/adjustment point |
|---|---|---|
| Task 2 | `MeteringRuntimeInfrastructure.swift`: `MeteringRuntimeClock`, `MeteringProcessRole`; `MeteringDeviceActivityCenter.swift`: `MeteringDeviceActivityCenter` | Inject the final clock/center names into Tasks 12-15. If only initializer labels differ, isolate the change in composition. Push still receives no center. |
| Task 5 | `DeviceEpochStore.swift`: `transaction<Value>(expectedOwner: UUID?, _:)` under `ActiveLockPersistenceLock` | Task 6 either adds an `appLimits` substate or reuses the exact lock/file helper. Do not assume `expectedOwner` is a process role and do not add a second lock. |
| Tasks 8/14 | `EarnedShieldEffectStore.swift` and its durable claim/readback behavior | Task 14 reuses its lock/CAS primitive or extracts a neutral helper. It must not create an independent shield authority. |
| Task 12 | `EarnedMeteringCallback.swift`: 30-second default/60-second maximum physical trust | Task 13 extracts a shared pure predicate while preserving all earned vectors. If no helper symbol exists, extraction is the adjustment; constants and semantics do not change. |
| Task 18 | `MeteringProductionComposition.swift`; `MeteringProductionIntegrationTests.swift` | Tasks 10-11 add app-limit adapters without replacing earned production factories. Use this exact production integration test; do not invent an alias. |
| Task 21 | `MeteringProcessEntries.swift`: `AppMeteringEntry`, `DAMMeteringEntry`; Push persist-only hook | Task 11 hooks app-limit recovery into the final entries. If method names differ, adapt calls only; ownership remains app/DAM. |
| Task 29 | `scripts/verify_metering_phase3_completion.sh`; `MeteringPhase3CompletionVerifierTests.swift`; final attestation path `.superpowers/evidence/metering-phase3/report-commit-attestation.json` | Hard prerequisite verifies the attested Task 30 report commit/blob. It never tests the Phase 3 plan review status. |
| Task 30 | `docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md` | Hard prerequisite requires `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE` and `releasable: false`. Physical pending is a valid dependency state, not a failure. |

## Pinned Phase 4 Contracts

These contracts are normative unless Task 1 records a Phase 3 naming-only adaptation.

```swift
nonisolated enum AppLimitCommandSource: String, Codable, Sendable {
    case poll
    case notificationServiceExtension
    case wakeRecovery
}

nonisolated enum AppLimitCommandKind: String, Codable, Sendable {
    case set
    case clear
}

nonisolated struct AppLimitCommandEnvelope: Codable, Equatable, Sendable {
    let commandID: UUID
    let ruleID: UUID
    let orderingToken: Int64
    let kind: AppLimitCommandKind
    let payloadDigest: String
    let receivedAt: Date
    let source: AppLimitCommandSource
    let rule: AppLimitRule?
}

nonisolated enum AppLimitCommandDisposition: Equatable, Sendable {
    case acceptedNeedsOwner
    case duplicatePending
    case duplicateApplied(AppLimitApplyReceipt)
    case superseded(latestOrderingToken: Int64)
    case equalTokenConflict
}

nonisolated struct AppLimitApplyReceipt: Codable, Equatable, Sendable {
    let ruleID: UUID
    let orderingToken: Int64
    let commandKind: AppLimitCommandKind
    let armID: UUID?
    let source: String
    let appliedAt: Date
    let storeRevision: UInt64
}
```

`orderingToken` is required and positive on new set and clear commands. Decode backend JSON integers losslessly into `Int64`; do not pass through `Double`. `payloadDigest` is SHA-256 over canonical command fields and exact token bytes, not display text. An equal token with an unequal digest is corrupt input and fails closed with zero mutation.

The persisted per-rule slot is independent of whether a rule is active:

```swift
nonisolated struct AppLimitVersionSlot: Codable, Equatable, Sendable {
    let ruleID: UUID
    var latestOrderingToken: Int64
    var latestKind: AppLimitCommandKind
    var latestPayloadDigest: String
    var activeRule: AppLimitRule?
    var clearTombstone: AppLimitClearTombstone?
    var pendingOwnerWork: AppLimitOwnerWork?
    var appliedReceipt: AppLimitApplyReceipt?
}
```

One transaction must compare the token, update the slot, write/clear active rule state, write a tombstone for clear, invalidate lower-token work and receipts, and enqueue the new durable owner work. No caller may write an `AppLimitRuleStore` row and then separately write its token. Synchronous local monitor/shield mutations run while holding the same `ActiveLockPersistenceLock` critical section after the final current-token check and before receipt commit; a newer clear therefore either runs first and rejects the old set, or runs second and removes its effects before releasing the lock. Async network work runs outside the file lock, carries `ordering_token`, and is rejected by the backend if stale; its local result is committed only after a fresh token/arm recheck.

Each armed rule/day/window stores the design's exact provenance:

```text
ruleID, ruleRevision (= orderingToken), childDeviceID, usageDate, timezone,
scheduleWindow, tokenDigest, budgetMinutes, startedAt, baseAcceptedMinutes,
lastRawThresholdMinutes, ignoredWhilePausedMinutes, activityName, armID
```

The stable replacement key is:

```text
ruleID + ruleRevision + childDeviceID + usageDate + timezone +
scheduleWindow + tokenDigest + budgetMinutes
```

`startedAt`, accepted usage, raw threshold progress, ignored paused usage, callbacks, effect work, and receipts are progress, not identity. They must never cause re-arming. An intentional pause-resume replacement creates a new `armID`, carries a conservative accepted base, resets the raw DeviceActivity counter with `includesPastActivity=false`, and records its predecessor.

For callback time trust:

```text
adjustedEstimate = baseAcceptedMinutes + max(0, rawThresholdMinutes - ignoredWhilePausedMinutes)
deltaMinutes = adjustedEstimate - baseAcceptedMinutes
activeElapsedSeconds = observedAt - startedAt - pausedSecondsWithinArm
trusted iff deltaMinutes >= 0
        and deltaMinutes * 60 <= activeElapsedSeconds + jitterSeconds
```

Default `jitterSeconds` is 30. There is no minimum-age/freshness rejection: a delayed but physically possible callback is valid. A callback while paused may update only the ignored raw high-water mark in the same store transaction; it may not mutate accepted usage, retry/network state, backend rows, shields, notifications, schedules, or applied receipts.

### Ack Mapping

| Disposition | NSE ack | App owner poll/wake ack | Mutation after ingest |
|---|---|---|---|
| `acceptedNeedsOwner` | `pending`, detail says `persisted_waiting_for_owner` | Confirm only after owner receipt is durably read back | Owner work only |
| `duplicatePending` | `pending` | Resume existing work; do not enqueue/re-arm again | None |
| `duplicateApplied` | `confirmed` with existing receipt | `confirmed` with existing receipt | None |
| `superseded` | `confirmed`, detail says `superseded_by_token` | Same | None |
| `equalTokenConflict` | `failed` | `failed` | None; retain prior state |

Posting a `pending` ack sets `acked_at` and stops alert escalation while the command remains pollable because its `ack_status` remains pending. The later app-owner confirmation must reference the same command ID and persisted receipt.

## Target Membership

| Source | App | DAM | Push | Tests |
|---|---:|---:|---:|---:|
| `AppLimitEpochTypes.swift` | yes | yes | yes | via app |
| `AppLimitEpochStore.swift` | yes | yes | yes | via app |
| `AppLimitCommandCoordinator.swift` | yes | yes | yes | via app |
| `AppLimitProvenance.swift` | yes | yes | no | via app |
| `AppLimitEffectJournal.swift` | yes | yes | no | via app |
| `AppLimitProductionComposition.swift` | yes | yes | yes, persistence adapter only | via app |

Push target code must not import or instantiate `DeviceActivityCenter`, `MeteringDeviceActivityCenter`, `ManagedSettingsStore`, `AppLimitPlanner`, or the effect driver. Add explicit project membership exceptions and a source scan test.

## Golden Vectors

Both fixtures must contain these exact IDs and the same canonical inputs/expected outputs:

| ID | Required result |
|---|---|
| `P4V01` | Newer set is accepted and persists active rule plus owner work. |
| `P4V02` | Older set is superseded before rule, schedule, usage, shield, notification, or network mutation. |
| `P4V03` | Newer clear removes active rule and writes the latest tombstone atomically. |
| `P4V04` | Old set arriving after clear cannot remove tombstone or resurrect the rule. |
| `P4V05` | Equal applied set acks from existing receipt with no re-arm or duplicate effect. |
| `P4V06` | Equal applied clear acks from existing receipt with no mutation. |
| `P4V07` | Equal NSE-persisted command remains pending and owner recovery uses the single existing work item. |
| `P4V08` | Equal token plus unequal digest fails closed with no mutation. |
| `P4V09` | Poll/NSE/wake permutations converge to identical persisted bytes and receipt. |
| `P4V10` | Progress changes do not change replacement key, activity name, event name, or arm ID. |
| `P4V11` | Enforcement and measurement events both encode `includesPastActivity=false`. |
| `P4V12` | Immediate full-budget callback is physically impossible and has zero side effects. |
| `P4V13` | Delayed physically possible callback is accepted exactly once. |
| `P4V14` | Late but possible callback is accepted; no lower-bound age gate exists. |
| `P4V15` | Callback while paused updates ignored high-water only and has zero external effects. |
| `P4V16` | Resume creates a fresh arm with conservative base and no overcharge. |
| `P4V17` | Restart during pause/resume preserves ignored usage and does not overcharge. |
| `P4V18` | Applied source and receipt match current token/arm before UI/readback says enforced. |
| `P4V19` | Wrong rule/activity/event/day/token provenance rejects before every side effect. |
| `P4V20` | Per-app exhaustion affects only that app; device-total ledger and unrelated apps do not change. |

Every callback vector asserts the complete side-effect tuple: local accepted estimate, retry queue, network request, backend sample row, backend ledger, notification, shield source, schedule arm/stop, command work/tombstone, and applied receipt.

## Exact Commit Order

```text
01 test: register metering phase 4 safety states
02 test: add metering phase 4 backend vectors
03 feat: deliver app limit commands to nse
04 fix: reject stale app limit usage samples
05 feat: decode app limit ordering tokens everywhere
06 feat: persist app limit versions and tombstones
07 test: mirror metering phase 4 vectors in swift
08 feat: arbitrate app limit commands transactionally
09 feat: route polled app limits through epoch store
10 feat: persist nse app limits for owner recovery
11 feat: recover pending app limits on wake
12 feat: arm stable per-rule app limit epochs
13 fix: validate app limit callback physical time
14 feat: journal app limit effects with receipts
15 fix: resume app limits conservatively
16 test: prove app limit reordering convergence
17 test: add metering phase 4 automated gate
18 test: prepare phase 4 physical gate
```

---

## Task 1: Register Phase 4 Safety State and Freeze Phase 3 Capabilities

**Repository:** iOS.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-phase4-preflight.md`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase4SafetyRegistrationTests.swift`

**Interfaces:** The report records Phase 3 SHAs, dirty hashes, final symbol/file mapping, conservative capability branch, and R-16 registration for `AppLimitVersionSlot`, clear tombstone, pending owner work, effect lease, paused raw high-water, and applied receipt. For each state it names the replaced legacy state, why it is net-new if none, deletion criterion, and vector IDs.

**RED:** Add a test that reads the report and requires all six state names, `NSE=persist-only`, all `P4V01...P4V20`, and the two repository SHAs. Run it before creating the report; expected failure is `NSCocoaErrorDomain Code=260` for the missing report, not an unrelated compile failure.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase4SafetyRegistrationTests')
```

**Minimal GREEN:** Create the report from observed outputs. Resolve every row in the Phase 3 adjustment matrix. A naming-only change is allowed; any ownership, trust, durability, or transaction semantic difference blocks the task and requires a plan revision.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase4SafetyRegistrationTests' -only-testing:'Evlin iOSTests/MeteringProductionIntegrationTests' -only-testing:'Evlin iOSTests/MeteringPhase3CompletionVerifierTests')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'docs/superpowers/reports/2026-07-17-metering-phase4-preflight.md' 'Evlin iOSTests/MeteringPhase4SafetyRegistrationTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'test: register metering phase 4 safety states')
```

The staged name list must contain exactly the two declared files.

## Task 2: Add Backend Phase 4 Golden Vectors

**Repository:** Backend.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_epoch_contract.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_vector_contract.py`

**Interfaces:** Add pure canonical types for command disposition, per-rule slot, provenance, physical-time decision, and the complete side-effect tuple. JSON integers remain integers. Canonical store bytes sort rule IDs and work IDs.

**RED:** First add tests requiring exact ID set `P4V01...P4V20`, unique IDs, complete side-effect fields, and pure evaluator output. Expected failure is missing IDs/evaluator support.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest tests/test_metering_epoch_vector_contract.py -q)
```

**Minimal GREEN:** Add the 20 fixture cases and only enough pure contract logic to evaluate them. Do not change a route, ORM model, or database schema.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest tests/test_metering_epoch_vector_contract.py tests/test_app_limit_wire_contract.py tests/test_app_limit_delivery.py -q)
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git add -- 'tests/fixtures/metering_epoch_vectors.json' 'app/services/metering_epoch_contract.py' 'tests/test_metering_epoch_vector_contract.py')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git commit -m 'test: add metering phase 4 backend vectors')
```

The staged name list must contain exactly the three declared files.

## Task 3: Deliver Tokened App-Limit Commands to NSE

**Repository:** Backend.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/app_control_delivery.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/app_control_execution.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_app_limit_delivery.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/services/test_lock_command_alert_payload.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_command_delivery_apns.py`

**Interfaces:** Add `set_limit` and `clear_limit` to the alert delivery action set so APNs can invoke NSE. Preserve each nested payload byte-for-byte, including positive `ordering_token`. Alert copy says a limit is being updated/cleared; it must not claim enforcement. Existing silent wake remains.

**RED:** Replace the old assertions that set/clear are excluded. Assert immediate alert plus silent wake, mutable-content command ID, nested token preservation, and that a later `pending` ack prevents escalation resend while leaving the command pollable. Expected failure is action exclusion or missing alert.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest tests/test_app_limit_delivery.py tests/services/test_lock_command_alert_payload.py tests/test_command_delivery_apns.py -q)
```

**Minimal GREEN:** Expand delivery filtering/copy only. Do not change command ordering generation, polling projection, or acknowledgement endpoint semantics.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest tests/test_app_limit_delivery.py tests/services/test_lock_command_alert_payload.py tests/test_command_delivery_apns.py tests/test_lock_command_shape.py -q)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/run_limits_db_regression.py tests/api/test_command_scoped_fetch.py tests/api/test_app_limits_endpoint.py)
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git add -- 'app/services/app_control_delivery.py' 'app/services/app_control_execution.py' 'tests/test_app_limit_delivery.py' 'tests/services/test_lock_command_alert_payload.py' 'tests/test_command_delivery_apns.py')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git commit -m 'feat: deliver app limit commands to nse')
```

The staged name list must contain exactly the five declared files.

## Task 4: Reject Stale Per-App Usage Before Persistence

**Repository:** Backend.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/child_device.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_app_limit_usage.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/api/test_app_limits_endpoint.py`

**Interfaces:** `AppLimitUsageSampleRequest` requires positive `ordering_token`. `AppLimitUsageSnapshot` adds `accepted`, `current_ordering_token`, and nullable `reason`. Under the existing per-device DB lock, only equality with the rule's current token may reach gate evaluation or `ingest_usage_sample`; stale/future mismatches return HTTP 200 with `accepted=false`, current used minutes, and no row/ledger mutation so clients do not retry obsolete work.

**RED:** Add DB tests for equal accepted, older rejected, future rejected, clear race rejected, and no usage row/ledger change. Both test files are already real entries in the local regression runner; do not edit the runner. Expected failure is request validation/old sample insertion.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/run_limits_db_regression.py tests/test_app_limit_usage.py tests/api/test_app_limits_endpoint.py)
```

**Minimal GREEN:** Add request/response fields and compare under the existing device lock before `usage_counting_allowed` and before any sample write. Add no migration and no new table.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/run_limits_db_regression.py)
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git add -- 'app/api/routes/child_device.py' 'tests/test_app_limit_usage.py' 'tests/api/test_app_limits_endpoint.py')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git commit -m 'fix: reject stale app limit usage samples')
```

The staged name list must contain exactly the three declared files.

## Task 5: Decode `ordering_token` in Poll and NSE Models

**Repository:** iOS.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/CommandModels.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/APIClient.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/NSECommandWireModels.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/Fixtures/app_limit_wire.json`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitWireContractTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitRuleDTOTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/CommandPollerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/NSEUnshieldTests.swift`

**Interfaces:** `LimitRule`, `ClearLimit`, `PollLimitDTO`, `PollClearDTO`, and their NSE mirrors expose required `orderingToken: Int64` with `ordering_token` coding keys. Missing, zero, negative, fractional, or overflowing values reject the command; they never default to zero.

**RED:** Add shared wire examples for set and clear at token `9_007_199_254_740_993` to prove no JavaScript/Double truncation. Assert poll and NSE create identical command envelopes. Expected failure is missing coding key/property.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitWireContractTests' -only-testing:'Evlin iOSTests/AppLimitRuleDTOTests' -only-testing:'Evlin iOSTests/CommandPollerTests' -only-testing:'Evlin iOSTests/NSEUnshieldTests')
```

**Minimal GREEN:** Add only required integer fields/coding keys and validation. Do not persist or apply commands yet.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitWireContractTests' -only-testing:'Evlin iOSTests/AppLimitRuleDTOTests' -only-testing:'Evlin iOSTests/CommandPollerTests' -only-testing:'Evlin iOSTests/NSEUnshieldTests' -only-testing:'Evlin iOSTests/ActionExecutorLimitTests')
```

**Commit:** If any declared file is dirty, stop; do not edit or partially stage it.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Models/CommandModels.swift' 'Evlin iOS/Services/APIClient.swift' 'Evlin iOS/Models/NSECommandWireModels.swift' 'Evlin iOSTests/Fixtures/app_limit_wire.json' 'Evlin iOSTests/AppLimitWireContractTests.swift' 'Evlin iOSTests/AppLimitRuleDTOTests.swift' 'Evlin iOSTests/CommandPollerTests.swift' 'Evlin iOSTests/NSEUnshieldTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'feat: decode app limit ordering tokens everywhere')
```

The staged name list must contain exactly the eight declared files.

## Task 6: Persist Per-Rule Versions, Tombstones, and Owner Work

**Repository:** iOS.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitEpochTypes.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitRuleStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitEpochStoreTests.swift`

**Interfaces:** Implement schema-versioned atomic state with `transaction(source:expectedOwner:_:)`, monotonically increasing `storeRevision`, sorted canonical encoding, atomic temp-write/fsync/rename/readback, and `ActiveLockPersistenceLock`. `AppLimitRuleStore` becomes a compatibility facade over active slots; migrate its old UserDefaults bytes exactly once while preserving a digest/audit marker. Never delete `latestOrderingToken` when the active rule clears.

**RED:** Tests cover empty state, restart, corrupt-file quarantine, interrupted write, concurrent app/NSE writers, clear tombstone survival, lower-token rejection after restart, deterministic bytes, and one-time legacy migration. Expected failure is missing types/store.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests')
```

**Minimal GREEN:** Reuse Phase 3 lock/atomic helpers. Persist only state and work descriptions; do not schedule, shield, notify, or send network requests in the store.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests' -only-testing:'Evlin iOSTests/AppLimitRuleStoreTests' -only-testing:'Evlin iOSTests/ActiveLockStoreLimitReconcileTests')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'EvlinDeviceActivityMonitor' -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'EvlinPushApplier' -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Services/AppLimitEpochTypes.swift' 'Evlin iOS/Services/AppLimitEpochStore.swift' 'Evlin iOS/Services/AppLimitRuleStore.swift' 'Evlin iOS.xcodeproj/project.pbxproj' 'Evlin iOSTests/AppLimitEpochStoreTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'feat: persist app limit versions and tombstones')
```

The staged name list must contain exactly the five declared files. Confirm the project diff changes only target membership for the two new shared files.

## Task 7: Mirror Phase 4 Vectors in Swift

**Repository:** iOS.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/Fixtures/metering_epoch_vectors.json`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochVectorCoverageTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochGoldenVectorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochContract.swift`

**Interfaces:** Swift decodes all 20 backend vectors and produces the same disposition, store bytes, provenance decision, physical decision, and side-effect tuple. Keep the fixture byte-identical across repositories.

**RED:** Copy only the fixture first and require all Phase 4 IDs; expected failure is missing Swift decoding/evaluator cases.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests')
```

**Minimal GREEN:** Extend only pure contract decoding/evaluation. Production command routing still waits for Task 8.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && cmp 'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/MeteringEpochContractTests')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' 'Evlin iOSTests/MeteringEpochVectorCoverageTests.swift' 'Evlin iOSTests/MeteringEpochGoldenVectorTests.swift' 'Evlin iOS/Services/MeteringEpochContract.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'test: mirror metering phase 4 vectors in swift')
```

The staged name list must contain exactly the four declared files.

## Task 8: Arbitrate Commands in One Transaction

**Repository:** iOS.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitCommandCoordinator.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitEpochTypes.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitCommandCoordinatorTests.swift`

**Interfaces:** Implement `ingest(_:) -> AppLimitCommandDisposition` as one `AppLimitEpochStore.transaction`. Newer set/clear updates slot/work/tombstone atomically. Lower token and equal same-digest commands are no-ops. Equal conflicting digest fails closed. The coordinator returns an ack decision but performs no external side effect.

**RED:** Add tests for P4V01-P4V08, all six order permutations of old set/new clear/equal clear, restart between messages, and byte-for-byte no mutation on stale/equal. Expected failure is missing coordinator.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests')
```

**Minimal GREEN:** Add the pure transaction coordinator. Do not call planner, ManagedSettings, URLSession, notification APIs, or ack networking.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests' -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Services/AppLimitCommandCoordinator.swift' 'Evlin iOS/Services/AppLimitEpochTypes.swift' 'Evlin iOS.xcodeproj/project.pbxproj' 'Evlin iOSTests/AppLimitCommandCoordinatorTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'feat: arbitrate app limit commands transactionally')
```

The staged name list must contain exactly the four declared files.

## Task 9: Route Poll Through the Coordinator

**Repository:** iOS.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/CommandPoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/ActionExecutor.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/CommandPollerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/ActionExecutorLimitTests.swift`

**Interfaces:** Poll constructs the canonical envelope and calls the coordinator before any old rule/shield/planner path. `ActionExecutor` set/clear becomes an owner-work adapter; it may not directly `upsert/remove` the compatibility store. Ack mapping follows the table above and includes token, disposition, and receipt revision.

**RED:** Add poll tests for newer set, clear then delayed old set, equal applied set, equal pending set, conflicting equal token, and exact ack body. Assert planner/store/shield spies stay at zero for stale/equal. Expected failure is direct ActionExecutor mutation.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/CommandPollerTests' -only-testing:'Evlin iOSTests/ActionExecutorLimitTests')
```

**Minimal GREEN:** Inject the coordinator and ack mapper. Keep non-limit command behavior byte-for-byte unchanged.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/CommandPollerTests' -only-testing:'Evlin iOSTests/ActionExecutorLimitTests' -only-testing:'Evlin iOSTests/ActionExecutorTests' -only-testing:'Evlin iOSTests/CommandPollerEffectiveStateTests')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Services/CommandPoller.swift' 'Evlin iOS/Services/ActionExecutor.swift' 'Evlin iOSTests/CommandPollerTests.swift' 'Evlin iOSTests/ActionExecutorLimitTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'feat: route polled app limits through epoch store')
```

The staged name list must contain exactly the four declared files.

## Task 10: Make NSE Persist-Only and Ack Pending

**Repository:** iOS.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinPushApplier/NotificationService.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/NSECommandWireModels.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitProductionComposition.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/NSEAppLimitPersistenceTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/NSEUnshieldTests.swift`

**Interfaces:** NSE scoped-fetch decodes set/clear, calls the same coordinator with source `.notificationServiceExtension`, posts `pending` for accepted/duplicate-pending, and posts confirmed for stale/duplicate-applied. It then requests an app wake. Its composition exposes no center/planner/shield/effect capability.

**RED:** Test set, clear, stale, equal pending, equal applied, fetch failure, ack failure, and expiry. Assert persisted bytes match poll ingest and all monitor/shield spies are absent/zero. Add a source scan rejecting `startMonitoring`, `stopMonitoring`, `DeviceActivityCenter(`, and `ManagedSettingsStore(` from Push-compiled Phase 4 files. Expected failure is current set/clear `nil` handling.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/NSEAppLimitPersistenceTests' -only-testing:'Evlin iOSTests/NSEUnshieldTests')
```

**Minimal GREEN:** Add persistence/ack/wake routing only. Keep the delivered alert truthful: “Updating limit” is allowed; “Limit applied” is forbidden before owner receipt.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/NSEAppLimitPersistenceTests' -only-testing:'Evlin iOSTests/NSEUnshieldTests' -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'EvlinPushApplier' -configuration Release -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && ! rg -n 'startMonitoring|stopMonitoring|DeviceActivityCenter\(|ManagedSettingsStore\(' 'EvlinPushApplier/NotificationService.swift' 'Evlin iOS/Services/AppLimitProductionComposition.swift')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'EvlinPushApplier/NotificationService.swift' 'Evlin iOS/Models/NSECommandWireModels.swift' 'Evlin iOS/Services/AppLimitProductionComposition.swift' 'Evlin iOS.xcodeproj/project.pbxproj' 'Evlin iOSTests/NSEAppLimitPersistenceTests.swift' 'Evlin iOSTests/NSEUnshieldTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'feat: persist nse app limits for owner recovery')
```

The staged name list must contain exactly the six declared files.

## Task 11: Recover Durable Owner Work on Wake

**Repository:** iOS.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitProductionComposition.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringProcessEntries.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Evlin_iOSApp.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/CommandPoller.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitWakeRecoveryTests.swift`

**Interfaces:** Every app launch, foreground, silent remote notification, and poll completion invokes one idempotent owner recovery entry. Recovery claims the single current owner work, never recreates work for an equal token, and confirms pending command IDs only after applied receipt readback. Lower-token work is terminalized as superseded.

**RED:** Simulate NSE set -> app launch, NSE clear -> silent wake, poll/equal while recovering, crash after claim, and clear while old set effect is in flight. Expected failure is no common wake recovery path.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests')
```

**Minimal GREEN:** Wire the entry points to one recovery driver. At this task, planner/effects may remain spies; prove ownership and ack sequencing first.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests' -only-testing:'Evlin iOSTests/CommandPollerTests' -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Services/AppLimitProductionComposition.swift' 'Evlin iOS/Services/MeteringProcessEntries.swift' 'Evlin iOS/Evlin_iOSApp.swift' 'Evlin iOS/Services/CommandPoller.swift' 'Evlin iOSTests/AppLimitWakeRecoveryTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'feat: recover pending app limits on wake')
```

The staged name list must contain exactly the five declared files.

## Task 12: Arm Stable Per-Rule Provenance With No Past Activity

**Repository:** iOS.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitProvenance.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitPlanner.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitEpochTypes.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitPlannerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitMeasurementTests.swift`

**Interfaces:** Derive a stored `armID` once per replacement key. Names encode the opaque arm ID: activity `evlin.limit.v2.<armID>`, enforcement event `evlin.limit.v2.<armID>.budget`, measurement event `evlin.applimit.v2.<armID>.t<N>`. Both event kinds call the iOS 17.4+ initializer with `includesPastActivity: false`. Progress updates preserve identity and do not stop/re-arm windows.

**RED:** Add P4V10/P4V11 tests for identical names across usage progress/restart, changed names only when replacement key changes, exact provenance readback, no progress-triggered center calls, and explicit `includesPastActivity == false` for every event. Expected failure is current window/re-arm identity and implicit initializer.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitPlannerTests' -only-testing:'Evlin iOSTests/AppLimitMeasurementTests')
```

**Minimal GREEN:** Replace planner-generated transient identity with persisted provenance. Do not add callback effects yet.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitPlannerTests' -only-testing:'Evlin iOSTests/AppLimitMeasurementTests' -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'EvlinDeviceActivityMonitor' -configuration Release -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Services/AppLimitProvenance.swift' 'Evlin iOS/Services/AppLimitPlanner.swift' 'Evlin iOS/Services/AppLimitEpochTypes.swift' 'Evlin iOS.xcodeproj/project.pbxproj' 'Evlin iOSTests/AppLimitPlannerTests.swift' 'Evlin iOSTests/AppLimitMeasurementTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'feat: arm stable per-rule app limit epochs')
```

The staged name list must contain exactly the six declared files.

## Task 13: Validate Provenance and Physical Time Before Effects

**Repository:** iOS.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitCallbackValidator.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitCallbackValidatorTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitCallbackNoEffectsTests.swift`

**Interfaces:** Extract/reuse the Phase 3 elapsed-time predicate at default jitter 30 seconds. `AppLimitCallbackValidator` first resolves exact rule/activity/event/day/token/arm provenance, checks gate/pause, then applies the physical formula. Its result is the sole input to effect work. No lower-bound age test is permitted.

**RED:** Add P4V12-P4V15/P4V19/P4V20. Immediate full budget must reject with every side-effect spy at zero; delayed and late physically possible callbacks accept once; wrong provenance rejects; paused callbacks only update ignored high-water. Expected failure is the extension's current direct shield/report path.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitCallbackValidatorTests' -only-testing:'Evlin iOSTests/AppLimitCallbackNoEffectsTests')
```

**Minimal GREEN:** Route DAM callbacks through the pure validator and return before all effects on rejection. Preserve earned callback results exactly while sharing the predicate.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitCallbackValidatorTests' -only-testing:'Evlin iOSTests/AppLimitCallbackNoEffectsTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/EarnedSampleReporterTests')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Services/AppLimitCallbackValidator.swift' 'Evlin iOS/Services/EarnedMeteringCallback.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOS.xcodeproj/project.pbxproj' 'Evlin iOSTests/AppLimitCallbackValidatorTests.swift' 'Evlin iOSTests/AppLimitCallbackNoEffectsTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'fix: validate app limit callback physical time')
```

The staged name list must contain exactly the six declared files.

## Task 14: Journal Effects and Require Applied Readback

**Repository:** iOS.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitEffectJournal.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitUsageReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitProductionComposition.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitEpochTypes.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitEffectJournalTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/LimitShieldLogicTests.swift`

**Interfaces:** Accepted callbacks enqueue durable effect work keyed by rule/token/arm/effect kind. A worker transaction claims one lease. For synchronous local monitor/shield mutation, it keeps `ActiveLockPersistenceLock` held from the final current-token/arm/lease check through mutation and receipt write/readback. For async usage transport, it releases the lock, sends `ordering_token`, then re-enters the store and commits the response only if current slot/token/arm and lease still match; the backend independently rejects stale tokens. Shield records use source `.limit` plus rule/token/arm provenance. UI/ack reads `AppLimitApplyReceipt`; queued work alone is never “applied.”

**RED:** Test crash before/after each boundary, duplicate callback, clear between claim and shield, old set between claim and usage, source readback, receipt readback, stale backend sample response, and per-app isolation. Assert old work cannot commit after a newer clear. Expected failure is current direct local/network/shield mutation.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' -only-testing:'Evlin iOSTests/LimitShieldLogicTests')
```

**Minimal GREEN:** Add the durable claim/recheck journal and adapters. Do not broaden NSE ownership. Do not write device-total or earned ledgers from a per-app callback.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' -only-testing:'Evlin iOSTests/AppLimitCallbackNoEffectsTests' -only-testing:'Evlin iOSTests/LimitShieldLogicTests' -only-testing:'Evlin iOSTests/ShieldSourceSetTests' -only-testing:'Evlin iOSTests/AppLimitMeasurementTests')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/run_limits_db_regression.py tests/test_app_limit_usage.py)
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Services/AppLimitEffectJournal.swift' 'Evlin iOS/Services/AppLimitUsageReporter.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOS/Services/AppLimitProductionComposition.swift' 'Evlin iOS/Services/AppLimitEpochTypes.swift' 'Evlin iOS.xcodeproj/project.pbxproj' 'Evlin iOSTests/AppLimitEffectJournalTests.swift' 'Evlin iOSTests/LimitShieldLogicTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'feat: journal app limit effects with receipts')
```

The staged name list must contain exactly the eight declared files.

## Task 15: Account Conservatively Across Pause, Resume, and Restart

**Repository:** iOS.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitEpochTypes.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitPlanner.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitPauseResumeTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`

**Interfaces:** Gate close persists `pausedAt` and does not stop monitors. Paused callbacks advance only the paused arm's `ignoredWhilePausedMinutes` high-water. Gate open atomically closes pause, computes conservative accepted base, creates one successor arm, and installs remaining thresholds with `includesPastActivity=false`. The successor starts with raw and ignored high-water at zero; predecessor ignored minutes are audit provenance and are never subtracted from the successor's counter. Restart resumes the same pending replacement; it never subtracts unknown usage, resets accepted usage, or charges ignored pause usage.

**RED:** Add P4V15-P4V17 tests for close/callback/open, multiple paused callbacks, restart before open, restart during replacement, repeated open, midnight/date change, and clear while paused. Assert no overcharge and no callback side effects while paused. Expected failure is current `arm([])` stop and reconstructed-remaining behavior.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitPauseResumeTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests')
```

**Minimal GREEN:** Replace stop/reconstruct logic with persisted pause state and one idempotent successor-arm operation. Keep whole-device and earned pause semantics unchanged.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitPauseResumeTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' -only-testing:'Evlin iOSTests/TaskPauseShieldMappingTests' -only-testing:'Evlin iOSTests/AppLimitPlannerTests' -only-testing:'Evlin iOSTests/AppLimitCallbackNoEffectsTests')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Services/BigKidStatePoller.swift' 'Evlin iOS/Services/AppLimitEpochTypes.swift' 'Evlin iOS/Services/AppLimitPlanner.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/AppLimitPauseResumeTests.swift' 'Evlin iOSTests/BigKidStatePollerTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'fix: resume app limits conservatively')
```

The staged name list must contain exactly the six declared files.

## Task 16: Prove Production Reordering Convergence

**Repository:** iOS.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/ActionExecutor.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitRuleStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitProductionComposition.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitProductionReorderingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochVectorCoverageTests.swift`

**Interfaces:** Remove or make unreachable every legacy direct set/clear production write after the transactional path is green. Poll, NSE, wake, app launch, DAM callback, pause/resume, planner, shield, usage reporter, and ack receipt all consume the same slot/work transaction and current-token recheck.

**RED:** Add a deterministic scheduler that interleaves all three command sources around transaction/claim/effect/readback boundaries. Run P4V01-P4V20 and assert every permutation ends with identical canonical store bytes, no old-set resurrection, one clear tombstone, at most one arm/effect/ack, and correct source/receipt. Add a source scan rejecting production calls to legacy `AppLimitRuleStore.upsert/remove` outside the compatibility facade.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitProductionReorderingTests' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests')
```

**Minimal GREEN:** Route the last legacy callers through composition and delete only now-unreachable direct mutation methods. Do not refactor unrelated command actions.

**Verify:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitProductionReorderingTests' -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests' -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests' -only-testing:'Evlin iOSTests/NSEAppLimitPersistenceTests' -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' -only-testing:'Evlin iOSTests/AppLimitPauseResumeTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && ! rg -n 'AppLimitRuleStore\([^\n]*\)\.(upsert|remove)|\.upsert\(.*AppLimitRule|\.remove\(ruleID:' 'Evlin iOS' 'EvlinDeviceActivityMonitor' 'EvlinPushApplier')
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Services/ActionExecutor.swift' 'Evlin iOS/Services/AppLimitRuleStore.swift' 'Evlin iOS/Services/AppLimitProductionComposition.swift' 'Evlin iOSTests/AppLimitProductionReorderingTests.swift' 'Evlin iOSTests/MeteringEpochVectorCoverageTests.swift')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'test: prove app limit reordering convergence')
```

The staged name list must contain exactly the five declared files.

## Task 17: Add the Automated Phase 4 Gate

**Repository:** iOS; the script reads/runs both local repositories.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase4.sh`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase4CompletionVerifierTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md`

**Interfaces:** The script has `--automated` and `--release` modes. `--automated` runs exact cross-stack fixture comparison, backend pure tests, isolated local DB regression, iPhone and iPad Phase 4 suites, all six Release device builds, deployment/family scans, Push ownership scan, and dirty-path allowlist checks. It creates the Phase 4/Phase 5 handoff at the exact path `docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md` with status `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE`, `releasable: false`, Task 16's exact stale-path removal commit SHA, and raw-log/product/vector hashes. `--release` additionally requires signed physical artifacts and must exit nonzero while physical rows are PENDING.

**RED:** First add the verifier test and invoke the missing script. Expected RED is exit 127/missing script. The test also requires `--release` to fail with `physical_gate_pending`, not to skip it.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase4CompletionVerifierTests')
```

**Minimal GREEN:** Implement the script with absolute roots and exact test paths. It must contain these real entries, not a generic test discovery command:

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest tests/test_metering_epoch_vector_contract.py tests/test_app_limit_delivery.py tests/services/test_lock_command_alert_payload.py tests/test_command_delivery_apns.py tests/test_app_limit_wire_contract.py -q)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/run_limits_db_regression.py)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests' -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests' -only-testing:'Evlin iOSTests/NSEAppLimitPersistenceTests' -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests' -only-testing:'Evlin iOSTests/AppLimitPlannerTests' -only-testing:'Evlin iOSTests/AppLimitCallbackValidatorTests' -only-testing:'Evlin iOSTests/AppLimitCallbackNoEffectsTests' -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' -only-testing:'Evlin iOSTests/AppLimitPauseResumeTests' -only-testing:'Evlin iOSTests/AppLimitProductionReorderingTests')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/AppLimitProductionReorderingTests' -only-testing:'Evlin iOSTests/AppLimitPauseResumeTests')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -configuration Release -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'EvlinDeviceActivityMonitor' -configuration Release -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'EvlinPushApplier' -configuration Release -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'EvlinShieldConfig' -configuration Release -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'EvlinDeviceActivityReport' -configuration Release -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -target 'Evlin iOSTests' -configuration Release -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
```

Write command, SHA, runtime, and result into the completion report. The completion verifier requires the exact handoff path and exact three-part status, and rejects any `physical passed`, `releasable: true`, missing Task 16 SHA, or stale pre-transaction mutation path. Do not paste credentials or database URLs.

**Verify:** Run automated mode; then prove release mode refuses completion.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && /bin/bash '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase4.sh' --automated)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && ! /bin/bash '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase4.sh' --release)
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'scripts/verify_metering_phase4.sh' 'Evlin iOSTests/MeteringPhase4CompletionVerifierTests.swift' 'docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'test: add metering phase 4 automated gate')
```

The staged name list must contain exactly the three declared files. Automated PASS means “ready for physical gate,” not Phase 4 complete or releasable. Phase 5 consumes the completion report at this exact path; Task 18's separate physical report supplements it and never replaces it.

## Task 18: Prepare but Do Not Claim the DEBUG Physical Gate

**Repository:** iOS.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Components/Debug/AppLimitOneMinuteProbeView.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Components/Debug/CommandDeliveryDiagnosticsView.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitOneMinuteProbeTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-phase4-physical.md`

**Interfaces:** A `#if DEBUG` probe creates one disposable rule/arm with a one-minute event through production planner/coordinator/store composition and exposes raw timestamped readback: arm provenance, `includesPastActivity`, callback decision/reason, current token/tombstone, shield source, and applied receipt. It cannot override the clock, jitter, gate, owner, or trust decision. Release builds contain no probe entry.

**RED:** Add tests requiring exactly one minute, production composition, no synthetic callback injection, no release symbol, and a physical report whose status is exactly `PENDING`. Expected failure is missing probe/report.

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitOneMinuteProbeTests')
```

**Minimal GREEN:** Add the DEBUG-only probe and a report with all rows `PENDING`. Do not run or fabricate a physical result in this task.

**Automated verify first:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild test -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/AppLimitOneMinuteProbeTests' -only-testing:'Evlin iOSTests/MeteringPhase4CompletionVerifierTests')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -configuration Debug -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && xcodebuild build -project '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -configuration Release -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && /bin/bash '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase4.sh' --automated)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && ! /bin/bash '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase4.sh' --release)
```

**Commit:**

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git add -- 'Evlin iOS/Components/Debug/AppLimitOneMinuteProbeView.swift' 'Evlin iOS/Components/Debug/CommandDeliveryDiagnosticsView.swift' 'Evlin iOSTests/AppLimitOneMinuteProbeTests.swift' 'docs/superpowers/reports/2026-07-17-metering-phase4-physical.md')
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --check)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached --name-only)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git diff --cached)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git commit -m 'test: prepare phase 4 physical gate')
```

The staged name list must contain exactly the four declared files.

### Manual Physical Procedure — Remains PENDING

Only after Tasks 1-18 and `--automated` pass, use an enrolled K-mode physical iPhone/iPad with Screen Time authorization. Build the Debug app from the existing main workspace using Xcode's selected physical-device destination; do not use TestFlight.

1. Record device model, OS, build SHA, local timezone, selected app token digest, rule ID, ordering token, arm ID, activity/event names, and start timestamp.
2. Arm the one-minute rule while the selected app has not been used in the new arm. Verify readback says `includesPastActivity=false` for enforcement and measurement events.
3. Leave the selected app unused for at least 90 seconds. PASS requires no immediate callback, no limit shield, no usage request, no notification, and no applied receipt.
4. Use only the selected app continuously for at least one minute. PASS requires one physically plausible accepted callback, one `.limit` shield for that app only, one tokened usage sample, one applied receipt matching rule/token/arm, and no device-total ledger change.
5. Repeat with gate paused across the threshold, kill/relaunch the app during pause, then resume. PASS requires ignored paused high-water, one conservative successor arm, and no overcharge.
6. Deliver newer clear, then replay an older set through another available test channel. PASS requires the clear tombstone to remain newest and no shield/rule resurrection.
7. Attach timestamped screenshots/log export and store-byte digest to the physical report. A reviewer changes a row from PENDING only after checking artifacts.

This manual procedure has no completion claim in this plan. Do not change `Status: PENDING` merely because the probe built or simulator tests passed.

## Final Automated Verification

After Task 18, run the complete local automated gate once more from clean task commits:

```bash
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && /bin/bash '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase4.sh' --automated)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && ! /bin/bash '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase4.sh' --release)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS && git status --short --branch)
(cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git status --short --branch)
```

Compare the final dirty/untracked hashes with the immutable baseline plus the exact task commits. Any unexplained delta blocks handoff.

## Physical Items Still Required

These remain outside automated completion:

| Gate | Scope | Status after this plan |
|---|---|---|
| P4-DEVICE-1 | DEBUG one-minute per-app false-immediate/one-real-shield proof on an enrolled physical child device | **PENDING** |
| P4-DEVICE-2 | Physical pause/callback/restart/resume conservative-accounting proof | **PENDING** |
| P4-DEVICE-3 | Physical newer-clear/older-set cross-channel tombstone proof | **PENDING** |
| P4-DEVICE-4 | Two-device attribution/readback proof for the same child profile | **PENDING** |
| P3-DEVICE | Inherited Phase 3 earned 6-7 minute, ownership, and physical iOS 17.6 smoke gates | **PENDING until Phase 3 evidence says otherwise** |
| P5-G18 | Force-kill NSE delivery/application/readback closure | **PENDING; Phase 5 ownership** |
| RELEASE | TestFlight overnight and production rollout | **NOT AUTHORIZED by this plan** |

Phase 4 may be described as “automated gates passed; physical gate pending” only after Task 17/18 automated evidence exists. It must not be described as complete, release-ready, deployed, or physically verified while any Phase 4 physical row is PENDING.

## Requirements Traceability

| Requirement | Tasks/vectors |
|---|---|
| Backend -> poll/NSE/wake `ordering_token` | Tasks 2-5, 9-11; P4V01-P4V09 |
| Persisted tombstone/newest-wins/equal-token ack | Tasks 6, 8-11, 16; P4V03-P4V09 |
| Stable per-rule provenance | Tasks 7, 12-14; P4V10, P4V18-P4V20 |
| `includesPastActivity=false` | Task 12; P4V11 |
| Physical-time trust | Task 13; P4V12-P4V14, P4V19 |
| Conservative pause/resume/restart | Task 15; P4V15-P4V17 |
| Same transaction; old set cannot revive clear | Tasks 6, 8, 14, 16; P4V02-P4V09 |
| Automated first; physical PENDING | Tasks 17-18 and physical table |
| Phase 3 prerequisites/capability adjustment | Hard prerequisite, Task 1, adjustment matrix |
| Absolute workdirs/real entries/concrete destinations | Global constraints and every command block |
| No push/deploy/TestFlight/prod DB | Global constraints and physical procedure |

## Plan Self-Review Record

### Review 1 — Requirement and Boundary Audit

- Confirm all eight requested requirements map to named tasks and vectors.
- Confirm Phase 3 is a hard execution prerequisite, not an assumed completed dependency.
- Confirm the Phase 3 prerequisite consumes Task 30's completion report plus Task 29's final attestation and never requires the Phase 3 plan status to become PASS.
- Confirm every Phase 3 consumed symbol/file/test/report is present in the mechanical cross-phase manifest and the real production test is `MeteringProductionIntegrationTests`.
- Confirm conservative iPad capability branch forbids NSE monitor/effect ownership.
- Confirm token comparison happens before rule, schedule, usage, shield, notification, and receipt mutation.
- Confirm equal-token duplicates have explicit pending/applied ack behavior and zero repeat work.
- Confirm DEBUG one-minute physical evidence is PENDING and Phase 5 G18 remains open.
- Confirm Task 17 creates the Phase 5-pinned `2026-07-17-metering-epoch-phase-4-completion.md` handoff with automated passed, physical pending, and not releasable; Task 18 keeps a separate physical report.
- Confirm authoring changes only this new plan and implementation constraints preserve dirty files.

**Result:** PASS. Mechanical cross-check found every consumed Phase 3 artifact in its producer task, removed the invalid plan-status gate and synthetic test selector, and aligned the Phase 4 completion handoff with Phases 5/6. No requirement omission remains.

### Review 2 — Fresh-Agent Executability Audit

- Confirm every numbered task has repository, exact files, pinned interface/behavior, named RED failure, minimal GREEN, focused/regression verification, explicit staging allowlist, and exact commit subject.
- Confirm all backend commands use the repository interpreter; DB tests use `scripts/run_limits_db_regression.py`; no bare test runner appears.
- Confirm every shell command establishes an absolute working directory.
- Confirm every iOS command uses an installed simulator destination or `generic/platform=iOS`, with deployment 17.6 and family `1,2`.
- Confirm no command pushes, deploys, uploads, stashes, resets, or accesses production data.
- Confirm no placeholder wording delegates core behavior to the implementer.

**Result:** PASS. The scan resolves every XCTest/backend test entry to an existing file, a Phase 3 producer, or the exact earlier Phase 4 create task; all 18 tasks contain RED/GREEN/verify/commit sections and matching staged-file counts. Implementation remains blocked on Phase 3 completion evidence and physical evidence remains PENDING.
