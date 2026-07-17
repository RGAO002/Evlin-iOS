# Metering Epoch Phase 5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close G-17, G-18, and G-19 so reflection transitions, per-app limit commands, earned-time policy changes, and shared-pool fanout converge per device through durable force-kill-capable delivery and truthful monitor-owner readback.

**Architecture:** The backend owns canonical transition, command, ordering, fanout, and receipt state. The Phase 1 physical result fixes the conservative branch: `EvlinPushApplier` may decode and durably persist newest desired rule/tombstone/policy state, but it never starts or replaces a production `DeviceActivity` monitor and never acknowledges enforcement merely because persistence succeeded. Phase 4's persisted newest-token transaction is the only G-18 ordering authority; the current main-app `AppLimitPlanner` path remains the per-app monitor owner, while Phase 3's Device Epoch Store and recovery driver remain the G-19 earned-policy owner.

**Tech Stack:** Python 3.11, FastAPI, SQLAlchemy 2, PostgreSQL, pytest through the repository virtual environment, Swift 5, XCTest, App Group persistence, DeviceActivity, ManagedSettings, Notification Service Extension, Xcode 26.3.

## Global Constraints

- Work only in `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS` and `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend`; do not create a worktree.
- Before each task, capture `git status --short` in both repositories. Never restore, stage, or edit a pre-existing dirty path unless that exact path is listed by the task and its baseline diff is recorded first.
- Phase 5 is blocked until the canonical Phase 4 handoff reports `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE` and proves persisted latest ordering tokens, clear tombstones, equal-token idempotence, and reordered NSE/wake/poll convergence. Physical completion is not a Phase 5 prerequisite. No Phase 5 task may recreate, alias, adapt, shadow, or bypass that state.
- The binding capability result is `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/research/2026-07-15-metering-monitor-capability-results.md`: DAM and NSE monitor installation were not proven. Production Push code may persist desired state and wake recovery only; it may not call `startMonitoring`, `stopMonitoring`, or claim monitor ownership.
- A command is `enforced` only after the designated monitor owner verifies the requested version and posts owner readback. NSE persistence alone is `persisted_awaiting_owner`, not success.
- `set_limit`, `clear_limit`, and `earned_time_config` remain wire-compatible. Additive ordering/readback fields must decode safely on old clients; no existing endpoint or response field is removed.
- Identity is checked before mutation, before write, after readback, before monitor application, and before acknowledgement. A mismatched child device has zero rule, policy, monitor, shield, receipt, or ack effects.
- Preserve manual, task-pause, reflection, admin, block, and unrelated limit sources byte-for-byte. A command may mutate only its named rule, policy, receipt, or earned source.
- Use literal installed simulator destinations `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1` and `platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1`, with `IPHONEOS_DEPLOYMENT_TARGET=17.6`, `TARGETED_DEVICE_FAMILY='1,2'`, and `-parallel-testing-enabled NO`.
- Pure backend tests use `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest`. Every touched DB suite uses `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py`; a skipped DB test is not evidence.
- Do not push, deploy, upload TestFlight, contact production services, query or mutate a production database, or change APNs credentials. All DB commands in this plan target the guarded disposable local database runner.
- Physical-device, one-release, TestFlight, and Fred-approval rows remain exactly `PENDING` until separately performed. Simulator/unit results cannot promote those rows.
- Every task follows RED -> minimal implementation -> focused GREEN -> full affected regression -> exact-path staging -> one precise commit. Inspect `git diff --cached --check`, `git diff --cached`, and `git diff --cached --name-only` before committing.

## Required Phase 3 Handoff

Phase 5 consumes the Phase 3 completion artifact, not a status token in the Phase 3 plan and not physical completion. These exact files are mandatory:

```text
/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase3_completion.sh
/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase3CompletionVerifierTests.swift
/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/.superpowers/evidence/metering-phase3/report-commit-attestation.json
```

The report status must be exactly `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE`. The Task 29 attestation must bind the report blob hash to the unique report commit and prove `verify_metering_phase3_completion.sh final <report-commit-sha>` exited zero. A check for `**Status:** PASS` in `2026-07-17-metering-epoch-phase-3.md`, a plan review status, a unit test alone, or any physical `PENDING` row is never a blocker substitute and never satisfies this handoff.

## Required Phase 4 Handoff

Phase 5 consumes the exact pinned contracts in `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/plans/2026-07-17-metering-epoch-phase-4.md`. It must not create an alias, adapter type, compatibility store, second owner field, or shadow ordering/tombstone state. If an API required by Phase 5 is genuinely absent, revise Phase 4's single interface and rerun its gate before Phase 5; do not invent a Phase 5 parallel API.

