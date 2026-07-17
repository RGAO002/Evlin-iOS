# Metering Epoch Phase 2 Completion Report

Status: DONE_WITH_CONCERNS. This report is the iOS task artifact. The
cross-repository final report, including both immutable commit SHAs, is at
`/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.superpowers/sdd/task-8-report.md`.

## Commit and Recovery Evidence

- Backend start: `099204036343cac9f1761d29a6af4fd4b7319d20`
- Backend task commit: `7c6a87d36a07aae26d45fbfe3585d56c85682900`
- iOS start/recovery pointer: `42a0aa4ef1f040940da399a2c73553927787f4d9`
- iOS end: this report commit (`docs: report metering epoch phase 2`); its
  immutable SHA is recorded in the cross-repository final report after commit.

## Fixture and XCTest Gates

The following commands ran from `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS`:

```sh
cmp \
  'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json

cmp \
  'Evlin iOSTests/Fixtures/app_limit_wire.json' \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/app_limit_wire.json

xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/MeteringEpochVectorCoverageTests \
  -only-testing:Evlin\ iOSTests/AppLimitWireContractTests
```

Both `cmp` commands exited 0. The metering fixture has 23 cases across its
seven case groups and is byte-identical to the backend fixture:
`dae61b95d500d54318e76ec0ce27e2999c6fb0e4325b78f187043542b33e47e2`.
The app-limit wire fixture is byte-identical:
`4d651a535dc2c698fdf5f76cca77d86806ae543b6e2efea33f049c50a91ea8b4`.

The standard XCTest command completed with `** TEST SUCCEEDED **`: 6 tests
passed (2 `MeteringEpochVectorCoverageTests`, 4 `AppLimitWireContractTests`) in
41.303 seconds. The observed Sentry simulator CodeSign failure did not occur,
so no `CODE_SIGNING_ALLOWED=NO` rerun was needed.

## Backend Integration and Rollout Evidence

The backend task commit adds the real-PostgreSQL Phase 2 integration scenario
and appends its six Phase 2 files to the disposable regression runner. The
scenario passed directly: `1 passed in 2.66s`.

Pure contracts/readiness/policy identity passed: `79 passed in 0.44s`.
`alembic heads` reported the sole head:
`2026_07_16_meter_epoch_v2 (head)`.

The advertised-v1 disposable gate passed: `27 passed, 1 xfailed, 3 warnings in
23.23s`. This verifies schema readiness while unratcheted child state advertises
version 1. The selected v2 registration suite passed separately: `39 passed in
25.73s`, verifying a first v2 registration is allowed. The exact combined v2
command had `44 passed, 1 failed`; the only failure asserted that a `Settings`
instance must default to 1 while the command explicitly injects
`METERING_EPOCH_ADVERTISED_VERSION=2`. This is a test-command expectation
conflict, not a product failure.

Configured protocol remains 1 outside these disposable command environments.
No Render deployment, TestFlight upload, production environment change, or
production-data mutation occurred. No production Swift epoch adapter changed.

## Concerns and Later Rollout Order

The complete disposable runner ended `201 passed, 1 failed`; the unrelated
failure is `tests/api/test_limits_regression_pack.py::test_limits_regression_pack_parent_child_flow`.
It was reproduced standalone before reporting: the test summarizes
`date.today()` while its earned sample is fixed at `2026-06-23`, resulting in
`used_minutes == 0` rather than 30. Neither that file nor production code was
modified.

The targeted bundle ended `136 passed, 4 failed`. The four failures are exactly
the already A/B-proven Phase 2 task-lock failures:
`test_tokenless_selected_set_emits_warning_not_command`,
`test_task_executor_approve_reconciles_existing_task_pause_lock`,
`test_task_executor_delete_reconciles_existing_task_pause_lock`, and
`test_task_executor_cancel_reconciles_existing_task_pause_lock`.

Later rollout order, not executed:

1. merge backend code and migration
2. deploy backend with advertised version 1
3. verify /health says schema_ready true
4. ship Phase 3 iOS with v2 support but no device can ratchet while server advertises 1
5. ask Fred for explicit approval
6. set advertised version 2
7. monitor registration conflicts, terminal v1 drops, fanout receipts, and command acknowledgements

Pre-existing iOS dirty files were neither staged nor intentionally modified;
only this completion report is staged for the iOS task commit.
