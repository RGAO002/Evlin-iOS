# Locked-Set Full Coverage ("Paper Lock" Fix) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the "paper-thin lock" defect proven by the 2026-07-02 evening device timeline (`.superpowers/sdd/progress.md`, "NEW TIER2 CASE"): a kid's App-Controls selection ("all apps and categories") produced a "Locked set" shield that only covered catalog-**matched** app tokens — unmatched apps and every category were unshielded while the parent's lock button correctly showed red. Root cause: catalog matching (bundle-id/display-name binding) silently gates what gets shielded, when it must only ever gate *display*. Fix: when the kid's device locks the "Locked set", the ManagedSettings shield must cover **everything currently in the kid's local App-Controls `FamilyActivitySelection`** — apps and categories, matched or not — by reading the device-local selection directly instead of relying on the backend's catalog-matched token enumeration. A selection that included "all apps and categories" additionally engages the existing `appliesToAll` shield tier (`ActivityCategoryPolicy.all()`), which today is wired end-to-end for the `.all`/`.allApps` tiers but is never set for `.savedList`.

**Architecture:** iOS (`Evlin-iOS`, branch `calendar-in-chat`) becomes the authority for "what does 'Locked set' cover right now" — `ActionExecutor.buildShieldRecord`'s `.savedList` case and the extension's `applyEarnedTimeShield` both switch from "prefer backend-enumerated tokens, fall back to a blob nobody populates" to "always union the device-local `DefaultLockGroupStore` selection into the shield, in addition to whatever the backend sent." Backend (`Evlin-Backend`, same branch) is untouched for the token-union fix (device-local authority makes backend enumeration display/audit-only) but gains ONE new boolean, `all_selected`, threaded from the K-side upload of the "Locked set" list through to the lock-command payload, so the executor can also flip `appliesToAll = true` for `.savedList` exactly like it already does for `.all`/`.allApps` — reusing the fully-wired `ActiveLockStore.recomputeAndApply()` broad-shield path (`store.shield.applicationCategories = .all()`) instead of inventing a new enforcement mechanism.

**Tech Stack:** FastAPI, SQLAlchemy async, asyncpg, pytest(+asyncio, DB-gated); Swift, XCTest, FamilyControls/ManagedSettings.

**Design decision (chosen: hybrid of (a) + existing `appliesToAll` plumbing, closest to option (a) "device-local authority"):** The device already holds the ground truth — `DefaultLockGroupStore.load()` returns the *exact* `FamilyActivitySelection` the kid picked in the FamilyActivityPicker, unfiltered by catalog binding. Backend enumeration (`ensure_selected_set` → `load_selected_set` → `applications`/`applicationCategories` in the command payload) becomes a *display/audit* projection only — it is what the parent chat/UI narrates ("3 apps, 2 categories") and remains useful offline-diagnostically, but it must never be the sole source of shield coverage. Concretely: `ActionExecutor.buildShieldRecord`'s `.savedList` case unions `DefaultLockGroupStore.load()`'s tokens into `appTokens`/`categoryTokens` unconditionally (not just when the backend sent zero tokens), and the extension's `applyEarnedTimeShield` does the same instead of relying on `earnedStore.lockedSetTokenData` (verified: nothing in the app ever writes non-nil data there — both call sites of `saveLockedSetID` pass `tokenData: nil`, so that fallback is dead code today). For "all apps and categories" specifically, we add a minimal backend flag (`all_selected` on `ChildCatalogList`, populated at upload time when the K-side selection has `FamilyActivitySelection.includeEntireCategory`/every known category checked — practically: iOS sets it because it, not the backend, can see the raw picker semantics) threaded into the `savedList` command payload as `target.all_selected`, so the executor can set `appliesToAll = true` and get Apple's true "shield every category" enforcement (`ActivityCategoryPolicy.all()`) rather than a token enumeration that can never be complete (new apps installed after lock, unrentable system categories, etc.). This beats pure option (a) alone because token-only coverage still misses *future* apps/categories under "select all"; it beats pure option (b) (persist-everything, drop match gates) because match gates already don't exist on the enforcement read-path once we bypass backend enumeration — persisting unmatched entries server-side would still require a *second* code path (server round-trip) to reach parity with data the device already has locally, and would not fix the "new app after lock" gap that `appliesToAll` fixes for free. It also does not touch the offline case: `DefaultLockGroupStore` is local storage, so the device can enforce the full local selection even with zero network connectivity, which pure backend-enumeration (option b) cannot do. Multi-device: each child device syncs its own local selection into the shield it applies to itself — this is unchanged from today's per-device architecture (`ChildCatalogList` is already scoped to `child_device_id`).

**Anchor dossier:** All anchors in this plan are independently verified by direct file reads (see Task sections). No `.superpowers/sdd/*-anchors.md` file was pre-generated for this case; this plan carries the anchors inline.

## Global Constraints