```swift
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

All poll, NSE, and wake ingress calls `AppLimitCommandCoordinator.ingest(_:) -> AppLimitCommandDisposition`. Persistence occurs only inside `AppLimitEpochStore.transaction(source:expectedOwner:_:)`, guarded by `ActiveLockPersistenceLock`; `AppLimitRuleStore` remains only Phase 4's compatibility facade over active slots. Owner identity is the transaction's `expectedOwner` plus the canonical rule/command payload, not a second field added to the envelope by Phase 5.

The Phase 4 completion report path is fixed as
`/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md`.
Its legal handoff status is exactly `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE`; it must identify the exact removal commit for every stale pre-transaction mutation path and keep every unrun physical row `PENDING`. Phase 4 physical completion is neither required nor implied.

Phase 4 Task 17 directly creates this canonical report and binds its verifier/script SHA plus raw log, product, vector, and stale-path-removal evidence. Task 18 separately creates `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-phase4-physical.md` with physical rows `PENDING`; that report supplements but never replaces the Task 17 canonical handoff. No other automated report path is part of the dependency contract.

## File and Ownership Map

| Responsibility | Repository and authoritative files |
|---|---|
| Phase 5 prerequisite and completion verification | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase5_prerequisites.sh`, `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase5_completion.sh` |
| Canonical reflection transition plus delivery | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/reflection_delivery.py` and its route/tool/executor callers |
| Immediate alert plus retry delivery classification | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/app_control_delivery.py` |
| Per-app newest desired state | Phase 4 `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitEpochStore.swift` plus `AppLimitCommandCoordinator`; Phase 5 adds no second token/tombstone authority |
| G-18 monitor-owner recovery and readback | Phase 4 `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitProductionComposition.swift`, `MeteringProcessEntries.swift`, and `AppLimitApplyReceipt` |
| G-19 backend ordering | `Device.metering_policy_delivery_token` and `_insert_earned_time_config_command` in the Backend repository |
| G-19 desired policy and owner readback | Phase 3 `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift` and `EarnedMeteringRecoveryDriver.swift` |
| Push decoding/persistence only | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/NSECommandWireModels.swift` and `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinPushApplier/NotificationService.swift` |
| Cross-stack fanout/readback evidence | Backend disposable-DB tests plus byte-identical `metering_epoch_phase5_vectors.json` fixtures in both repositories |

---

### Task 1: Gate Phase 5 on Phase 3/4 Automated Handoffs

**Repository:** iOS.

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase5_prerequisites.sh`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase5PrerequisiteTests.swift`

**Interfaces:** Consumes the Phase 1 conservative result, the Phase 3 completion report plus Task 29 attestation, and the canonical Phase 4 automated handoff. Produces a fail-closed preflight; it changes no product behavior and never requires physical completion.

- [ ] **Step 1: Write the failing verifier tests**

Add XCTest cases that invoke the verifier against temporary fixture roots and require stable failures for a missing Phase 3 report, missing/invalid Task 29 `report-commit-attestation.json`, a fixture that offers only Phase 3 plan `PASS`, a missing canonical Phase 4 report, the Task 18 physical report offered in place of the canonical handoff, a missing `AppLimitCommandEnvelope`/`AppLimitCommandCoordinator`, a missing clear tombstone assertion, and a Push production source that calls a monitor API outside `#if DEBUG`. Add a positive fixture whose Phase 3 and Phase 4 statuses are both `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE`; it must pass without any physical-complete artifact.

```swift
func test_missingPhase4ReportFailsClosed() throws {
    let result = try runPrerequisiteVerifier(fixture: "missing-phase4-report")
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("phase4_completion_report_missing"))
}

func test_completeFixturePasses() throws {
    XCTAssertEqual(try runPrerequisiteVerifier(fixture: "complete").exitCode, 0)
}
```

- [ ] **Step 2: Run RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase5PrerequisiteTests'
```

Expected RED: the test target cannot find `verify_metering_phase5_prerequisites.sh` and the complete fixture cannot pass.

- [ ] **Step 3: Implement the fail-closed preflight**

The script accepts optional `--ios-root` and `--backend-root` fixture roots, defaults to the two absolute repository paths, and verifies all of the following:

```text
Phase 1 decision contains "not proven / conservative branch"
Phase 3 canonical report status is exactly "AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE"
Phase 3 Task 29 report-commit-attestation JSON binds the report blob and unique report commit
Phase 3 Task 29 verifier script/test exist and final mode is attested zero
no Phase 3 plan PASS token is read or accepted as evidence
Phase 4 canonical report path exists with exactly "AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE"
Phase 4 canonical report binds Task 17 verifier/test, raw log/product/vector hashes, stale-path-removal SHA, --automated success, and --release physical_gate_pending failure
Phase 4 Task 18 physical report, when present, contains only PENDING physical rows and supplements rather than replaces the canonical report
Phase 4 report records newest set/set, set/clear tombstone, equal-token, poll/NSE/wake, and P4V01-P4V20 evidence
the exact Required Phase 4 Handoff symbols exist in production Swift
Push production code has no unguarded DeviceActivityCenter/startMonitoring/stopMonitoring owner call
both repositories have a branch HEAD and the report records immutable prerequisite SHAs
```

No prerequisite is inferred from a passing unit test alone.

- [ ] **Step 4: Run GREEN and the real preflight**

Run the Step 2 command, then:

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
bash scripts/verify_metering_phase5_prerequisites.sh
PHASE4_PLAN='/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/plans/2026-07-17-metering-epoch-phase-4.md'
PHASE5_PLAN='/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/plans/2026-07-17-metering-epoch-phase-5.md'
for symbol in AppLimitCommandKind AppLimitCommandEnvelope AppLimitCommandDisposition AppLimitVersionSlot AppLimitEpochStore AppLimitCommandCoordinator; do
  rg -q "$symbol" "$PHASE4_PLAN"
  rg -q "$symbol" "$PHASE5_PLAN"
done
rg -q 'transaction\(source:expectedOwner:_:\)' "$PHASE4_PLAN"
FORBIDDEN="Versioned""AppLimit|ingest""Desired|next""Desired|mark""Applied|AppLimitCommand""RecoveryDriver"
! rg -n "$FORBIDDEN" "$PHASE5_PLAN"
```

