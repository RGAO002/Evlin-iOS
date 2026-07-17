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
- Backend locked timezone authority and atomic promotion:
  `a13f29a16da1aeac1e654753a18c2d4bd84ed98d`
- Backend opaque instant authority and cross-date promotion:
  `a914397c93c065519ddc3f1db557571f7cfe1a7f`
- Backend final-review completion report:
  `23922a5b081fb31a735fe9b4104306dfd273893f`
- Backend final re-review evidence report:
  `57beda038c6547978b89d1b7e3c119c2b2bb8f40`
- Backend third-correction completion report:
  `0d5c19195343648625df32a4008c6cd538b38ab8`
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
.venv/bin/python scripts/run_limits_db_regression.py -- \
  tests/test_metering_epoch_phase2_integration.py::test_phase2_metering_epoch_integrated_rollout_gate \
  -vv -o faulthandler_timeout=10
```

Result: `1 passed in 2.52s`; the prior lock-hang correction remains effective.

```sh
.venv/bin/python scripts/run_limits_db_regression.py
```

Result: `212 passed in 121.37s` with no warning output.

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

Result: `140 passed in 78.28s`.

Mandatory same-disposable-database receipts/registration/sample/reconciler
suite: `91 passed in 51.93s`.

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

## Third Architectural Correction

Backend commit `a13f29a16da1aeac1e654753a18c2d4bd84ed98d` makes canonical
context a locked authority. Direct ingest and runtime consumers now validate
scope, aware UTC instant, valid IANA timezone, projected civil date, and exact
equality with the locked profile timezone before mutation. Raw runtime
timezone/date compatibility arguments pass through the same validator.

Migration promotion is now atomic. Exact empty current-day bootstrap config,
cap, child-day, and device-day state is normalized to the promoted timezone in
the same transaction. Any sample, epoch, nonzero ledger, exhaustion/override/
automatic-lock provenance, active earned receipt, lock command history, or
approved task bypass defers promotion and preserves the coherent old authority;
only last-reported observation metadata changes. A later clean day retries
without rewriting old samples or day rows. Parent/device-confirmed timezone
authority remains stable.

Focused TDD RED:

```sh
.venv/bin/python scripts/run_limits_db_regression.py -- \
  tests/services/test_earned_ingest_canonical_date.py \
  tests/test_metering_epoch_sample_adapter.py \
  -k 'forged_canonical or same_date_first_promotion'
```

Result: `4 failed, 29 deselected in 3.40s`. Expanded focused GREEN:
`5 passed, 29 deselected in 3.81s`; complete canonical service plus adapter
modules: `34 passed in 19.88s`.

The initial full runner exposed a real test lock hang. PostgreSQL showed the
integrated test's read transaction owning profile advisory key
`303271830327230503` while its independent reconciler session waited on that
same key. Only the owned runner was terminated. The test now ends the read
transaction before starting the cross-session writer and separately proves
same-session lock acquisition is reentrant. The exact `-vv`/faulthandler
minimal reproduction above passed `1 passed in 2.51s`; no timeout was raised.

Fresh remaining backend results: profile-lock module `4 passed in 2.06s`,
same-DB lock suite `91 passed in 51.95s`, full runner `211 passed in 120.18s`,
targeted bundle `140 passed in 80.72s`, and delivery/override suite
`93 passed in 46.40s`. Dedicated earned override and task-bypass invariants
remain intact.

## Final Re-Review Blocker Corrections

Backend commit `a914397c93c065519ddc3f1db557571f7cfe1a7f` closes the two
remaining blockers without changing migrations, dependencies, Phase 3 docs,
shared fixtures, or iOS production source.

The prior frozen dataclass validated self-consistency but could not prove that
`now_utc` came from the production clock. A direct caller could construct or
`replace` a context with a self-consistent 2035 New York instant/date, and
sample ingest and runtime also exposed arbitrary `now_utc`; runtime retained
raw timezone/date override parameters.

`SampleCanonicalContext` is now an opaque Protocol handle. Its concrete class
and immutable state live inside the module issuer closure, with authority
identity held in a weak identity registry. Public construction, dataclass
replacement, shape-compatible fake objects, blank instances of the concrete
type, and serialization cannot mint registry state. Validation first requires
issuer identity, then rechecks family/profile scope, aware UTC, IANA timezone,
instant-to-date projection, and exact equality with the locked profile row.
There is no wall-clock tolerance, global feature flag, persisted HMAC, or new
caller-controlled authorization boolean.

Public resolver/load functions no longer accept an instant and each calls
`screen_time_clock.now_utc` exactly once. Direct ingest has no `now_utc`
parameter. Runtime has no `now_utc` or raw canonical timezone/date parameters;
it either consumes an issued authority or captures one internally. New epoch
registration mints once and shares that authority with runtime and all
registration timestamps. The sample route shares one resolver-minted instant
across route checks, runtime, and persistence. Child state captures once inside
runtime. Focused tests record exactly one production-clock call for route,
direct service, registration, runtime, and child state.

For cross-date migration promotion, strict empty-bootstrap detection now also
requires no rollover command and no last-sample timestamp. When the old and
promoted civil dates differ, provably empty old-date child/device rows are
deleted in the same transaction; active config/cap and any existing
promoted-date child/device rows are normalized before the promoted-date sample
is persisted. This is the explicit old-date policy: discard only bootstrap
rows with no accounting/lock/sample provenance. Any nonempty or provenance-
bearing state still defers promotion and retries on a later clean day, so
historical rows are not rewritten and mixed provenance cannot survive.

Initial production RED:

```sh
.venv/bin/python scripts/run_limits_db_regression.py -- \
  tests/services/test_earned_ingest_canonical_date.py \
  tests/test_metering_epoch_sample_adapter.py \
  -k 'publicly_constructible or caller_constructed_future or future_instant_override or runtime_has_no_raw or cannot_be_replaced or validator_requires_issuer or cross_date_first_promotion' \
  -vv
