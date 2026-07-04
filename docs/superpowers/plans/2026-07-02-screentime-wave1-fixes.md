# Screen-Time Wave-1: Command Lifecycle + Hygiene Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the command-lifecycle gaps proven by the 2026-07-01 night device tests (A1 timeline): config changes now push lock/unlock commands in BOTH directions (Fix 8), the once-per-day auto-lock guard clears on unlock so exhaustion can re-lock, future-dated ("tomorrow") configs stop bleeding into today (Fix 3 read-side), and the iOS hygiene fixes — honest effective-date wiring, savedList recordKey case normalization (the "immortal lock" bug), and the extension cap/pool label split + the DeviceAppsSheet cap read-back — all land with regression tests.

**Architecture:** Backend (`Evlin-Backend`, branch `calendar-in-chat`): reuse the existing `_maybe_queue_auto_lock` helper and `screen_time_event_service.emit` inside `put_pool_config`/`put_device_cap` after the config row is written; clear `selected_lock_command_id` in the unlock-selected route and the raise path; add `effective_date <= as_of` to the six active-row read sites. iOS (`Evlin-iOS`, same branch): plumb `effective:` through the two write call sites with an honest label; lowercase savedList `targetKey` in `makeRecordKey` + a one-time re-key sweep in `ActiveLockStore.restore()`; split cap vs pool exhaustion in the extension emit and fix the `EarnedPolicyDeviceDTO` field-name mismatch that fed the pool into `deviceCapMinutes`.

**Tech Stack:** FastAPI, SQLAlchemy async, asyncpg, pytest(+asyncio, DB-gated); Swift, XCTest.

**Anchor dossier (verified quotes/locals for every fix site):** `.superpowers/sdd/wave1-anchors.md` in the Evlin-iOS repo — implementers should consult it when an anchor's surroundings matter.

## Global Constraints

- Backend repo: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend` (Tasks 1–3, branch `calendar-in-chat`). iOS repo: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS` (Tasks 4–6, same branch).
- Backend DB tests require `EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test` (they skip without it) and the venv: `source .venv/bin/activate`. iOS tests: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' test`, filtered via `-only-testing:`.
- Commits include ONLY the files named in each task. Never stage `.env`, `xcuserstate`, or `.DS_Store`. Never stage unrelated `project.pbxproj` churn beyond target-membership additions. **Do NOT push either repo** — the user controls pushes (backend push auto-deploys to Render).
- **Backend whole-suite check:** after each backend task run `python -m pytest -q` and confirm no NEW reds vs the pre-task baseline (there are known pre-existing unrelated failures in the app_control/fastpath/catalog/saved_list suite — those are baseline, not regressions).
- **iOS no-regression check:** these existing classes MUST stay green — `CommandPollerEffectiveStateTests`, `CurrentRestrictionsReaderTests`, `DeviceIdentityTests`, `ScreenTimeEventUploaderTests` (plus, for Task 5, any existing ActiveLockStore/record-key test classes found under `Evlin iOSTests`).

### Semantic rules (binding — user review 2026-07-01)

1. **Manual locks survive raises.** A raise-triggered unlock strips ONLY `earned_time` (`unlock_sources=["earned_time"]`); a `.manual` shield is never touched.
2. **R20 override suppresses auto-lock.** A `child_day_state == "override_unlocked"` day suppresses the auto-lock even after a lower. `_maybe_queue_auto_lock` already enforces this (earned_time_service.py:125) — reusing it inherits the rule for free.
3. **Per-app limit shields are unaffected** by pool/cap changes. The unlock only names the `earned_time` source on the savedList "Locked set" shield; per-app (`exactApp` tier, `.limit` source) shields are a separate record system and precedence handles them.

### Precedence (design spec Part C)
`manual > account/admin-disabled > earned-pool-exhausted > device-cap-exhausted > per-app-exhausted > task-pause`. Shields union; the reason shown is the highest-precedence hit. Override suppresses only the named automated sources for that `day_key`, never manual.

---

## File Structure

