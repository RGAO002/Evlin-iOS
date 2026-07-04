# Task-Gated Lock — Implementation Plan

> **For agentic workers:** Execute task-by-task with direct TDD (superpowers:executing-plans conventions). Steps use checkbox (`- [ ]`) syntax for tracking. Do NOT use subagent-driven execution for this plan.
>
> **IMPLEMENTER IRON RULE (binding):** You implement this yourself. Do NOT use the Agent/Task tool. Do NOT delegate any task, sub-step, test-write, or verification to another agent. No spawning parallel workers. Each task is written to be executed directly by one implementer in one session, TDD-first, with the exact commands given.

**Goal:** When the kid has ANY incomplete task for today AND the Daily Screen Time rule is enabled, auto-lock the Locked set (equivalent to the parent green Lock button) with shield source `taskPause`; usage counting is already paused for all three meters in that state, so no time is deducted. When ALL of today's tasks are complete, auto-unlock (strip only the `task_pause` claim) and resume metering. Parent manual Lock/Unlock overrides the task lock (precedence: manual > taskPause); after a parent unlock, do not re-lock for tasks for the rest of that day.

**Order matters — the two wire tasks (1, 2) first; they are prerequisites for every shield/unshield.**

**Architecture:**
- **The usage-counting half already ships.** `usage_counting_allowed` gates earned-time ingest (`earned_time.py:72`), per-app ingest (`child_device.py:2356`), and bigkid time-consumption (`bigkid_child.py:392`); each returns an uncounted snapshot when there is any incomplete task. This plan adds ONLY the shield side + parent-override precedence + the wire plumbing for a new `task_pause` provenance.
- iOS (`Evlin-iOS`, branch `calendar-in-chat`): add `.taskPause` to the `ShieldSource` enum; map wire `"task_pause"` → `.taskPause` in the two `ActionExecutor` seams. (Kid-side "Finish today's tasks to unlock" copy already exists in `BigKidHomeView`.)
- Backend (`Evlin-Backend`, same branch): extend the `lock_source`/`unlock_sources` Literals to include `"task_pause"`; add `EarnedTimeDay.task_lock_suppressed_at` + `EarnedTimeDeviceDay.task_lock_command_id` columns (one migration); add a centralized `reconcile_task_lock()` service that queues shield/unshield of the Locked set off the post-mutation `usage_counting_allowed` state; call it from every task-mutating route; make the parent `unlock-selected` route strip `task_pause` and set the suppression flag; make `lock-selected` (manual) win.

**Tech Stack:** Swift, XCTest; FastAPI, SQLAlchemy async, asyncpg, Alembic, pytest(+asyncio, DB-gated).

---

## Global Constraints

- iOS repo: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS` (Task 3). Backend repo: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend` (Tasks 1, 2, 4, 5, 6, 7). Both on branch `calendar-in-chat`.
- **iOS tests:** `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' test`, filtered via `-only-testing:`.
- **Backend DB tests** require `EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test` (they skip without it) and the venv: `source .venv/bin/activate`.
- Commits include ONLY the files named in each task. Never stage `.env`, `xcuserstate`, or `.DS_Store`. Never stage unrelated `project.pbxproj` churn beyond target-membership additions. **Do NOT push either repo** — the user controls pushes (backend push auto-deploys to Render).
- **Backend whole-suite check:** after each backend task run `python -m pytest -q` and confirm no NEW reds vs the pre-task baseline (there are known pre-existing unrelated reds in the app_control/fastpath/catalog/saved_list suite — those are baseline, not regressions).
- **W1 + PL + Fix4 regression gates (must stay green):**
  - Backend five suites: `test_config_change_commands.py`, `test_earned_time_policy_summary.py`, `test_earned_time_remaining_recompute.py`, `test_screen_time_events_api.py`, `test_earned_time_auto_lock.py`.
  - PL two functions: `tests/test_catalog_list_routes.py::test_upload_catalog_list_persists_all_selected`, `tests/test_selected_set_lock.py::test_lock_command_payload_carries_all_selected_regardless_of_member_count`.
  - Fix4 additions: `tests/test_earned_time_config.py` (14 tests).
  - iOS ten classes: `CommandPollerEffectiveStateTests`, `CurrentRestrictionsReaderTests`, `DeviceIdentityTests`, `ScreenTimeEventUploaderTests`, `EarnedSampleReporterTests`, `LockedSetFullCoverageTests`, `EarnedBudgetSchedulerTests`, `BigKidStatePollerTests`, `EarnedGateTautologyTests`, `ArmGenerationTests`.
- **Concurrent-session caution:** a second session may share the `ale_test` DB AND the `.superpowers/sdd/*brief*.md` filenames. Prefix any scratch brief you create with `taskgate-`.