```

Result before production changes: `8 failed, 31 deselected in 4.71s`. The
failures independently proved public construction, accepted caller-created
2035 authority, accepted direct-service future `now_utc`, retained raw/future
runtime inputs, accepted a fake runtime authority, successful future
`dataclasses.replace`, missing issuer validation, and retained old-date empty
bootstrap rows.

Expanded focused GREEN added both same-date policies:

```sh
.venv/bin/python scripts/run_limits_db_regression.py -- \
  tests/services/test_earned_ingest_canonical_date.py \
  tests/test_metering_epoch_sample_adapter.py \
  -k 'publicly_constructible or caller_constructed_future or future_instant_override or runtime_has_no_raw or cannot_be_replaced or validator_requires_issuer or same_date_first_promotion or cross_date_first_promotion' \
  -vv
```

Result: `10 passed, 29 deselected in 5.80s`. A separate route/service/
registration/state clock gate passed `5 passed in 3.87s`, with exact one-call
assertions. Complete canonical service plus adapter modules passed
`39 passed in 21.84s`.

Fresh final verification:

- exact integrated rollout gate: `1 passed in 2.52s` with the existing
  10-second faulthandler diagnostic and no advisory wait;
- profile-lock concurrency: `4 passed in 2.04s`;
- same-DB receipt + registration + sample + reconciler: `91 passed in 51.93s`;
- full disposable DB runner: `212 passed in 121.37s`;
- exact targeted Phase 2/task-lock bundle: `140 passed in 78.28s`;
- delivery/override bundle: `94 passed in 46.78s`; the increase from 93 is
  exactly the new cross-date adapter regression;
- strict v1 warning gate: `27 passed, 1 xfailed in 94.29s`, with RuntimeWarning
  and unraisable warnings promoted to errors and only the two named PostgREST
  deprecations filtered;
- v2 readiness/registration gate: `46 passed in 22.60s`;
- pure vector/readiness/policy gate: `79 passed in 0.42s`;
- Alembic: one head, `2026_07_16_meter_epoch_v2 (head)`; and
- both backend/iOS fixture comparisons exited 0.

The Backend checkout was clean but already at `cf209ec` rather than the
requested `0d5c191`; that intervening commit contains only Phase 3 review maps.
Those Phase 3 files were not modified or staged. No iOS XCTest was rerun because
no iOS source, shared fixture, or cross-platform contract assertion changed.
Phase 2 remains `PENDING FINAL RE-REVIEW`; independent final re-review is the
sole remaining blocker.

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

Result: `27 passed, 1 xfailed in 94.29s`. RuntimeWarning and
unraisable warnings were errors; only the two named third-party PostgREST
deprecations were filtered.

```sh
METERING_EPOCH_ADVERTISED_VERSION=2 \
  .venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_readiness.py \
  tests/test_metering_epoch_registration.py
```

Result: `46 passed in 22.60s`. Configured protocol remains version 1 outside
the disposable v2 command environment.

The pure contract/readiness/policy gate passed `79 passed in 0.42s`.
`alembic heads` reported the single head
`2026_07_16_meter_epoch_v2 (head)`.

## iOS Compatibility

The fixture comparisons were rerun for this correction from
`/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS`. The selected XCTest command
and result below are preserved from the prior Task 8 run:

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

Both fixture comparisons exited 0 and remained byte-identical. The metering
fixture contains 23 vectors
and has SHA-256
`dae61b95d500d54318e76ec0ce27e2999c6fb0e4325b78f187043542b33e47e2`.
The app-limit wire fixture has SHA-256
`4d651a535dc2c698fdf5f76cca77d86806ae543b6e2efea33f049c50a91ea8b4`.
The prior XCTest completed with `** TEST SUCCEEDED **`: 6 tests passed in
41.303 seconds. Selected XCTest was not rerun for this correction because no
fixture, cross-platform contract assertion, or iOS source changed.

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