Expected GREEN: fixture tests and exact-symbol cross-checks pass. The real command exits zero when both automated handoffs and immutable attestations are valid while physical rows remain pending and both phases remain not releasable. It must not wait for, infer, or require physical completion.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- scripts/verify_metering_phase5_prerequisites.sh 'Evlin iOSTests/MeteringPhase5PrerequisiteTests.swift'
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'test: gate metering phase 5 prerequisites'
```

---

### Task 2: Route Every Reflection Transition Through One Delivery Helper (G-17)

**Repository:** Backend.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/reflection_delivery.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/parent_chat.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/bigkid_parent.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/parent_agent.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/agent_tools/reflection_tools.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/reflection_executor.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/plan_orchestrator.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_reflection_transition_delivery.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/api/test_bigkid_task_notifications.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/services/test_reflection_executor.py`

**Interfaces:** Produces one queue-before-mutate helper and a request-bound context for sessionless agent tools. The command scheduler supplies one durable command intent, one collapsed silent wake, and one NSE alert; the old reflection-only wake is not a substitute.

```python
class ReflectionTransitionKind(str, Enum):
    propose = "propose"
    cancel = "cancel"
    approve = "approve"
    request_redo = "request_redo"

@dataclass(frozen=True)
class ReflectionTransitionContext:
    session: AsyncSession
    store: BigKidStore

@contextmanager
def bind_reflection_transition_context(context: ReflectionTransitionContext): ...

async def apply_reflection_transition(
    *,
    kind: ReflectionTransitionKind,
    child_device_id: UUID,
    mutate: Callable[[], T],
    context: ReflectionTransitionContext | None = None,
) -> T: ...
```

- [ ] **Step 1: Write table-driven RED coverage**

Cover the five required bypasses separately: chat interception, REST trigger, agent propose, agent cancel, and agent approve. Also cover plan-executor propose/cancel/approve/redo and REST approve/cancel/redo so existing paths cannot retain duplicate bespoke delivery.

For each case assert exactly one expected transition, one command with `shield` for propose/redo or `unshield` for cancel/approve, one scheduler item, and no direct `schedule_reflection_wake`. Inject command queue failure and require `mutate` call count zero. Assert the plan orchestrator no longer sends `lock=True` for cancel/approve.

- [ ] **Step 2: Run RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest -q tests/services/test_reflection_executor.py
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/test_reflection_transition_delivery.py tests/api/test_bigkid_task_notifications.py
```

Expected RED: the five bypasses either emit no command or use bespoke code, and plan cancel/approve incorrectly re-lock.

- [ ] **Step 3: Implement the canonical transition**

`apply_reflection_transition` requires both a bound `SilentWakeScheduler` and a transition context. It calls a non-swallowing `queue_reflection_lockdown` first, verifies a `Command` was flushed, then calls `mutate`. A queue failure therefore cannot mutate reflection state. The request transaction remains responsible for commit; any mutation exception propagates so the command row rolls back.

Bind the context in parent chat, parent agent exec, and REST reflection routes. Convert all reflection executor branches to async and call the helper with the matching kind. Keep notification-feed emission after a successful transition and preserve its existing best-effort behavior.

Add a source-architecture assertion that these consumer files contain no direct calls to `trigger_reflection*`, `ack_reflection`, `parent_cancel_reflection`, `parent_approve_reflection`, or `request_reflection_redo` outside the helper-owned closure sites.

- [ ] **Step 4: Run focused and disposable-DB GREEN**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest -q tests/services/test_reflection_executor.py
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/test_reflection_transition_delivery.py tests/api/test_bigkid_task_notifications.py tests/api/test_reflection_e2e.py
```

Expected GREEN: every transition has one matching durable command/wake intent; no test is skipped; command queue failure leaves the state mutation count at zero.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
git add -- app/services/reflection_delivery.py app/api/routes/parent_chat.py app/api/routes/bigkid_parent.py app/api/routes/parent_agent.py app/services/agent_tools/reflection_tools.py app/services/reflection_executor.py app/services/plan_orchestrator.py tests/test_reflection_transition_delivery.py tests/api/test_bigkid_task_notifications.py tests/services/test_reflection_executor.py
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'fix: unify reflection transition delivery'
```

---

### Task 3: Make Limit and Policy Commands Force-Kill-Capable on the Backend

**Repository:** Backend.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/app_control_delivery.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/app_control_execution.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/earned_time_service.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/lock_escalation.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_app_limit_delivery.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_config.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/api/test_notif_phase4_command_receipt.py`

**Interfaces:** Extends `LOCK_COMMAND_ACTIONS` with `set_limit`, `clear_limit`, and `earned_time_config`. Alert copy says an update was received; it does not assert enforcement.

- [ ] **Step 1: Replace the old silent-only contract with failing tests**

Assert all three actions receive immediate `lock_command_alert` plus silent wake after commit and remain eligible for the 15-second delivery retry only until any durable NSE `pending` transport ack or terminal ack. A Phase 4 `pending/persisted_waiting_for_owner` ack stops alert escalation but leaves the command pollable and unapplied; only truthful owner/superseded readback may make it terminal. Pin exact neutral alert bodies:

```python
assert lock_alert_body("set_limit", "Instagram") == "Instagram limit update received."
assert lock_alert_body("clear_limit", "Instagram") == "Instagram limit removal received."
assert lock_alert_body("earned_time_config", "Screen Time") == "Screen Time policy update received."
```

