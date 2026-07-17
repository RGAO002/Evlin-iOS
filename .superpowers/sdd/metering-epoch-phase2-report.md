# Metering Epoch Phase 2 Completion Report

Status: DONE

This is the final iOS-side Task 8 evidence record. No iOS production code was
changed for Task 8 or its review-fix waves.

## Commit Evidence

- Backend original Task 8:
  `7c6a87d36a07aae26d45fbfe3585d56c85682900`
- Backend deterministic test hygiene:
  `57f9eb8409d7160be7d0b774e8ab1586cd0b1d6b`
- Backend task-lock prerequisite:
  `2944580dfd4d32d818f94c7b5d3492343ca11243`
- Backend first review-proof wave:
  `32056af3df3f9a005a1afe479e7d8a209e73d227`
- Backend final integration-test commit:
  `722978073700d402adf45b24684a737400e0fb11`
- Original iOS Task 8 report:
  `67f22be1afd74f3aac7dc1d3233d5f81948e6e78`
- Prior committed iOS review evidence:
  `f5af66b8a6acc5faa36b184dd827910767921ea2`

The commit containing this final report cannot identify its own SHA without
changing that SHA. Its exact report-only commit is recorded after commit in
`/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.superpowers/sdd/task-8-report.md`.

## Final Backend Proof

The final integration scenario proves complete rejected-sample effect
snapshots, valid A t5 replay idempotency, default-v1 behavior, real manual and
task-pause source isolation, independently derived receipt command IDs, and
strict D+1 repeat idempotency. The D+1 snapshot includes complete persisted
`BigKidTaskRecord` content, task status/phase, bypass status and canonical
provenance; the replay comparison normalizes only `last_sample_at`.

Run from `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend`:

```sh
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_phase2_integration.py
```

Result: `1 passed in 3.31s`.

```sh
.venv/bin/python scripts/run_limits_db_regression.py
```

Result: `202 passed in 131.69s (0:02:11)`.

```sh
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_earned_time_sample.py \
  tests/test_earned_time_auto_lock.py \
  tests/test_earned_time_config.py \
  tests/test_earned_time_policy_summary.py \
  tests/test_task_lock_service.py \
  tests/test_task_gated_lock_routes.py \
  tests/test_app_limit_delivery.py \
  tests/test_app_limit_wire_contract.py \
  tests/api/test_app_limits_endpoint.py \
  tests/test_effective_state_sources.py
```

Result: `140 passed in 86.75s (0:01:26)`.

The exact targeted bundle is the approval gate for task-lock prerequisite
`2944580dfd4d32d818f94c7b5d3492343ca11243`. Its own focused evidence was
`4 passed in 3.07s`, and its full task-lock module evidence was
`39 passed in 28.24s`.

## Rollout Gates

```sh
METERING_EPOCH_ADVERTISED_VERSION=1 \
  .venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_readiness.py \
  tests/test_bigkid_endpoints.py
```

Result: `27 passed, 1 xfailed, 3 warnings in 23.82s`.

```sh
METERING_EPOCH_ADVERTISED_VERSION=2 \
  .venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_readiness.py \
  tests/test_metering_epoch_registration.py
```

Result: `45 passed in 35.17s`.

The v1 warnings are non-failing asyncpg cancellation and Supabase deprecation
warnings. Configured protocol remains version 1 outside the disposable v2
command environment.

The pure contract/readiness/policy gate passed `79 passed in 0.44s`.
`alembic heads` reported the single head
`2026_07_16_meter_epoch_v2 (head)`.

## iOS Compatibility

Run from `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS`:

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

Both fixtures were byte-identical. The metering fixture contains 23 vectors
and has SHA-256
`dae61b95d500d54318e76ec0ce27e2999c6fb0e4325b78f187043542b33e47e2`.
The app-limit wire fixture has SHA-256
`4d651a535dc2c698fdf5f76cca77d86806ae543b6e2efea33f049c50a91ea8b4`.
XCTest completed with `** TEST SUCCEEDED **`: 6 tests passed in 41.303 seconds.

## Operational Constraints

Pre-existing iOS WIP remained unstaged and unmodified by this task. No push,
deployment, Render environment change, TestFlight upload, production database
access, or production data mutation occurred.

Later rollout order remains:

1. merge backend code and migration
2. deploy backend with advertised version 1
3. verify `/health` reports `schema_ready: true`
4. ship Phase 3 iOS with v2 support while server advertisement remains 1
5. obtain Fred's explicit approval
6. set advertised version 2
7. monitor registration conflicts, terminal v1 drops, fanout receipts, and command acknowledgements