**Backend (Evlin-Backend):**
- **Modify** `app/services/earned_time_service.py` — Task 1 (lock/unlock in `put_pool_config` + `put_device_cap`), Task 2 (clear guard in raise path), Task 3 (six read-site `effective_date <= as_of` filters).
- **Modify** `app/api/routes/child_device.py` — Task 2 (clear `selected_lock_command_id` in `unlock_selected_set`).
- **Create** `tests/test_config_change_commands.py` — Task 1 + Task 2 DB-gated regression tests.
- **Modify** `tests/test_earned_time_policy_summary.py` — Task 3 effective-date regression test (append; if this file does not exist, create it with the same DB-gated pytestmark header as `tests/test_screen_time_events_api.py`).

**iOS (Evlin-iOS):**
- **Modify** `Evlin iOS/Views/Profile/ProfileView.swift` — Task 4 (`effective:` plumbing on `savePool`).
- **Modify** `Evlin iOS/Views/Profile/DeviceAppsSheet.swift` — Task 4 (honest label + `effective:` wiring), Task 6b (cap read-back reader).
- **Modify** `Evlin iOS/Models/ShieldRecord.swift` — Task 5 (lowercase savedList targetKey in `makeRecordKey`).
- **Modify** `Evlin iOS/Services/ActionExecutor.swift` — Task 5 (call-site comments :734, :743→removeExplicit).
- **Modify** `Evlin iOS/Services/ActiveLockStore.swift` — Task 5 (one-time re-key sweep in `restore()`).
- **Modify** `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` — Task 5 (route recordKey through `makeRecordKey`), Task 6a (cap-vs-pool source split).
- **Modify** `Evlin iOS/Services/APIClient.swift` — Task 6b (rename `EarnedPolicyDeviceDTO.daily_cap_minutes` → `device_cap_minutes`).
- **Create** `Evlin iOSTests/RecordKeyNormalizationTests.swift` — Task 5 unit tests (incl. merge case).

---

## Task 1: Backend — Fix 8 both directions (lower→lock, raise→unlock)

**Files:**
- Modify: `app/services/earned_time_service.py` (`put_pool_config` lines 1101–1246, `put_device_cap` lines 1253–1379)
- Test: `tests/test_config_change_commands.py` (create)

**Interfaces:**
- Consumes: `_maybe_queue_auto_lock(db, *, child_device, device_day_row, child_day_state, max_estimated, effective_cap, now_utc)` (line 97; internally enforces R20 override skip at :125 and the `selected_lock_command_id` idempotency guard at :133); `screen_time_event_service.emit`; `queue_app_control(session, *, family_id, child: Device, target: ControlTargetResolution, verb: str, ..., unlock_sources: list | None)` (app_control_execution.py — returns `Command | list[Command]`); `load_selected_set(db, family_id=..., child_device_id=...)`; models `EarnedTimeDay`, `EarnedTimeDeviceDay`.
- Produces: on `effective == "today"` config writes — a lock command + timeline `reason="policy_lowered_lock"` when new value ≤ current usage; an `unshield` command with `unlock_sources=["earned_time"]` + timeline `reason="policy_raised_unlock"` (and guard clear) when raised above usage with a prior lock. Task 2's tests rely on the raise path clearing `selected_lock_command_id`.

- [ ] **Step 1: Write the failing tests** — create `tests/test_config_change_commands.py`

Header + seeds: same DB-gated `pytestmark` as `tests/test_screen_time_events_api.py`; clone the family/profile/device/config seed helpers from that file (`Family` → `ChildProfile` → child-mode `Device` → `EarnedTimeConfig`), and seed today's ledger rows directly (`EarnedTimeDay(family_id=…, child_profile_id=…, usage_date=today, timezone="America/New_York", daily_pool_minutes=60, used_minutes=30, remaining_minutes=30, state="available")` and `EarnedTimeDeviceDay(family_id=…, child_profile_id=…, child_device_id=…, usage_date=today, timezone="America/New_York", estimated_minutes=30, last_sample_at=now)`). For tests that need the lock to actually QUEUE, monkeypatch `ets.load_selected_set` / `ets.ensure_selected_set` / `ets.queue_app_control` exactly as `tests/test_screen_time_events_api.py::test_backend_emits_auto_lock_command_event` already does (SimpleNamespace with `list_id`, `executable_tokens_count=1`) — this keeps the tests focused on the emission decision, not selected-set materialization.

