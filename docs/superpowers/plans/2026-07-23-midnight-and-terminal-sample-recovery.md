# Midnight and Terminal Sample Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore v2 earned metering across canonical midnight and guarantee delivery of already-applied per-app terminal usage.

**Architecture:** Separate future schedule installation authority from callback accounting authority, then wire the existing durable rollover state machine into production DAM and app recovery. Treat a durable per-app local receipt as immutable transport authority while keeping stale execution and owner fences intact.

**Tech Stack:** Swift, XCTest, DeviceActivity, App Group persistence, FastAPI, SQLAlchemy, pytest.

## Global Constraints

- Preserve all existing owner, identity-switch, physical plausibility, and callback provenance fences.
- Never call global `stopMonitoring()` from rollover, manual lock, or manual unlock.
- Future-route installation does not authorize future-route callbacks.
- Only a durable, exact local receipt may survive a rule clear for transport.
- Do not revert or stage unrelated beta-agreement, onboarding, diagnostics, or user WIP.
- RED must be observed before each production behavior change.

---

### Task 1: Candidate Horizon Installation Authority

**Files:**
- Modify: `Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `Evlin iOS/Services/DatedRouteInstaller.swift`
- Test: `Evlin iOSTests/DatedRouteInstallerTests.swift`
- Test: `Evlin iOSTests/EarnedMeteringCallbackTests.swift`

**Interfaces:**
- Produces an install-only provenance predicate for bounded future routes in the exact candidate generation.
- Existing callback provenance remains unchanged.

- [ ] Add a failing test that starts a candidate generation handoff, reconciles its future routes before activation, and expects those routes to be verified rather than terminal `route_superseded`.
- [ ] Add a failing test proving the same future route's callback is still rejected before activation.
- [ ] Run both tests and verify the first fails for `route_superseded`.
- [ ] Implement the narrow install-only predicate and use it in claim/install/verify/defer paths.
- [ ] Run the focused installer and callback suites.

### Task 2: Production Canonical Rollover Trigger

**Files:**
- Modify: `Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `Evlin iOS/Services/MeteringProcessEntries.swift`
- Modify: `Evlin iOS/Services/MeteringProductionComposition.swift`
- Modify: `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Test: `Evlin iOSTests/MeteringRolloverRecoveryTests.swift`
- Test: `Evlin iOSTests/MeteringColdReopenRecoveryTests.swift`
- Test: `Evlin iOSTests/MeteringProductionIntegrationTests.swift`

**Interfaces:**
- Produces one idempotent `ensureCanonicalRollover(owner:observedAt:)`.
- DAM interval end and app/DAM recovery call the same operation.

- [ ] Add failing tests for DAM midnight and cold reopen converging on one rollover work ID.
- [ ] Add a failing test where today's install work is terminal superseded and must be replaced once.
- [ ] Add a failing production-composition test proving the rollover reset adapter is present and does not globally stop monitoring.
- [ ] Run focused tests and verify failures are caused by missing production wiring.
- [ ] Implement the shared preparation entry and production adapter.
- [ ] Wire earned v2 interval end and both recovery entries.
- [ ] Run rollover, cold-reopen, production-integration, callback, and installer suites together.

### Task 3: Durable Per-App Terminal Outbox

**Files:**
- Modify: `Evlin iOS/Services/AppLimitEffectJournal.swift`
- Modify: `Evlin iOS/Services/MeteringProcessEntries.swift`
- Test: `Evlin iOSTests/AppLimitEffectJournalTests.swift`
- Test: `Evlin iOSTests/AppLimitWakeRecoveryTests.swift`

**Interfaces:**
- A journal item with exact durable `localReceipt` remains claimable for transport after rule clear while owner identity remains unchanged.

- [ ] Add a failing test: apply terminal effect, clear/replace the rule, reopen the journal, then require one successful usage submission.
- [ ] Add failing tests for unapplied stale effect and owner switch producing zero network calls.
- [ ] Run the focused tests and verify the applied historical case fails under current-rule fencing.
- [ ] Split execution-current checks from receipt-backed transport checks.
- [ ] Run journal and wake-recovery suites together.

### Task 4: Backend Historical Sample Acceptance

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/child_device.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/app_limit_rules.py`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/api/test_app_limits_endpoint.py`

**Interfaces:**
- Accepts exact-token physical usage for a disabled historical rule without changing rule state.

- [ ] Add a failing test that disables a rule after a preceding sample, posts its exact-token terminal sample, and expects accepted idempotent usage plus unchanged disabled state.
- [ ] Add failing mismatch-token and foreign-device tests.
- [ ] Run the focused backend tests and verify the exact historical case currently returns `rule_cleared`.
- [ ] Implement usage-only historical acceptance after all existing identity and plausibility checks.
- [ ] Run app-limit endpoint, aggregation, command-delivery, and receipt suites together.

### Task 5: Combined Verification

**Files:**
- Modify only test manifests or reports required by existing repository tooling.

- [ ] Run the focused iOS suites from Tasks 1-3 in one invocation.
- [ ] Run generic iOS build and DeviceActivity extension build.
- [ ] Run the focused backend suites from Task 4 in one DB-backed invocation.
- [ ] Inspect diffs and prove unrelated WIP is unstaged and byte-unchanged.
- [ ] Record true-device gates as pending; do not claim release readiness before they pass.