### Semantic rules (binding)
1. **Manual locks survive raises/unlocks/task-completion.** Task-lock reconciliation strips ONLY the `task_pause` source (`unlock_sources=["task_pause"]`); a `.manual` or `.earnedTime` shield is never touched.
2. **Manual overrides task-pause.** A parent unlock-selected strips `task_pause` (among others) AND sets a per-day `task_lock_suppressed_at` on the `EarnedTimeDay`; while set, `reconcile_task_lock` refuses to re-lock for tasks for the rest of that day.
3. **"Has incomplete tasks today" == `usage_counting_allowed()==False`.** This is vacuously "all done" (no lock) for an empty task list — a child with zero tasks is NOT task-locked. Reuse the existing gate; do not re-derive.
4. **Level-triggered, not edge-triggered.** `reconcile_task_lock` computes the desired shield state from current facts (gate + config-enabled + suppression flag + already-queued command id) and converges to it idempotently, so a missed transition or a multi-worker race self-heals on the next task mutation.

### Precedence (design spec Part C)
`manual > account/admin-disabled > earned-pool-exhausted > device-cap-exhausted > per-app-exhausted > task-pause`. Shields union; the reason shown is the highest-precedence hit. Task-pause is LAST — it never overrides a manual/earned/cap lock, and stripping `task_pause` never removes a manual/earned shield.

---

## File Structure

**Backend (Evlin-Backend):**
- **Modify** `app/services/app_control_execution.py` — Task 1 (extend `lock_source`/`unlock_sources` Literals to include `"task_pause"` at :425-426 and :954-955).
- **Modify** `app/api/routes/child_device.py` — Task 1 (`ParentLockSelectedRequest.source` Literal :1791), Task 6 (`unlock-selected` strips `task_pause` + sets suppression flag :1876-1990), Task 5 (task-mutating helpers if any live here — none; skip).
- **Create** one `alembic` migration adding `evlin_earned_time_days.task_lock_suppressed_at` AND `evlin_earned_time_device_days.task_lock_command_id` — Task 4.
- **Modify** `app/db/models/earned_time.py` — Task 4 (both columns).
- **Modify** `tests/test_earned_time_models.py` — Task 4 (expected-columns pins).
- **Create** `app/services/task_lock_service.py` — Task 5 (`reconcile_task_lock`).
- **Modify** `app/api/routes/bigkid_parent.py` — Task 5 (call reconcile after `review_task` approve/redo, `create_task`, `delete_task`, `respond_bypass` approve/deny; import `bind_request_scheduler`).
- **Modify** `app/api/routes/bigkid_child.py` — Task 5 (call reconcile after `create_bypass` if it changes done-count; it does not change status — verify and likely skip; `submit_evidence` goes to `submitted` not `done` — skip).
- **Modify** `app/services/task_executor.py` — Task 5 (chat/plan executor task mutations: `_run_assign` :96, `_run_delete` :153, `_run_approve` :244, `_run_request_redo` :293 → call reconcile after persistence).
- **Modify** `app/api/routes/parent_actions.py` — Task 6 (`/parent/actions/{action_id}/revert` :25/:62 — Undo mutates tasks directly today, so add session/background task plumbing, persist the inverse mutation, and re-run reconcile).
- **Create** `tests/test_task_lock_service.py` — Task 5.
- **Create** `tests/test_task_gated_lock_routes.py` — Task 6/7 (end-to-end route transitions + manual override + suppression).
- **Modify** `tests/test_selected_set_lock.py` — Task 1 (append a `task_pause` provenance round-trip test).

**iOS (Evlin-iOS):**
- **Modify** `Evlin iOS/Models/ShieldRecord.swift` — Task 3 (`ShieldSource` add `case taskPause`).
- **Modify** `Evlin iOS/Services/ActionExecutor.swift` — Task 3 (`shieldSources(fromWireLockSource:)` :672 + unshield loop :772 map `"task_pause"`).
- **Create** `Evlin iOSTests/TaskPauseShieldMappingTests.swift` — Task 3.

---

## Task 1: Backend — extend wire provenance to accept `task_pause`

**Why:** `lock_source`/`unlock_sources` are `Literal["manual","earned_time"]` at `app_control_execution.py:425-426` and `:954-955`; `ParentLockSelectedRequest.source` is `Literal["manual","earned_time"]` at `child_device.py:1791`. A `task_pause` shield cannot be queued or stripped until these accept the value. The value is threaded into the `list`/`all` payload target verbatim (`:983-986`, `:1034-1037`), so no other backend change is needed for the wire to carry it.

**Files:**
- Modify `app/services/app_control_execution.py` (:425-426, :954-955 — add `"task_pause"` to both Literals in both the public `queue_app_control` and the internal `_queue_app_control_list` signatures).
- Modify `app/api/routes/child_device.py` (:1791 — add `"task_pause"` to `ParentLockSelectedRequest.source`).
- Modify `tests/test_selected_set_lock.py` (append a round-trip test).

