# Metering Epoch Phase 6 Automated Boundary

AUTOMATED DEMOLITION READY; T6/T10 PENDING; PHASE 6 INCOMPLETE; NOT RELEASABLE

status_code: AUTOMATED_DEMOLITION_READY_PENDING
phase_complete: false
releasable: false

This report records local, reversible automation only. It does not authorize a
release, deployment, production flag change, production database access, T6
removal, or T10 removal.

## Demolition Ledger

| Row | Legacy mechanism | Replacement | Vector/log evidence | Demolition SHA/revert | Status |
|---|---|---|---|---|---|
| T1 | scalar arm signature churn | generation key + immutable routes | V01/V02/V03/V06/V07/V24/P3T1-121; `c6e027b4...` | `d33218e7...`; ledgered revert | REMOVED |
| T2 | stale raw threshold ceiling | identity + route provenance + physical trust | V04/V05/V08/V13/V27; `545b2ad4...` | `6194a048...`; ledgered revert | REMOVED |
| T3 | fresh-at-fire gate | callback trust + active epoch gate + effect envelope | V04/V05/V10/V12/P3V01; `4187bfb0...` | `e46ffe15...`; ledgered revert | REMOVED |
| T4 | backend headroom veto | trusted exhaustion + durable effect + CAS correction | V15/V16/P3V01/P3V02/P5V08-P5V12; `6cb868f9...` | `26fec04d...`; ledgered revert | REMOVED |
| T5 | backend plus-five tolerance | strict elapsed + bounded jitter | V04/V05/V19/V30; `343238fd...` | `ff1436de...`; ledgered revert | REMOVED |
| T6 | legacy device-total chain | earned runtime authority | automated observation logs `3ed7a1f1...` and `dde4fac2...` | none | PENDING_ONE_RELEASE |
| T7 | counter recovery flags | epoch pause/resume state machine | V06/V10/V11/V12/V33/V34/V37; `78a21a01...` | `21269f5b...`; ledgered revert | REMOVED |
| T8 | duplicate activity lifecycle | Device Epoch Store + compatibility state | V01/V08/V09/V13/V21/V22/V28/V36-V38; `0dc558fb...` | `ad1e6394...`; ledgered revert | REMOVED |
| T9 | dead earned token blob | canonical selected-set stores | P3V01/P3V02/T9 vectors; `ef2e836c...` | `2a94762f...`; ledgered revert | REMOVED |
| T10 | superseded unlock contract | manual CTA + separate override | automated replacement logs `227b2476...` and `f667ba24...` | none | PENDING_FRED_APPROVAL |
| T11 | iOS whole-bucket plus-five heuristic | strict elapsed/jitter trust | V04/V05/V19/V30; `343238fd...` | `bef870fa...`; ledgered revert | REMOVED |

The machine-readable ledger contains every full vector identifier, SHA-256,
40-character commit SHA, and literal revert command.

## Guard Recount

The production earned decision surface contains exactly three registered
mechanisms:

- identity match: `authorizedEarnedGeneration`;
- physical trust: `physical_threshold_is_trustworthy`;
- gate state: `usageCountingAllowed` / `usage_counting_allowed` across the
  device and backend boundaries.

The temporary `LegacyDeviceTotalMode` is observation state for T6, not a second
metering decision guard, and remains ledgered until the one-release gate closes.

## Automated Verification

- Backend: 70 epoch vectors and 86 disposable-DB regressions passed. Evidence
  SHA-256: `6de859b6494cdaba9a19f37891cbf698768bdf33267201679b25223eb359fb7e`.
- iPhone 17 Pro / iOS 26.3.1: 1670 tests executed. The exact 12 failing test
  identifiers equal the Phase 3 named baseline: 11 historical fixture debts and
  the one authoritative-correction exception with pre-Task-25 birth evidence.
  There are zero new failures. Log SHA-256:
  `75035e9c8ddd295960110267a10f7c3b736f7e8b9f416f08e2bae07867cb6509`.
- iPad Pro 13-inch (M5) / iOS 26.3.1: 1668 applicable tests executed with the
  same exact named set and zero new failures. `ProfileSnapshotTests` is excluded
  because its approved harness is intentionally pinned to iPhone 17 Pro and
  fails closed on every other destination. Log SHA-256:
  `6db257b44647456ea5ca4585f6c558817b64c7dee58bc6db76d245e7447c6ba9`.
- Products: five production Release-iphoneos executables and one Debug XCTest
  executable were freshly built; all six are nonempty arm64 Mach-O files and no
  seventh product exists. Manifest SHA-256:
  `11aa77b4da360374319b11b616b5a1be17f4ae55b52e903d46bb897b151f5075`.

The test runs are Debug simulator runs. The production binaries were Release
builds. This report does not describe the simulator tests as Release tests.

## Pending Gates

| Gate | Status |
|---|---|
| T6 release observation | PENDING |
| T10 Fred approval | PENDING |
| iPhone physical gate | PENDING |
| iPad physical gate | PENDING |

Local simulator, disposable-database, and Release-product verification cannot
satisfy these release/manual gates. A later reviewed workflow must attach the
real release observation for T6 and Fred's explicit written approval for T10.