- [ ] **Step 2: Run RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest -q tests/test_app_limit_delivery.py
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/api/test_notif_phase4_command_receipt.py
```

Expected RED: the current test explicitly excludes set/clear, and config has silent wake only.

- [ ] **Step 3: Implement additive delivery classification**

Add the three actions to `LOCK_COMMAND_ACTIONS`. Keep `set_limit` and `earned_time_config` out of user-facing success receipts until owner readback; alert delivery metadata remains transport evidence only. Ensure `_insert_earned_time_config_command` and both app-limit queue helpers always enqueue through the request scheduler after flush. Delivery code never marks an applied field. The existing ack endpoint may record Phase 4's `pending` transport status, but must retain command polling/owner work until a later `confirmed`, `superseded`, or `failed` terminal readback.

- [ ] **Step 4: Run GREEN and DB controls**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest -q tests/test_app_limit_delivery.py
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/test_earned_time_config.py tests/api/test_notif_phase4_command_receipt.py tests/api/test_command_scoped_fetch.py
```

Expected GREEN: immediate and retry alert tests pass, DB tests have zero skips, a durable NSE pending ack stops duplicate alert escalation while leaving the command pollable, and transport acceptance alone never becomes applied/confirmed.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
git add -- app/services/app_control_delivery.py app/services/app_control_execution.py app/services/earned_time_service.py app/services/lock_escalation.py tests/test_app_limit_delivery.py tests/test_earned_time_config.py tests/api/test_notif_phase4_command_receipt.py
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'fix: deliver metering policy commands through NSE'
```

---

### Task 4: Decode Versioned Limit and Policy Payloads in App and Push

**Repository:** iOS.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/APIClient.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/CommandModels.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/NSECommandWireModels.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/CommandPoller.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/NSEVersionedCommandWireTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitWireContractTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedConfigCommandTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**Interfaces:** Consumes Phase 4's existing positive `orderingToken: Int64` mapping for `LimitRule`, `ClearLimit`, poll, and NSE without changing it. Adds only `EarnedTimeConfigCommand` with `policyRevision`, `orderingToken`, owner, date/timezone, pool/cap, remaining, bucket, and selected-set identity. App and Push map the same bytes to the same shared command models.

- [ ] **Step 1: Write failing byte-level decode tests**

Keep Phase 4's canonical set/clear fixtures green, then decode canonical config JSON through both `PollCommandDTO -> CommandPoller.lockCommand` and `NSECommandWireDecoder`. Assert structural equality, full-width 64-bit tokens, snake-case fields, fractional ISO-8601 dates, owner ID, and old config payload compatibility. Missing config ordering token is accepted only for old non-NSE foreground compatibility and maps to no versioned application authority; Phase 5 does not weaken Phase 4's required positive set/clear token.

- [ ] **Step 2: Run RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/NSEVersionedCommandWireTests' -only-testing:'Evlin iOSTests/AppLimitWireContractTests' -only-testing:'Evlin iOSTests/EarnedConfigCommandTests'
```

Expected RED: all Phase 4 set/clear wire tests remain green, while Push drops `earned_time_config` and app models omit its policy fields.

- [ ] **Step 3: Implement one shared mapped shape**

Extend `NSEWireCommand` with the optional earned-policy payload and pass it into `LockCommand`. Extend app DTO mapping without changing unknown-field compatibility or any Phase 4 app-limit type/disposition. Add shared model membership only where required; `APIClient.swift` remains app-only.

- [ ] **Step 4: Run GREEN on iPhone and iPad, then compile Push**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/NSEVersionedCommandWireTests' -only-testing:'Evlin iOSTests/AppLimitWireContractTests' -only-testing:'Evlin iOSTests/EarnedConfigCommandTests'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/NSEVersionedCommandWireTests'
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
```

Expected GREEN: app and Push observations are byte-equivalent and the extension target compiles.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- 'Evlin iOS/Services/APIClient.swift' 'Evlin iOS/Models/CommandModels.swift' 'Evlin iOS/Models/NSECommandWireModels.swift' 'Evlin iOS/Services/CommandPoller.swift' 'Evlin iOSTests/NSEVersionedCommandWireTests.swift' 'Evlin iOSTests/AppLimitWireContractTests.swift' 'Evlin iOSTests/EarnedConfigCommandTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'feat: decode versioned policy commands in push'
```

---

### Task 5: Persist Newest Limit Rule or Tombstone in NSE Without False Ack (G-18)

**Repository:** iOS.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinPushApplier/NotificationService.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/NSECommandWireModels.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitProductionComposition.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase5G18DeliveryTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/NSEAppLimitPersistenceTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitCommandCoordinatorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitEpochStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`

**Interfaces:** Consumes Phase 4's `AppLimitCommandEnvelope`, `AppLimitCommandDisposition`, `AppLimitCommandCoordinator`, and `AppLimitEpochStore` unchanged. It adds only the mapping from Task 3's force-kill alert payload into that existing ingress. Phase 5 creates no app-limit state type, store, alias, adapter, owner field, or coordinator.

- [ ] **Step 1: Write failing ordering and acknowledgement tests**

Drive Task 3's real alert envelope for set(2), set(1), clear(3), set(2), clear(3) through `NSECommandWireDecoder`, `AppLimitCommandCoordinator.ingest`, and the real `AppLimitEpochStore`. Assert final tombstone token 3; exactly two accepted slot mutations; zero monitor starts/stops; zero shield/usage mutation; `acceptedNeedsOwner` and `duplicatePending` post Phase 4's `pending/persisted_waiting_for_owner` transport ack; `superseded` posts its terminal ack; `duplicateApplied` may replay the existing `AppLimitApplyReceipt` without reapplying; `equalTokenConflict` fails with zero mutation.

Inject owner swap, lock failure, atomic-write failure, and readback mismatch. Every fault has zero ack and preserves prior bytes.

- [ ] **Step 2: Run RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase5G18DeliveryTests' -only-testing:'Evlin iOSTests/NSEAppLimitPersistenceTests' -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests' -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests'
```