Six tests:
```python
async def test_pool_lowered_below_used_queues_lock(session, monkeypatch): ...
    # seed used=30, call ets.put_pool_config(body: pool=20, effective="today", confirm_cascade=True)
    # assert fake queue_app_control called with verb="shield"
    # assert timeline row reason=="policy_lowered_lock"

async def test_cap_lowered_below_estimate_queues_lock(session, monkeypatch): ...
    # device estimated=30, put_device_cap(cap=15) -> shield + policy_lowered_lock

async def test_pool_raised_above_used_with_prior_lock_unshields(session, monkeypatch): ...
    # device_day.selected_lock_command_id = uuid4() beforehand
    # put_pool_config(pool=120) -> fake queue_app_control called with verb="unshield",
    # unlock_sources==["earned_time"]; guard cleared (selected_lock_command_id is None);
    # timeline row reason=="policy_raised_unlock"

async def test_raise_without_prior_lock_is_noop(session, monkeypatch): ...
    # selected_lock_command_id None -> no unshield call, no policy_raised_unlock row

async def test_override_day_suppresses_lower_lock(session, monkeypatch): ...
    # child_day.state="override_unlocked", put_pool_config(pool=10)
    # -> no shield call (R20 via _maybe_queue_auto_lock)

async def test_lower_never_touches_manual_or_perapp(session, monkeypatch): ...
    # assert the ONLY queued verbs are shield/unshield on the savedList target
    # (fake queue_app_control records calls; no exactApp/manual-source calls made)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
source .venv/bin/activate
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_config_change_commands.py -v
```
Expected: FAIL — no lock/unlock commands are emitted from the config paths yet.

- [ ] **Step 3: Wire the pool path** — in `put_pool_config`, inside the `if body.effective == "today":` block, AFTER the `for dev in devices_rows:` config-command loop ends (~line 1239) and BEFORE `return ConfigWrittenResponse(...)`, insert (locals verified: `family_id`, `child_profile_id`, `new_pool`, `devices_rows`):

```python
        # --- Fix 8: reconcile lock state against the NEW pool, both directions.
        today = date.today()
        child_day_row = (
            await db.execute(
                select(EarnedTimeDay).where(
                    EarnedTimeDay.family_id == family_id,
                    EarnedTimeDay.child_profile_id == child_profile_id,
                    EarnedTimeDay.usage_date == today,
                )
            )
        ).scalar_one_or_none()
        if child_day_row is not None:
            for dev in devices_rows:
                device_day_row = (
                    await db.execute(
                        select(EarnedTimeDeviceDay).where(
                            EarnedTimeDeviceDay.family_id == family_id,
                            EarnedTimeDeviceDay.child_device_id == dev.id,
                            EarnedTimeDeviceDay.usage_date == today,
                        )
                    )
                ).scalar_one_or_none()
                if device_day_row is None:
                    continue
                if child_day_row.used_minutes >= new_pool:
                    # Lowered below usage → lock now. R20 override skip and the
                    # already-locked idempotency guard live inside the helper.
                    await _maybe_queue_auto_lock(
                        db,
                        child_device=dev,
                        device_day_row=device_day_row,
                        child_day_state=child_day_row.state,
                        max_estimated=device_day_row.estimated_minutes,
                        effective_cap=new_pool,
                        now_utc=datetime.now(timezone.utc),
                    )
                    await screen_time_event_service.emit(
                        db,
                        family_id=family_id,
                        device_id=dev.id,
                        kind="lock",
                        source="earnedPool",
                        reason="policy_lowered_lock",
                        nums={"used": child_day_row.used_minutes, "poolTotal": new_pool},
                    )
                elif device_day_row.selected_lock_command_id is not None:
                    # Raised above usage with a prior lock → earned-time-only
                    # unlock. Manual claims survive (unlock_sources names only
                    # earned_time); per-app shields are a separate system.
                    preview = await load_selected_set(
                        db, family_id=family_id, child_device_id=dev.id,
                    )
                    if preview is not None:
                        ucmd = await queue_app_control(
                            db,
                            family_id=family_id,
                            child=dev,
                            target=ControlTargetResolution(
                                status="resolved",
                                target_type="list",
                                alias_key=preview.list_id,
                                display="Locked set",
                            ),
                            verb="unshield",
                            unlock_sources=["earned_time"],
                        )
                        first_cmd = ucmd[0] if isinstance(ucmd, list) else ucmd
                        device_day_row.selected_lock_command_id = None  # Task 2 raise-path clear
                        await screen_time_event_service.emit(
                            db,
                            family_id=family_id,
                            device_id=dev.id,
                            kind="unlock",
                            source="earnedPool",
                            reason="policy_raised_unlock",
                            nums={"used": child_day_row.used_minutes, "poolTotal": new_pool},
                            corr_id=str(first_cmd.id),
                        )
```

