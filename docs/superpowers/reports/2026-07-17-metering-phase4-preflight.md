# Metering Phase 4 Preflight Registration

## Scope

Phase 4 Task 1 registers safety state only. It adds no production behavior,
migration, monitor ownership, or replacement lock.

## Immutable Baseline

Captured before the Task 1 RED test.

| Item | Result |
|---|---|
| iOS branch/status | `calendar-in-chat...origin/calendar-in-chat [ahead 169]`; six tracked WIP paths and four untracked WIP paths listed below |
| Backend branch/status | `tz-root-fix`; clean |
| iOS HEAD | `16b06c735eec80d849d62aaded9c3e684ce95d35` |
| Backend HEAD | `37c391a8acd1b79163f80698c680417d19551579` |
| iOS dirty diff SHA-256 | `f9fef8ed72a042bd22d813ae389cbb2bf09864815c70fbb931440db7b01760a8` |
| Backend dirty diff SHA-256 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| iOS untracked manifest SHA-256 | `7d7fcb1a24051dbc2350b2300ec5c2bbab8f269e9141a3a7784402531c42ef84` |
| Backend untracked manifest SHA-256 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| Lock-boundary SHA-256 | `c0ae054794ca344c71b5497496f148cb7e4087b89c605ec5e60157e6b601ceba` |

The pre-existing iOS tracked WIP was `Evlin iOS.xcodeproj/project.pbxproj`, its
two `xcuserdata` files, `Evlin iOS/ContentView.swift`,
`Evlin iOS/Services/APIClient.swift`, and
`Evlin iOS/Views/Onboarding/OnboardingCoordinator.swift`. The pre-existing
untracked WIP was `.DS_Store`, the Xcode `xcdebugger` directory,
`Evlin iOS/Views/Onboarding/Parent/V2/ParentBetaAgreementStep.swift`, and
`docs/superpowers/plans/2026-07-16-metering-epoch-phase-2.md`.

## Phase 3 Attestation

The hard-completion checks all exited `0`: the completion report exists and
contains `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE` and
`releasable: false`; the Task 29 attestation exists; the shell verifier exists;
and the attestation resolves exactly one report-only commit with a matching
commit/blob-or-SHA-256 reference. This is a valid physical-pending dependency,
not a release claim.

Behavioral evidence before RED:

| Gate | Exit/result |
|---|---|
| iOS Phase 3 golden vector and production integration tests | `0`, `TEST SUCCEEDED` |
| Phase 3 host verifier | `0`, `33 passed in 467.35s` |
| Backend local DB regression | `0`, `49 passed in 42.28s`; temporary local database dropped |

## Capability Inventory

Every prescribed inventory probe was run. `0` means the probe matched its
expected spelling. The two `1` results are the documented naming-only moves;
their equivalent final symbols below were found with `rg` and do not alter
ownership, trust, durability, or transaction semantics.

| Probe | Exit | Result |
|---|---:|---|
| `test -f MeteringRuntimeInfrastructure.swift` | 0 | present |
| `test -f MeteringDeviceActivityCenter.swift` | 0 | present |
| `test -f DeviceEpochStore.swift` | 0 | present |
| `test -f EarnedMeteringCallback.swift` | 0 | present |
| `test -f EarnedShieldEffectStore.swift` | 0 | present |
| `test -f MeteringProductionComposition.swift` | 0 | present |
| `test -f MeteringProcessEntries.swift` | 0 | present |
| `test -f MeteringProductionIntegrationTests.swift` | 0 | present |
| `test -f scripts/test_verify_metering_phase3_completion.py` | 0 | present |
| `rg -U -q 'func transaction<Value>( expectedOwner: UUID?' DeviceEpochStore.swift` | 0 | present |
| `rg -q 'protocol MeteringDeviceActivityCenter' MeteringDeviceActivityCenter.swift` | 0 | present |
| `rg -q 'enum MeteringRuntimeClock' MeteringRuntimeInfrastructure.swift` | 0 | present |
| `rg -q 'enum MeteringProcessRole' MeteringRuntimeInfrastructure.swift` | 1 | final location is `DeviceEpochStore.swift` |
| `rg -q 'enum MeteringProductionComposition' MeteringProductionComposition.swift` | 0 | present |
| `rg -q 'final class AppMeteringEntry' MeteringProcessEntries.swift` | 0 | present |
| `rg -q 'final class DAMMeteringEntry' MeteringProcessEntries.swift` | 0 | present |
| `rg -q 'includesPastActivity: false' EarnedBudgetScheduler.swift` | 1 | final location is `MeteringDatedSchedule.swift` |
| `rg -q NSE persistence-only research statement` | 0 | present |

## Frozen Phase 3 Mapping