- Backend repo: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend` (Task 1, branch `calendar-in-chat`). iOS repo: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS` (Tasks 2–4, same branch).
- Backend DB tests require `EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test` (they skip without it) and the venv: `source .venv/bin/activate`. iOS tests: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' test`, filtered via `-only-testing:`.
- Commits include ONLY the files named in each task. Never stage `.env`, `xcuserstate`, or `.DS_Store`. Never stage unrelated `project.pbxproj` churn beyond target-membership additions. **Do NOT push either repo** — the user controls pushes (backend push auto-deploys to Render).
- **Backend whole-suite check (non-negotiable, every backend task):** `EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test python -m pytest -q` — confirm no NEW reds vs baseline, AND explicitly confirm these five stay green: `tests/test_config_change_commands.py`, `tests/test_screen_time_events_api.py`, `tests/test_earned_time_policy_summary.py`, `tests/test_earned_time_remaining_recompute.py`, `tests/test_earned_time_auto_lock.py`.
- **iOS no-regression check (non-negotiable, every iOS task):** these existing classes MUST stay green — `CommandPollerEffectiveStateTests`, `CurrentRestrictionsReaderTests`, `DeviceIdentityTests`, `ScreenTimeEventUploaderTests`, `RecordKeyNormalizationTests` (xcodebuild, simulator `iPhone 17`).
- **New regression coverage this plan MUST add** (binding, from the task brief): (1) a backend or iOS test proving a lock covers an unmatched app and a category (device-local union path); (2) a test proving an "all apps and categories" selection covers an app not present in the catalog at all (appliesToAll path). Both land in Task 3 (iOS unit tests, since the union/appliesToAll logic is entirely iOS-side) plus a Task 1 backend test for the `all_selected` plumbing round-trip.
- **Zero placeholders.** Every step below has verified locals and exact anchors; anywhere an anchor could not be nailed to the line, it is called out explicitly in "Anchors I could not fully nail" at the end.

### Semantic rules (binding — user's spec, 2026-07-02)