(`date`, `datetime`, `timezone`, `select`, `EarnedTimeDay`, `EarnedTimeDeviceDay`, `load_selected_set`, `queue_app_control`, `ControlTargetResolution`, `screen_time_event_service` are all already imported at module top — verify and add any that are missing.)

- [ ] **Step 4: Wire the cap path** — in `put_device_cap`, inside its `if body.effective == "today":` block, AFTER `cmd = await _insert_earned_time_config_command(...)` (~line 1372) and BEFORE the return, insert the same logic scoped to the single device (locals verified: `family_id`, `child_profile_id`, `child_device_id`, `new_cap`, `device`):

```python
        # --- Fix 8 (cap): reconcile this device's lock state against the NEW cap.
        today = date.today()
        child_day_row = (
            await db.execute(
                select(EarnedTimeDay).where(
                    EarnedTimeDay.family_id == family_id,
                    EarnedTimeDay.child_profile_id == child_profile_id,
                    EarnedTimeDay.usage_date == today,
                )
            )
        ).scalar_one_or_none()
        device_day_row = (
            await db.execute(
                select(EarnedTimeDeviceDay).where(
                    EarnedTimeDeviceDay.family_id == family_id,
                    EarnedTimeDeviceDay.child_device_id == child_device_id,
                    EarnedTimeDeviceDay.usage_date == today,
                )
            )
        ).scalar_one_or_none()
        if device_day_row is not None:
            if device_day_row.estimated_minutes >= new_cap:
                await _maybe_queue_auto_lock(
                    db,
                    child_device=device,
                    device_day_row=device_day_row,
                    child_day_state=(child_day_row.state if child_day_row else "available"),
                    max_estimated=device_day_row.estimated_minutes,
                    effective_cap=new_cap,
                    now_utc=datetime.now(timezone.utc),
                )
                await screen_time_event_service.emit(
                    db,
                    family_id=family_id,
                    device_id=child_device_id,
                    kind="lock",
                    source="deviceCap",
                    reason="policy_lowered_lock",
                    nums={"used": device_day_row.estimated_minutes, "cap": new_cap},
                )
            elif device_day_row.selected_lock_command_id is not None:
                preview = await load_selected_set(
                    db, family_id=family_id, child_device_id=child_device_id,
                )
                if preview is not None:
                    ucmd = await queue_app_control(
                        db,
                        family_id=family_id,
                        child=device,
                        target=ControlTargetResolution(
                            status="resolved",
                            target_type="list",
                            alias_key=preview.list_id,
                            display="Locked set",
                        ),
                        verb="unshield",
                        unlock_sources=["earned_time"],
                    )
                    first_cmd = ucmd[0] if isinstance(ucmd, list) else ucmd
                    device_day_row.selected_lock_command_id = None
                    await screen_time_event_service.emit(
                        db,
                        family_id=family_id,
                        device_id=child_device_id,
                        kind="unlock",
                        source="deviceCap",
                        reason="policy_raised_unlock",
                        nums={"used": device_day_row.estimated_minutes, "cap": new_cap},
                        corr_id=str(first_cmd.id),
                    )
```

