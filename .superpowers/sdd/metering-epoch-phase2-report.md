# Metering Epoch Phase 2 Completion Report

Status: PENDING FINAL RE-REVIEW

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
- Backend request-time canonical day:
  `4bdd76e019b9bb683e40e1ad82f35e1facc2203a`
- Backend manual-only legacy unlock:
  `79fdc6d46572bd884120ab9b12a49182ba62ffe5`
- Backend stable predecessor tie-break:
  `03b562bdbe06c47a9ee38402fbb342ef192f4891`
- Backend stable 64-bit advisory locks:
  `1aa5dd783c66a293b078d2cb299118d446cadf73`
- Backend request-engine notification drains:
  `bcb8afcbd527b0353b73ff1b0f139c686984eb82`
- Backend request-engine app-control delivery:
  `92628ef17fe29298b3a2dafe7b43a89bafe153f5`
- Backend one-context timezone promotion fix:
  `081955d3732239dfc80f35d06d3614d8bccd253b`
- Backend final-review completion report:
  `23922a5b081fb31a735fe9b4104306dfd273893f`
- Backend final re-review evidence report:
  `57beda038c6547978b89d1b7e3c119c2b2bb8f40`
- Original iOS Task 8 report:
  `67f22be1afd74f3aac7dc1d3233d5f81948e6e78`
- Prior committed iOS review evidence:
  `f5af66b8a6acc5faa36b184dd827910767921ea2`

The commit containing this final report cannot identify its own SHA without
changing that SHA. Its exact report-only commit is recorded after commit in
`/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.superpowers/sdd/phase2-final-review-fix-report.md`.

## Final Backend Proof

The final-review wave additionally proves server-authoritative request day for
v1/v2, manual-only legacy unlock with automatic policy state unchanged,
deterministic predecessor ties, stable full-width advisory locks, mandatory
concurrency rendezvous, and warning-clean async background database cleanup.
Dedicated earned override and task-bypass coverage remains intact.

Run from `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend`:

```sh
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_phase2_integration.py
```

Result: `1 passed in 2.47s`.

```sh
.venv/bin/python scripts/run_limits_db_regression.py
```

Result: `209 passed in 113.39s (0:01:53)` with no warning output.

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

Result: `140 passed in 75.65s (0:01:15)`.

Mandatory same-disposable-database receipts/registration/sample/reconciler
suite: `91 passed in 52.81s`.

The exact targeted bundle is the approval gate for task-lock prerequisite
`2944580dfd4d32d818f94c7b5d3492343ca11243`. Its own focused evidence was
`4 passed in 3.07s`, and its full task-lock module evidence was
`39 passed in 28.24s`.

## Final Re-Review Evidence

At server `2026-07-17T03:30:00Z`, the old sample route derived New York date 16
before a first authenticated Tokyo sample promoted the profile's migration
timezone. It therefore rejected legitimate Tokyo date 17 and could accept a
mixed date-16/Tokyo sample.

Backend commit `081955d3732239dfc80f35d06d3614d8bccd253b` resolves one scoped
canonical context under the profile lock and carries its single captured UTC
instant, resolved timezone, and date through validation, v2 runtime, and
persistence. Rejected authenticated samples may persist valid timezone
observation/promotion metadata, but the regression proves no sample, epoch,
ledger, command, receipt, APNs, shield, or task effect.

Focused route TDD command:

```sh
.venv/bin/python scripts/run_limits_db_regression.py -- \
  tests/test_metering_epoch_sample_adapter.py -k first_timezone_promotion
```

RED: `2 failed, 21 deselected in 2.33s`. GREEN:
`2 passed, 21 deselected in 2.23s`. Canonical service plus full adapter modules
passed `29 passed in 16.96s`, including delayed-prior-day coverage and stable
parent/device-confirmed timezones.

A positive first-promotion v2 fixture was not fabricated: epoch registration
rejects timezone/date mismatches against the still-New-York runtime before it
can insert a Tokyo/date-17 epoch. Existing v2 paths consume the resolved request
context and cannot persist mixed provenance.

The delivery/override suite passed `91 passed in 45.11s`; the two-test increase
is exactly the new adapter regressions, and dedicated earned override and task
bypass coverage remains intact.

## Rollout Gates

```sh
METERING_EPOCH_ADVERTISED_VERSION=1 \
PYTHONTRACEMALLOC=25 \
PYTHONWARNINGS='error::RuntimeWarning' \
  .venv/bin/python scripts/run_limits_db_regression.py -- \
  tests/test_metering_epoch_readiness.py tests/test_bigkid_endpoints.py \
  -W 'error::pytest.PytestUnraisableExceptionWarning' \
  -W "ignore:The 'timeout' parameter is deprecated.*:DeprecationWarning:postgrest._sync.client" \
  -W "ignore:The 'verify' parameter is deprecated.*:DeprecationWarning:postgrest._sync.client"
```

Result: `27 passed, 1 xfailed in 114.30s (0:01:54)`. RuntimeWarning and
unraisable warnings were errors; only the two named third-party PostgREST
deprecations were filtered.

```sh
METERING_EPOCH_ADVERTISED_VERSION=2 \
  .venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_readiness.py \
  tests/test_metering_epoch_registration.py
```

Result: `46 passed in 22.78s`. Configured protocol remains version 1 outside
the disposable v2 command environment.

The pure contract/readiness/policy gate passed `79 passed in 0.40s`.
`alembic heads` reported the single head
`2026_07_16_meter_epoch_v2 (head)`.

## iOS Compatibility

Preserved from the prior Task 8 run in
`/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS`:

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
These fixture comparisons and selected XCTest were not rerun for final
re-review because no fixture, cross-platform contract assertion, or iOS source
changed.

## Operational Constraints

Pre-existing iOS WIP remained unstaged and unmodified by this task. No push,
deployment, Render environment change, TestFlight upload, production database
access, or production data mutation occurred.

Phase 2 remains `PENDING FINAL RE-REVIEW`. Exact remaining blocker: independent
final re-review only.

Later rollout order remains:

1. merge backend code and migration
2. deploy backend with advertised version 1
3. verify `/health` reports `schema_ready: true`
4. ship Phase 3 iOS with v2 support while server advertisement remains 1
5. obtain Fred's explicit approval
6. set advertised version 2
7. monitor registration conflicts, terminal v1 drops, fanout receipts, and command acknowledgements