Expected RED: Phase 4's direct command fixtures pass, but Task 3's force-kill alert envelope is not yet mapped into the pinned coordinator path.

- [ ] **Step 3: Implement conservative NSE ingress**

Map set/clear transport bytes into the exact Phase 4 `AppLimitCommandEnvelope`, including its canonical `payloadDigest`, `receivedAt`, `.notificationServiceExtension` source, and existing `AppLimitRule?`. Validate the authenticated/expected owner before calling only `AppLimitCommandCoordinator.ingest`. Do not call `ActionExecutor`, `AppLimitPlanner`, `DeviceActivityCenter`, `ActiveLockStore`, or any second persistence API.

Use Phase 4's ack mapping verbatim. `acceptedNeedsOwner` and `duplicatePending` post `status=pending`, `detail=persisted_waiting_for_owner`; this stops alert escalation but leaves the command pollable and never claims enforcement. `superseded` is terminal with its latest token, `duplicateApplied` confirms from the persisted receipt, and `equalTokenConflict` fails closed. No disposition is renamed in Phase 5.

- [ ] **Step 4: Run GREEN and Release ownership scan**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase5G18DeliveryTests' -only-testing:'Evlin iOSTests/NSEAppLimitPersistenceTests' -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests' -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests' -only-testing:'Evlin iOSTests/NSEUnshieldTests'
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
```

Then preprocess/inspect the Release Push product and require no production `startMonitoring` or `stopMonitoring` reference attributable to Phase 5. The existing DEBUG capability probe remains compile-time excluded.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- 'EvlinPushApplier/NotificationService.swift' 'Evlin iOS/Models/NSECommandWireModels.swift' 'Evlin iOS/Services/AppLimitProductionComposition.swift' 'Evlin iOSTests/MeteringPhase5G18DeliveryTests.swift' 'Evlin iOSTests/NSEAppLimitPersistenceTests.swift' 'Evlin iOSTests/AppLimitCommandCoordinatorTests.swift' 'Evlin iOSTests/AppLimitEpochStoreTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift'
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'feat: persist newest app limit command in NSE'
```

---

### Task 6: Apply and Acknowledge Limit Versions Only From the Monitor Owner

**Repository:** iOS.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitProductionComposition.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringProcessEntries.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/CommandPoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/AppLimitOwnerReadbackClient.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase5G18OwnerReadbackTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitWakeRecoveryTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AppLimitEffectJournalTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/CommandPollerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**Interfaces:** Phase 4's `AppLimitProductionComposition` and process entries remain the single owner-recovery path. The current main-app planner is the only proven per-app monitor installer; DAM continues callback handling and acquires no Phase 5 installation ownership. Phase 5 adds only a network client that confirms the already durable Phase 4 receipt.

```swift
protocol AppLimitOwnerReadbackClient: Sendable {
    func confirm(commandID: UUID, receipt: AppLimitApplyReceipt) async throws
}
```

- [ ] **Step 1: Write crash-boundary RED tests**

Extend Phase 4's real wake recovery tests for persisted set, persisted clear, stale set after clear, duplicate delivery, crash before owner claim, crash after planner verification but before the `AppLimitApplyReceipt` transaction, crash after durable receipt but before network confirm, confirm retry, planner quota failure, and identity switch. Require no `confirmed`/enforced ack until the exact current `AppLimitApplyReceipt` reads back from `AppLimitEpochStore`.

- [ ] **Step 2: Run RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase5G18OwnerReadbackTests' -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests' -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests'
```

Expected RED: Phase 4 can recover and persist an applied receipt, but no Phase 5 client posts the Task 3 command's final owner confirmation and resumes it after a network crash.

- [ ] **Step 3: Implement owner application and durable readback**

Extend the existing Phase 4 owner-work finalizer reached from app startup, scene activation, silent wake, and command poll. It must not reload or mutate through another store. After Phase 4's effect journal commits and reads back the exact `AppLimitApplyReceipt`, `AppLimitOwnerReadbackClient` posts:

```json
{
  "status": "confirmed",
  "detail": {
    "verb": "set_limit",
    "rule_id": "<uuid>",
    "ordering_token": 3,
    "application_state": "applied",
    "owner": "main_app",
    "source": "monitor_owner_readback"
  }
}
```

Clear derives `application_state=cleared` from `receipt.commandKind`; set derives `applied`. An applied-but-unconfirmed command remains represented by the same Phase 4 slot/work/receipt and retries only that ack. A planner/effect failure stays pending and reports diagnostics without a receipt, confirmed ack, or token advance. Phase 5 adds no owner record or recovery queue.

- [ ] **Step 4: Run focused, overlap, and full-target GREEN**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase5G18OwnerReadbackTests' -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests' -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' -only-testing:'Evlin iOSTests/AppLimitPlannerTests' -only-testing:'Evlin iOSTests/ActiveLockStoreLimitReconcileTests' -only-testing:'Evlin iOSTests/CommandPollerTests'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase5G18OwnerReadbackTests' -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests'
```