- [ ] **Step 5: Run tests + whole suite**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_config_change_commands.py tests/test_screen_time_events_api.py -v
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest -q   # no NEW reds vs baseline
```
Expected: all Task-1 tests PASS; screen-time events suite stays green; no new suite reds.

- [ ] **Step 6: Commit**

```bash
git add app/services/earned_time_service.py tests/test_config_change_commands.py
git commit -m "fix(screentime): Fix 8 both directions — config change emits lock (lower) / earned_time unshield (raise)"
```

---

## Task 2: Backend — guard #6: clear `selected_lock_command_id` on unlock so exhaustion can re-lock same day

**Files:**
- Modify: `app/api/routes/child_device.py` (`unlock_selected_set` route, ~lines 1917–1930)
- Test: `tests/test_config_change_commands.py` (append)

**Root cause (progress.md bug #6):** `_maybe_queue_auto_lock` skips when `device_day_row.selected_lock_command_id is not None` (earned_time_service.py:133) — a once-per-day guard that is never cleared on unlock, so after an unshield the same day can NEVER re-lock. Fix in two places: (a) the unlock-selected route; (b) the Task-1 raise path (already included there).

- [ ] **Step 1: Write the failing test** (append to `tests/test_config_change_commands.py`)

```python
async def test_unlock_clears_guard_so_next_exhaustion_relocks(client, session, monkeypatch): ...
    # 1. seed lock state: device_day.selected_lock_command_id = uuid4()
    # 2. POST /parent/device/unlock-selected (same auth pattern as the app uses;
    #    clone the request shape from existing unlock-selected tests if present,
    #    else construct: family_id, child_device_id, source="manual")
    # 3. assert device_day.selected_lock_command_id is None after the call
    # 4. call ets._maybe_queue_auto_lock(... estimated >= cap ...) with the fakes
    #    from Task 1 -> assert a NEW shield command IS queued (guard no longer skips)
```

- [ ] **Step 2: Verify it fails**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_config_change_commands.py::test_unlock_clears_guard_so_next_exhaustion_relocks -v
```
Expected: FAIL at step-3 assert — the guard survives the unlock.

- [ ] **Step 3: Clear the guard in `unlock_selected_set`** — the route already loads the `EarnedTimeDay` for `(req.family_id, child.child_profile_id, today)` (~lines 1920–1928) but never touches `EarnedTimeDeviceDay`. Immediately after that block add:

```python
    # Bug #6: clear the once-per-day auto-lock guard so pool/cap exhaustion can
    # re-lock the SAME day after this parent unlock. Without this, the device-
    # day's selected_lock_command_id stays set and _maybe_queue_auto_lock
    # (earned_time_service.py:133) skips every subsequent exhaustion today.
    device_day_row = (
        await session.execute(
            select(EarnedTimeDeviceDay).where(
                EarnedTimeDeviceDay.family_id == req.family_id,
                EarnedTimeDeviceDay.child_device_id == req.child_device_id,
                EarnedTimeDeviceDay.usage_date == today,
            )
        )
    ).scalar_one_or_none()
    if device_day_row is not None:
        device_day_row.selected_lock_command_id = None
```