- [ ] **Step 1: Write the failing test** — append to `tests/test_selected_set_lock.py` (same DB-gated header + seed helpers already in that file):
  ```python
  async def test_lock_command_payload_carries_task_pause_lock_source(session):
      # Seed family/child/device + an active Locked-set list with >=1 token.
      # Call queue_app_control(..., target=<list>, verb="shield",
      #   lock_source="task_pause"); assert the queued Command.payload
      #   top-level lock_source == "task_pause" AND target.lock_source == "task_pause".

  async def test_unshield_payload_carries_task_pause_in_unlock_sources(session):
      # queue_app_control(..., verb="unshield", unlock_sources=["task_pause"]);
      # assert payload unlock_sources == ["task_pause"].
  ```
  Model these on the existing `test_lock_command_payload_carries_all_selected_regardless_of_member_count` in the same file (reuse its seed helpers verbatim).

- [ ] **Step 2: Verify it fails**
  ```bash
  cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
  source .venv/bin/activate
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_selected_set_lock.py -k task_pause -v
  ```
  Expected: FAIL — pydantic/Literal validation rejects `"task_pause"` OR the type checker forbids it. (If Literal is not runtime-enforced here, the test may pass trivially; in that case keep it as a regression guard and proceed — the real enforcement is the Task 6 route Literal.)

- [ ] **Step 3: Extend the Literals** — in `app_control_execution.py`, change both occurrences (:425-426 public, :954-955 internal) of
  `Literal["manual", "earned_time"]` → `Literal["manual", "earned_time", "task_pause"]`
  for BOTH `lock_source` and `unlock_sources` element type. In `child_device.py:1791` change `source: Literal["manual", "earned_time"] = "manual"` → `Literal["manual", "earned_time", "task_pause"]`.

- [ ] **Step 4: Run tests + suite**
  ```bash
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_selected_set_lock.py tests/test_catalog_list_routes.py -v
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest -q
  ```
  Expected: task_pause tests PASS; PL two functions still green; no new suite reds.

- [ ] **Step 5: Commit**
  ```bash
  git add app/services/app_control_execution.py app/api/routes/child_device.py tests/test_selected_set_lock.py
  git commit -m "feat(taskgate): extend lock_source/unlock_sources wire Literals to accept task_pause"
  ```

---

## Task 2: (folded into Task 1)

*(No separate backend wire task — the payload threads provenance generically. Task 2 slot intentionally empty; renumbering avoided to keep anchors stable.)*

---

## Task 3: iOS — map `task_pause` to `.taskPause` shield source

**Why:** iOS has `ScreenTimeEvent.Source.taskPause` (event label) but the enforcement enum `ShieldSource` (`ShieldRecord.swift:16`) has only `manual, limit, earnedTime`. The two wire seams map only `"earned_time"`:
- `ActionExecutor.shieldSources(fromWireLockSource:)` (:672) — `case "earned_time": return [.earnedTime]; default: return [.manual]`.
- The unshield removal loop (:772) — `let src: ShieldSource = wireSource == "earned_time" ? .earnedTime : .manual`.
Without a `.taskPause` case, a `task_pause` shield decodes as `.manual` (via the unknown-tolerant `ShieldSource.init(from:)` fallback at :29) and a `unlock_sources=["task_pause"]` unshield would wrongly strip the `.manual` claim.

**Files:**
- Modify `Evlin iOS/Models/ShieldRecord.swift` (:16 enum — add `case taskPause`).
- Modify `Evlin iOS/Services/ActionExecutor.swift` (:672 map, :772 map).
- Create `Evlin iOSTests/TaskPauseShieldMappingTests.swift`.

- [ ] **Step 1: Write failing tests** — `Evlin iOSTests/TaskPauseShieldMappingTests.swift`:
  ```swift
  import XCTest
  @testable import Evlin_iOS

  final class TaskPauseShieldMappingTests: XCTestCase {
      func test_wireLockSource_taskPause_mapsToTaskPauseSource() {
          XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: "task_pause"), [.taskPause])
      }
      func test_wireLockSource_earnedTime_stillMaps() {
          XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: "earned_time"), [.earnedTime])
      }
      func test_wireLockSource_unknown_defaultsToManual() {
          XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: nil), [.manual])
          XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: "schedule"), [.manual])
      }
      func test_shieldSource_rawValue_taskPause() {
          XCTAssertEqual(ShieldSource.taskPause.rawValue, "taskPause")
          // unknown-tolerant decode still falls back to manual for garbage:
          XCTAssertEqual(ShieldSource(rawValue: "nope") ?? .manual, .manual)
      }
  }
  ```

- [ ] **Step 2: Verify it fails** — `-only-testing:"Evlin iOSTests/TaskPauseShieldMappingTests"`; expected BUILD FAIL (`.taskPause` not a member of `ShieldSource`).

