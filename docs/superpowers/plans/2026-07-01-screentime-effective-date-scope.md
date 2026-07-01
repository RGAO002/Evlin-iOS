# Screen-Time effective_date Bleed Fix — Scope Notes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans once this plan is expanded to executable TDD steps. **STATUS: scope + design captured; byte-accurate TDD steps are NOT yet written** (they require a focused read pass of the sites below). Do NOT implement from this doc until the tasks are expanded.

**Goal:** A "tomorrow" earned-time config/cap change must not affect **today**. Today's policy must stay in force until the day flips; every active-policy read must be scoped to the day it is answering for.

**Why split from Tier 1:** unlike the two Tier-1 fixes (one iOS mirror, one one-line recompute), this threads a new `as_of` day parameter through shared loaders and their ~6 callers, edits two inline queries, and changes supersede semantics. It is a careful multi-site backend change, not a near-zero-risk edit. Repo: `Evlin-Backend`, file `app/services/earned_time_service.py`.

## Design

1. **Day-scope every active-policy read.** Active policy = "latest enabled row with `effective_date <= as_of` and `superseded_at IS NULL`", ordered by `effective_date DESC LIMIT 1`. `as_of` comes from the caller's context:
   - sample **ingest** → `body.usage_date`
   - device-day **snapshot** → the requested `usage_date`
   - **summary** → the query date
   - **policy** read → child-timezone "today"
2. **Supersede at effective_date, not now().** A "tomorrow" config must set the prior row's `superseded_at` to the **new row's `effective_date`** (i.e. the boundary), so today's row stays active for today's reads.

## Affected sites (verified line anchors — read each before writing steps)

- `_load_active_config` (`earned_time_service.py:798`) — shared loader; add `as_of: date` param + `.where(EarnedTimeConfig.effective_date <= as_of)`.
- `_load_active_cap` (`earned_time_service.py:817`) — shared loader; add `as_of: date` param + `.where(EarnedTimeDeviceCap.effective_date <= as_of)`.
- `_load_active_caps_for_profile` (`earned_time_service.py:836`) — same treatment.
- Inline active-config query in `get_policy` (`earned_time_service.py:528`) — add the `effective_date <= as_of` filter.
- Inline active-config query in `get_summary` (`earned_time_service.py:670`) — add the `effective_date <= as_of` filter.
- **All callers** of the loaders must pass `as_of` (thread from their context): `ingest_sample` (uses `body.usage_date`), `current_device_day_snapshot` (uses `usage_date`), plus any cascade/config-write paths that read active config/cap.
- Supersede helper `_supersede_and_insert_config` (and the device-cap equivalent) — change `superseded_at = now()` → `superseded_at = <new row effective_date>` for future-effective writes. (Read the helper first: `_effective_date_for` is at `earned_time_service.py:913`.)

## Tests to add (targeted regressions, existing pytest infra)

Mirror `tests/test_earned_time_config.py` / `tests/test_earned_time_remaining_recompute.py` (DB-gated on `EVLIN_TEST_DATABASE_URL`; `client`/`session` shared per `tests/conftest.py`):

1. **Tomorrow decrease does not bleed into today:** with an active pool=120 effective today, write a pool=60 config effective **tomorrow**; assert today's `get_summary` / device snapshot still see pool=120 (today's remaining unchanged), and tomorrow's `as_of` sees 60.
2. **Today decrease applies today:** pool=120 → pool=60 effective **today** → today sees 60.
3. **Supersede boundary:** after a tomorrow-effective write, the prior today row is still returned by an `as_of=today` read (not superseded early).

## Expansion checklist (do this to make the plan executable)

- [ ] Read `_load_active_config` / `_load_active_cap` / `_load_active_caps_for_profile` bodies + signatures.
- [ ] Read the inline queries in `get_policy` and `get_summary`.
- [ ] Read every caller of the three loaders; list the exact `as_of` source for each.
- [ ] Read `_supersede_and_insert_config` + `_effective_date_for` (`:913`) and the device-cap supersede path.
- [ ] Write per-site TDD tasks (failing test → minimal edit → green → commit), one commit per coherent site group.