1. **Matching is display-only.** Catalog bundle-id/display-name matching (`ChildAppCatalogEntry.token_available`, `identity_source`, etc.) may determine what the parent SEES in chat/UI previews. It must NEVER determine what gets shielded when the Locked set is locked.
2. **"Has it → shield it."** If a token (app or category) is present anywhere in the kid's current App-Controls `FamilyActivitySelection`, locking the Locked set shields it — matched or not, catalog-uploaded or not.
3. **"All apps and categories" → `appliesToAll`.** When the K-side selection is (or becomes, via Apple's "Select All" picker affordance) the maximal selection, the shield must use `ActivityCategoryPolicy.all()` semantics (the existing `appliesToAll` broad-shield path), not a token enumeration — because enumeration can never cover apps installed after the lock engages.
4. **Selection-changes-while-locked stays out of scope for this plan.** progress.md's Tier2 addendum ("apps added to app-control/locked-set while a shield is active do NOT join the existing shield — token snapshot at lock time") is a known, separate limitation. This plan fixes the snapshot's *completeness at lock time*; it does not make the shield live-reactive to later selection edits. Flagged as a follow-up, not blocking.

---

## File Structure

**Backend (Evlin-Backend):**
- **Modify** `app/db/models/child_catalog_list.py` — Task 1 (add `all_selected: Mapped[bool]` column to `ChildCatalogList`).
- **Create** migration `alembic/versions/<rev>_add_all_selected_to_catalog_list.py` — Task 1.
- **Modify** `app/api/routes/child_device.py` — Task 1 (`ChildCatalogListUploadRequest.all_selected` field; persist it in `upload_child_catalog_list`).
- **Modify** `app/services/app_control_execution.py` — Task 1 (`_queue_app_control_list` threads `saved_list.all_selected` into `payload_target["all_selected"]`).
- **Modify** `tests/test_catalog_list_upload.py` (or nearest existing catalog-list test file — create with standard header if none exists) — Task 1 regression test.

**iOS (Evlin-iOS):**
- **Modify** `Evlin iOS/Services/APIClient.swift` — Task 2 (`PollTargetDTO.all_selected: Bool?` decode; `ControlListInput` gains `allSelected: Bool`).
- **Modify** `Evlin iOS/Services/LockedSetBackendSync.swift` — Task 2 (`LockedSetSyncInputBuilder` computes `allSelected` from the raw `FamilyActivitySelection`, not from `catalogListMembers`).
- **Modify** `Evlin iOS/Services/ActionExecutor.swift` — Task 3 (`buildShieldRecord`'s `.savedList` case unions `DefaultLockGroupStore.load()` tokens + reads `cmd.target.allSelected` to set `appliesToAll`).
- **Modify** `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` — Task 3 (`applyEarnedTimeShield` unions `DefaultLockGroupStore.load()` tokens instead of the dead `lockedSetTokenData` blob path; reads an `EarnedTimeStore.lockedSetAllSelected` flag).
- **Modify** `Evlin iOS/Services/EarnedTimeStore.swift` — Task 3 (`lockedSetAllSelected: Bool` read/write pair, persisted alongside `lockedSetID`).
- **Modify** `Evlin iOS/Views/Profile/ProfileView.swift` and `Evlin iOS/Services/CommandPoller.swift` — Task 3 (the two `saveLockedSetID` call sites also persist `allSelected` learned from the backend policy/lock response).
- **Create** `Evlin iOSTests/LockedSetFullCoverageTests.swift` — Task 3 unit tests (unmatched app + category coverage; all-selected coverage of an uncataloged app).

---

## Task 1: Backend — `all_selected` flag on `ChildCatalogList` + payload threading

**Files:**
- Modify: `app/db/models/child_catalog_list.py`
- Create: `alembic/versions/<rev>_add_all_selected_to_catalog_list.py`
- Modify: `app/api/routes/child_device.py` (`ChildCatalogListUploadRequest`, `upload_child_catalog_list`, ~lines 154–162, 906–990)
- Modify: `app/services/app_control_execution.py` (`_queue_app_control_list`, lines 944–1043)
- Test: `tests/test_catalog_list_upload.py` (create, or append to nearest existing catalog-list upload test module — grep `upload_child_catalog_list` under `tests/` first to check for an existing home)

**Interfaces:**
- Consumes: `ChildCatalogList` model (`app/db/models/child_catalog_list.py:33`, columns verified at lines 43–73 above); `upload_child_catalog_list` route (`app/api/routes/child_device.py:911`, request schema `ChildCatalogListUploadRequest` at lines 154–162); `_queue_app_control_list` (`app/services/app_control_execution.py:944`), which already builds `payload_target` via `_base_target` (line 970) and updates it at lines 1011–1019 depending on whether `member_count > 0`.
- Produces: `ChildCatalogList.all_selected: bool` (default `False`) persisted from the upload payload; `payload_target["all_selected"]` (new key) set to `saved_list.all_selected` in the `savedList` lock-command payload, independent of whether `member_count > 0` or the blob fallback fires — this must be set UNCONDITIONALLY (outside the `if member_count > 0 / elif selection_blob_base64 / else` branch) so iOS gets the flag no matter which coverage path the backend took.

- [ ] **Step 1: Write the failing test**

First check for an existing home:
```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
grep -rl "upload_child_catalog_list\|/child/catalog-list" tests/ | head -5
```
If a suitable file exists (e.g. `tests/test_child_catalog_list.py` or similar), append to it using its existing `pytestmark`/client fixture pattern. Otherwise create `tests/test_catalog_list_upload.py` with the same DB-gated `pytestmark` header as `tests/test_screen_time_events_api.py`.

```python
async def test_upload_catalog_list_persists_all_selected(client, session): ...
    # 1. Seed family + child-mode Device (clone seed helpers from the chosen
    #    existing test module's fixtures).
    # 2. POST /child/catalog-list with body:
    #    {device_id, list_name: "Locked set", all_selected: true,
    #     members: [{target_type: "app", alias_key: <uuid of a seeded
    #     ChildAppCatalogEntry>}]}
    #    (seed one ChildAppCatalogEntry first so alias_key resolves.)
    # 3. assert response 200
    # 4. re-fetch the ChildCatalogList row by (child_device_id, list_name) ->
    #    assert row.all_selected is True

async def test_lock_command_payload_carries_all_selected_regardless_of_member_count(
    session, monkeypatch
): ...
    # 1. Seed a ChildCatalogList with all_selected=True and ZERO members
    #    (member_count == 0 -> exercises the selection_blob_base64 branch,
    #    or the final `else` HTTPException branch if blob is also empty —
    #    seed a non-empty selection_blob_base64 to avoid the exception).
    # 2. Call app_control_execution.queue_app_control(..., target=list target,
    #    verb="shield") directly (async, DB session).
    # 3. Inspect the inserted Command.payload["target"]["all_selected"] -> True.
    # 4. Repeat with member_count > 0 (seed one active/token-available
    #    ChildAppCatalogEntry as a member) and all_selected=True -> same assert,
    #    proving the flag threads through BOTH branches of _queue_app_control_list.
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
source .venv/bin/activate
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_catalog_list_upload.py -v
```
Expected: FAIL — `all_selected` does not exist on the model/schema/payload yet.

- [ ] **Step 3: Add the column + migration**

In `app/db/models/child_catalog_list.py`, inside `class ChildCatalogList` (line 33), add after `status` (line 64):
```python
    all_selected: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false"
    )
```
(Verify `Boolean` is already imported at the top of the file — it is used implicitly by other boolean columns in sibling model files; if not imported here, add `from sqlalchemy import Boolean` or use whatever import style the file's other columns use — check the file's import block first.)

Generate the migration:
```bash
alembic revision -m "add all_selected to child_catalog_list"
```
Fill in the generated file's `upgrade()`/`downgrade()`:
```python
def upgrade() -> None:
    op.add_column(
        "evlin_child_catalog_list",
        sa.Column("all_selected", sa.Boolean(), nullable=False, server_default="false"),
    )


def downgrade() -> None:
    op.drop_column("evlin_child_catalog_list", "all_selected")
```

- [ ] **Step 4: Wire the upload route**

In `app/api/routes/child_device.py`, `ChildCatalogListUploadRequest` (line 154), add a field after `app_count` (line 161):
```python
    all_selected: bool = False
```
In `upload_child_catalog_list` (function body starting line 911), find where the row is created/updated (the block after `row = natural_owner` / `existing_by_id.get(...)`, continuing past line 955 — read the full function body first, since the anchors dossier for this route was not pre-generated; the row-write block sets `list_name`, `aliases`, `selection_blob_base64`, `app_count`, `status` — add `row.all_selected = req.all_selected` alongside those same assignments, for both the create-new-row and update-existing-row branches).

- [ ] **Step 5: Wire the lock-command payload**

In `app/services/app_control_execution.py`, `_queue_app_control_list` (line 944), the `payload_target` dict is built at line 970 via `_base_target(...)` then mutated across lines 980–1024 depending on `member_count`. Add, immediately after line 978 (right after the `_base_target` call, BEFORE the `lock_source`/`unlock_sources` conditional at lines 982–985), so it applies unconditionally to every branch below it:
```python
    payload_target["all_selected"] = bool(saved_list.all_selected)
```

- [ ] **Step 6: Run tests + whole suite**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_catalog_list_upload.py -v
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_config_change_commands.py tests/test_screen_time_events_api.py \
    tests/test_earned_time_policy_summary.py tests/test_earned_time_remaining_recompute.py \
    tests/test_earned_time_auto_lock.py -v
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest -q   # no NEW reds vs baseline
alembic upgrade head   # apply the migration to the dev DB
```
Expected: all new tests PASS; all five guardrail suites stay green; no new reds; migration applies cleanly.

- [ ] **Step 7: Commit**

```bash
git add app/db/models/child_catalog_list.py app/api/routes/child_device.py \
        app/services/app_control_execution.py alembic/versions/*_add_all_selected_to_catalog_list.py \
        tests/test_catalog_list_upload.py
git commit -m "feat(app-control): thread all_selected flag through catalog-list upload -> lock command payload"
```

---

## Task 2: iOS — upload `allSelected` alongside the Locked-set sync

**Files:**
- Modify: `Evlin iOS/Services/APIClient.swift` (`PollTargetDTO`, `ControlListInput` — grep exact line numbers first; verified above only for `PollTargetDTO.target_all` at line 417/437/465, which is a DIFFERENT field — `all_selected` is new and separate)
- Modify: `Evlin iOS/Services/LockedSetBackendSync.swift` (`LockedSetSyncInputBuilder.build(selection:existingAliasKey:)`, lines 296–304 of the plan that created this file — re-verify current line numbers by reading the file fresh, since Wave-1/other work may have shifted it)

**Interfaces:**
- Consumes: `FamilyActivitySelection.categoryTokens` / `.applicationTokens` (Apple FamilyControls API — no "select all" sentinel exists; "select all" surfaces as every available category token being present). `ControlListInput` struct (defined at `APIClient.swift`, referenced at `docs/superpowers/plans/2026-06-23-locked-set-sync.md:613` as living at `APIClient.swift:1174` — re-verify current line since that plan predates Wave-1).
- Produces: `ControlListInput.allSelected: Bool` new field, serialized as JSON key `all_selected`; `LockedSetSyncInputBuilder.build(selection:existingAliasKey:)` computes it.

**All-selected heuristic (binding):** iOS cannot ask Apple's FamilyControls framework "did the user tap Select All" directly — `FamilyActivitySelection` has no such bit. The practical, verifiable signal available today is `selection.categoryTokens.count >= <all known category tokens the device has ever seen>` OR (simpler, and the one this plan uses) **`selection.includeEntireCategory`** — confirm this property's exact name by inspecting the `FamilyActivitySelection` type in the FamilyControls framework header (`Xcode > Jump to Definition` on `FamilyActivitySelection` from any existing call site, e.g. `DefaultLockGroupStore.swift`) before implementing; if `includeEntireCategory` (or equivalent) is not present in this SDK version, fall back to: `allSelected = !selection.categoryTokens.isEmpty && selection.applicationTokens.isEmpty` is WRONG (too broad) — instead use a conservative heuristic: `allSelected = selection.categoryTokens.count >= AppleFamilyControlsCategoryCatalog.knownCategoryCount` if such a catalog exists in this codebase (grep `ActivityCategory\b` under `Evlin iOS/` first), else ship Task 2 with `allSelected` always `false` (safe default — Task 3's per-token union still fixes the primary bug) and flag the heuristic as a follow-up. **Do not guess the SDK symbol name in code — verify by Xcode jump-to-definition or Apple's documentation before writing the property access**, since compiling against a wrong property name is a hard build failure, not a soft regression.

- [ ] **Step 1: Verify the FamilyActivitySelection "all selected" signal**

```bash
grep -rn "includeEntireCategory\|FamilyActivitySelection" "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DefaultLockGroupStore.swift"
```
Open Xcode, jump to the `FamilyActivitySelection` type definition, and confirm the exact property/API for detecting an "entire category" or "all categories" selection. Record the finding in the PR description or a plan addendum before Step 2.

- [ ] **Step 2: Write the failing test** — create `Evlin iOSTests/LockedSetFullCoverageTests.swift` (this file is shared with Task 3; start it here):

```swift
import XCTest
import FamilyControls
@testable import Evlin_iOS

final class LockedSetFullCoverageTests: XCTestCase {

    func test_buildInput_allSelectedFlag_reflectsFullCategorySelection() {
        // Construct a FamilyActivitySelection using the verified Step-1 API
        // to represent "all categories selected" vs "one category selected".
        // Assert LockedSetSyncInputBuilder.build(selection:existingAliasKey:)
        // ?.allSelected == true for the full-selection case and == false for
        // the partial case.
    }
}
```
(Exact assertions depend on Step 1's finding — write them once the real API is confirmed, not before.)

- [ ] **Step 3: Verify it fails / doesn't compile**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS"
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Evlin iOSTests/LockedSetFullCoverageTests" test 2>&1 | tail -20
```

- [ ] **Step 4: Add `allSelected` to `ControlListInput` and the upload call**

In `APIClient.swift`, find `struct ControlListInput` (grep `struct ControlListInput` to get the current line — the 2026-06-23 plan cited `:1174` but that has likely shifted). Add a field:
```swift
let allSelected: Bool
```
Add `all_selected` to its `Encodable` coding keys / JSON body construction (match however the struct currently serializes `selectionBlobBase64` — same pattern, snake_case wire key).

- [ ] **Step 5: Compute it in `LockedSetSyncInputBuilder`**

In `LockedSetBackendSync.swift`, `LockedSetSyncInputBuilder.build(selection:existingAliasKey:)` (originally lines 298–304 per the source plan; re-read the file to confirm current lines), compute `allSelected` using the Step-1-verified API and pass it into both `build(members:existingAliasKey:)` overloads (add an `allSelected: Bool = false` parameter to the `members:` overload too, since the `selection:` overload delegates to it).

- [ ] **Step 6: Build + run**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Evlin iOSTests/LockedSetFullCoverageTests" \
  -only-testing:"Evlin iOSTests/CommandPollerEffectiveStateTests" \
  -only-testing:"Evlin iOSTests/CurrentRestrictionsReaderTests" \
  -only-testing:"Evlin iOSTests/DeviceIdentityTests" \
  -only-testing:"Evlin iOSTests/ScreenTimeEventUploaderTests" \
  -only-testing:"Evlin iOSTests/RecordKeyNormalizationTests" test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add "Evlin iOS/Services/APIClient.swift" "Evlin iOS/Services/LockedSetBackendSync.swift" \
        "Evlin iOSTests/LockedSetFullCoverageTests.swift"
git commit -m "feat(ios): upload allSelected flag with Locked-set sync"
```

---

## Task 3: iOS — device-local union in `ActionExecutor` + extension `applyEarnedTimeShield`

**Files:**
- Modify: `Evlin iOS/Services/ActionExecutor.swift` (`buildShieldRecord`, `.savedList` case, lines 561–591)
- Modify: `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` (`applyEarnedTimeShield`, lines 426–471)
- Modify: `Evlin iOS/Services/EarnedTimeStore.swift` (new `lockedSetAllSelected` read/write pair, alongside `lockedSetID` at lines 83–109)
- Modify: `Evlin iOS/Views/Profile/ProfileView.swift` (`applyListIDIfNeeded`, line 924) and `Evlin iOS/Services/CommandPoller.swift` (~line 596) — persist `allSelected` at the same two call sites that already persist `lockedSetID`
- Modify: `Evlin iOS/Services/APIClient.swift` (`PollTargetDTO` gains `all_selected: Bool?` decode, mirroring the existing `target_all` decode pattern at lines 417/437/465 but as a NEW distinct key)
- Test: `Evlin iOSTests/LockedSetFullCoverageTests.swift` (append)

**Interfaces:**
- Consumes: `DefaultLockGroupStore.load() -> FamilyActivitySelection` (existing, used today by `syncLockedSetToBackend`); `cmd.target.allSelected` (new, from Task 2's backend `all_selected` payload key, decoded via the same `PollTargetDTO` pattern as `target_all`); `EarnedTimeStore.shared.lockedSetAllSelected` (new, Task 3).
- Produces: `.savedList` `ShieldRecord` whose `appTokens`/`categoryTokens`/`webDomainTokens` are the UNION of (a) backend-enumerated tokens (existing `CatalogCommandTokenData` decode, lines 567–572) and (b) `DefaultLockGroupStore.load()`'s raw tokens (device-local, unconditional — not gated behind "backend sent zero tokens" as today); `appliesToAll = true` when `cmd.target.allSelected == true` (parent-triggered lock path) or `EarnedTimeStore.shared.lockedSetAllSelected == true` (extension exhaustion path).

**Anchor — current (buggy) `.savedList` case, `ActionExecutor.swift:561–591`:**
```swift
case .savedList:
    if let id = cmd.target.listID {
        targetKey = id.uuidString
    } else {
        throw ExecuteError.malformed
    }
    if let catalogApps = try CatalogCommandTokenData.decodedApplicationTokenSet(from: cmd.target) {
        appTokens = catalogApps
    }
    if let catalogCategories = try CatalogCommandTokenData.decodedCategoryTokenSet(from: cmd.target) {
        categoryTokens = catalogCategories
    }
    if appTokens.isEmpty && categoryTokens.isEmpty {
        let sel: FamilyActivitySelection
        if let blob = blob,
           let decoded = (try? JSONDecoder().decode(FamilyActivitySelection.self, from: blob))
                      ?? (try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: blob)) {
            sel = decoded
        } else if let name = cmd.target.listName,
                  let local = LocalAliasStore.shared.savedList(named: name) {
            sel = local
        } else {
            throw ExecuteError.listNotFound(cmd.target.listName ?? "(unnamed)")
        }
        appTokens = sel.applicationTokens
        categoryTokens = sel.categoryTokens
        webDomainTokens = sel.webDomainTokens
    }
    displayName = cmd.target.listName ?? "saved list"
```
The bug: the local-selection fallback only fires when the backend sent ZERO tokens (`appTokens.isEmpty && categoryTokens.isEmpty`, line 573). Whenever the backend sends ANY matched tokens (the common case — most apps DO match), the fallback never runs and unmatched apps/categories in `DefaultLockGroupStore`'s selection are silently dropped.

- [ ] **Step 1: Write the failing tests** (append to `Evlin iOSTests/LockedSetFullCoverageTests.swift`)

```swift
func test_savedListShield_unionsUnmatchedDeviceLocalTokensWithBackendTokens() {
    // 1. Seed DefaultLockGroupStore with a FamilyActivitySelection containing
    //    TWO application tokens (fixture tokens, same pattern as
    //    CommandPollerEffectiveStateTests uses for ApplicationToken fixtures)
    //    and ONE category token.
    // 2. Build a LockCommand whose target carries backend-enumerated tokens
    //    for only ONE of the two app tokens (simulating "one app matched the
    //    catalog, one didn't, category never had a catalog entry").
    // 3. Call ActionExecutor's buildShieldRecord (may need to expose it
    //    `internal` for test access, matching how buildShieldRecord is
    //    already reached in existing ActionExecutor tests, if any exist —
    //    grep `buildShieldRecord` under Evlin iOSTests/ first).
    // 4. Assert the resulting ShieldRecord.appTokens contains BOTH app
    //    tokens (matched + unmatched) and .categoryTokens contains the
    //    category token — proving the union, not just the backend set.
}

func test_savedListShield_allSelectedSetsAppliesToAll() {
    // 1. Build a LockCommand whose target.allSelected == true.
    // 2. Call buildShieldRecord.
    // 3. Assert ShieldRecord.appliesToAll == true — this is what makes
    //    ActiveLockStore.recomputeAndApply() take the store.shield
    //    .applicationCategories = .all() branch (ActiveLockStore.swift:459),
    //    covering apps not in ANY catalog, matched or not, present or not
    //    yet installed.
}

func test_extensionShield_unionsDeviceLocalTokensOnExhaustion() {
    // Mirrors the first test but for the extension's applyEarnedTimeShield
    // path: seed DefaultLockGroupStore + EarnedTimeStore.lockedSetID, call
    // applyEarnedTimeShield (or its testable core if refactored out), assert
    // the resulting ShieldRecord's appTokens/categoryTokens include tokens
    // that were never in earnedStore.lockedSetTokenData (proving the fix
    // moved off the dead blob path onto DefaultLockGroupStore).
}

func test_extensionShield_lockedSetAllSelectedSetsAppliesToAll() {
    // Seed EarnedTimeStore.lockedSetAllSelected = true, call
    // applyEarnedTimeShield, assert ShieldRecord.appliesToAll == true.
}
```

- [ ] **Step 2: Verify they fail**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Evlin iOSTests/LockedSetFullCoverageTests" test 2>&1 | tail -30
```
Expected: FAIL on the union/appliesToAll assertions (current code only unions on the zero-tokens fallback and never sets `appliesToAll` for `.savedList`).

- [ ] **Step 3: Fix `ActionExecutor.buildShieldRecord`'s `.savedList` case**

Replace the block quoted in the anchor above with:
```swift
case .savedList:
    if let id = cmd.target.listID {
        targetKey = id.uuidString
    } else {
        throw ExecuteError.malformed
    }
    if let catalogApps = try CatalogCommandTokenData.decodedApplicationTokenSet(from: cmd.target) {
        appTokens = catalogApps
    }
    if let catalogCategories = try CatalogCommandTokenData.decodedCategoryTokenSet(from: cmd.target) {
        categoryTokens = catalogCategories
    }
    // Device-local union (paper-lock fix): backend enumeration only ever
    // contains catalog-MATCHED tokens (app_control_execution.py resolves
    // list membership through ensure_selected_set's token_available filter).
    // The kid's own FamilyActivitySelection in DefaultLockGroupStore is the
    // ground truth for "what did the kid actually pick" — union it in
    // UNCONDITIONALLY so unmatched apps and every category are covered too,
    // not just when the backend sent zero tokens.
    let localSelection = DefaultLockGroupStore.load()
    appTokens.formUnion(localSelection.applicationTokens)
    categoryTokens.formUnion(localSelection.categoryTokens)
    webDomainTokens.formUnion(localSelection.webDomainTokens)
    // Legacy blob/local-list fallback stays as a last resort for the
    // (now rare) case where DefaultLockGroupStore itself is empty but an
    // older opaque blob or named local list still carries tokens.
    if appTokens.isEmpty && categoryTokens.isEmpty {
        let sel: FamilyActivitySelection
        if let blob = blob,
           let decoded = (try? JSONDecoder().decode(FamilyActivitySelection.self, from: blob))
                      ?? (try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: blob)) {
            sel = decoded
        } else if let name = cmd.target.listName,
                  let local = LocalAliasStore.shared.savedList(named: name) {
            sel = local
        } else {
            throw ExecuteError.listNotFound(cmd.target.listName ?? "(unnamed)")
        }
        appTokens = sel.applicationTokens
        categoryTokens = sel.categoryTokens
        webDomainTokens = sel.webDomainTokens
    }
    if cmd.target.allSelected == true {
        appliesToAll = true
    }
    displayName = cmd.target.listName ?? "saved list"
```
(`DefaultLockGroupStore.load()` is a static/free function already used elsewhere in this same target — e.g. `AppControlsV2View.swift`'s `onSave` closure per the 2026-06-23 plan — so it is safe to call from `ActionExecutor` without new imports; verify the exact call signature by reading `DefaultLockGroupStore.swift` before wiring, since the plan's earlier grep only confirmed `applicationTokens.remove`/`categoryTokens.remove` at lines 20/26, not the `load()` signature itself.)

Add `allSelected: Bool?` to `CommandTarget` (the type `cmd.target` is — grep `struct CommandTarget` or wherever `cmd.target.listID`/`cmd.target.listName` are declared, and add the new field decoded from `PollTargetDTO.all_selected` the same way `listID`/`listName` are already threaded from their respective DTO fields).

- [ ] **Step 4: Fix the extension's `applyEarnedTimeShield`**

In `DeviceActivityMonitorExtension.swift`, replace the token-population block (lines ~442–452) inside `applyEarnedTimeShield`:
```swift
            // Device-local union (paper-lock fix): earnedStore.lockedSetTokenData
            // is never actually populated anywhere in the app today (both
            // saveLockedSetID call sites pass tokenData: nil — ProfileView.swift:928,
            // CommandPoller.swift:596), so this blob decode was dead code. Read the
            // kid's live FamilyActivitySelection from DefaultLockGroupStore instead —
            // same ground-truth source ActionExecutor now uses on the parent-lock path.
            var appTokens: Set<ApplicationToken> = []
            var catTokens:  Set<ActivityCategoryToken> = []
            var webTokens:  Set<WebDomainToken> = []
            let localSelection = DefaultLockGroupStore.load()
            appTokens = localSelection.applicationTokens
            catTokens = localSelection.categoryTokens
            webTokens = localSelection.webDomainTokens
            // Legacy blob fallback, kept for completeness if a future writer
            // ever does populate lockedSetTokenData ahead of DefaultLockGroupStore.
            if appTokens.isEmpty && catTokens.isEmpty,
               let blob = earnedStore.lockedSetTokenData,
               let sel = try? JSONDecoder().decode(FamilyActivitySelection.self, from: blob) {
                appTokens = sel.applicationTokens
                catTokens = sel.categoryTokens
                webTokens = sel.webDomainTokens
            }
```
And change the `ShieldRecord(...)` construction's `appliesToAll: false` (line 462) to:
```swift
                appliesToAll: earnedStore.lockedSetAllSelected,
```
(Verify `DeviceActivityMonitorExtension.swift` can already see `DefaultLockGroupStore` — it is in the same App Group / shared code target as `EvlinDeviceActivityMonitor`'s other `Evlin iOS/Services/*.swift` dependencies it already imports, e.g. `ShieldRecord`, `ShieldSourceLogic`; if `DefaultLockGroupStore.swift` is not currently a member of the extension's Xcode target, add it via the project file the same way `LockedSetBackendSync.swift` was added to the app target in the 2026-06-23 plan's Task 2 Step 5.)

- [ ] **Step 5: Add `lockedSetAllSelected` to `EarnedTimeStore`**

In `EarnedTimeStore.swift`, alongside `lockedSetIDKey` (line 38) and the `lockedSetID` property (lines 83–86) and `saveLockedSetID` (line 108), add:
```swift
private let lockedSetAllSelectedKey = "earned.lockedSetAllSelected"

var lockedSetAllSelected: Bool {
    defaults?.bool(forKey: lockedSetAllSelectedKey) ?? false
}

func saveLockedSetAllSelected(_ value: Bool) {
    defaults?.set(value, forKey: lockedSetAllSelectedKey)
    defaults?.synchronize()
}
```
Add `lockedSetAllSelectedKey` to the existing `removeAll`/`reset()` key array (same array `lockedSetListAliasKeyKey` was added to per the 2026-06-23 plan's Task 1 Step 4).

- [ ] **Step 6: Persist `allSelected` at both existing `saveLockedSetID` call sites**

`ProfileView.swift:924` (`applyListIDIfNeeded`) and `CommandPoller.swift:596` both currently call `saveLockedSetID(id, tokenData: nil)`. At each site, add a companion call reading the new `all_selected` field from whatever DTO/response is in scope at that point (the policy/lock-state response that already carries `list_id` — grep the response type used at each call site, e.g. `newID` in `applyListIDIfNeeded`'s caller, to find the sibling `all_selected` field once Task 1/2 land it on the wire):
```swift
EarnedTimeStore.shared.saveLockedSetID(id, tokenData: nil)
EarnedTimeStore.shared.saveLockedSetAllSelected(response.allSelected ?? false)
```
(Exact `response.allSelected` accessor name depends on whatever DTO these two call sites decode — verify by reading the surrounding function signature at each site before wiring; do not guess the DTO's property name.)

- [ ] **Step 7: Run new + no-regression suites**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Evlin iOSTests/LockedSetFullCoverageTests" \
  -only-testing:"Evlin iOSTests/CommandPollerEffectiveStateTests" \
  -only-testing:"Evlin iOSTests/CurrentRestrictionsReaderTests" \
  -only-testing:"Evlin iOSTests/DeviceIdentityTests" \
  -only-testing:"Evlin iOSTests/ScreenTimeEventUploaderTests" \
  -only-testing:"Evlin iOSTests/RecordKeyNormalizationTests" test 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` — all new tests pass, all five guardrail classes stay green.

- [ ] **Step 8: Full build (app + extension target)**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **` (confirms the extension target compiles with the new `DefaultLockGroupStore` dependency, if it needed adding).

- [ ] **Step 9: Commit**

```bash
git add "Evlin iOS/Services/ActionExecutor.swift" \
        "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift" \
        "Evlin iOS/Services/EarnedTimeStore.swift" \
        "Evlin iOS/Views/Profile/ProfileView.swift" \
        "Evlin iOS/Services/CommandPoller.swift" \
        "Evlin iOS/Services/APIClient.swift" \
        "Evlin iOSTests/LockedSetFullCoverageTests.swift" \
        "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "fix(screentime): Locked-set shield unions device-local selection + appliesToAll for all-selected (paper-lock fix)"
```

---

## Task 4: Manual device E2E verification (with the user)

1. Kid device: in App Controls, select "all apps and categories" (or as close to it as the picker UI allows), save.
2. Confirm `syncLockedSetToBackend` fires (existing behavior) — check backend `ChildCatalogList.all_selected` is `true` via SQL or a debug endpoint.
3. Parent: lock the "Locked set". Confirm on-device: `store.shield.applicationCategories == .all()` — inspectable via `HomeSettingsSheet`'s `evlin.lastRecompute` diagnostic (`ActiveLockStore.writeRecomputeDiag`, branch should read `"all"` or `"all_apps_only"`, not `"union"`).
4. Attempt to use an app that was NEVER in the kid's catalog (e.g. a freshly installed app, or one that never got a "name this app" binding) while locked — confirm it IS shielded (this is the core regression the 2026-07-02 evening incident exposed).
5. Attempt to use a category-only app (e.g. something under Games with no explicit per-app catalog entry) while locked — confirm it IS shielded.
6. Unlock, confirm shield clears (no regression to the unlock path — `executeUnshield` is unmodified by this plan).
7. Repeat steps 1–6 for a PARTIAL selection (a few named apps only, no "all") to confirm the union logic doesn't over-shield: apps NOT in the kid's App-Controls selection at all must remain unshielded.
8. Earned-time exhaustion path: let the pool/cap exhaust naturally or via the sample-injection technique documented in progress.md (canonical `client_sample_id`s, clean up after) — confirm the extension's `applyEarnedTimeShield` shield also covers the full local selection (steps 4–5 repeated under the exhaustion trigger instead of a manual parent lock).

---

## Anchors I could not fully nail

1. **`FamilyActivitySelection`'s "all selected" signal (Task 2, Step 1).** I could not find a codebase reference to an `includeEntireCategory` (or equivalent) property in this repo's existing call sites — `DefaultLockGroupStore.swift` only exercises `.applicationTokens.remove` / `.categoryTokens.remove`, not any "select all" bit. This must be verified against the actual FamilyControls SDK (Xcode jump-to-definition or Apple docs) before Task 2 is implemented; the plan calls this out explicitly and provides a safe fallback (ship `allSelected` always `false`, defer the heuristic) rather than guessing the API shape.
2. **`ControlListInput`'s current line number.** The 2026-06-23 sync plan cited `APIClient.swift:1174`; this plan explicitly instructs re-grepping before editing since Wave-1 and other work have likely shifted it.
3. **The exact DTO/property names for `response.allSelected` at the two `saveLockedSetID` call sites (Task 3, Step 6).** I traced the call sites (`ProfileView.swift:924`, `CommandPoller.swift:596`) and confirmed both currently pass `tokenData: nil`, but did not trace the full response-type chain each function decodes its `newID`/`listID` parameter from, since that requires reading substantially more of both files than was needed to confirm the core bug. The step explicitly instructs verifying the sibling field name before wiring rather than guessing.
4. **Whether `DefaultLockGroupStore.swift` is currently a member of the `EvlinDeviceActivityMonitor` extension's Xcode target.** I confirmed the file exists and confirmed the extension file already imports sibling `Evlin iOS/Services/*.swift` types (`ShieldRecord`, `ShieldSourceLogic`), which implies a shared-source-membership pattern, but did not open `project.pbxproj` to confirm `DefaultLockGroupStore.swift` specifically is already in that target's file list. Task 3 Step 4 flags this as a possible added-file step, mirroring the precedent in the 2026-06-23 plan's Task 2 Step 5.