- [ ] **Step 3: Add the enum case** — in `ShieldRecord.swift`, add `case taskPause` to `ShieldSource` (after `earnedTime`). The unknown-tolerant `init(from:)` at :29 is unchanged (a newer `taskPause` written by a newer binary and read by an older extension already falls back to `.manual` — acceptable; the extension just won't distinguish the source label).

- [ ] **Step 4: Map both seams** — in `ActionExecutor.swift`:
  - `shieldSources(fromWireLockSource:)` (:672):
    ```swift
    switch wireSource {
    case "earned_time": return [.earnedTime]
    case "task_pause":  return [.taskPause]
    default:            return [.manual]
    }
    ```
  - Unshield loop (:772):
    ```swift
    let src: ShieldSource
    switch wireSource {
    case "earned_time": src = .earnedTime
    case "task_pause":  src = .taskPause
    default:            src = .manual
    }
    ```

- [ ] **Step 5: Run tests + regression classes + build (app + both extensions)**
  ```bash
  cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS"
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:"Evlin iOSTests/TaskPauseShieldMappingTests" \
    -only-testing:"Evlin iOSTests/LockedSetFullCoverageTests" \
    -only-testing:"Evlin iOSTests/CommandPollerEffectiveStateTests" test 2>&1 | tail -6
  xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
    -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
  ```
  Expected: `TEST SUCCEEDED`; `** BUILD SUCCEEDED **`. (The `ShieldSource` decode of persisted records must still round-trip — `LockedSetFullCoverageTests` covers this.)

- [ ] **Step 6: Commit**
  ```bash
  git add "Evlin iOS/Models/ShieldRecord.swift" \
          "Evlin iOS/Services/ActionExecutor.swift" \
          "Evlin iOSTests/TaskPauseShieldMappingTests.swift"
  git commit -m "feat(taskgate): iOS ShieldSource.taskPause + wire mapping for task_pause lock/unlock"
  ```

---

## Task 4: Backend — TWO columns + one migration (`task_lock_suppressed_at` + `task_lock_command_id`)

**Why:** (a) After a parent manual unlock, the task lock must NOT re-apply for the rest of that day (precedence: manual > taskPause) — per-(child, day) sticky flag on `EarnedTimeDay`, dedicated column (not the `state` string) because a day can be BOTH task-locked AND pool-exhausted. (b) Task 5's idempotency needs a task-specific command id per (device, day): the real model only has `selected_lock_command_id` (`earned_time.py:309`, owned by the earned auto-lock — do NOT reuse it), so add `task_lock_command_id` to `EarnedTimeDeviceDay` in the SAME migration.

**Files:**
- Modify `app/db/models/earned_time.py` (`EarnedTimeDay` — add `task_lock_suppressed_at`; `EarnedTimeDeviceDay` — add `task_lock_command_id`).
- Create ONE Alembic migration adding both columns.
- Modify `tests/test_earned_time_models.py` (update expected-columns assertions for both tables — the suite pins model columns).

- [ ] **Step 1: Confirm migration tooling**
  ```bash
  cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
  source .venv/bin/activate
  ls alembic/versions | tail -3 && grep -rn "def upgrade" alembic/versions | tail -1
  ```
  Record the current head revision id (used as `down_revision`). ANCHOR NOTE: if the repo does NOT use Alembic (no `alembic/` dir), STOP and re-scope — the column must be added via whatever migration mechanism the repo uses (check `app/db/` for a create-all/bootstrap path).

- [ ] **Step 2: Add BOTH columns to the models** — in `earned_time.py`:
  - `EarnedTimeDay`, after `exhaustion_override_at`:
  ```python
  task_lock_suppressed_at: Mapped[Optional[datetime]] = mapped_column(
      DateTime(timezone=True), nullable=True
  )
  ```
  - `EarnedTimeDeviceDay`, after `selected_lock_command_id` (:309 — mirror its FK-less nullable-UUID idiom exactly):
  ```python
  # Task-gate: id of the task_pause shield command queued for this device-day.
  # Distinct from selected_lock_command_id (earned auto-lock's guard) — the two
  # lock systems must not share idempotency state.
  task_lock_command_id: Mapped[Optional[uuid.UUID]] = mapped_column(
      UUID(as_uuid=True), nullable=True
  )
  ```

- [ ] **Step 3: Generate + hand-verify the migration**
  ```bash
  alembic revision -m "add task-gate columns to earned_time day tables"
  ```
  Edit the new file so `upgrade()` runs BOTH:
  `op.add_column("evlin_earned_time_days", sa.Column("task_lock_suppressed_at", sa.DateTime(timezone=True), nullable=True))` and
  `op.add_column("evlin_earned_time_device_days", sa.Column("task_lock_command_id", postgresql.UUID(as_uuid=True), nullable=True))`;
  `downgrade()` drops both. Set `down_revision` to the head from Step 1. (Do NOT autogenerate blindly — hand-write the two add_columns to avoid unrelated drift.)

- [ ] **Step 3b: Update the model-column pin tests** — `tests/test_earned_time_models.py` asserts expected columns for these tables; add `task_lock_suppressed_at` / `task_lock_command_id` to the expectations and run that file.

- [ ] **Step 4: Apply + verify against the test DB**
  ```bash
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test alembic upgrade head
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest -q
  ```
  Expected: migration applies; no new suite reds. (If the test harness builds schema via `Base.metadata.create_all` rather than Alembic, the model change alone suffices for tests — the migration is for prod. Verify which path `tests/conftest.py` uses.)

- [ ] **Step 5: Commit**
  ```bash
  git add app/db/models/earned_time.py alembic/versions/<new_file>.py tests/test_earned_time_models.py
  git commit -m "feat(taskgate): add task_lock_suppressed_at + task_lock_command_id columns (+migration)"
  ```

---

## Task 5: Backend — `reconcile_task_lock` service + wire into task routes

**Why:** Central, idempotent, level-triggered reconcile called after every task mutation. Desired state:
- **Lock** (queue savedList shield, `lock_source="task_pause"`) iff: `usage_counting_allowed()==False` (has incomplete task) AND Daily Screen Time enabled (`_load_active_config(...) is not None` for today) AND NOT suppressed (`task_lock_suppressed_at is None`) AND not already task-locked this day.
- **Unlock** (queue savedList unshield, `unlock_sources=["task_pause"]`) iff: `usage_counting_allowed()==True` (all done) AND a task lock is currently recorded.
- Idempotency tracked via `EarnedTimeDeviceDay.task_lock_command_id` (added in Task 4 — its own column, never `selected_lock_command_id` which belongs to the earned auto-lock).

**Files:**
- Create `app/services/task_lock_service.py`.
- Modify `app/api/routes/bigkid_parent.py` (call after `review_task` approve/redo :451/:481, `create_task` :577, `delete_task` :644/:651, `respond_bypass` :672).
- Modify `app/services/task_executor.py` (chat/plan execution mutates tasks too — call reconcile after `_run_assign` :96, `_run_delete` :153, `_run_approve` :244, `_run_request_redo` :293; verify each site's post-mutation store state is hydrated before the call).
- Create `tests/test_task_lock_service.py`.

**Interface (pattern mirrors `queue_reflection_lockdown` in `reflection_delivery.py:73`):**
```python
async def reconcile_task_lock(
    session: AsyncSession,
    store: BigKidStore,
    *,
    child_device_id: UUID,
    usage_date: Optional[date] = None,   # test seam; None → child-tz today
    now_utc: Optional[datetime] = None,  # test seam; None → datetime.now(utc)
) -> None:
    """Converge the Locked-set task_pause shield to the desired state.

    Level-triggered & idempotent. Best-effort: never raises to the request path.
    Requires a request-scoped SilentWakeScheduler bound by the caller (mirror
    queue_reflection_lockdown). No-ops when child_profile_id is nil.
    """
    child = await session.get(Device, child_device_id)
    if child is None or child.family_id is None or child.child_profile_id is None:
        return
    now_utc = now_utc or datetime.now(timezone.utc)
    # Load the config FIRST — its timezone defines the child's "today".
    # Use a helper that accepts now_utc, e.g.
    #   local_date_for_timezone(tz, now_utc) =
    #       now_utc.astimezone(ZoneInfo(tz)).date()
    # falling back to now_utc.date() on invalid tz. Do NOT call the existing
    # today_for_timezone() directly in this service; it uses wall-clock "now"
    # internally and would make the now_utc test seam a lie.
    # Chicken-and-egg note: _load_active_config needs as_of; resolve with a
    # provisional server-date read, then recompute usage_date from the config's
    # timezone and re-load ONLY if the dates differ (rare, ±1 day at midnight).
    provisional = usage_date or now_utc.date()
    config = await _load_active_config(session, family_id=child.family_id,
        child_profile_id=child.child_profile_id, as_of=provisional)
    if config is None:
        daily_on = False
        usage_date = usage_date or provisional
    else:
        daily_on = True
        real_today = usage_date or local_date_for_timezone(config.timezone, now_utc)
        if real_today != provisional:
            config = await _load_active_config(session, family_id=child.family_id,
                child_profile_id=child.child_profile_id, as_of=real_today)
            daily_on = config is not None
        usage_date = real_today
    has_incomplete = not await usage_counting_allowed(session, store, child_device_id)
    day_row = <load-or-none EarnedTimeDay for (family, profile, usage_date)>
    device_day = <load-or-none EarnedTimeDeviceDay for (family, device, usage_date)>
    suppressed = day_row is not None and day_row.task_lock_suppressed_at is not None
    currently_locked = device_day is not None and device_day.task_lock_command_id is not None

    want_lock = has_incomplete and daily_on and not suppressed
    if want_lock and not currently_locked:
        # ensure_selected_set; if None/tokenless → emit warning event, return
        cmd = await queue_app_control(session, family_id=..., child=child,
            target=<Locked set list>, verb="shield", duration_minutes=None,
            lock_source="task_pause")
        # BOOTSTRAP (the task lock may be the FIRST write of the day — both
        # tables have NOT NULL fields that must be sourced from the config):
        #   EarnedTimeDay(family_id, child_profile_id, usage_date,
        #       timezone=config.timezone, daily_pool_minutes=config.daily_pool_minutes,
        #       used_minutes=0, remaining_minutes=config.daily_pool_minutes,
        #       state="available")
        #   EarnedTimeDeviceDay(family_id, child_profile_id, child_device_id,
        #       usage_date, timezone=config.timezone, estimated_minutes=0,
        #       last_sample_at=now_utc)
        # (config is guaranteed non-None here because want_lock ⇒ daily_on.)
        <load-or-bootstrap device_day as above; set device_day.task_lock_command_id = cmd.id>
        <emit ScreenTimeEvent kind="command_emit" source="taskPause" reason="tasks_incomplete_lock">
    elif (not has_incomplete) and currently_locked:
        await queue_app_control(session, family_id=..., child=child,
            target=<Locked set list>, verb="unshield",
            unlock_sources=["task_pause"])
        <device_day.task_lock_command_id = None>
        <emit ScreenTimeEvent kind="command_emit" source="taskPause" reason="tasks_complete_unlock">
```

- [ ] **Step 1: Write failing service tests** — `tests/test_task_lock_service.py` (DB-gated header; seed via the same fixtures `test_earned_time_auto_lock.py` uses — family, child profile, child device, an active Locked-set list with ≥1 token, an enabled `EarnedTimeConfig` for today, and BigKid store tasks):
  - `test_incomplete_tasks_enabled_config_queues_task_pause_shield` — one incomplete task, config enabled, not suppressed → exactly one `shield` command with `lock_source="task_pause"`; `device_day.task_lock_command_id` set.
  - `test_all_tasks_done_strips_task_pause` — pre-set `task_lock_command_id`; all tasks done → one `unshield` with `unlock_sources=["task_pause"]`; command id cleared.
  - `test_daily_screen_time_off_no_lock` — incomplete task but no enabled config → no command.
  - `test_suppressed_day_no_relock` — `task_lock_suppressed_at` set, incomplete task, enabled → no command.
  - `test_idempotent_no_duplicate_lock` — already `task_lock_command_id` set, still incomplete → no second command.
  - `test_empty_task_list_no_lock` — zero tasks (`usage_counting_allowed==True`) → no command.
  - `test_nil_child_profile_noop` — device with nil `child_profile_id` → no command, no raise.
  - `test_tokenless_selected_set_emits_warning_not_command` — Locked set tokenless → warning event, no shield command.
  - `test_first_write_of_day_bootstraps_rows` — NO EarnedTimeDay/EarnedTimeDeviceDay rows exist for usage_date; reconcile locks → both rows created with `timezone=config.timezone`, `daily_pool_minutes=config.daily_pool_minutes`, `used_minutes=0`, `estimated_minutes=0` (no NOT-NULL violation — this is the "task lock before any sample" path).
  - `test_usage_date_follows_config_timezone` — inject `now_utc` only: with config timezone "Pacific/Auckland" and a UTC evening `now`, the reconcile reads/writes the row for the CHILD-LOCAL day, not the UTC/server day. Separately, `usage_date=` remains a hard test override for Task 7.

- [ ] **Step 2: Verify it fails**
  ```bash
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_task_lock_service.py -v
  ```
  Expected: import error / all fail (module absent).

- [ ] **Step 3: Implement `task_lock_service.py`** per the interface above. Reuse: `usage_counting_allowed` (bigkid_usage_gate), `_load_active_config` + `ensure_selected_set`/`load_selected_set` + `queue_app_control` + `screen_time_event_service.emit` (earned_time_service / app_control_execution). Load/bootstrap `EarnedTimeDay` and `EarnedTimeDeviceDay` with the same select+with_for_update idiom `apply_override` uses. `task_lock_command_id` is not optional here — Task 4 added it to `EarnedTimeDeviceDay`.

- [ ] **Step 4: Wire into the task routes** — in `bigkid_parent.py`, after each mutation commits its `upsert_task` and BEFORE returning, bind a scheduler and call reconcile. Pattern (mirror the cancel-reflection route at :429-434):
  ```python
  from app.services.app_control_delivery import SilentWakeScheduler, bind_request_scheduler
  from app.services.task_lock_service import reconcile_task_lock
  # review_task needs `background_tasks: BackgroundTasks` added to its signature.
  with bind_request_scheduler(SilentWakeScheduler(background_tasks)):
      await reconcile_task_lock(session, store, child_device_id=persisted_child_id)
  ```
  Call sites: `review_task` (both approve and redo branches, both the persisted and fallback loops), `create_task`, `delete_task`, `respond_bypass` (approve → fewer incomplete; deny → no change but reconcile is idempotent, safe to call). Add `background_tasks: BackgroundTasks` params where missing. Skip `submit_evidence`/`create_bypass` (they don't change `done`-count: submit→`submitted`, bypass create→`pending`) — but ADD a code comment noting this so a future reader knows it was considered.

  **ALSO wire the chat/plan executor** — `app/services/task_executor.py` mutates tasks OUTSIDE the routes: assign at :96, delete at :153, approve at :244, request-redo at :293. After each mutation persists, call `reconcile_task_lock` the same way (these run inside chat request contexts — locate how they obtain/bind a SilentWakeScheduler; if none is bound in that path, mirror how the executor's existing command-queuing handles delivery, and disclose the pattern used in the report). Missing these means the AI-chat flow ("批准他的任务", "给他加个任务", "删掉那个任务") silently bypasses the task gate.

- [ ] **Step 5: Run service + route tests + gates**
  ```bash
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_task_lock_service.py tests/test_earned_time_auto_lock.py \
      tests/test_config_change_commands.py -v
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest -q
  ```
  Expected: all pass; no new suite reds.

- [ ] **Step 6: Commit**
  ```bash
  git add app/services/task_lock_service.py app/api/routes/bigkid_parent.py \
          app/services/task_executor.py tests/test_task_lock_service.py
  git commit -m "feat(taskgate): reconcile_task_lock service + wire into task routes AND chat task executor"
  ```

---

## Task 6: Backend — parent manual unlock strips task_pause + sets suppression flag

**Why:** Precedence manual > taskPause. `unlock-selected` (`child_device.py:1876`) already strips `["manual","earned_time"]` and clears `selected_lock_command_id`. Extend it to ALSO strip `task_pause` and set `EarnedTimeDay.task_lock_suppressed_at = now` so `reconcile_task_lock` won't re-lock today. Manual `lock-selected` needs no change (a `.manual` shield already wins the union and survives task-completion's `task_pause`-only strip).

**Files:**
- Modify `app/api/routes/child_device.py` (`unlock_selected_set` :1876-1990).
- Modify `app/api/routes/parent_actions.py` (`revert_action` :25 and `_execute_inverse` :54 — add async/session-aware persistence + reconcile for task inverses).

- [ ] **Step 1: Write failing test** — append to `tests/test_task_gated_lock_routes.py` (create it; DB-gated + route client fixture from an existing route test):
  - `test_manual_unlock_strips_task_pause_and_suppresses` — task-locked day (`task_lock_command_id` set), call `POST /parent/device/unlock-selected` → unshield command carries `unlock_sources` containing `"task_pause"`; `EarnedTimeDay.task_lock_suppressed_at` is set; `device_day.task_lock_command_id` cleared.
  - `test_after_manual_unlock_reconcile_does_not_relock` — after the above, call `reconcile_task_lock` with still-incomplete tasks → NO new shield command (suppressed).
  - `test_manual_lock_survives_task_completion` — a `.manual` Locked-set shield present; complete all tasks → reconcile issues `unshield unlock_sources=["task_pause"]` only; assert the command does NOT include `"manual"`.
  - **Chat-executor coverage (blocker-4 acceptance):**
    - `test_chat_approve_task_unlocks` — task-locked; drive the approve path through `task_executor` `_run_approve` (:244) for the last incomplete task → unshield `["task_pause"]` queued.
    - `test_chat_request_redo_relocks` — all done/unlocked; `task_executor` `_run_request_redo` (:293) makes a task incomplete again → task_pause shield queued.
    - `test_chat_assign_task_locks` — all done/unlocked; `task_executor` assign (:96) creates a new incomplete task → task_pause shield queued.
    - `test_chat_delete_last_incomplete_task_unlocks` — task-locked with one incomplete task; `task_executor` delete (:153) removes it → unshield `["task_pause"]` queued.
    - `test_undo_approve_relocks` — approve via executor, then `POST /parent/actions/{action_id}/revert` (parent_actions.py:62) → task incomplete again → reconcile re-locks (if revert flows through task_executor internally, assert the end state; else this test exposes the missing wiring and the fix goes wherever revert mutates the task).

- [ ] **Step 2: Verify it fails**
  ```bash
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_task_gated_lock_routes.py -v
  ```

- [ ] **Step 3: Extend `unlock_selected_set`** — in the `unlock_sources` list (:1913) add `"task_pause"`: `["manual", "earned_time", "task_pause"]`. For the task suppression row, use the SAME config-timezone usage-date helper as `reconcile_task_lock` (do not use bare `date.today()`; the existing earned override code may still have its own server-date behavior, but task suppression must line up with Task 5). In the `if child.child_profile_id is not None:` block (:1915+), after clearing `device_day_row.selected_lock_command_id`, also:
  ```python
  # Precedence manual > taskPause: a parent unlock suppresses task re-lock
  # for the rest of today, and clears the task-lock command id.
  from app.services.earned_time_service import apply_task_lock_suppression  # or inline
  <bootstrap/load EarnedTimeDay for task_usage_date; set task_lock_suppressed_at = now_utc>
  if device_day_row is not None:
      device_day_row.task_lock_command_id = None
  ```
  Reuse the existing `day_row`/`device_day_row` loads only if their `usage_date` matches `task_usage_date`; otherwise load/bootstrap the task-day rows explicitly so unlock suppression and reconcile read the same local day.

- [ ] **Step 3b: Extend chat Undo task inverses** — in `parent_actions.py`, `revert_action` must accept `BackgroundTasks` and `AsyncSession`, and `_execute_inverse` must become async/session-aware for task inverses. For `request_redo`, `approve_task`, and `respond_bypass` inverses: hydrate if possible, apply the store mutation, persist the affected task with `upsert_task`, then bind `SilentWakeScheduler(background_tasks)` and call `reconcile_task_lock(session, store, child_device_id=<child_id>)` before returning. This path does NOT currently flow through `task_executor`, so a test-only change is insufficient.

- [ ] **Step 4: Run + suite**
  ```bash
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_task_gated_lock_routes.py tests/test_selected_set_lock.py -v
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest -q
  ```

- [ ] **Step 5: Commit**
  ```bash
  git add app/api/routes/child_device.py app/api/routes/parent_actions.py tests/test_task_gated_lock_routes.py
  git commit -m "feat(taskgate): parent manual unlock strips task_pause + suppresses task re-lock for the day"
  ```

---

## Task 7: Backend — day-reset clears suppression (verify + test)

**Why:** "for the rest of that day" — the suppression flag lives on the per-day `EarnedTimeDay` row, so a new usage_date naturally has a fresh row with `task_lock_suppressed_at IS NULL`. This task VERIFIES that no code carries suppression across days and adds a regression test. No new production code expected unless the verification finds a leak.

**Files:**
- Modify `tests/test_task_gated_lock_routes.py` (append).

- [ ] **Step 1: Grep for cross-day carry**
  ```bash
  cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
  grep -rn "task_lock_suppressed_at\|state == \"override_unlocked\"\|is sticky" app/services/earned_time_service.py
  ```
  Confirm suppression is read only for `usage_date == today` (per-row), never copied forward. If a day-rollover copies prior-day state, STOP and add an explicit clear.

- [ ] **Step 2: Add the regression test** — `test_suppression_is_per_day` — set `task_lock_suppressed_at` on day D; call `reconcile_task_lock(..., usage_date=D+1)` (the Task-5 injection seam — no wall-clock dependence; fresh row, incomplete tasks, enabled) → a `task_pause` shield IS queued (new day re-locks).

- [ ] **Step 3: Run + commit**
  ```bash
  EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
    python -m pytest tests/test_task_gated_lock_routes.py -v
  git add tests/test_task_gated_lock_routes.py
  git commit -m "test(taskgate): suppression flag is per-day; new day re-locks for tasks"
  ```

---

## Final regression pass (before declaring done)

```bash
# Backend
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && source .venv/bin/activate
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test python -m pytest \
  tests/test_config_change_commands.py tests/test_earned_time_policy_summary.py \
  tests/test_earned_time_remaining_recompute.py tests/test_screen_time_events_api.py \
  tests/test_earned_time_auto_lock.py tests/test_earned_time_config.py \
  tests/test_catalog_list_routes.py tests/test_selected_set_lock.py \
  tests/test_task_lock_service.py tests/test_task_gated_lock_routes.py -q
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test python -m pytest -q

# iOS (ten regression classes + new mapping test)
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS"
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Evlin iOSTests/TaskPauseShieldMappingTests" \
  -only-testing:"Evlin iOSTests/LockedSetFullCoverageTests" \
  -only-testing:"Evlin iOSTests/CommandPollerEffectiveStateTests" \
  -only-testing:"Evlin iOSTests/CurrentRestrictionsReaderTests" \
  -only-testing:"Evlin iOSTests/DeviceIdentityTests" \
  -only-testing:"Evlin iOSTests/ScreenTimeEventUploaderTests" \
  -only-testing:"Evlin iOSTests/EarnedSampleReporterTests" \
  -only-testing:"Evlin iOSTests/EarnedBudgetSchedulerTests" \
  -only-testing:"Evlin iOSTests/BigKidStatePollerTests" \
  -only-testing:"Evlin iOSTests/EarnedGateTautologyTests" \
  -only-testing:"Evlin iOSTests/ArmGenerationTests" test 2>&1 | tail -8
```

## Deferred (UX follow-up, not in this plan)
- iOS reason-display precedence branch for `taskPause` (spec precedence LAST). The kid-side "Finish today's tasks to unlock" copy already exists in `BigKidHomeView.swift:191`; a distinct locked-reason label for the Locked-set shield source is a separate UX task.
- Multi-worker durability of the in-memory `BigKidStore` transition detection (mitigated here by level-triggered reconcile; a durable "has_incomplete" column is out of scope).
```

---