Expected GREEN: every crash resumes one version; stale set never resurrects a clear; unrelated sources remain byte-identical.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- 'Evlin iOS/Services/AppLimitProductionComposition.swift' 'Evlin iOS/Services/MeteringProcessEntries.swift' 'Evlin iOS/Services/CommandPoller.swift' 'Evlin iOS/Services/BigKidStatePoller.swift' 'Evlin iOS/Services/AppLimitOwnerReadbackClient.swift' 'Evlin iOSTests/MeteringPhase5G18OwnerReadbackTests.swift' 'Evlin iOSTests/AppLimitWakeRecoveryTests.swift' 'Evlin iOSTests/AppLimitEffectJournalTests.swift' 'Evlin iOSTests/CommandPollerTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'feat: acknowledge app limits from monitor owner'
```

---

### Task 7: Add Monotonic Earned-Policy Delivery Ordering (G-19 Backend)

**Repository:** Backend.

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/alembic/versions/2026_07_17_meter_policy_delivery.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/db/models/device.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/earned_time_service.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_day_reconciler.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_config.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_day_reconciler.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_policy_delivery_ordering.py`

**Interfaces:** Adds `Device.metering_policy_delivery_token: int`, default 0. `_insert_earned_time_config_command` locks the device row, increments exactly once, and writes nested `earned_time_config.ordering_token`; `policy_revision` remains policy identity and is not treated as order.

- [ ] **Step 1: Write failing migration and concurrency tests**

Assert migration upgrade/downgrade, default zero, two concurrent same-device inserts produce tokens 1 and 2, different devices each begin at 1, retries preserve the original command token, all config emitters use the helper, and command payload construction never uses timestamp or UUID lexical order.

- [ ] **Step 2: Run RED through the guarded DB runner**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/test_metering_policy_delivery_ordering.py tests/test_earned_time_config.py tests/test_metering_day_reconciler.py
```

Expected RED: the column and nested ordering token do not exist.

- [ ] **Step 3: Implement row-locked token allocation**

Use migration revision `2026_07_17_meter_policy_delivery` with down revision `2026_07_17_meter_epoch_conservative`. Add a nonnegative check constraint. Inside `_insert_earned_time_config_command`, reload the device with `SELECT ... FOR UPDATE`, increment, deep-copy the payload, set `earned_time_config["ordering_token"]`, then insert the command. Reconciler and request paths continue calling only this helper.

- [ ] **Step 4: Run GREEN and the complete touched DB set**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/test_metering_policy_delivery_ordering.py tests/test_earned_time_config.py tests/test_metering_day_reconciler.py tests/test_metering_epoch_phase2_integration.py
```

Expected GREEN: no skips, strict per-device monotonic order, and no duplicate allocation on delivery retry.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
git add -- alembic/versions/2026_07_17_meter_policy_delivery.py app/db/models/device.py app/services/earned_time_service.py app/services/metering_day_reconciler.py tests/test_earned_time_config.py tests/test_metering_day_reconciler.py tests/test_metering_policy_delivery_ordering.py
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'feat: order earned policy delivery per device'
```

---

### Task 8: Persist and Apply Earned Policy Through Device Epoch Ownership (G-19 iOS)

**Repository:** iOS.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochWire.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinPushApplier/NotificationService.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/CommandPoller.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringPolicyOwnerReadbackClient.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPolicyInboxTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPolicyOwnerReadbackTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/DeviceEpochStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`

**Interfaces:** Bumps `DeviceEpochStoreState.currentSchemaVersion` from 4 to 5 and adds one owner-fenced desired-policy/readback lane inside the existing root.

```swift
nonisolated struct MeteringDesiredPolicy: Codable, Equatable, Sendable {
    let commandID: UUID
    let ownerChildDeviceID: UUID
    let orderingToken: Int64
    let policyRevision: String
    let usageDate: String
    let canonicalTimezone: String
    let dailyPoolMinutes: Int
    let deviceCapMinutes: Int
    let remainingMinutes: Int?
    let enforcementSetID: UUID?
    let receivedAt: Date
    var appliedAt: Date?
    var ackedAt: Date?
}
```

`MeteringPolicyOwnerReadbackClient` is a network-only interface that posts the existing command ID plus verified Device Epoch policy readback. It owns no persistence, ordering, scheduling, or recovery state.

- [ ] **Step 1: Write failing persistence and owner-readback tests**

Cover config(2), config(1), duplicate(2), config(3); owner mismatch; write/readback faults; crash after desired persist; same policy no-churn; changed policy creates fresh generation, epoch, and route; crash after activation before ack; and app poll delivery racing NSE delivery. Assert Push writes pool/cap/policy into the App Group root immediately but performs zero monitor calls and zero ack until the active generation/route read back the same revision and token.

- [ ] **Step 2: Run RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPolicyInboxTests' -only-testing:'Evlin iOSTests/MeteringPolicyOwnerReadbackTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests'
```

Expected RED: Device Epoch Store schema 4 has no desired policy and NSE rejects config.

- [ ] **Step 3: Implement newest-wins policy ingress and recovery**

NSE decodes the config, verifies body owner equals fetched/mirrored owner, and transactionally stores only a greater ordering token. Older config gets terminal `superseded` readback; equal pending uses a transport-pending ack but remains owner work; equal applied replays the stored owner readback. The recovery driver consumes newest desired policy using the existing Phase 3 policy-change replacement transaction and install/verify/activate sequence. It marks `appliedAt` only when the active generation, epoch, route, coverage, pool, and cap all read back the requested policy; then `MeteringPolicyOwnerReadbackClient` posts owner confirmation and stores `ackedAt`.

The foreground `CommandPoller` calls the same ingress/recovery APIs. Delete the old unconditional `earned_time_config` confirmed ack and direct `EarnedBudgetArming.armIfReady()` branch; do not create a second policy store or scheduling path.

- [ ] **Step 4: Run GREEN and all owner recovery controls**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPolicyInboxTests' -only-testing:'Evlin iOSTests/MeteringPolicyOwnerReadbackTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests' -only-testing:'Evlin iOSTests/EarnedConfigCommandTests'
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
```