(Add `EarnedTimeDeviceDay` to the existing `from app.db.models.earned_time import ...` import in `child_device.py`; reuse the route's existing `today` local — if the route computes it under a different name, match that name.)

- [ ] **Step 4: Run tests + whole suite**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_config_change_commands.py -v
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest -q
```
Expected: all PASS; no new reds.

- [ ] **Step 5: Commit**

```bash
git add app/api/routes/child_device.py tests/test_config_change_commands.py
git commit -m "fix(screentime): clear selected_lock_command_id on parent unlock so same-day re-lock works (bug #6)"
```

---

## Task 3: Backend — `effective_date <= as_of` read-side hardening (Fix 3)

**Files:**
- Modify: `app/services/earned_time_service.py` (six read sites)
- Test: `tests/test_earned_time_policy_summary.py` (append; create with the standard DB-gated header if absent)

**The six sites (dossier §3 — all currently filter only `superseded_at IS NULL` + `enabled` and order by `effective_date.desc()`, so a future-dated row wins the moment it is inserted):**
1. `get_policy` config query (lines 560–567) — `as_of` = child-tz today.
2. `get_policy` caps query (lines 589–593) — `as_of` = child-tz today.
3. `get_summary` config query (lines 702–707) — `as_of` = `date_` (the query date).
4. `_load_active_config` (lines 842–851) — gains `as_of: date` kwarg (no default — force every caller to state its day).
5. `_load_active_cap` (lines 854–870) — gains `as_of: date`.
6. `_load_active_caps_for_profile` (lines 873–889) — gains `as_of: date`.

Caller threading: `put_pool_config` (:1127, :1141) and `put_device_cap` (:1293, :1305) pass `as_of=date.today()`; `resolve_effective_cap_for_device` (:1505, :1510) gains its own `as_of: date` kwarg threaded from `ingest_sample`'s `usage_date` (call sites :433/:439) and `current_device_day_snapshot`'s `usage_date` (:508/:519); `get_summary` (:770) passes `as_of=date_`; `get_policy` computes child-tz today once and passes it to both its queries.

- [ ] **Step 1: Write the failing regression test**

```python
async def test_tomorrow_config_does_not_bleed_into_today(client, session): ...
    # seed: active config effective_date=today pool=60 AND a second row
    # effective_date=today+1 pool=45 (superseded_at=None, enabled=True)
    # assert get_policy -> pool 60; get_summary(date_=today) -> pool 60;
    # ingest_sample(usage_date=today) snapshot pool -> 60.
    # (Before the fix the +1 row wins the .desc() ordering everywhere.)
```

- [ ] **Step 2: Verify it fails** — run the single test; expected FAIL (future row wins).

- [ ] **Step 3: Apply the filter to all six sites** — add `.where(<Model>.effective_date <= as_of)` to each query; add the `as_of: date` kwargs; update every caller listed above. No site may keep an unfiltered read (grep `superseded_at.is_(None)` in the file afterward and account for every hit).

- [ ] **Step 4: Run tests + whole suite**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_earned_time_policy_summary.py tests/test_config_change_commands.py tests/test_screen_time_events_api.py tests/test_earned_time_remaining_recompute.py -v
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest -q
```
Expected: new test PASSES; all prior suites stay green; no new reds.

- [ ] **Step 5: Commit**

```bash
git add app/services/earned_time_service.py tests/test_earned_time_policy_summary.py
git commit -m "fix(screentime): filter active config/cap reads by effective_date <= as_of (Fix 3 read-side)"
```

---

## Task 4: iOS — effective honest wiring (Fix 3 UI)

**Files:**
- Modify: `Evlin iOS/Views/Profile/ProfileView.swift` (`savePool`, ~line 1490)
- Modify: `Evlin iOS/Views/Profile/DeviceAppsSheet.swift` (`saveDeviceCap` ~:789 + "changes tomorrow" label ~:558)

**Product decision 2026-07-01:** default stays `"today"` (apply-now). There is no real "tomorrow" selector in the UI today, so: make the static label truthful, and add `effective` parameter plumbing so a future selector can pass it.

- [ ] **Step 1:** add `effective: String = "today"` param to `savePool(newMinutes:confirmedCascade:)` and forward it into the `putEarnedConfig(childProfileID:poolMinutes:effective:confirmCascade:)` call (~line 1490). Existing callers unchanged (default).
- [ ] **Step 2:** add `effective: String = "today"` param to `saveDeviceCap` and forward to `putDeviceCap(..., effective: effective, ...)` (~line 789, currently hardcodes `"today"`).
- [ ] **Step 3:** change the static chip text in `DeviceAppsSheet.limitPicker(for:)` (~line 558) from `"· changes tomorrow"` to `"· applies immediately"`, and update the stale doc comment (~line 533) to match. This is the only literal "tomorrow" UI string; it was never wired to `effective:"tomorrow"`.
- [ ] **Step 4: Build**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS"
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Views/Profile/ProfileView.swift" "Evlin iOS/Views/Profile/DeviceAppsSheet.swift"
git commit -m "fix(screentime): honest effective wiring + truthful 'applies immediately' label (Fix 3 UI)"
```

---

## Task 5: iOS — recordKey savedList case normalization + one-time re-key sweep

**Files:**
- Modify: `Evlin iOS/Models/ShieldRecord.swift` (`makeRecordKey`, ~line 88)
- Modify: `Evlin iOS/Services/ActionExecutor.swift` (call-site comments :734, :743)
- Modify: `Evlin iOS/Services/ActiveLockStore.swift` (`restore()` sweep, ~line 606)
- Modify: `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` (raw literal ~:427 → canonical helper)
- Test: `Evlin iOSTests/RecordKeyNormalizationTests.swift` (create)

**Root cause (tonight's "immortal lock"):** the extension writes `savedList:<lockedSetID>` with the backend's lowercase UUID string; the parent unlock path builds the key via `id.uuidString` (UPPERCASE); `removeSource` misses the dict key; the record is immortal and the parent button stays red.

- [ ] **Step 1: Write the failing tests** — create `Evlin iOSTests/RecordKeyNormalizationTests.swift` covering:
  1. `makeRecordKey(.savedList, targetKey: "D6510F2A-DBF0-4EF5-A21D-B4F78D3374CF")` == `"savedList:d6510f2a-dbf0-4ef5-a21d-b4f78d3374cf"`.
  2. Other tiers pass through unchanged (`exactApp:com.foo.Bar` keeps its case; `category:social`, `allApps:all`, `all`).
  3. Round-trip: a record stored under the lowercase key is FOUND and removed when the remover builds the key from `UUID(uuidString:)!.uuidString` (uppercase input, normalized inside the helper).
  4. Migration sweep merge: seed BOTH `savedList:<UPPER>` (sources `[.manual]`) and `savedList:<lower>` (sources `[.earnedTime]`) in an injected suite; run the sweep; assert ONE lowercase record with sources `[.manual, .earnedTime]`.
  (Fixture style: memberwise `ShieldRecord` with empty token sets, exactly as `CommandPollerEffectiveStateTests` does.)

- [ ] **Step 2: Verify it fails** — `-only-testing:"Evlin iOSTests/RecordKeyNormalizationTests"`; expected FAIL/BUILD FAIL.

- [ ] **Step 3:** in `makeRecordKey`, change the savedList case to `case .savedList: return "savedList:\(targetKey.lowercased())"`. Only savedList: its targetKey is the UUID-shaped, case-insensitively-safe segment; exactApp/category targetKeys are already lowercased at their call sites — leave them untouched.
- [ ] **Step 4:** add a one-line comment at `ActionExecutor.swift:734` and near `removeExplicit` (:868) noting the helper normalizes savedList case (no functional change needed — they call the helper).
- [ ] **Step 5:** in the extension (~:427) replace the raw literal `"savedList:\(lockedSetID)"` with `ShieldRecord.makeRecordKey(tier: .savedList, targetKey: lockedSetID)` (recordKey canonical; `targetKey:` field on the constructed record stays the raw id).
- [ ] **Step 6:** in `ActiveLockStore.restore()` after `shieldRecords` is decoded (~line 606), add the one-time sweep: for every key with prefix `savedList:` whose value != its lowercased form, re-key to lowercase; when a lowercase twin exists, merge by unioning `sources` (keep the twin's other fields); mark the store's existing `migrated`/persist-after-migrate flag so the cleaned dict is persisted.
- [ ] **Step 7: Run new + no-regression suites**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Evlin iOSTests/RecordKeyNormalizationTests" \
  -only-testing:"Evlin iOSTests/CommandPollerEffectiveStateTests" \
  -only-testing:"Evlin iOSTests/CurrentRestrictionsReaderTests" test 2>&1 | tail -5
```
Expected: `TEST SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add "Evlin iOS/Models/ShieldRecord.swift" "Evlin iOS/Services/ActionExecutor.swift" \
        "Evlin iOS/Services/ActiveLockStore.swift" \
        "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift" \
        "Evlin iOSTests/RecordKeyNormalizationTests.swift"
git commit -m "fix(screentime): lowercase savedList recordKey + one-time re-key sweep (immortal-lock bug)"
```

---

## Task 6: iOS — extension cap/pool label split + cap read-back fix

**Files:**
- Modify: `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` (`handleEarnedThreshold` ~:375–411, `applyEarnedTimeShield` ~:475)
- Modify: `Evlin iOS/Services/APIClient.swift` (`EarnedPolicyDeviceDTO`, ~:2632–2637)
- Modify: `Evlin iOS/Views/Profile/DeviceAppsSheet.swift` (reader, ~:162)

**6b root cause (bug #5, VERIFIED):** backend serializes the per-device cap as `device_cap_minutes` (`app/schemas/earned_time.py:79`) but `EarnedPolicyDeviceDTO` decodes `daily_cap_minutes` (APIClient.swift:2634) — the JSON key never matches, the optional is always nil, and `DeviceAppsSheet.swift:162` falls back to `policy.pool_minutes`. That is exactly why "DEVICE DAILY TOTAL" always shows the pool.

- [ ] **Step 1 (6b):** rename `EarnedPolicyDeviceDTO.daily_cap_minutes` → `device_cap_minutes`; update the sole reader `DeviceAppsSheet.swift:162` to `devEntry.device_cap_minutes ?? policy.pool_minutes`. Leave the top-level `EarnedPolicyDTO.daily_cap_minutes` (~:2620) and its else-branch fallback (~:167) untouched — the top-level PolicyResponse has no per-device cap; that branch is the no-device-match fallback.
- [ ] **Step 2 (6a):** in `handleEarnedThreshold`, after `effectiveCap` is computed and before the `applyEarnedTimeShield` call (~:411), derive the binding budget (locals verified in scope: `poolMinutes`, `capMinutes`, `adjustedN`):

```swift
        // Which budget actually bound: an explicit device cap below the pool
        // means this exhaustion is the DEVICE CAP's, not the shared pool's.
        let boundSource: ScreenTimeEvent.Source =
            (capMinutes < poolMinutes && adjustedN >= capMinutes) ? .deviceCap : .earnedPool
```

Thread `boundSource` into `applyEarnedTimeShield(..., source: boundSource)` (add the parameter) and use it in the `emitEvent(...)` call (~:475): `source: source`, `reason: source == .deviceCap ? "cap_exhausted" : "pool_exhausted"`. When `capMinutes == poolMinutes` (R7 collapse, no explicit cap) the derivation correctly defaults to `.earnedPool`.
- [ ] **Step 3: Build** — same xcodebuild build command; expected `** BUILD SUCCEEDED **` (app + extension).
- [ ] **Step 4: Commit**

```bash
git add "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift" \
        "Evlin iOS/Services/APIClient.swift" "Evlin iOS/Views/Profile/DeviceAppsSheet.swift"
git commit -m "fix(screentime): deviceCap vs earnedPool exhaustion source split + cap read-back DTO field (bug #5)"
```

---

## End-to-end verification (manual, with the user)

1. Backend up (`colima start` + `./dev.sh`); Cmd+R both phones.
2. Lower pool below current usage → timeline shows `policy_lowered_lock` + a queued shield command; kid device locks.
3. Parent unlock → SQL shows `selected_lock_command_id` cleared; keep using the device past the cap → a NEW lock fires the same day (bug #6 gone).
4. Raise pool above usage → `policy_raised_unlock` + earned_time-only unshield; a manual shield placed beforehand survives; the FB per-app shield survives.
5. Write a tomorrow-dated config via API → today's policy/summary/ingest still use today's pool (Fix 3).
6. Exhaust at an explicit cap < pool → timeline row has `source=deviceCap`, `reason=cap_exhausted`; "DEVICE DAILY TOTAL" sheet shows the true cap after edit (bug #5).
7. The parent lock button: no more immortal red state after unlock (recordKey normalized; sweep cleaned old records).