| Phase 4 dependency | Final Phase 3 capability | Adjustment/result |
|---|---|---|
| Cross-process lock | `ActiveLockPersistenceLock.shared`, adapted by `DeviceEpochStoreLocking` in `DeviceEpochStore.swift` | Reuse this lock and atomic-file path; no second lock. |
| Atomic App Group state | `DeviceEpochStore.transaction(expectedOwner:_:)` in `DeviceEpochStore.swift` | Retains the owner check and one transaction boundary. |
| Process roles | `MeteringProcessRole.app` and `.deviceActivityMonitor` in `DeviceEpochStore.swift` | Naming-only file move from `MeteringRuntimeInfrastructure.swift`; Push remains persistence-only. |
| DeviceActivity adapter | `MeteringDeviceActivityCenter` protocol in `MeteringDeviceActivityCenter.swift` | App/DAM composition boundary only; Push receives no center. |
| Clock | `MeteringRuntimeClock.live()` and injected `MeteringClock` | Final names match; no direct `Date()` in pure Phase 4 logic. |
| Physical predicate | `EarnedMeteringCallback.defaultJitterSeconds = 30` and `maximumJitterSeconds = 60` | Reuse/extract a shared pure predicate without semantic change. |
| Shield persistence | `EarnedShieldEffectStore` with `ActiveLockPersistenceLock` and `DeviceEpochStore` | Reuse durable claim/readback primitives; no second receipt authority. |
| Production hooks | `MeteringProductionComposition`, `AppMeteringEntry`, and `DAMMeteringEntry` | Existing factories/entries are retained; the Push hook must remain persist-only. |
| No-past-activity scheduler | `includesPastActivity: false` in `MeteringDatedSchedule.swift` | Naming-only file move from `EarnedBudgetScheduler.swift`; semantics match. |
| Backend migration head | Backend HEAD `37c391a8acd1b79163f80698c680417d19551579`, local DB regression green | Phase 4 Task 1 adds no migration. |

The fixed capability branch is exactly `NSE=persist-only`: it may persist the
newest desired state/tombstone and wake state, but app/DAM own monitor
installation and enforcement. No semantic gap was found.

## Registered Safety States

| State | Replaces legacy state or net-new rationale | Deletion criterion | Vectors |
|---|---|---|---|
| `AppLimitVersionSlot` | Replaces an unversioned active-rule row as the sole per-rule newest-token authority. | Compact only after durable removal can prove no retained command, tombstone, work item, or receipt refers to the slot token. | P4V01, P4V02, P4V04, P4V05, P4V07, P4V08, P4V09, P4V18 |
| `AppLimitClearTombstone` | Replaces destructive legacy clear/remove semantics. | Remove only after a durable higher token supersedes it and no pending owner/effect/readback path can observe the cleared token. | P4V03, P4V04, P4V06, P4V09 |
| `AppLimitOwnerWork` | Net-new durable replacement for in-memory/poll-only owner recovery. | Delete only after the exact current receipt has been durably read back and acknowledged, or a newer token atomically supersedes it. | P4V01, P4V05, P4V07, P4V09, P4V18 |
| `AppLimitEffectLease` | Net-new durable ownership claim; legacy effects had no app-limit lease. | Clear after the final token/arm recheck commits the receipt, on supersession, or after expiry followed by a fresh claim/recheck. | P4V05, P4V09, P4V18, P4V19 |
| `ignoredWhilePausedMinutes` | Net-new app-limit paused raw high-water; it must not reuse earned progress as identity. | Delete only with the retired arm after its replacement/tombstone is durably current and no callback for that arm is accepted. | P4V12, P4V13, P4V14, P4V15, P4V16, P4V17, P4V19 |
| `AppLimitApplyReceipt` | Net-new durable proof replacing ephemeral side-effect acknowledgement. | Delete only when a newer current token invalidates it and all associated owner work/effect leases are terminal. | P4V05, P4V06, P4V09, P4V18 |

## Phase 4 Vector Register

| ID | Required safety result |
|---|---|
| P4V01 | Newer set persists active rule and owner work. |
| P4V02 | Older set is superseded before every side effect. |
| P4V03 | Newer clear atomically removes active rule and writes tombstone. |
| P4V04 | Old set cannot resurrect after clear. |
| P4V05 | Equal applied set reuses receipt without re-arm/effect. |
| P4V06 | Equal applied clear has no mutation. |
| P4V07 | Equal NSE-persisted command remains one pending owner work item. |
| P4V08 | Equal token with unequal digest fails closed. |
| P4V09 | Poll/NSE/wake converge to identical state and receipt. |
| P4V10 | Progress never changes replacement identity or arm. |
| P4V11 | Measurement and enforcement use `includesPastActivity=false`. |
| P4V12 | Impossible immediate callback has zero side effects. |
| P4V13 | Delayed possible callback is accepted once. |
| P4V14 | Late possible callback has no freshness rejection. |
| P4V15 | Paused callback updates only ignored high-water. |
| P4V16 | Resume creates conservative fresh arm. |
| P4V17 | Restart preserves ignored usage without overcharge. |
| P4V18 | UI/readback requires current token/arm receipt. |
| P4V19 | Wrong provenance rejects before side effects. |
| P4V20 | Per-app exhaustion leaves unrelated ledgers unchanged. |

## TDD Evidence

The initial test was added before this report and run with the declared
destination. It failed with exit `65` because the report was absent; the
xcresult failure is `NSCocoaErrorDomain Code=260` for the exact expected report
path. The subsequent focused GREEN run is recorded by the Task 1 verification
commands.