Expected GREEN: policy bytes persist under force-kill-capable Push execution, only the Phase 3 owner changes monitoring, and ack follows verified activation.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' 'Evlin iOS/Services/MeteringEpochWire.swift' 'EvlinPushApplier/NotificationService.swift' 'Evlin iOS/Services/CommandPoller.swift' 'Evlin iOS/Services/MeteringPolicyOwnerReadbackClient.swift' 'Evlin iOSTests/MeteringPolicyInboxTests.swift' 'Evlin iOSTests/MeteringPolicyOwnerReadbackTests.swift' 'Evlin iOSTests/DeviceEpochStoreTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift'
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'feat: apply earned policy through epoch ownership'
```

---

### Task 9: Prove Per-Device Fanout, Receipt, Source, and Attribution in Real Rows

**Repository:** Backend.

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_phase5_vectors.json`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_phase5_delivery.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_lock_receipts.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_day_reconciler.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_phase2_integration.py`

**Interfaces:** Produces P5V01-P5V12 and real disposable-DB assertions for every target device. A stopped counter or APNs 200 is never accepted as shield evidence.

- [ ] **Step 1: Write failing integrated scenarios**

Use two enrolled child devices A/B and assert:

```text
P5V01-P5V05: set/clear newest desired, duplicate, superseded, and owner readback
P5V06-P5V07: earned config newest desired and owner readback
P5V08: A device cap -> A meter terminal, A earned source + receipt, B unchanged
P5V09: shared pool exhaustion -> A/B meters terminal, distinct A/B sources and receipts
P5V10: B fanout failure -> A remains acknowledged, B alone retries, no duplicate A command
P5V11: A usage changes shared pool and A cap only; reverse for B
P5V12: owner mismatch and unverified persistence have zero applied acknowledgement
```

Post real `/child/ack` owner-readback payloads and query `Command`, `EarnedTimeLockCommand`, device day, child day, bank ledger, and `Device.last_effective_state`. Require each durable shield snapshot to contain the expected `earnedTime` or `.limit` source and command/record identity.

- [ ] **Step 2: Run RED through disposable PostgreSQL**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/test_metering_phase5_delivery.py tests/test_earned_time_lock_receipts.py tests/test_metering_day_reconciler.py tests/test_metering_epoch_phase2_integration.py
```

Expected RED: owner readback fields and full per-device source/receipt assertions are absent.

- [ ] **Step 3: Add only missing reconciliation/readback behavior**

Keep Phase 2 durable receipt reconciliation as authority. Extend ack detail validation and readback projection only as needed to distinguish `persisted_awaiting_owner`, `applied`, `cleared`, and `superseded`. Partial retry recomputes desired receipts from rows, never process-local state, and targets only missing/unacknowledged devices.

- [ ] **Step 4: Run GREEN and the full limits DB runner**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py
```

Expected GREEN: every configured DB suite passes without skips and P5V01-P5V12 query real rows.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
git add -- tests/fixtures/metering_epoch_phase5_vectors.json tests/test_metering_phase5_delivery.py tests/test_earned_time_lock_receipts.py tests/test_metering_day_reconciler.py tests/test_metering_epoch_phase2_integration.py
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'test: prove metering phase 5 fanout readback'
```

---

### Task 10: Mirror Phase 5 Delivery Vectors Through Production Swift

**Repository:** iOS.

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/Fixtures/metering_epoch_phase5_vectors.json`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochPhase5VectorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochVectorCoverageTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**Interfaces:** Consumes the exact Backend fixture bytes and production Push decoder, Phase 4 coordinator/epoch store/production composition, Device Epoch Store, earned recovery driver, planner fake, and both Phase 5 readback-client fakes. Produces Swift P5V01-P5V12 observations with full effects.

- [ ] **Step 1: Add the fixture parity and production-path tests**

Copy the backend fixture byte-for-byte. Hash both absolute files and require equality. For every vector assert desired/applied token, active rule/tombstone, desired/applied policy, monitor calls, persisted shield source, ack count/detail, and owner. Rejected/pending vectors assert zero monitor, shield, and ack effects.

- [ ] **Step 2: Run RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochPhase5VectorTests' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests'
```

Expected RED: the Phase 5 fixture/suite is missing and the production path cannot execute all IDs.

- [ ] **Step 3: Complete only missing adapters**

Do not add a test-only evaluator. Route fixture inputs through `NSECommandWireDecoder`, `AppLimitCommandCoordinator`, `AppLimitEpochStore`, `AppLimitProductionComposition`, `DeviceEpochStore`, `EarnedMeteringRecoveryDriver`, `AppLimitOwnerReadbackClient`, and `MeteringPolicyOwnerReadbackClient` fakes. Add missing target membership only; no Phase 4 alias or adapter is permitted.

