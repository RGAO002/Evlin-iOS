# Metering Phase 3 R-16 Registration

Date: 2026-07-17

This report records the Phase 3 safety states registered under rulebook R-16
before any Phase 3 implementation state is introduced. T5 remains the Phase 2
backend heuristic; T11 is the distinct iOS whole-bucket heuristic scheduled for
removal in Phase 3 Task 26.

## Rulebook Evidence

- Path: `/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md`
- SHA-256: `e31b46af239a366b905583e7841726f7889b4460a2b0a41f6d86ed52b5c5d15b`
- Verifier: `scripts/verify_metering_phase3_r16.py`

The verifier pins every cell in the pre-existing T1-T11 dismantling ledger and
every cell in the registration below. Heading matching is exact after trimming
outer whitespace, and duplicate or malformed tables are rejected.

### Phase 3 registered safety state

| State | Replaces or justifies | Delete only when | Vectors |
|---|---|---|---|
| `MeteringCallbackRoute/route tombstone` | T2/T8 callback provenance | stop acknowledged, all references terminal, retention elapsed | V04,V05,V08,V27,V35 |
| `LegacyCompatibilityMonitorState` | preserves T8 v1 behavior while replacing its storage authority | owner v2 activated and legacy stop acknowledged | V30,V38 |
| `pendingStart/starting/installed/verified/dualActive/active/pendingStop/stopped` | replaces T8 lifecycle choreography; `dualActive` closes the backend/local ratchet crash window | daemon presence/config or absence acknowledged | V28,V30,V33,V38 |
| `V2RouteHandoff.preparing/dualV2/cutoverReady/committed` | net-new crash-safe v2-to-v2 replacement without a zero-metering window or stale prior sample loss | prior queue/in-flight barrier closed, replacement active, prior stop acknowledged, overlap samples terminal | V09,V21,V22,V32,V37 |
| `ActivityInstallClaim 60-second lease` | net-new app/DAM single-start arbitration | one proven monitor-owner process exists | V33 |
| `futurePlanned/offlinePending` | net-new explicit bounded authorization | registered/activated, retired, or stopped | V24,V27 |
| `MonitorCoverageState.readyThrough/coverageExhausted` | replaces false repeating coverage | horizon refilled or owner/generation retired | V24,V25,V26 |
| `registration/activation queue and per-owner protocol ratchet` | replaces direct v1-only dispatch without breaking v1 | owner retired after terminal queues | V19,V20,V30,V38 |
| `BaseCorrectionState.available/used` | net-new bounded 409 correction | registration accepted or correction terminal | V32 |
| `process-role monitor owner` | net-new capability boundary | physical ownership proof authorizes another role | target/Release/physical evidence |
| `resumeBoundaryPending/paused high-water` | replaces T7 | first new-route callback discarded or epoch retired | V10,V11,V12,V37 |
| `0/5/15/60/300 retry schedule` | net-new deterministic recovery policy | all work terminal | V34 |
| `EarnedShieldEffectEnvelope` | replaces T4 veto | exact release/CAS terminal | V15,V16,P3V01,P3V02,V36 |
| `IdentityCleanupWork` | replaces T8 detached teardown | every captured acknowledgement durable | V13,V29 |
| `RolloverEffectsWork` | net-new durable canonical rollover | all exact old/new effects acknowledged | V09,V21,V22,V29 |
| `EpochSampleWork` | replaces legacy retry/fallback after activation | accepted or terminal disposition | V19,V20,V30,V32 |

## TDD Evidence

### RED

To re-establish test-first evidence after taking over interrupted partial work,
only the exact `### Phase 3 registered safety state` heading and its 16-row
table were temporarily removed from the external rulebook. The pre-existing
T1-T11 table was preserved unchanged.

```sh
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/verify_metering_phase3_r16.py
```

The command exited 1 with the expected assertion:

```text
AssertionError: expected exactly one heading '### Phase 3 registered safety state', found 0
```

### GREEN

The exact heading and the exact 16 rows above were restored immediately after
T1-T11. The restored external rulebook hash is:

```text
e31b46af239a366b905583e7841726f7889b4460a2b0a41f6d86ed52b5c5d15b  /Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md
```

The verifier then exited 0, confirming every expected T1-T11 data cell and
every expected Phase 3 data cell.

The focused vector command also exited 0:

```sh
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' test
```

`MeteringEpochVectorCoverageTests` passed both
`testCanonicalVectorBackendByteParity` and
`testCanonicalVectorSchemaAndCoverage`.

## Full Suite Deviation

The mandated full suite was run with the same project, scheme, simulator, and
build settings. It exited 65: 1,173 passed, 36 failed, and 4 skipped out of
1,213 tests. The metering vector and golden-vector tests in that run passed.

The failures span pre-existing/unrelated worktree areas, including snapshots,
chat, PlanArch cards, calendar DTOs, catalog binding, and onboarding/reflection
models. The worktree also contained unrelated modified and untracked iOS files
before Task 1 was resumed. This task touched only this report and
`scripts/verify_metering_phase3_r16.py`; it neither changed nor staged the
unrelated WIP. The full-suite baseline remains red and is not represented as
Task 1 success.

No push, deployment, Render, TestFlight, production database, or physical
device action was performed.

## Commit Evidence

Only the report and verifier were staged. `git diff --cached --check` passed,
the staged stat reported 402 insertions across exactly two files, and the full
staged diff was inspected before committing with:

```sh
git commit -m 'test: register phase 3 metering safety states'
```

The commit completed successfully with the exact message above. Unrelated WIP
remained unstaged.