- [ ] **Step 4: Run GREEN on both installed destinations**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochPhase5VectorTests' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochPhase5VectorTests'
```

Expected GREEN: all 12 IDs execute through production symbols on iPhone and iPad, and fixture hashes match.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- 'Evlin iOSTests/Fixtures/metering_epoch_phase5_vectors.json' 'Evlin iOSTests/MeteringEpochPhase5VectorTests.swift' 'Evlin iOSTests/MeteringEpochVectorCoverageTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'test: mirror metering phase 5 delivery vectors'
```

---

### Task 11: Record Automated Evidence Without Crossing Physical Gates

**Repository:** iOS.

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase5_completion.sh`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase5CompletionVerifierTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-5-completion.md`

**Interfaces:** Produces hash-attested automated evidence and an honest `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE` report. It cannot perform or promote physical/release work.

- [ ] **Step 1: Write failing verifier fixtures**

Require failures for a missing G-17 path, absent Phase 4 dependency SHA, fixture mismatch, any Push monitor-owner symbol in Release, an owner ack before application, missing A/B source or receipt, skipped DB output, missing simulator result, or any physical row other than `PENDING`.

- [ ] **Step 2: Run RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase5CompletionVerifierTests'
```

Expected RED: verifier and report do not exist.

- [ ] **Step 3: Implement and run the automated gate**

The verifier runs Task 1 preflight; all focused Swift suites; the full iPhone and iPad test target; the full Backend disposable-DB runner; byte parity; exact task-subject ancestry; and Release builds of App, DAM, Report, Shield Config, Push, and XCTest. It requires six nonempty Mach-O products and proves the Push Release product has no Phase 5 monitor-owner path.

The report contains exact commit SHAs and this table:

| Gate | Required evidence | Status |
|---|---|---|
| G-17 five bypasses | table-driven canonical helper plus real command/wake rows | AUTOMATED PASS or FAILED |
| G-18 newest delivery | P5V01-P5V05, Phase 4 tombstone SHA, Push persistence | AUTOMATED PASS or FAILED |
| G-18 owner readback | verified planner state before exact ack | AUTOMATED PASS or FAILED |
| G-19 persistence/readback | P5V06-P5V07, policy token, active route readback | AUTOMATED PASS or FAILED |
| Multi-device fanout | P5V08-P5V11, A/B source and receipt rows | AUTOMATED PASS or FAILED |
| Force-killed set/clear physical | real device App Group capture and owner ack | PENDING |
| Force-killed config physical | real device policy bytes and owner activation ack | PENDING |
| DEBUG one-minute per-app threshold | no immediate shield, one real-use shield | PENDING |
| Two-device attribution smoke | A then B production bucket with distinct own-cap bars | PENDING |
| TestFlight overnight | two force-killed devices across canonical midnight | PENDING |
| Physical 17.6 minimum floor | install/start/callback/stop and horizon behavior | PENDING |

The verifier rejects `PHYSICAL PASS`, `RELEASABLE`, or a completion claim while any physical row is pending.

- [ ] **Step 4: Run final automated verification**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
bash scripts/verify_metering_phase5_completion.sh pre-report
```

Expected GREEN: automated rows pass with raw-log hashes; physical rows remain `PENDING`; status remains not releasable. No push, deploy, TestFlight upload, APNs production send, or production DB access occurs.

- [ ] **Step 5: Commit exact report/verifier files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- scripts/verify_metering_phase5_completion.sh 'Evlin iOSTests/MeteringPhase5CompletionVerifierTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-5-completion.md
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: record metering phase 5 automated evidence'
```

## Automated Completion Boundary

Tasks 1-11 may be completed automatically in local repositories. `AUTOMATED PASSED` requires exact Phase 3/4 dependency SHAs, all G-17 paths, P5V01-P5V12 in both languages, full disposable-DB coverage without skips, both literal simulators, six Release products, and no Push production monitor ownership.

This does not complete or release Phase 5. The force-killed set/clear and config readbacks, real one-minute per-app threshold, two-device attribution, TestFlight overnight, and physical 17.6 rows remain human/device/release gates. This plan contains no command that can mark them passed and no command that pushes, deploys, uploads TestFlight, or touches production data.

## Requirements Trace

| Requirement | Owning tasks |
|---|---|
| Strict Phase 4 newest-token/tombstone dependency | 1, 5, 6, 11 |
| G-17 five bypasses and existing reflection paths | 2 |
| G-18 immediate force-kill-capable transport | 3-5 |
| G-18 truthful monitor-owner readback | 5-6, 9-11 |
| G-19 monotonic delivery, App Group persistence, owner readback | 3-4, 7-8, 10-11 |
| Shared-pool fanout, receipt, source, attribution, partial retry | 9-11 |
| Conservative branch and Push no-owner proof | 1, 5, 8, 11 |
| Physical and release gates remain pending | 11 and Automated Completion Boundary |

## Self-Review Checklist

- **Coverage:** G-17, G-18, G-19, Phase 4 dependency, fanout, source, receipt, attribution, partial retry, and all physical gates map to named tasks.
- **Ordering:** Backend command delivery never becomes application truth; NSE persistence precedes owner application; owner verification precedes ack.
- **Single authority:** Phase 4 owns per-app token/tombstone state; Device Epoch Store owns earned policy/generation state; no Phase 5 shadow store exists.
- **Commands:** Every Python test uses `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python`; DB tests use the guarded disposable runner; both simulator destinations are literal and installed.
- **Commit integrity:** Each task stages exact files in one repository and has one precise commit subject. Cross-repository work is split into separate tasks/commits.
- **Human boundary:** all real-device, TestFlight, release, and approval work is `PENDING`; no prohibited operation appears as an executable step.
