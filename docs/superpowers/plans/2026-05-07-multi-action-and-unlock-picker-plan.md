# Multi-Action Staging + U1 Unlock Card + App Icons — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Multi-action commands stage as bundled proposals (one card per shield/unshield type), bare "unlock" with N≥2 active shields surfaces a checkbox U1 card, and every app/category name renders with its real Apple icon.

**Architecture:** Backend agent_loop accumulates legacy actions instead of short-circuiting on the first; new staging path bundles by type into multi-row Proposals. Backend persists kid's last `effectiveState` per device; bare unlock dispatches a U1 card whose confirm marker (`U1:<token>:all` / `U1:<token>:selected:0,2`) is intercepted at the top of `parent_chat` to bypass the agent loop. iOS gets a multi-row `ProposalCard`, a new `U1Card`, and a `NameWithIcon` helper that uses `Label(token).labelStyle(.iconOnly)` to render Apple's app icon next to display names.

**Tech Stack:** Python 3.11 / FastAPI / SQLAlchemy 2 / Alembic / pytest (backend); Swift 5.9 / SwiftUI / FamilyControls / XCTest (iOS).

---

## File Structure

### Backend — modify

| File | Responsibility added |
|---|---|
| `backend/app/db/models/device.py` | Two new columns: `last_effective_state JSONB`, `last_effective_state_at TIMESTAMP` |
| `backend/app/api/routes/child_device.py` | `ack_command` writes both new columns from `req.detail.effective_state` |
| `backend/app/schemas/agent.py` | `AgentResponse.legacy_gemini_actions: list[dict]`, `ask_pick_payloads: list[dict]` |
| `backend/app/services/agent_loop.py` | Remove short-circuit; accumulate legacy + ask_pick payloads in one pass |
| `backend/app/api/routes/parent_chat.py` | Top-of-handler U1 marker interception; `_load_effective_state`; `_stage_legacy_actions`; `_stage_bundled_proposal`; `_handle_u1_confirm`; CardContext additions |
| `backend/app/api/routes/parent_agent.py` | `_exec_legacy_shield` reads `args["actions"]` plural; `ExecResponse.legacy_actions: list[dict]` |
| `backend/app/services/chat_resolver.py` | `_route_unshield` U1 branch when `_effective_shields` injected |

### Backend — create

| File | Responsibility |
|---|---|
| `backend/alembic/versions/<timestamp>_add_last_effective_state.py` | Alembic migration adding the two device columns |
| `backend/tests/services/test_agent_loop_multi_action.py` | Accumulator behavior |
| `backend/tests/api/test_parent_chat_multi_action.py` | Bundled proposal staging + label generation |
| `backend/tests/services/test_chat_resolver_u1.py` | U1 routing branch |
| `backend/tests/api/test_parent_chat_u1_confirm.py` | Marker parsing + round-trip |

### iOS — modify

| File | Responsibility added |
|---|---|
| `Evlin iOS/Models/CardID.swift` | New `case U1` |
| `Evlin iOS/Components/ConfirmationCards/CardDispatcher.swift` | `CardContext.u1Token`, `u1ShieldList`; `.U1` switch case |
| `Evlin iOS/Components/ConfirmationCards/CardPayloadBuilder.swift` | (no-op for U1 — U1Card builds its own payload from context) |
| `Evlin iOS/Components/ConfirmationCards/ProposalCard.swift` | Multi-row layout when `args.rows.count > 1` |
| `Evlin iOS/Views/Chat/ChatViewModel.swift` | `extractAliasTargets` (plural); per-row `pendingAliasMisses`; `confirmProposal` plural results; U1 confirm round-trip |
| `Evlin iOS/Services/AgentClient.swift` | `AgentExecResult.legacyActions` plural case; `ExecResponseDTO.legacy_actions` |
| `Evlin iOS/Components/ReceiptCard.swift` | Use `NameWithIcon` for displayName lines |
| `Evlin iOS/Views/Settings/AliasManagementView.swift` | Use `NameWithIcon` per row |

### iOS — create

| File | Responsibility |
|---|---|
| `Evlin iOS/Components/Helpers/NameWithIcon.swift` | Reusable `Label(token).labelStyle(.iconOnly)` + text fallback |
| `Evlin iOS/Components/ConfirmationCards/U1Card.swift` | The U1 picker view (rows + Unlock selected / everything / Cancel) |
| `Evlin iOS/Models/U1Models.swift` | `U1ShieldEntry` Codable struct shared by CardContext + view |
| `Evlin iOSTests/MultiActionStagingTests.swift` | `extractAliasTargets`, per-row miss detection |
| `Evlin iOSTests/U1MarkerTests.swift` | Marker building helpers |

---

## Deploy Order Note

Backend tasks 1-9 are backwards-compatible (older iOS clients see the singular field). iOS tasks 10-19 handle both old and new response shapes. Land backend first, then iOS.

---

## Section A — Backend: Schema + Effective State Persistence

### Task 1: Add `last_effective_state` columns to Device

**Note:** This repo has no Alembic — `backend/app/db/engine.py:48-56` uses `Base.metadata.create_all` on startup. New columns appear automatically on next process restart for fresh schemas. For Railway (existing data), an explicit ADD COLUMN is required because `create_all` is no-op on existing tables.

**Files:**
- Modify: `backend/app/db/models/device.py`
- Create: `backend/scripts/migrations/2026_05_07_add_last_effective_state.sql`

- [ ] **Step 1: Add columns to the SQLAlchemy model**

Open `backend/app/db/models/device.py` and add inside the `Device` class (after the existing `mode` column):

```python
from datetime import datetime
from sqlalchemy import DateTime
from sqlalchemy.dialects.postgresql import JSONB

last_effective_state: Mapped[dict | None] = mapped_column(
    JSONB, nullable=True, default=None
)
last_effective_state_at: Mapped[datetime | None] = mapped_column(
    DateTime(timezone=True), nullable=True, default=None
)
```

- [ ] **Step 2: Write the SQL migration script**

Create `backend/scripts/migrations/2026_05_07_add_last_effective_state.sql`:

```sql
-- Phase 1 multi-action plan: U1 unlock card needs the most-recent
-- effectiveState the kid posted with each ack. Stored on the device row
-- so parent_chat can read without joining through the latest Command.
ALTER TABLE evlin_devices
    ADD COLUMN IF NOT EXISTS last_effective_state JSONB,
    ADD COLUMN IF NOT EXISTS last_effective_state_at TIMESTAMP WITH TIME ZONE;
```

- [ ] **Step 3: Apply locally for tests**

Local dev / CI test DBs use `create_all` on startup, so a fresh container picks up the columns automatically. To run tests against the new columns immediately without restart:

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
psql "$DATABASE_URL" -f backend/scripts/migrations/2026_05_07_add_last_effective_state.sql
```

Expected: `ALTER TABLE` (with no error if already applied).

- [ ] **Step 4: Document Railway deploy step**

Add a one-liner under `backend/scripts/migrations/README.md` (create if missing):

```markdown
# Manual SQL migrations

This repo doesn't use Alembic. New columns added to SQLAlchemy models
appear automatically on fresh DBs via `Base.metadata.create_all`. For
existing DBs (Railway production), apply each script in order against
the production DB before restarting the backend. Do not skip — `create_all`
is no-op against existing tables and won't add new columns.

| Date | Script | Reason |
|---|---|---|
| 2026-05-07 | `2026_05_07_add_last_effective_state.sql` | U1 unlock card data source |
```

- [ ] **Step 5: Commit**

```bash
git add backend/app/db/models/device.py backend/scripts/migrations/
git commit -m "feat(db): add last_effective_state columns to device + manual migration script"
```

**Railway deploy step (informational, not part of this task):** the user (or release runbook) must `psql $RAILWAY_DATABASE_URL -f 2026_05_07_add_last_effective_state.sql` before pushing the backend code.

---

### Task 2: Persist effective state on child ack

**Files:**
- Modify: `backend/app/api/routes/child_device.py:63-102`
- Test: `backend/tests/api/test_child_ack_persists_effective_state.py`

- [ ] **Step 1: Write failing test**

Create `backend/tests/api/test_child_ack_persists_effective_state.py`:

```python
import pytest
from datetime import datetime, timezone
from uuid import uuid4
from httpx import AsyncClient
from backend.app.db.models import Family, Device, Command
from backend.app.db.models.device import DeviceMode
from backend.app.db.models.command import AckStatus


@pytest.mark.asyncio
async def test_ack_persists_effective_state_on_device(
    client: AsyncClient, session
):
    family = Family(id=uuid4())
    device = Device(id=uuid4(), family_id=family.id, label="Liam", mode=DeviceMode.child)
    cmd = Command(
        family_id=family.id, target_device_id=device.id,
        payload={}, ack_status=AckStatus.pending,
    )
    session.add_all([family, device, cmd])
    await session.commit()

    eff = {
        "isBlocked": True,
        "shieldsCovering": [
            {"displayName": "Instagram", "expiresAtISO": None, "tier": "exactApp"}
        ],
        "possibleSavedListCoverage": False,
    }
    resp = await client.post("/api/v1/child/ack", json={
        "command_id": str(cmd.id),
        "status": "confirmed",
        "detail": {"verb": "shield", "display_name": "Instagram", "effective_state": eff},
    })
    assert resp.status_code == 200

    await session.refresh(device)
    assert device.last_effective_state == eff
    assert device.last_effective_state_at is not None
    assert (datetime.now(timezone.utc) - device.last_effective_state_at).total_seconds() < 5
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
pytest backend/tests/api/test_child_ack_persists_effective_state.py -v
```

Expected: FAIL — `device.last_effective_state == None`.

- [ ] **Step 3: Implement**

In `backend/app/api/routes/child_device.py`, find `ack_command` (around line 63) and after the existing block that writes `cmd.ack_effective_state` (around line 92-94), add:

```python
# Persist on the device row too — parent_chat reads this for U1 picker
# data on the next bare-unlock turn. Mirrors the per-command write but
# allows /parent/chat to fetch without joining through the latest cmd.
if req.detail and req.detail.get("effective_state"):
    device = await session.get(Device, cmd.target_device_id)
    if device is not None:
        device.last_effective_state = req.detail["effective_state"]
        device.last_effective_state_at = datetime.now(timezone.utc)
```

Add `from backend.app.db.models import Device` at the top if missing.

- [ ] **Step 4: Run to confirm pass**

```bash
pytest backend/tests/api/test_child_ack_persists_effective_state.py -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/routes/child_device.py backend/tests/api/test_child_ack_persists_effective_state.py
git commit -m "feat(child_device): persist effective_state to device row on ack"
```

---

## Section B — Backend: Multi-Action Staging Plumbing

### Task 3: Add plural fields to AgentResponse

**Files:**
- Modify: `backend/app/schemas/agent.py:29-40`

- [ ] **Step 1: Add fields**

Replace the `AgentResponse` class in `backend/app/schemas/agent.py`:

```python
class AgentResponse(BaseModel):
    message: str = ""
    reasoning: str | None = None
    proposals: list[Proposal] = Field(default_factory=list)
    receipts: list[Receipt] = Field(default_factory=list)
    cancelled_proposals: list[str] = Field(default_factory=list)
    # Singular kept for backwards compat — populated when len == 1.
    # New code reads `legacy_gemini_actions` (plural).
    legacy_gemini_action: dict | None = None
    legacy_gemini_actions: list[dict] = Field(default_factory=list)
    # Phase 2 scaffolding: ask_pick tool produces these. Phase 1 wires
    # the accumulator branch but the tool itself doesn't exist yet.
    ask_pick_payloads: list[dict] = Field(default_factory=list)
```

- [ ] **Step 2: Commit**

```bash
git add backend/app/schemas/agent.py
git commit -m "feat(agent): add plural legacy_gemini_actions + ask_pick_payloads on AgentResponse"
```

---

### Task 4: Remove agent_loop short-circuit; accumulate

**Files:**
- Modify: `backend/app/services/agent_loop.py:160-186`
- Test: `backend/tests/services/test_agent_loop_multi_action.py`

- [ ] **Step 1: Write failing test**

Create `backend/tests/services/test_agent_loop_multi_action.py`:

```python
import pytest
from unittest.mock import AsyncMock, MagicMock
from backend.app.services.agent_loop import AgentLoop, AgentInput
from backend.app.services.agent_tools.decorator import GLOBAL_REGISTRY
from backend.app.schemas.agent import AgentResponse


@pytest.mark.asyncio
async def test_two_legacy_calls_in_one_turn_both_accumulate():
    """Two shield_app calls in the same turn should both end up in
    legacy_gemini_actions, not short-circuit on the first.

    AgentLoop calls `gemini.chat(...)` (not generate). The Gemini stub
    returns one turn with 2 parallel tool_calls; our accumulator code
    should drain both before returning.
    """
    call_a = MagicMock(
        id="c1", name="shield_app",
        args={"target": "A", "target_kind": "app", "minutes": 15},
    )
    call_b = MagicMock(
        id="c2", name="shield_app",
        args={"target": "B", "target_kind": "app", "minutes": 15},
    )
    first_resp = MagicMock(tool_calls=[call_a, call_b], text="")
    fake_gemini = MagicMock()
    fake_gemini.chat = AsyncMock(side_effect=[first_resp])

    loop = AgentLoop(
        gemini=fake_gemini,
        registry=GLOBAL_REGISTRY,
        proposal_store=None,
        action_log=None,
    )

    inp = AgentInput(
        message="lock A and B for 15 min",
        history=[],
        child_device_id=None,
        child_name="Liam",
        state_snapshot=None,
        force_confirmations=[],
    )
    resp = await loop.run(inp)

    assert isinstance(resp, AgentResponse)
    assert len(resp.legacy_gemini_actions) == 2, (
        f"expected both legacy actions, got {resp.legacy_gemini_actions}"
    )
    targets = [a["target_request"] for a in resp.legacy_gemini_actions]
    assert "A" in targets and "B" in targets
```

- [ ] **Step 2: Run to confirm failure**

```bash
pytest backend/tests/services/test_agent_loop_multi_action.py -v
```

Expected: FAIL — `len(resp.legacy_gemini_actions) == 0` (current code short-circuits and only sets singular).

- [ ] **Step 3: Replace short-circuit with accumulation**

In `backend/app/services/agent_loop.py`, find the for-loop (lines ~93-186). Before the loop, add:

```python
legacy_actions: list[dict] = []
ask_pick_payloads: list[dict] = []
```

Replace the short-circuit block (lines 160-175 currently) with:

```python
# Legacy-forwarding tools (shield_app / unshield_app etc.) put a
# Gemini-shaped action dict in result.public["legacy_gemini_action"].
# Accumulate them; emit all at end so multi-target turns don't drop
# the trailing actions.
if isinstance(result.public, dict):
    if result.public.get("legacy_gemini_action"):
        legacy_actions.append(result.public["legacy_gemini_action"])
        last_results.append({
            "call_id": call.id, "name": call.name,
            "status": "ok", "data": result.public,
        })
        continue
    # Phase 2 scaffolding: ask_pick tool emits payload here. Phase 1
    # leaves the branch in place so adding the tool later is one file.
    if result.public.get("ask_pick_payload"):
        ask_pick_payloads.append(result.public["ask_pick_payload"])
        last_results.append({
            "call_id": call.id, "name": call.name,
            "status": "ok", "data": result.public,
        })
        continue
```

After the for-loop body completes (before the existing iteration-cap return at line 188-196), add:

```python
# Drain accumulated legacy / ask_pick actions before any further Gemini
# turns. We exit the iteration loop here even on partial accumulation
# because parent_chat needs to stage proposals for parent confirmation.
if legacy_actions or ask_pick_payloads:
    return AgentResponse(
        message="",
        proposals=proposals,
        receipts=receipts,
        # Backwards compat: populate singular when exactly one.
        legacy_gemini_action=legacy_actions[0] if len(legacy_actions) == 1 else None,
        legacy_gemini_actions=legacy_actions,
        ask_pick_payloads=ask_pick_payloads,
    )
```

This sits inside the `while iter < max_iter` outer loop, after each Gemini turn finishes processing all its tool_calls.

- [ ] **Step 4: Run to confirm pass**

```bash
pytest backend/tests/services/test_agent_loop_multi_action.py -v
```

Expected: PASS.

- [ ] **Step 5: Confirm singular path still works**

```bash
pytest backend/tests/ -k "agent_loop" -v
```

Expected: ALL pass (existing single-action tests still satisfied because the singular field is set when len==1).

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/agent_loop.py backend/tests/services/test_agent_loop_multi_action.py
git commit -m "feat(agent_loop): accumulate legacy + ask_pick actions instead of short-circuiting"
```

---

### Task 5: `_stage_bundled_proposal` with mixed-duration label fix

**Files:**
- Modify: `backend/app/api/routes/parent_chat.py` (replace `_stage_legacy_shield_proposal`)
- Test: `backend/tests/api/test_parent_chat_bundled_label.py`

- [ ] **Step 1: Write failing test for label generation**

Create `backend/tests/api/test_parent_chat_bundled_label.py`:

```python
from backend.app.api.routes.parent_chat import _build_bundle_label


def test_uniform_duration_label():
    actions = [
        {"target_request": "IG", "duration_minutes": 15, "duration_state": "set"},
        {"target_request": "TT", "duration_minutes": 15, "duration_state": "set"},
    ]
    assert _build_bundle_label("shield", actions) == "Shield 2 items for 15 min"


def test_mixed_durations_label_does_not_silently_pick_min():
    actions = [
        {"target_request": "IG", "duration_minutes": 30, "duration_state": "set"},
        {"target_request": "TT", "duration_minutes": 15, "duration_state": "set"},
    ]
    assert _build_bundle_label("shield", actions) == "Shield 2 items (mixed durations)"


def test_all_permanent_label():
    actions = [
        {"target_request": "IG", "duration_minutes": None, "duration_state": "permanent"},
        {"target_request": "TT", "duration_minutes": None, "duration_state": "permanent"},
    ]
    assert _build_bundle_label("shield", actions) == "Shield 2 items permanently"


def test_unshield_label_no_duration_suffix():
    actions = [
        {"target_request": "IG", "duration_minutes": None},
        {"target_request": "TT", "duration_minutes": None},
    ]
    assert _build_bundle_label("unshield", actions) == "Unshield 2 items"


def test_single_action_label_uses_target_name():
    actions = [{"target_request": "Instagram", "duration_minutes": 15, "duration_state": "set"}]
    assert _build_bundle_label("shield", actions) == "Shield Instagram for 15 min"
```

- [ ] **Step 2: Run to confirm failure**

```bash
pytest backend/tests/api/test_parent_chat_bundled_label.py -v
```

Expected: FAIL — `_build_bundle_label` doesn't exist.

- [ ] **Step 3: Add the helper**

In `backend/app/api/routes/parent_chat.py`, add this function above `_stage_legacy_shield_proposal`:

```python
def _build_bundle_label(action_type: str, actions: list[dict]) -> str:
    """Generate the parent-facing label for a bundled proposal.

    Reviewer caught the original `min(minutes_set)` bug: when one action
    had duration=30 and another had duration=15, the label silently said
    "for 15 min" and dropped the 30. Now we only emit a duration suffix
    when ALL rows agree; otherwise "(mixed durations)". Permanent
    intent gets its own suffix when uniform.
    """
    is_unshield = action_type == "unshield"
    verb = "Unshield" if is_unshield else "Shield"
    targets = [a.get("target_request") or "?" for a in actions]
    head = targets[0] if len(actions) == 1 else f"{len(actions)} items"

    if is_unshield:
        return f"{verb} {head}"

    durations = [
        a.get("duration_minutes")
        for a in actions
        if isinstance(a.get("duration_minutes"), int)
    ]
    permanent_count = sum(
        1 for a in actions if a.get("duration_state") == "permanent"
    )
    all_uniform = (
        len(durations) == len(actions) and len(set(durations)) == 1
    )
    all_permanent = permanent_count == len(actions)
    if all_uniform:
        return f"{verb} {head} for {durations[0]} min"
    if all_permanent:
        return f"{verb} {head} permanently"
    if durations or permanent_count:
        return f"{verb} {head} (mixed durations)"
    return f"{verb} {head}"
```

- [ ] **Step 4: Run to confirm label tests pass**

```bash
pytest backend/tests/api/test_parent_chat_bundled_label.py -v
```

Expected: PASS (all 5 cases).

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/routes/parent_chat.py backend/tests/api/test_parent_chat_bundled_label.py
git commit -m "feat(parent_chat): bundle label helper with mixed-duration safe fallback"
```

---

### Task 6: `_stage_bundled_proposal` + `_stage_legacy_actions` dispatcher

**Files:**
- Modify: `backend/app/api/routes/parent_chat.py` (add helpers; update legacy-action branch in main handler)
- Test: `backend/tests/api/test_parent_chat_multi_action.py`

- [ ] **Step 1: Write failing test for staging**

Create `backend/tests/api/test_parent_chat_multi_action.py`:

```python
import pytest
from uuid import uuid4
from backend.app.services.proposal_store import ProposalStore
from backend.app.api.routes.parent_chat import (
    _stage_bundled_proposal, _stage_legacy_actions, ChatRequest,
)


@pytest.mark.asyncio
async def test_two_shields_one_proposal_with_two_rows():
    store = ProposalStore()
    actions = [
        {"type": "shield", "target_request": "IG", "target_kind_hint": "app",
         "duration_minutes": 15, "duration_state": "set"},
        {"type": "shield", "target_request": "TT", "target_kind_hint": "app",
         "duration_minutes": 15, "duration_state": "set"},
    ]
    req = ChatRequest(message="lock IG and TT for 15 min", child_name="Liam")
    proposal = _stage_bundled_proposal(
        proposal_store=store, action_type="shield", actions=actions,
        req=req, message="", reasoning=None,
    )
    assert proposal.tool == "shield_app_legacy"
    rows = proposal.args["rows"]
    assert len(rows) == 2
    assert rows[0]["target"] == "IG" and rows[1]["target"] == "TT"
    assert proposal.label == "Shield 2 items for 15 min"


@pytest.mark.asyncio
async def test_mixed_shield_unshield_two_proposals():
    store = ProposalStore()
    actions = [
        {"type": "shield", "target_request": "ent", "target_kind_hint": "category",
         "duration_minutes": 60, "duration_state": "set"},
        {"type": "unshield", "target_request": "bilibili", "target_kind_hint": "app"},
    ]
    req = ChatRequest(message="shield ent but not bilibili", child_name="Liam")
    resp = await _stage_legacy_actions(
        proposal_store=store, actions=actions, req=req,
        message="", reasoning=None, session=None,
    )
    assert len(resp.proposals) == 2
    tools = {p.tool for p in resp.proposals}
    assert tools == {"shield_app_legacy", "unshield_app_legacy"}
```

- [ ] **Step 2: Run to confirm failure**

```bash
pytest backend/tests/api/test_parent_chat_multi_action.py -v
```

Expected: FAIL — `_stage_bundled_proposal` and `_stage_legacy_actions` don't exist.

- [ ] **Step 3: Implement `_stage_bundled_proposal`**

In `backend/app/api/routes/parent_chat.py`, **replace** the existing `_stage_legacy_shield_proposal` function (around line 495) with:

```python
def _stage_bundled_proposal(
    *,
    proposal_store: ProposalStore,
    action_type: str,             # "shield" | "unshield"
    actions: list[dict],
    req: "ChatRequest",
    message: str,
    reasoning: str | None,
) -> Proposal:
    """Bundle N homogeneous-type legacy actions into one Proposal.

    `args.actions` carries the full gemini_actions for exec replay.
    `args.rows` carries the iOS-render payload (target + kind + minutes
    per row). The split keeps the iOS payload small and stable while
    exec gets the source-of-truth dicts.
    """
    is_unshield = action_type == "unshield"
    tool_name = "unshield_app_legacy" if is_unshield else "shield_app_legacy"

    chat_context = {
        "message": message,
        "reasoning": reasoning,
        "family_id": str(req.family_id) if req.family_id else None,
        "child_name": req.child_name,
        "child_device_id": str(req.child_device_id) if req.child_device_id else None,
        "force_confirmations": list(req.force_confirmations or []),
    }
    token = proposal_store.stage(
        tool=tool_name,
        args={"actions": actions},
        chat_context=chat_context,
    )

    rows = [
        {
            "target": a.get("target_request") or "",
            "target_kind": a.get("target_kind_hint", "app"),
            "minutes": (
                a.get("duration_minutes")
                if isinstance(a.get("duration_minutes"), int)
                else None
            ),
        }
        for a in actions
    ]
    label = _build_bundle_label(action_type, actions)
    return Proposal(
        tool=tool_name,
        args={"rows": rows},
        label=label,
        danger="low" if is_unshield else "medium",
        token=token,
    )
```

- [ ] **Step 4: Implement `_stage_legacy_actions`**

In the same file, **add below** `_stage_bundled_proposal`:

```python
async def _stage_legacy_actions(
    *,
    proposal_store: ProposalStore,
    actions: list[dict],
    req: "ChatRequest",
    message: str,
    reasoning: str | None,
    session: AsyncSession | None,
) -> "ChatResponse":
    """Entry point for the multi-action branch of parent_chat.

    Single-action turn with a non-eligible action keeps the eager path
    (preserves D1/D3/D4 surfacing). Otherwise: group by type, bundle
    each type into its own Proposal. Mixed eligible/non-eligible inside
    a multi-action turn always go through staging — alternative (mixing
    eager and proposals in one ChatResponse) makes UX confusing.
    """
    from collections import defaultdict

    if (
        len(actions) == 1
        and not _is_lazy_tag_eligible(actions[0], req.force_confirmations)
    ):
        return await _handle_gemini_action(
            gemini_action=actions[0], message=message, reasoning=reasoning,
            req=req, session=session,
        )

    # D1 / D3 gating: if ANY action in a multi-turn would normally bounce
    # back as D1 (missing duration) or D3 (>24h, unconfirmed), we cannot
    # bundle — those cards must surface BEFORE proposal exec, otherwise
    # the legacy dispatcher fires inside _exec_legacy_shield and returns
    # an unsupported card mid-confirm. Detect and route the offending
    # action through the eager path instead. Only one card surfaces at a
    # time — that action becomes the bottleneck; siblings get re-emitted
    # by Gemini on the next round.
    for a in actions:
        if a.get("type") != "shield":
            continue
        state = a.get("duration_state")
        dur = a.get("duration_minutes")
        if isinstance(dur, float):
            dur = int(dur)
        elif isinstance(dur, str) and dur.isdigit():
            dur = int(dur)
        if state == "missing":
            return await _handle_gemini_action(
                gemini_action=a, message=message, reasoning=reasoning,
                req=req, session=session,
            )
        if (
            isinstance(dur, int) and dur > 24 * 60
            and "D3" not in (req.force_confirmations or [])
        ):
            return await _handle_gemini_action(
                gemini_action=a, message=message, reasoning=reasoning,
                req=req, session=session,
            )

    by_type: dict[str, list[dict]] = defaultdict(list)
    for a in actions:
        by_type[a["type"]].append(a)

    proposals: list[Proposal] = []
    for action_type, group in by_type.items():
        proposals.append(
            _stage_bundled_proposal(
                proposal_store=proposal_store,
                action_type=action_type,
                actions=group,
                req=req,
                message=message,
                reasoning=reasoning,
            )
        )

    return ChatResponse(
        message=message or "",
        reasoning=reasoning,
        action=None,
        proposals=proposals,
    )
```

- [ ] **Step 5: Update main handler to use plural**

In `backend/app/api/routes/parent_chat.py`, find the agent-path handler (around line 407 — `if agent_resp.legacy_gemini_action is not None:`). **Replace** the entire block from there through the eager `_handle_gemini_action` call (around line 432) with:

```python
if agent_resp.legacy_gemini_actions:
    return await _stage_legacy_actions(
        proposal_store=get_proposal_store(),
        actions=agent_resp.legacy_gemini_actions,
        req=req,
        message=agent_resp.message or "",
        reasoning=agent_resp.reasoning,
        session=session,
    )
# Backwards compat: old singular path still works if AgentResponse
# only set the singular field (won't happen with new agent_loop, but
# keeps any external test fixture from breaking mid-deploy).
if agent_resp.legacy_gemini_action is not None:
    return await _handle_gemini_action(
        gemini_action=agent_resp.legacy_gemini_action,
        message=agent_resp.message or "",
        reasoning=agent_resp.reasoning,
        req=req, session=session,
    )
```

- [ ] **Step 6: Run to confirm tests pass**

```bash
pytest backend/tests/api/test_parent_chat_multi_action.py -v
pytest backend/tests/api/test_parent_chat_bundled_label.py -v
```

Expected: PASS.

- [ ] **Step 7: Run full backend suite to catch regressions**

```bash
pytest backend/tests/ -x -q
```

Expected: all green. If any prior `_stage_legacy_shield_proposal` tests fail, update them to use the renamed `_stage_bundled_proposal`.

- [ ] **Step 8: Commit**

```bash
git add backend/app/api/routes/parent_chat.py backend/tests/api/test_parent_chat_multi_action.py
git commit -m "feat(parent_chat): _stage_bundled_proposal + _stage_legacy_actions dispatcher"
```

---

### Task 7: parent_agent exec for plural actions

**Files:**
- Modify: `backend/app/api/routes/parent_agent.py:49-163`
- Test: `backend/tests/api/test_parent_agent_multi_exec.py`

- [ ] **Step 1: Write failing test**

Create `backend/tests/api/test_parent_agent_multi_exec.py`:

```python
import pytest
from uuid import uuid4
from httpx import AsyncClient
from backend.app.services.proposal_store import get_proposal_store
from backend.app.db.models import Family, Device
from backend.app.db.models.device import DeviceMode


@pytest.mark.asyncio
async def test_exec_two_shield_actions_returns_two_legacy_actions(
    client: AsyncClient, session
):
    family = Family(id=uuid4())
    device = Device(id=uuid4(), family_id=family.id, label="Liam", mode=DeviceMode.child)
    session.add_all([family, device])
    await session.commit()

    store = get_proposal_store()
    actions = [
        {"type": "shield", "target_request": "IG", "target_kind_hint": "app",
         "duration_minutes": 15, "duration_state": "set"},
        {"type": "shield", "target_request": "TT", "target_kind_hint": "app",
         "duration_minutes": 15, "duration_state": "set"},
    ]
    token = store.stage(
        tool="shield_app_legacy",
        args={"actions": actions},
        chat_context={
            "message": "lock IG and TT", "reasoning": None,
            "family_id": str(family.id), "child_name": "Liam",
            "child_device_id": str(device.id), "force_confirmations": [],
        },
    )

    resp = await client.post("/api/v1/parent/agent/exec", json={"token": token})
    assert resp.status_code == 200
    body = resp.json()
    assert "legacy_actions" in body
    assert len(body["legacy_actions"]) == 2
    targets = [r["action"]["target_display"] for r in body["legacy_actions"]]
    assert "IG" in targets and "TT" in targets
```

- [ ] **Step 2: Run to confirm failure**

```bash
pytest backend/tests/api/test_parent_agent_multi_exec.py -v
```

Expected: FAIL — `legacy_actions` plural key absent (current code returns `legacy_action` singular).

- [ ] **Step 3: Add plural field to ExecResponse**

In `backend/app/api/routes/parent_agent.py` (around line 49), update `ExecResponse`:

```python
class ExecResponse(BaseModel):
    receipt: Receipt | None = None
    legacy_action: dict | None = None        # backwards compat (len==1 case)
    legacy_actions: list[dict] = Field(default_factory=list)  # new plural
    message: str | None = None
    reasoning: str | None = None
```

Add `from pydantic import Field` if missing.

- [ ] **Step 4: Update `_exec_legacy_shield` to handle plural**

In the same file (around line 114), replace the body of `_exec_legacy_shield`:

```python
async def _exec_legacy_shield(
    *,
    args: dict[str, Any],
    chat_context: dict[str, Any],
    session: AsyncSession,
) -> ExecResponse:
    """Re-run _handle_gemini_action for one or more staged gemini_actions.

    args["actions"] (plural, new): list of gemini_action dicts from
    _stage_bundled_proposal. Iterate each, dispatch through
    _handle_gemini_action, collect a per-action {action, message} dict.

    args["gemini_action"] (singular, legacy): treated as a 1-item list
    so old proposals in flight at deploy time still execute.
    """
    from backend.app.api.routes.parent_chat import (
        _handle_gemini_action, ChatRequest,
    )

    actions = args.get("actions")
    if actions is None:
        single = args.get("gemini_action")
        actions = [single] if single else []
    if not actions:
        raise HTTPException(status_code=400, detail="exec body has no actions")

    req_dict: dict[str, Any] = {
        "message": chat_context.get("message", ""),
        "child_name": chat_context.get("child_name") or "Liam",
    }
    if chat_context.get("family_id"):
        req_dict["family_id"] = UUID(chat_context["family_id"])
    if chat_context.get("child_device_id"):
        req_dict["child_device_id"] = UUID(chat_context["child_device_id"])
    fc = chat_context.get("force_confirmations")
    if isinstance(fc, list) and fc:
        req_dict["force_confirmations"] = list(fc)
    req = ChatRequest(**req_dict)

    results: list[dict[str, Any]] = []
    for action in actions:
        if action.get("target_kind_hint") == "app":
            action["force_exact_app"] = True
        chat_response = await _handle_gemini_action(
            gemini_action=action,
            message=chat_context.get("message", ""),
            reasoning=chat_context.get("reasoning"),
            req=req,
            session=session,
        )
        action_dict = (
            chat_response.action.model_dump(mode="json")
            if chat_response.action is not None else None
        )
        results.append({
            "action": action_dict,
            "message": chat_response.message,
        })

    # Backwards compat: populate singular when exactly 1 result.
    return ExecResponse(
        legacy_action=results[0]["action"] if len(results) == 1 else None,
        legacy_actions=results,
        message=results[0]["message"] if results else None,
        reasoning=chat_context.get("reasoning"),
    )
```

- [ ] **Step 5: Run to confirm pass**

```bash
pytest backend/tests/api/test_parent_agent_multi_exec.py -v
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/routes/parent_agent.py backend/tests/api/test_parent_agent_multi_exec.py
git commit -m "feat(parent_agent): exec dispatches plural args.actions and returns legacy_actions list"
```

---

## Section C — Backend: U1 Routing

### Task 8: `_load_effective_state` helper

**Files:**
- Modify: `backend/app/api/routes/parent_chat.py`
- Test: `backend/tests/api/test_load_effective_state.py`

- [ ] **Step 1: Write failing test**

Create `backend/tests/api/test_load_effective_state.py`:

```python
import pytest
from datetime import datetime, timedelta, timezone
from uuid import uuid4
from backend.app.api.routes.parent_chat import _load_effective_state
from backend.app.db.models import Family, Device
from backend.app.db.models.device import DeviceMode


@pytest.mark.asyncio
async def test_returns_empty_when_no_state(session):
    family = Family(id=uuid4())
    device = Device(id=uuid4(), family_id=family.id, label="Liam", mode=DeviceMode.child)
    session.add_all([family, device])
    await session.commit()
    result = await _load_effective_state(session, device.id)
    assert result == []


@pytest.mark.asyncio
async def test_returns_active_shields_from_recent_state(session):
    family = Family(id=uuid4())
    eff = {
        "isBlocked": True,
        "shieldsCovering": [
            {"displayName": "Instagram", "expiresAtISO": "2026-05-07T16:19:00Z", "tier": "exactApp"},
            {"displayName": "Entertainment", "expiresAtISO": None, "tier": "category"},
        ],
        "possibleSavedListCoverage": False,
    }
    device = Device(
        id=uuid4(), family_id=family.id, label="Liam", mode=DeviceMode.child,
        last_effective_state=eff,
        last_effective_state_at=datetime.now(timezone.utc),
    )
    session.add_all([family, device])
    await session.commit()
    result = await _load_effective_state(session, device.id)
    assert len(result) == 2
    assert result[0]["display_name"] == "Instagram"
    assert result[0]["kind"] == "app"
    assert result[1]["display_name"] == "Entertainment"
    assert result[1]["kind"] == "category"


@pytest.mark.asyncio
async def test_marks_stale_when_older_than_5_min(session):
    family = Family(id=uuid4())
    eff = {"isBlocked": True, "shieldsCovering": [
        {"displayName": "IG", "expiresAtISO": None, "tier": "exactApp"}
    ], "possibleSavedListCoverage": False}
    device = Device(
        id=uuid4(), family_id=family.id, label="Liam", mode=DeviceMode.child,
        last_effective_state=eff,
        last_effective_state_at=datetime.now(timezone.utc) - timedelta(minutes=10),
    )
    session.add_all([family, device])
    await session.commit()
    result = await _load_effective_state(session, device.id)
    assert len(result) == 1
    assert result[0].get("stale") is True
```

- [ ] **Step 2: Run to confirm failure**

```bash
pytest backend/tests/api/test_load_effective_state.py -v
```

Expected: FAIL — `_load_effective_state` doesn't exist.

- [ ] **Step 3: Implement**

Add to `backend/app/api/routes/parent_chat.py` (alongside other helpers):

```python
async def _load_effective_state(
    session: AsyncSession,
    child_device_id: UUID,
) -> list[dict]:
    """Return the active-shield list from device.last_effective_state.

    Each entry: {kind, display_name, expires_at_iso, stale}.
    `kind` maps from ShieldCover.tier:
      "exactApp" → "app", "category" → "category",
      "savedList" → "list", "all" → "all".
    `stale=True` when the snapshot is older than 5 minutes.
    """
    from datetime import datetime, timedelta, timezone
    device = await session.get(Device, child_device_id)
    if device is None or not device.last_effective_state:
        return []
    eff = device.last_effective_state
    covers = eff.get("shieldsCovering") or []
    is_stale = False
    if device.last_effective_state_at is not None:
        age = datetime.now(timezone.utc) - device.last_effective_state_at
        is_stale = age > timedelta(minutes=5)
    tier_to_kind = {
        "exactApp": "app", "category": "category",
        "savedList": "list", "all": "all",
    }
    out = []
    for c in covers:
        out.append({
            "kind": tier_to_kind.get(c.get("tier"), "app"),
            "display_name": c.get("displayName") or "(unknown)",
            "expires_at_iso": c.get("expiresAtISO"),
            "stale": is_stale,
        })
    return out
```

Add `from backend.app.db.models import Device` and `from uuid import UUID` at the top if missing.

- [ ] **Step 4: Run to confirm pass**

```bash
pytest backend/tests/api/test_load_effective_state.py -v
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/routes/parent_chat.py backend/tests/api/test_load_effective_state.py
git commit -m "feat(parent_chat): _load_effective_state helper for U1 routing"
```

---

### Task 9: chat_resolver U1 routing branch

**Files:**
- Modify: `backend/app/services/chat_resolver.py:306-345` (`_route_unshield`)
- Modify: `backend/app/services/chat_resolver.py:395+` (`DispatchResult` add `u1_shield_list` field)
- Test: `backend/tests/services/test_chat_resolver_u1.py`

- [ ] **Step 1: Write failing test**

Create `backend/tests/services/test_chat_resolver_u1.py`:

```python
from backend.app.services.chat_resolver import _route_unshield, DispatchResult


def _eff(n: int) -> list[dict]:
    return [
        {"kind": "app", "display_name": f"App{i}", "expires_at_iso": None, "stale": False}
        for i in range(n)
    ]


def test_zero_active_shields_returns_receipt_only():
    action = {
        "type": "unshield",
        "target_request": "everything",
        "target_kind_hint": "all",
        "_effective_shields": _eff(0),
    }
    result = _route_unshield("std", action)
    assert result.receipt_only_text == "Nothing is locked right now."


def test_one_active_shield_routes_directly_to_that_unshield():
    action = {
        "type": "unshield",
        "target_request": "everything",
        "target_kind_hint": "all",
        "_effective_shields": [
            {"kind": "app", "display_name": "Instagram",
             "expires_at_iso": None, "stale": False},
        ],
    }
    result = _route_unshield("std", action)
    assert result.resolved is not None
    assert result.resolved.action == "unshield"
    assert result.resolved.tier == "exactApp"
    assert result.resolved.target_display == "Instagram"


def test_two_or_more_active_shields_returns_u1():
    action = {
        "type": "unshield",
        "target_request": "everything",
        "target_kind_hint": "all",
        "_effective_shields": _eff(3),
    }
    result = _route_unshield("std", action)
    assert result.requires_card == "U1"
    assert len(result.u1_shield_list) == 3


def test_specific_target_does_not_trigger_u1():
    """`unshield Instagram` with N>1 active shields routes specifically,
    not via U1 — U1 is only for ambiguous bare unlocks."""
    action = {
        "type": "unshield",
        "target_request": "Instagram",
        "target_kind_hint": "app",
        "_effective_shields": _eff(3),
    }
    result = _route_unshield("std", action)
    assert result.requires_card != "U1"
    assert result.resolved is not None
    assert result.resolved.target_display == "Instagram"
```

- [ ] **Step 2: Run to confirm failure**

```bash
pytest backend/tests/services/test_chat_resolver_u1.py -v
```

Expected: FAIL — `requires_card="U1"` is never set; `u1_shield_list` field doesn't exist on DispatchResult.

- [ ] **Step 3: Add `u1_shield_list` to DispatchResult**

In `backend/app/services/chat_resolver.py` (around line 395), update `DispatchResult`:

```python
@dataclass
class DispatchResult:
    resolved: ResolvedAction | None = None
    requires_card: str | None = None
    receipt_only_text: str | None = None
    list_suggestions: list[str] = field(default_factory=list)
    category_guess: str | None = None
    confirmation_required: bool = False
    confirmation_reason: str | None = None
    u1_shield_list: list[dict] = field(default_factory=list)   # new
```

- [ ] **Step 4: Add U1 branch to `_route_unshield`**

In the same file, replace `_route_unshield` (around line 306):

```python
def _route_unshield(mode: str, action: dict) -> DispatchResult:
    kind = action.get("target_kind_hint")
    target = (action.get("target_request") or "").strip()

    # U1 branch: bare/ambiguous unshield with effective state injected.
    # Triggered ONLY when caller (parent_chat) attached `_effective_shields`
    # AND target is empty / "everything" / "all". Specific targets bypass.
    bare_target = target.lower() in {"", "everything", "all", "everything locked"}
    eff_shields = action.get("_effective_shields")
    if bare_target and isinstance(eff_shields, list) and kind in {"all", None}:
        if len(eff_shields) == 0:
            return DispatchResult(receipt_only_text="Nothing is locked right now.")
        if len(eff_shields) == 1:
            sh = eff_shields[0]
            tier = _TIER_FROM_KIND.get(sh["kind"], "exactApp")
            display = sh["display_name"]
            # Kind-specific ResolvedAction so list/all/category each strip
            # the right shield layer. Mirrors the regular branches below.
            if tier == "savedList":
                return DispatchResult(
                    resolved=ResolvedAction(
                        action="unshield",
                        tier="savedList",
                        list_name=display,
                        target_display=display,
                    )
                )
            if tier == "all":
                return DispatchResult(
                    resolved=ResolvedAction(
                        action="unshield",
                        tier="all",
                        target_all=True,
                        target_display=display,
                    )
                )
            if tier == "category":
                return DispatchResult(
                    resolved=ResolvedAction(
                        action="unshield",
                        tier="category",
                        category_hint=display.lower(),
                        target_display=display,
                    )
                )
            # exactApp default
            return DispatchResult(
                resolved=ResolvedAction(
                    action="unshield",
                    tier="exactApp",
                    target_display=display,
                    bundle_id=None,
                )
            )
        return DispatchResult(
            requires_card="U1",
            u1_shield_list=eff_shields,
        )

    # Existing branches (list / category / all / app default) unchanged.
    if kind == "list":
        return DispatchResult(
            resolved=ResolvedAction(
                action="unshield",
                tier="savedList",
                list_name=action.get("target_request"),
            )
        )
    if kind == "category":
        return DispatchResult(
            resolved=ResolvedAction(
                action="unshield",
                tier="category",
                category_hint=action.get("target_request", "").lower(),
            )
        )
    if kind == "all":
        return DispatchResult(
            resolved=ResolvedAction(
                action="unshield",
                tier="all",
                target_all=True,
            )
        )
    # Default: app-level unshield (lazy-tag aware path from prior commit).
    target = action.get("target_request", "")
    if action.get("force_exact_app"):
        return DispatchResult(
            resolved=ResolvedAction(
                action="unshield",
                tier="exactApp",
                bundle_id=None,
                target_display=target,
                category_hint=action.get("category_hint_from_ai"),
            )
        )
    entry = catalog_lookup(target)
    category_hint = (
        entry.category_hint if entry else None
    ) or action.get("category_hint_from_ai")
    return DispatchResult(
        resolved=ResolvedAction(
            action="unshield",
            tier="exactApp",
            bundle_id=entry.bundle_id if entry else None,
            target_display=(entry.names[0] if entry else target),
            category_hint=category_hint,
        )
    )
```

Above the function, add the helper map:

```python
_TIER_FROM_KIND = {
    "app": "exactApp", "category": "category",
    "list": "savedList", "all": "all",
}
```

- [ ] **Step 5: Run to confirm pass**

```bash
pytest backend/tests/services/test_chat_resolver_u1.py -v
```

Expected: PASS (4 tests).

- [ ] **Step 6: Confirm no regression in other resolver tests**

```bash
pytest backend/tests/services/test_chat_resolver*.py -v
```

Expected: ALL pass.

- [ ] **Step 7: Commit**

```bash
git add backend/app/services/chat_resolver.py backend/tests/services/test_chat_resolver_u1.py
git commit -m "feat(chat_resolver): U1 branch in _route_unshield when effective_shields injected"
```

---

### Task 10: parent_chat U1 interception + `_handle_u1_confirm`

**Files:**
- Modify: `backend/app/api/routes/parent_chat.py` (add interception + handler)
- Modify: `backend/app/api/routes/parent_chat.py:238` (extend `ChatAction` with `u1_token`)
- Test: `backend/tests/api/test_parent_chat_u1_confirm.py`

- [ ] **Step 1: Write failing test**

Create `backend/tests/api/test_parent_chat_u1_confirm.py`:

```python
import pytest
from uuid import uuid4
from httpx import AsyncClient
from backend.app.services.proposal_store import get_proposal_store
from backend.app.db.models import Family, Device
from backend.app.db.models.device import DeviceMode


@pytest.mark.asyncio
async def test_u1_all_marker_dispatches_unshield_all(client: AsyncClient, session):
    family = Family(id=uuid4())
    device = Device(id=uuid4(), family_id=family.id, label="Liam", mode=DeviceMode.child)
    session.add_all([family, device])
    await session.commit()

    store = get_proposal_store()
    shield_list = [
        {"kind": "app", "display_name": "IG", "expires_at_iso": None, "stale": False},
        {"kind": "category", "display_name": "Entertainment", "expires_at_iso": None, "stale": False},
    ]
    u1_token = store.stage(
        tool="u1_card_state",
        args={"shield_list": shield_list},
        chat_context={"message": "unlock", "reasoning": None,
                      "family_id": str(family.id), "child_name": "Liam",
                      "child_device_id": str(device.id), "force_confirmations": []},
    )

    resp = await client.post("/api/v1/parent/chat", json={
        "message": "unlock",
        "child_name": "Liam",
        "family_id": str(family.id),
        "child_device_id": str(device.id),
        "force_confirmations": [f"U1:{u1_token}:all"],
    })
    assert resp.status_code == 200
    body = resp.json()
    # unshield_all queues a Command directly — action.command_id should be set
    assert body.get("action") is not None
    assert body["action"].get("command_id") is not None


@pytest.mark.asyncio
async def test_u1_selected_marker_stages_bundled_unshield(client: AsyncClient, session):
    family = Family(id=uuid4())
    device = Device(id=uuid4(), family_id=family.id, label="Liam", mode=DeviceMode.child)
    session.add_all([family, device])
    await session.commit()

    store = get_proposal_store()
    shield_list = [
        {"kind": "app", "display_name": "IG", "expires_at_iso": None, "stale": False},
        {"kind": "category", "display_name": "Entertainment", "expires_at_iso": None, "stale": False},
        {"kind": "app", "display_name": "TT", "expires_at_iso": None, "stale": False},
    ]
    u1_token = store.stage(
        tool="u1_card_state", args={"shield_list": shield_list},
        chat_context={"message": "unlock", "reasoning": None,
                      "family_id": str(family.id), "child_name": "Liam",
                      "child_device_id": str(device.id), "force_confirmations": []},
    )

    resp = await client.post("/api/v1/parent/chat", json={
        "message": "unlock",
        "child_name": "Liam",
        "family_id": str(family.id),
        "child_device_id": str(device.id),
        "force_confirmations": [f"U1:{u1_token}:selected:0,2"],
    })
    assert resp.status_code == 200
    body = resp.json()
    # Should stage 1 bundled unshield proposal containing 2 rows (IG, TT)
    assert "proposals" in body and len(body["proposals"]) == 1
    rows = body["proposals"][0]["args"]["rows"]
    assert len(rows) == 2
    assert {r["target"] for r in rows} == {"IG", "TT"}


@pytest.mark.asyncio
async def test_expired_u1_token_returns_friendly_message(client: AsyncClient, session):
    family = Family(id=uuid4())
    device = Device(id=uuid4(), family_id=family.id, label="Liam", mode=DeviceMode.child)
    session.add_all([family, device])
    await session.commit()

    resp = await client.post("/api/v1/parent/chat", json={
        "message": "unlock",
        "child_name": "Liam",
        "family_id": str(family.id),
        "child_device_id": str(device.id),
        "force_confirmations": ["U1:nonexistent_token:all"],
    })
    assert resp.status_code == 200
    body = resp.json()
    assert "expired" in body["message"].lower() or "ask me again" in body["message"].lower()
```

- [ ] **Step 2: Run to confirm failure**

```bash
pytest backend/tests/api/test_parent_chat_u1_confirm.py -v
```

Expected: FAIL — interception not present; markers ignored.

- [ ] **Step 3: Extend ChatAction with u1_token**

In `backend/app/api/routes/parent_chat.py` around line 238 (`ChatAction` definition), add:

```python
class ChatAction(BaseModel):
    # ... existing fields
    u1_token: str | None = None             # for CardID=U1 round-trip
    u1_shield_list: list[dict] | None = None  # rendered rows
```

- [ ] **Step 4: Implement `_handle_u1_confirm`**

Add to `backend/app/api/routes/parent_chat.py`:

```python
async def _handle_u1_confirm(
    marker: str,
    req: "ChatRequest",
    session: AsyncSession,
    proposal_store: ProposalStore,
) -> "ChatResponse":
    """Parse U1 marker, look up cached shield_list, dispatch.

    Marker forms:
      U1:<token>:all
      U1:<token>:selected:0,2,5
    """
    parts = marker.split(":")
    if len(parts) < 3 or parts[0] != "U1":
        raise HTTPException(status_code=400, detail=f"malformed U1 marker: {marker}")
    _, u1_token, mode, *rest = parts

    popped = proposal_store.pop(u1_token)
    if popped is None:
        return ChatResponse(
            message="That unlock list expired. Ask me again to see what's locked.",
            reasoning=None,
            action=None,
        )
    _tool, args, _ctx = popped
    shield_list: list[dict] = args.get("shield_list") or []

    if mode == "all":
        gemini_action = {
            "type": "unshield",
            "target_request": "everything",
            "target_kind_hint": "all",
            "duration_minutes": None,
            "category_hint_from_ai": None,
            "child_name_hint": None,
            "confirmation_required": False,
            "confirmation_reason": None,
        }
        return await _handle_gemini_action(
            gemini_action=gemini_action, message="", reasoning=None,
            req=req, session=session,
        )

    if mode == "selected":
        if not rest:
            raise HTTPException(status_code=400, detail="U1 selected marker missing indices")
        try:
            indices = [int(i) for i in rest[0].split(",") if i.strip()]
        except ValueError:
            raise HTTPException(status_code=400, detail=f"bad U1 indices: {rest[0]}")
        selected = [shield_list[i] for i in indices if 0 <= i < len(shield_list)]
        if not selected:
            return ChatResponse(message="Nothing selected.", reasoning=None, action=None)
        actions = [
            {
                "type": "unshield",
                "target_request": s["display_name"],
                "target_kind_hint": s["kind"],
                "duration_minutes": None,
                "category_hint_from_ai": None,
                "child_name_hint": None,
                "confirmation_required": False,
                "confirmation_reason": None,
            }
            for s in selected
        ]
        return await _stage_legacy_actions(
            proposal_store=proposal_store, actions=actions,
            req=req, message="", reasoning=None, session=session,
        )

    raise HTTPException(status_code=400, detail=f"unknown U1 mode: {mode}")
```

- [ ] **Step 5: Add interception at top of parent_chat handler**

Find the `parent_chat` request handler function (the `@router.post("/parent/chat")` route). At the very top of the body, **before any agent / Gemini call**, insert:

```python
# U1 confirm marker — must intercept BEFORE agent loop, otherwise
# Gemini sees "unlock" again and recursively re-renders U1.
u1_marker = next(
    (fc for fc in (req.force_confirmations or []) if fc.startswith("U1:")),
    None,
)
if u1_marker:
    return await _handle_u1_confirm(
        u1_marker, req, session, get_proposal_store(),
    )
```

- [ ] **Step 6: Wire effective state injection + U1 staging**

Still in `parent_chat`, after the agent loop returns and we hit the legacy-action branch (around the spot Task 6 modified), inject `_effective_shields` for unshield actions before dispatch:

In `_handle_gemini_action` (around line 557), at the top after the early returns, add:

```python
# For unshield actions with bare/all target, attach effective_shields
# so chat_resolver._route_unshield can decide between direct route /
# U1 / "nothing locked".
if (
    gemini_action is not None
    and gemini_action.get("type") == "unshield"
    and (gemini_action.get("target_kind_hint") in {"all", None})
    and req.child_device_id is not None
):
    gemini_action["_effective_shields"] = await _load_effective_state(
        session, req.child_device_id
    )
```

After dispatch returns and the result has `requires_card == "U1"`, stage the shield_list and build the ChatResponse:

In the existing card-handling block of `_handle_gemini_action` (around line 683-700), add a branch BEFORE the generic `requires_card` handler:

```python
if result.requires_card == "U1":
    proposal_store = get_proposal_store()
    u1_token = proposal_store.stage(
        tool="u1_card_state",
        args={"shield_list": result.u1_shield_list},
        chat_context={
            "message": message,
            "reasoning": reasoning,
            "family_id": str(req.family_id) if req.family_id else None,
            "child_name": req.child_name,
            "child_device_id": str(req.child_device_id) if req.child_device_id else None,
            "force_confirmations": [],
        },
    )
    return ChatResponse(
        message="Which one should I unlock?",
        reasoning=reasoning,
        action=ChatAction(
            type="unshield",
            confirmation_required=True,
            card_id="U1",
            u1_token=u1_token,
            u1_shield_list=result.u1_shield_list,
        ),
    )
```

- [ ] **Step 7: Run to confirm pass**

```bash
pytest backend/tests/api/test_parent_chat_u1_confirm.py -v
```

Expected: PASS (3 tests).

- [ ] **Step 8: Confirm no regression**

```bash
pytest backend/tests/ -x -q
```

Expected: green.

- [ ] **Step 9: Commit**

```bash
git add backend/app/api/routes/parent_chat.py backend/tests/api/test_parent_chat_u1_confirm.py
git commit -m "feat(parent_chat): U1 marker interception, _handle_u1_confirm, effective_state injection"
```

---

## Section D — iOS: NameWithIcon helper + adoption

### Task 11: Create `NameWithIcon` helper

**Files:**
- Create: `Evlin iOS/Components/Helpers/NameWithIcon.swift`

- [ ] **Step 1: Write the helper (no TDD — pure SwiftUI rendering)**

Create `Evlin iOS/Components/Helpers/NameWithIcon.swift`:

```swift
import SwiftUI
import FamilyControls
import ManagedSettings

/// Render an app/category name with its real Apple icon when available,
/// SF Symbol fallback otherwise. The text part stays our own `Text` so
/// `.font` and `.foregroundColor` modifiers from the call-site work —
/// Apple's `Label(token)` text rendering ignores those.
///
/// Why a helper: ApplicationToken is opaque; only `Label(token)` can
/// render Apple's icon, and only `.labelStyle(.iconOnly)` strips the
/// ignored-style text part. Centralizes that two-step dance.
enum NameIconKind {
    case app
    case category
    case savedList
    case all
}

struct NameWithIcon: View {
    let name: String
    let kind: NameIconKind
    var titleFont: Font = .body

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 24, height: 24)
            Text(name).font(titleFont)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch kind {
        case .app:
            if let token = LocalAliasStore.shared.applicationToken(forLookupKey: name) {
                Label(token).labelStyle(.iconOnly)
            } else {
                Image(systemName: "app.fill")
                    .foregroundStyle(Color.evOutline)
            }
        case .category:
            if let token = LocalAliasStore.shared.categoryToken(forName: name) {
                Label(token).labelStyle(.iconOnly)
            } else {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(Color.evOutline)
            }
        case .savedList:
            Image(systemName: "list.bullet.rectangle.fill")
                .foregroundStyle(Color.evOutline)
        case .all:
            Image(systemName: "iphone")
                .foregroundStyle(Color.evOutline)
        }
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 12) {
        NameWithIcon(name: "Instagram", kind: .app)
        NameWithIcon(name: "Entertainment", kind: .category)
        NameWithIcon(name: "Bedtime apps", kind: .savedList)
        NameWithIcon(name: "Whole phone", kind: .all)
    }
    .padding()
}
#endif
```

- [ ] **Step 2: Add file to Xcode project**

In Xcode:
1. Right-click `Components/` folder → "Add Files to Evlin iOS..."
2. Select `Components/Helpers/NameWithIcon.swift`
3. Check "Evlin iOS" target only → Add

- [ ] **Step 3: Build to verify it compiles**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "BUILD SUCCEEDED|error:" | head -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Components/Helpers/NameWithIcon.swift" "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "feat(ios): NameWithIcon helper renders real Apple icon next to display name"
```

---

### Task 12: Adopt NameWithIcon in ReceiptCard + AliasManagementView

**Files:**
- Modify: `Evlin iOS/Components/ReceiptCard.swift:54-90`
- Modify: `Evlin iOS/Views/Settings/AliasManagementView.swift`

- [ ] **Step 1: Update ReceiptCard primary lines**

In `Evlin iOS/Components/ReceiptCard.swift`, find the `confirmedExact` case (around line 54) and replace its content:

```swift
case .confirmedExact(let verb, let name, let unlocksAt):
    HStack(spacing: 8) {
        NameWithIcon(name: name, kind: .app, titleFont: .subheadline.weight(.medium))
        Spacer()
        Image(systemName: iconForVerb(verb))
            .foregroundStyle(Color.evSecondary)
    }
    .overlay(alignment: .bottomLeading) {
        if verb == .shield {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                if let at = unlocksAt {
                    Text("Unlocks at \(timeString(at))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Until you unlock").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 18)
        }
    }
```

For `confirmedFallback`, `failedAppNotConfigured`, `failedCategoryNotConfigured`: wrap the relevant name in `NameWithIcon` similarly:

```swift
case .confirmedFallback(let verb, let name, let category, let orig):
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            NameWithIcon(name: name, kind: .app, titleFont: .subheadline.weight(.medium))
            Spacer()
            Image(systemName: "arrow.triangle.branch")
        }
        Text("No exact match for \(orig); applied to \(category) instead.")
            .font(.caption).foregroundStyle(.secondary)
    }
case .failedAppNotConfigured(let ref):
    HStack(spacing: 6) {
        Image(systemName: "xmark.octagon").foregroundStyle(.red)
        Text("App ").font(.subheadline).foregroundStyle(.red)
        NameWithIcon(name: ref, kind: .app, titleFont: .subheadline)
        Text(" not found in Managed Apps.").font(.subheadline).foregroundStyle(.red)
    }
case .failedCategoryNotConfigured(let cat):
    HStack(spacing: 6) {
        Image(systemName: "xmark.octagon").foregroundStyle(.red)
        Text("Category ").font(.subheadline).foregroundStyle(.red)
        NameWithIcon(name: cat, kind: .category, titleFont: .subheadline)
        Text(" not configured.").font(.subheadline).foregroundStyle(.red)
    }
```

- [ ] **Step 2: Update AliasManagementView rows**

In `Evlin iOS/Views/Settings/AliasManagementView.swift`, replace the apps row body (around the `Text(entry.label.capitalized)` block):

```swift
ForEach(apps, id: \.label) { entry in
    VStack(alignment: .leading, spacing: 2) {
        NameWithIcon(name: entry.label, kind: .app, titleFont: .body)
        if let bid = entry.bundleID {
            Text(bid).font(.caption.monospaced()).foregroundStyle(.secondary)
                .padding(.leading, 32)
        }
    }
}
```

And the categories row:

```swift
ForEach(categories, id: \.self) { name in
    NameWithIcon(name: name, kind: .category, titleFont: .body)
}
```

And the lists row:

```swift
ForEach(lists, id: \.self) { name in
    NameWithIcon(name: name, kind: .savedList, titleFont: .body)
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "BUILD SUCCEEDED|error:" | head -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Components/ReceiptCard.swift" "Evlin iOS/Views/Settings/AliasManagementView.swift"
git commit -m "feat(ios): adopt NameWithIcon in ReceiptCard + AliasManagementView"
```

---

## Section E — iOS: Multi-Action Bundled ProposalCard

### Task 13: `extractAliasTargets` plural + per-row `pendingAliasMisses`

**Important prerequisite:** the current `AnyCodable` (at `APIClient.swift:365-387`) only decodes scalars (Int/Double/String/Bool) and collapses arrays/dicts to `""`. The `args.rows` plural shape is a JSON array of dicts → would decode as `""` and `extractAliasTargets` would return empty. **Step 0 below adds nested support before any other change.**

**Files:**
- Modify: `Evlin iOS/Services/APIClient.swift:365-387` (recursive AnyCodable)
- Modify: `Evlin iOS/Views/Chat/ChatViewModel.swift` (`extractAliasTarget` → `extractAliasTargets`; `pendingAliasMisses` becomes per-row keyed)
- Test: `Evlin iOSTests/MultiActionStagingTests.swift`

- [ ] **Step 0: Replace AnyCodable with recursive version**

In `Evlin iOS/Services/APIClient.swift` (replace the existing `AnyCodable` struct at line 365):

```swift
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let arr = try? container.decode([AnyCodable].self) {
            // Unwrap nested AnyCodable so `as? [Any]` works at call sites.
            value = arr.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case let string as String:
            try container.encode(string)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encode("")
        }
    }
}
```

- [ ] **Step 0.5: Add unit test for nested decode**

Append to `Evlin iOSTests/MultiActionStagingTests.swift` (or create the file if not yet — Step 1 creates it):

```swift
final class AnyCodableNestedTests: XCTestCase {
    func test_decodesNestedArrayOfDicts() throws {
        let json = """
        {"rows": [{"target": "IG", "target_kind": "app", "minutes": 15}]}
        """.data(using: .utf8)!
        struct Wrap: Decodable { let rows: AnyCodable }
        let decoded = try JSONDecoder().decode(Wrap.self, from: json)
        let rows = decoded.rows.value as? [Any]
        XCTAssertNotNil(rows)
        XCTAssertEqual(rows?.count, 1)
        let first = rows?.first as? [String: Any]
        XCTAssertEqual(first?["target"] as? String, "IG")
        XCTAssertEqual(first?["minutes"] as? Int, 15)
    }
}
```

- [ ] **Step 1: Write failing test**

Create `Evlin iOSTests/MultiActionStagingTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class ExtractAliasTargetsTests: XCTestCase {
    private func proposal(tool: String, rows: [[String: Any]]) -> ProposalDTO {
        let typedRows = rows.map { row in
            row.mapValues { AnyCodable($0) }
        }
        let typedRowsCodable = AnyCodable(typedRows)
        return ProposalDTO(
            tool: tool,
            args: ["rows": typedRowsCodable],
            label: "test",
            danger: "low",
            token: UUID().uuidString
        )
    }

    func test_extractsAllRows() {
        let p = proposal(tool: "shield_app_legacy", rows: [
            ["target": "IG", "target_kind": "app"],
            ["target": "TT", "target_kind": "app"],
            ["target": "Entertainment", "target_kind": "category"],
        ])
        let result = ChatViewModel.extractAliasTargets(from: p)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0]?.target, "IG")
        XCTAssertEqual(result[0]?.kind, .app)
        XCTAssertEqual(result[2]?.target, "Entertainment")
        XCTAssertEqual(result[2]?.kind, .category)
    }

    func test_legacy_singleArgsShape_returnsSingleRow() {
        // Old proposals (pre-bundling) had {target, target_kind} at top level.
        let p = ProposalDTO(
            tool: "shield_app_legacy",
            args: [
                "target": AnyCodable("IG"),
                "target_kind": AnyCodable("app"),
            ],
            label: "test",
            danger: "low",
            token: UUID().uuidString
        )
        let result = ChatViewModel.extractAliasTargets(from: p)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]?.target, "IG")
    }

    func test_returnsEmpty_forNonShieldTool() {
        let p = ProposalDTO(
            tool: "propose_reflection", args: [:],
            label: "test", danger: "low", token: UUID().uuidString
        )
        XCTAssertTrue(ChatViewModel.extractAliasTargets(from: p).isEmpty)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
xcodebuild test -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 16e" -only-testing:Evlin_iOSTests/ExtractAliasTargetsTests 2>&1 | tail -20
```

Expected: FAIL — `extractAliasTargets` doesn't exist.

- [ ] **Step 3: Add plural extractor**

In `Evlin iOS/Views/Chat/ChatViewModel.swift`, **add** this method alongside `extractAliasTarget` (which we keep for backwards compat):

```swift
/// Multi-row variant. Returns `[Optional]` with same length as rows;
/// nil at index i means row i isn't an alias-eligible target (kind
/// outside {app, category}). Empty list when proposal has no rows
/// AND no top-level target/kind args.
nonisolated static func extractAliasTargets(
    from proposal: ProposalDTO
) -> [(target: String, kind: AliasKind)?] {
    guard proposal.tool == "shield_app_legacy"
        || proposal.tool == "unshield_app_legacy"
    else { return [] }

    // New shape: args.rows is an array of {target, target_kind, minutes}
    if let rowsAny = proposal.args["rows"]?.value as? [Any] {
        return rowsAny.map { rowAny -> (target: String, kind: AliasKind)? in
            guard let row = rowAny as? [String: Any] else { return nil }
            guard let target = row["target"] as? String,
                  !target.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            guard let rawKind = row["target_kind"] as? String else { return nil }
            switch rawKind {
            case "app": return (target, .app)
            case "category": return (target, .category)
            default: return nil
            }
        }
    }

    // Legacy shape: {target, target_kind} at top level. Return as 1-row list.
    if let single = extractAliasTarget(from: proposal) {
        return [single]
    }
    return []
}
```

- [ ] **Step 4: Update `pendingAliasMisses` to keyed by (token, rowIndex)**

In the same file, change the type of `pendingAliasMisses`:

```swift
// Was: var pendingAliasMisses: [String: String] = [:]   // token -> target name
// Becomes: keyed by "\(token)#\(rowIndex)"
@Published var pendingAliasMisses: [String: String] = [:]   // "<token>#<idx>" -> target name
```

Add a helper:

```swift
nonisolated static func aliasMissKey(token: String, rowIndex: Int) -> String {
    "\(token)#\(rowIndex)"
}
```

- [ ] **Step 5: Update pre-flight loop to populate per-row**

Find the pre-flight block in `processResponse` / wherever `extractAliasTarget` is currently called (around line 224-240). Replace:

```swift
for proposal in proposals {
    let targets = Self.extractAliasTargets(from: proposal)
    for (idx, entry) in targets.enumerated() {
        guard let (target, kind) = entry else { continue }
        let hit: Bool
        switch kind {
        case .app: hit = LocalAliasStore.shared.applicationToken(forLookupKey: target) != nil
        case .category: hit = LocalAliasStore.shared.categoryToken(forName: target) != nil
        }
        if !hit {
            pendingAliasMisses[Self.aliasMissKey(token: proposal.token, rowIndex: idx)] = target
        }
    }
}
```

- [ ] **Step 6: Run to confirm pass**

```bash
xcodebuild test -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 16e" -only-testing:Evlin_iOSTests/ExtractAliasTargetsTests 2>&1 | tail -20
```

Expected: PASS (3 tests).

- [ ] **Step 7: Add file to Xcode test target**

In Xcode: right-click `Evlin iOSTests` group → Add Files → select `MultiActionStagingTests.swift` → check `Evlin iOSTests` target only.

- [ ] **Step 8: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatViewModel.swift" "Evlin iOSTests/MultiActionStagingTests.swift" "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "feat(ios): extractAliasTargets plural + per-row pendingAliasMisses keying"
```

---

### Task 14: AgentClient `legacyActions` plural case

**Files:**
- Modify: `Evlin iOS/Services/AgentClient.swift`

- [ ] **Step 1: Add plural enum case**

In `Evlin iOS/Services/AgentClient.swift`, replace `AgentExecResult`:

```swift
enum AgentExecResult {
    case receipt(ReceiptDTO)
    /// Singular legacy action — kept for backwards compat with old
    /// proposals in flight at deploy time. New code emits `legacyActions`.
    case legacyAction(action: APIClient.ChatActionResponse?, message: String?, reasoning: String?)
    /// Plural: each entry is one staged sub-action's exec result.
    case legacyActions(results: [LegacyActionResult], message: String?, reasoning: String?)
}

struct LegacyActionResult: Decodable {
    let action: APIClient.ChatActionResponse?
    let message: String?
}
```

- [ ] **Step 2: Update `ExecResponseDTO` decoding**

In the same file, replace `ExecResponseDTO`:

```swift
private struct ExecResponseDTO: Decodable {
    let receipt: ReceiptDTO?
    let legacy_action: APIClient.ChatActionResponse?
    let legacy_actions: [LegacyActionResult]?
    let message: String?
    let reasoning: String?
}
```

- [ ] **Step 3: Update `executeProposal` dispatching**

Replace the body of `executeProposal` (around line 28-37):

```swift
let decoded = try JSONDecoder().decode(ExecResponseDTO.self, from: data)
if let receipt = decoded.receipt {
    return .receipt(receipt)
}
if let plural = decoded.legacy_actions, !plural.isEmpty {
    return .legacyActions(
        results: plural,
        message: decoded.message,
        reasoning: decoded.reasoning
    )
}
return .legacyAction(
    action: decoded.legacy_action,
    message: decoded.message,
    reasoning: decoded.reasoning
)
```

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "BUILD SUCCEEDED|error:" | head -10
```

Expected: `BUILD SUCCEEDED` (compile errors will surface in next task when ChatViewModel uses the new case).

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Services/AgentClient.swift"
git commit -m "feat(ios): AgentExecResult.legacyActions plural case + DTO support"
```

---

### Task 15: ChatViewModel `confirmProposal` plural results

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatViewModel.swift:768+` (`confirmProposal`)

- [ ] **Step 1: Refactor pre-flight gate to per-row check**

Replace the hard guard at the top of `confirmProposal`:

```swift
func confirmProposal(_ p: ProposalDTO) async {
    // Hard guard: any row in this proposal still has an outstanding
    // alias miss → refuse. UI should also disable Confirm but this is
    // defense in depth.
    let targets = Self.extractAliasTargets(from: p)
    for (idx, _) in targets.enumerated() {
        let key = Self.aliasMissKey(token: p.token, rowIndex: idx)
        if pendingAliasMisses[key] != nil {
            errorMessage = "Tap \"Tag\" first so I know which app you mean."
            return
        }
    }
    // ... existing client.executeProposal call
}
```

- [ ] **Step 2: Handle new plural result case**

In the `do { let result = try await client.executeProposal(token: p.token); switch result { ... } }` block, **add** a third case before the closing brace:

```swift
case .legacyActions(let results, let message, let reasoning):
    // Remove the proposal from the previous agent bubble.
    if let i = messages.lastIndex(where: { $0.role == .agent }) {
        var msg = messages[i]
        msg.proposals?.removeAll(where: { $0.token == p.token })
        messages[i] = msg
    }
    // For each result with a command_id: append a fresh agent bubble +
    // start its own ack-poll. Receipts will update independently.
    for result in results {
        guard let act = result.action, let cid = act.command_id else {
            // No command_id (text-only result) — append as plain bubble.
            let bubble = ChatMessage(
                role: .agent,
                content: result.message ?? "",
                timestamp: Date(),
                reasoning: reasoning,
                action: nil
            )
            messages.append(bubble)
            continue
        }
        var msg = ChatMessage(
            role: .agent,
            content: result.message ?? "",
            timestamp: Date(),
            reasoning: reasoning,
            action: nil
        )
        msg.commandID = cid
        msg.receiptState = .pending
        messages.append(msg)
        startAckPoll(
            commandID: cid,
            messageID: msg.id,
            targetDisplay: act.target_display,
            expiresAt: act.duration_minutes.map {
                Date().addingTimeInterval(TimeInterval($0 * 60))
            }
        )
    }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "BUILD SUCCEEDED|error:" | head -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatViewModel.swift"
git commit -m "feat(ios): confirmProposal handles plural legacyActions; per-row alias-miss guard"
```

---

### Task 16: `ProposalCard` multi-row layout

**Files:**
- Modify: `Evlin iOS/Components/ConfirmationCards/ProposalCard.swift`

- [ ] **Step 1: Refactor ProposalCard to read rows**

Replace the body of `ProposalCard` to handle both single + multi:

```swift
struct ProposalCard: View {
    let proposal: ProposalDTO
    var onConfirm: () async -> Void
    var onSkip: () -> Void
    /// Caller (ChatView) supplies per-row miss targets. Index aligned
    /// with `rows` below; nil means the row is good.
    var rowAliasMissTargets: [String?] = []
    var onTagRow: (Int) -> Void = { _ in }
    @State private var working = false

    private var rows: [(target: String, kind: String, minutes: Int?)] {
        if let rowsAny = proposal.args["rows"]?.value as? [Any] {
            return rowsAny.compactMap { r in
                guard let dict = r as? [String: Any],
                      let target = dict["target"] as? String,
                      let kind = dict["target_kind"] as? String
                else { return nil }
                let minutes = dict["minutes"] as? Int
                return (target, kind, minutes)
            }
        }
        // Legacy shape: derive single row from top-level args
        if let target = proposal.args["target"]?.value as? String,
           let kind = proposal.args["target_kind"]?.value as? String {
            let minutes = proposal.args["minutes"]?.value as? Int
            return [(target, kind, minutes)]
        }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: dangerIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(dangerColor)
                Text(proposal.label)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.evOnSurface)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                rowView(idx: idx, row: row)
            }
            HStack(spacing: 10) {
                Button(action: { Task { await runConfirm() } }) {
                    Text(working ? "Working…" : (rows.count > 1 ? "Confirm all" : "Confirm"))
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(confirmBackground)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(confirmDisabled)
                Button(action: onSkip) {
                    Text("Skip")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.evSurfaceContainerLow)
                        .foregroundStyle(Color.evOnSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(16)
        .background(Color.evSurfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(dangerColor.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func rowView(idx: Int, row: (target: String, kind: String, minutes: Int?)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                NameWithIcon(
                    name: row.target,
                    kind: row.kind == "category" ? .category : .app,
                    titleFont: .system(size: 15, weight: .medium)
                )
                Spacer()
                if rowMissTarget(idx: idx) == nil && rows.count > 1 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.evSecondary)
                }
            }
            if let missTarget = rowMissTarget(idx: idx) {
                Button(action: { onTagRow(idx) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.white)
                        Text("First time locking — tap to confirm \"\(missTarget)\"")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(8)
        .background(Color.evSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func rowMissTarget(idx: Int) -> String? {
        guard idx < rowAliasMissTargets.count else { return nil }
        return rowAliasMissTargets[idx]
    }

    private func runConfirm() async {
        working = true
        await onConfirm()
        working = false
    }

    private var confirmDisabled: Bool {
        working || rowAliasMissTargets.contains(where: { $0 != nil })
    }

    private var confirmBackground: Color {
        rowAliasMissTargets.contains(where: { $0 != nil }) ? Color.evOutline : dangerColor
    }

    private var dangerColor: Color {
        switch proposal.danger {
        case "high": return Color.evError
        case "medium": return Color.orange
        default: return Color.evSecondary
        }
    }

    private var dangerIcon: String {
        switch proposal.danger {
        case "high": return "exclamationmark.triangle.fill"
        case "medium": return "questionmark.circle.fill"
        default: return "sparkles"
        }
    }
}
```

- [ ] **Step 2: Update ChatView call site to pass per-row data**

In `Evlin iOS/Views/Chat/ChatView.swift`, find the `ProposalCard(...)` invocation and replace:

```swift
ProposalCard(
    proposal: p,
    onConfirm: { await viewModel.confirmProposal(p) },
    onSkip: { viewModel.skipProposal(p) },
    rowAliasMissTargets: viewModel.rowAliasMissTargets(for: p),
    onTagRow: { idx in viewModel.beginLazyTag(for: p, rowIndex: idx) }
)
```

- [ ] **Step 3: Add `rowAliasMissTargets` and update `beginLazyTag` in ChatViewModel**

In `Evlin iOS/Views/Chat/ChatViewModel.swift`, replace `aliasMissTarget(for:)` with:

```swift
/// Per-row miss targets for ProposalCard. Index-aligned with the
/// proposal's rows. nil at i means row i has no outstanding miss.
func rowAliasMissTargets(for proposal: ProposalDTO) -> [String?] {
    let targets = Self.extractAliasTargets(from: proposal)
    return targets.enumerated().map { idx, _ in
        let key = Self.aliasMissKey(token: proposal.token, rowIndex: idx)
        return pendingAliasMisses[key]
    }
}
```

Update `beginLazyTag` to accept rowIndex:

```swift
func beginLazyTag(for proposal: ProposalDTO, rowIndex: Int) {
    let targets = Self.extractAliasTargets(from: proposal)
    guard rowIndex < targets.count, let (target, kind) = targets[rowIndex] else { return }
    activeLazyTagRequest = LazyTagRequest(
        proposalToken: proposal.token,
        rowIndex: rowIndex,
        target: target,
        kind: kind
    )
}
```

Update `LazyTagRequest` — fully specified. In `Evlin iOS/Models/LazyTagRequest.swift` (or wherever the type currently lives), replace with:

```swift
struct LazyTagRequest: Identifiable, Equatable {
    var id: String { "\(proposalToken)#\(rowIndex)" }
    let proposalToken: String
    let rowIndex: Int
    let target: String
    let kind: AliasKind
}
```

Update `handleTagSelection` to clear the per-row key:

```swift
func handleTagSelection(token: Any, request: LazyTagRequest) {
    let saveResult = LazyTagPersistence.persistAlias(
        token: token, kind: request.kind, target: request.target
    )
    switch saveResult {
    case .success:
        let key = Self.aliasMissKey(token: request.proposalToken, rowIndex: request.rowIndex)
        pendingAliasMisses.removeValue(forKey: key)
        activeLazyTagRequest = nil
    case .failure(let err):
        errorMessage = "Couldn't save tag: \(err)"
    }
}
```

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "BUILD SUCCEEDED|error:" | head -20
```

Expected: `BUILD SUCCEEDED`. Fix any compile errors surface (likely `LazyTagRequest` needs `rowIndex` field, sweep for stale `aliasMissTarget(for:)` callers).

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Components/ConfirmationCards/ProposalCard.swift" "Evlin iOS/Views/Chat/ChatView.swift" "Evlin iOS/Views/Chat/ChatViewModel.swift" "Evlin iOS/Models/LazyTagRequest.swift"
git commit -m "feat(ios): ProposalCard multi-row layout with per-row tag flow"
```

---

## Section F — iOS: U1 Card

### Task 17: Models + CardID + CardContext

**Files:**
- Create: `Evlin iOS/Models/U1Models.swift`
- Modify: `Evlin iOS/Models/CardID.swift`
- Modify: `Evlin iOS/Components/ConfirmationCards/CardDispatcher.swift` (CardContext fields)

- [ ] **Step 1: Create `U1Models.swift`**

```swift
import Foundation

/// Single row in a U1 unlock-disambiguation card. Mirrors backend's
/// _load_effective_state output dict.
struct U1ShieldEntry: Identifiable, Codable, Sendable {
    var id: Int { index }
    let index: Int        // position in original list — used for U1 marker
    let kind: String      // "app" | "category" | "list" | "all"
    let displayName: String
    let expiresAtISO: String?
    let stale: Bool

    enum CodingKeys: String, CodingKey {
        case index
        case kind
        case displayName = "display_name"
        case expiresAtISO = "expires_at_iso"
        case stale
    }
}
```

- [ ] **Step 2: Add `case U1` to CardID**

In `Evlin iOS/Models/CardID.swift`:

```swift
enum CardID: String, Codable, Sendable {
    case A1, A3
    case B1, B2
    case C1, C2
    case D1, D2, D3, D4
    case E1, E2, E3, E4
    case F1
    case G1
    case R1
    case U1   // unlock disambiguation
}
```

- [ ] **Step 3: Add U1 fields to CardContext**

In `Evlin iOS/Components/ConfirmationCards/CardDispatcher.swift`, add to `CardContext`:

```swift
struct CardContext {
    // ... existing fields
    let u1Token: String?
    let u1ShieldList: [U1ShieldEntry]
}
```

Update all CardContext call sites (search for `CardContext(`) to pass `u1Token: nil, u1ShieldList: []` for non-U1 cases. Default initializer recommended:

```swift
extension CardContext {
    static func defaultContext(targetDisplay: String, childName: String) -> CardContext {
        CardContext(
            targetDisplay: targetDisplay, childName: childName,
            durationMinutes: nil, categoryGuess: nil,
            listSuggestions: [], existingLists: [],
            blockItems: [], childDevices: [],
            mode: "std",
            existingRecordKey: nil, requestedExpiryISO: nil, existingMode: nil,
            u1Token: nil, u1ShieldList: []
        )
    }
}
```

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "BUILD SUCCEEDED|error:" | head -10
```

Fix call sites that fail to construct CardContext.

- [ ] **Step 5: Add file to Xcode**

Add `Models/U1Models.swift` to Evlin iOS target.

- [ ] **Step 6: Commit**

```bash
git add "Evlin iOS/Models/U1Models.swift" "Evlin iOS/Models/CardID.swift" "Evlin iOS/Components/ConfirmationCards/CardDispatcher.swift" "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "feat(ios): U1ShieldEntry model + CardID.U1 + CardContext U1 fields"
```

---

### Task 18: `U1Card.swift` view

**Files:**
- Create: `Evlin iOS/Components/ConfirmationCards/U1Card.swift`
- Modify: `Evlin iOS/Components/ConfirmationCards/CardDispatcher.swift` (`.U1` case)

- [ ] **Step 1: Create U1Card view**

```swift
import SwiftUI

struct U1Card: View {
    let entries: [U1ShieldEntry]
    let onUnlockSelected: ([Int]) -> Void
    let onUnlockEverything: () -> Void
    let onCancel: () -> Void

    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.open")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                Text("Unlock which one?")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.evOnSurface)
            }
            VStack(spacing: 6) {
                ForEach(entries) { entry in
                    rowView(entry: entry)
                }
            }
            VStack(spacing: 8) {
                Button(action: { onUnlockSelected(Array(selected).sorted()) }) {
                    Text("Unlock selected")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(selected.isEmpty ? Color.evOutline : Color.evPrimary)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(selected.isEmpty)
                Button(action: onUnlockEverything) {
                    Text("Unlock everything")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.evSurfaceContainerLow)
                        .foregroundStyle(Color.evError)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.evOutline)
                }
            }
        }
        .padding(16)
        .background(Color.evSurfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.evOutline.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func rowView(entry: U1ShieldEntry) -> some View {
        let kind: NameIconKind = {
            switch entry.kind {
            case "category": return .category
            case "list": return .savedList
            case "all": return .all
            default: return .app
            }
        }()
        Button(action: { toggle(entry.index) }) {
            HStack(spacing: 12) {
                Image(systemName: selected.contains(entry.index)
                      ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(selected.contains(entry.index)
                                     ? Color.evPrimary : Color.evOutline)
                VStack(alignment: .leading, spacing: 2) {
                    NameWithIcon(name: entry.displayName, kind: kind,
                                 titleFont: .system(size: 15, weight: .medium))
                    Text(subtitle(for: entry))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }
                Spacer()
            }
            .padding(8)
            .background(Color.evSurfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ idx: Int) {
        if selected.contains(idx) { selected.remove(idx) } else { selected.insert(idx) }
    }

    private func subtitle(for entry: U1ShieldEntry) -> String {
        let kindLabel: String = {
            switch entry.kind {
            case "app": return "App"
            case "category": return "Category"
            case "list": return "List"
            case "all": return "Whole phone"
            default: return entry.kind.capitalized
            }
        }()
        let expiry: String = {
            guard let iso = entry.expiresAtISO,
                  let date = ISO8601DateFormatter().date(from: iso)
            else { return "Until you unlock" }
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return "Unlocks \(f.string(from: date))"
        }()
        let prefix = entry.stale ? "May be stale · " : ""
        return "\(prefix)\(kindLabel) · \(expiry)"
    }
}
```

- [ ] **Step 2: Wire CardDispatcher to render U1**

In `Evlin iOS/Components/ConfirmationCards/CardDispatcher.swift`, add to the switch in `body`:

```swift
case .U1:
    U1Card(
        entries: context.u1ShieldList,
        onUnlockSelected: { indices in
            handlers.onU1UnlockSelected?(indices)
        },
        onUnlockEverything: { handlers.onU1UnlockEverything?() },
        onCancel: { handlers.onCancel?() }
    )
```

Add to `CardHandlers`:

```swift
var onU1UnlockSelected: (([Int]) -> Void)?
var onU1UnlockEverything: (() -> Void)?
```

- [ ] **Step 3: Add to Xcode + build**

Add `U1Card.swift` to Evlin iOS target. Build:

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "BUILD SUCCEEDED|error:" | head -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Components/ConfirmationCards/U1Card.swift" "Evlin iOS/Components/ConfirmationCards/CardDispatcher.swift" "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "feat(ios): U1Card view + CardDispatcher .U1 case"
```

---

### Task 19: U1 confirm round-trip in ChatViewModel

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatViewModel.swift`
- Test: `Evlin iOSTests/U1MarkerTests.swift`

- [ ] **Step 1: Write failing test for marker construction**

Create `Evlin iOSTests/U1MarkerTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class U1MarkerBuilderTests: XCTestCase {
    func test_allMarker() {
        let m = ChatViewModel.buildU1Marker(token: "abc123", mode: .all)
        XCTAssertEqual(m, "U1:abc123:all")
    }

    func test_selectedMarkerWithIndices() {
        let m = ChatViewModel.buildU1Marker(token: "abc123", mode: .selected([0, 2, 5]))
        XCTAssertEqual(m, "U1:abc123:selected:0,2,5")
    }

    func test_selectedMarkerEmptyIndicesNotAllowed() {
        let m = ChatViewModel.buildU1Marker(token: "abc123", mode: .selected([]))
        XCTAssertNil(m)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
xcodebuild test -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 16e" -only-testing:Evlin_iOSTests/U1MarkerBuilderTests 2>&1 | tail -10
```

Expected: FAIL — `buildU1Marker` doesn't exist.

- [ ] **Step 3: Add marker builder + handlers in ChatViewModel**

In `Evlin iOS/Views/Chat/ChatViewModel.swift`, add the message-capture state near the top with the other @Published vars:

```swift
/// Captured at sendMessage time so U1 confirm handlers can re-send the
/// original parent message with the marker appended. Reset whenever
/// `currentCard` clears (cancel / new chat round).
private var lastUserMessageForCard: String = ""
```

Inside `sendMessage()`, immediately before the `dispatchChat(userMessage: text, ...)` call, add:

```swift
lastUserMessageForCard = text
```

Then add the marker builder + handlers:

```swift
enum U1Mode {
    case all
    case selected([Int])
}

nonisolated static func buildU1Marker(token: String, mode: U1Mode) -> String? {
    switch mode {
    case .all:
        return "U1:\(token):all"
    case .selected(let indices):
        guard !indices.isEmpty else { return nil }
        let idx = indices.sorted().map(String.init).joined(separator: ",")
        return "U1:\(token):selected:\(idx)"
    }
}

func handleU1UnlockSelected(token: String, indices: [Int], originalMessage: String) {
    guard let marker = Self.buildU1Marker(token: token, mode: .selected(indices))
    else { return }
    dispatchChat(userMessage: originalMessage, forceConfirmations: [marker])
    currentCard = nil
}

func handleU1UnlockEverything(token: String, originalMessage: String) {
    let marker = Self.buildU1Marker(token: token, mode: .all)!
    dispatchChat(userMessage: originalMessage, forceConfirmations: [marker])
    currentCard = nil
}
```

- [ ] **Step 4: Wire handlers when rendering U1 card**

In ChatViewModel, find where `currentCard` is set for cards (search for `currentCard = (`). For the U1 case, set handlers:

```swift
case .U1:
    let token = act.u1_token ?? ""
    let entries = (act.u1_shield_list ?? []).enumerated().map { idx, dict -> U1ShieldEntry in
        U1ShieldEntry(
            index: idx,
            kind: dict["kind"] as? String ?? "app",
            displayName: dict["display_name"] as? String ?? "(unknown)",
            expiresAtISO: dict["expires_at_iso"] as? String,
            stale: dict["stale"] as? Bool ?? false
        )
    }
    let context = CardContext.defaultContext(
        targetDisplay: "", childName: childName
    )
    var ctx = context
    ctx = CardContext(
        targetDisplay: context.targetDisplay,
        childName: context.childName,
        durationMinutes: nil, categoryGuess: nil,
        listSuggestions: [], existingLists: [], blockItems: [],
        childDevices: [], mode: "std",
        existingRecordKey: nil, requestedExpiryISO: nil, existingMode: nil,
        u1Token: token,
        u1ShieldList: entries
    )
    // Source: ChatViewModel must store the user's last typed message
    // (the one that just produced this U1 card) on a property so the
    // U1 confirm round-trip can re-send it with the U1 marker. Add
    // `private var lastUserMessageForCard: String = ""` near the
    // other @Published vars, and assign it inside `sendMessage()`
    // right before calling `dispatchChat(...)`:
    //   lastUserMessageForCard = text
    let originalMessage = lastUserMessageForCard
    let handlers = CardHandlers(
        onCancel: { [weak self] in self?.currentCard = nil },
        onU1UnlockSelected: { [weak self] indices in
            self?.handleU1UnlockSelected(token: token, indices: indices, originalMessage: originalMessage)
        },
        onU1UnlockEverything: { [weak self] in
            self?.handleU1UnlockEverything(token: token, originalMessage: originalMessage)
        }
    )
    currentCard = (.U1, ctx, handlers)
```

- [ ] **Step 5: Update `ChatActionResponse` to include u1 fields**

In `Evlin iOS/Services/APIClient.swift`, find `ChatActionResponse` (around line 37) and add:

```swift
struct ChatActionResponse: Codable, Sendable {
    // ... existing fields
    let u1_token: String?
    let u1_shield_list: [[String: AnyCodable]]?
}
```

If `[String: AnyCodable]` doesn't decode cleanly from a JSON dict, adapt to a Codable wrapper or to `[U1ShieldEntry]` directly.

- [ ] **Step 6: Build + run U1 marker test**

```bash
xcodebuild test -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 16e" -only-testing:Evlin_iOSTests/U1MarkerBuilderTests 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 7: Add U1MarkerTests.swift to test target in Xcode**

- [ ] **Step 8: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatViewModel.swift" "Evlin iOS/Services/APIClient.swift" "Evlin iOSTests/U1MarkerTests.swift" "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "feat(ios): U1 marker builder + ChatViewModel U1 handlers + CardDispatcher wiring"
```

---

## Section G — End-to-end Smoke Test

### Task 20: Manual E2E verification

**Prerequisite:** the lazy-tagging plan (`docs/superpowers/plans/2026-05-06-lazy-tagging-plan.md`) must be fully implemented and deployed. This E2E exercises Saved tags, `CustomTokenPickerView`, and the alias pre-flight infrastructure built there. Without that foundation, Steps 2 and 6 below will fail at the lazy-tag picker.

**Files:** none (manual test script).

- [ ] **Step 1: Deploy backend + install fresh iOS build**

Push backend to Railway (auto-deploys). In Xcode: Clean Build Folder (`Shift+Cmd+K`) → Run on real device.

- [ ] **Step 2: Test multi-action shield**

1. Saved tags → Clear all aliases.
2. Chat: `lock IG and TT for 15 min`.
3. Verify: bundled shield card appears with 2 rows, each with "Tag" button.
4. Tap "Tag IG" → CustomTokenPickerView → select Instagram → save.
5. Tap "Tag TT" → CustomTokenPickerView → select TikTok → save.
6. Verify: row 1 and row 2 both show green checkmark; "Confirm all" enabled.
7. Tap "Confirm all".
8. Switch to K mode (FloatingModeToggle). Verify: both apps are shielded (icons greyed in springboard).
9. Switch back to P mode.
10. Verify: 2 receipt cards appear, both `confirmedExact` with displayName + icon, "Unlocks at HH:MM" line correct.

- [ ] **Step 3: Test U1 unlock disambiguation**

1. With both apps still shielded (from Step 2) + Entertainment shielded as category from Saved tags.
2. Chat: `unlock`.
3. Verify: U1 card appears with 3 rows (IG / TT / Entertainment), each with type label + icon + checkbox.
4. Check IG only → Unlock selected.
5. Verify: bundled unshield proposal appears with 1 row (IG).
6. Tap "Confirm".
7. Switch to K mode → verify IG unshielded; TT + Entertainment still shielded.
8. Switch back to P → receipt confirms IG unshielded.
9. Chat: `unlock` again → U1 card with 2 rows (TT, Entertainment).
10. Tap "Unlock everything" → verify all unshield Command queues.

- [ ] **Step 4: Test bare unlock with 1 active**

1. Reset to single shield (only IG).
2. Chat: `unlock`.
3. Verify: NO U1 card; goes directly to unshield IG (single-row proposal or eager dispatch).

- [ ] **Step 5: Test bare unlock with 0 active**

1. Reset all unshields.
2. Chat: `unlock`.
3. Verify: agent message reads "Nothing is locked right now." (no card, no command).

- [ ] **Step 6: Test mixed shield+unshield in one turn**

1. Tag bilibili (Saved tags → ensure aliased).
2. Chat: `lock entertainment for 15 min but not bilibili`.
3. Verify: 2 stacked cards — one shield (Entertainment) + one unshield (bilibili).
4. Confirm both → verify Entertainment shielded, bilibili unshielded as expected.

- [ ] **Step 7: Sign-off**

If all 6 scenarios pass: tick this checkbox; multi-action + U1 Phase 1 ships.

If any fail: open issue with the failing scenario number + console `[AckPoll]` logs + Railway backend logs for the corresponding chat round.

---

## Self-Review Checklist (already applied)

- [x] **Spec coverage:** Components 1, 2, 4 fully task-mapped. Component 3 (ask_pick) intentionally deferred — only the agent_loop accumulator branch is in Task 4.
- [x] **No placeholders:** every code step shows the exact code; every test step shows expected output.
- [x] **Type consistency:** `extractAliasTargets` (plural) used consistently from Task 13 onward; `args.rows` shape consistent across backend Task 6 and iOS Task 13/16; `pendingAliasMisses` keyed by `aliasMissKey(token:rowIndex:)` everywhere.
- [x] **Backwards compat:** singular `legacy_gemini_action` and `legacy_action` fields populated when len==1 (Tasks 4, 7); iOS handles both `legacyAction` and `legacyActions` enum cases (Task 14).
- [x] **Deploy order safe:** backend lands first (Tasks 1-10) — old iOS clients see the singular field. iOS lands second (Tasks 11-19) handling both.

## Review log

**Round 2 (2026-05-07)** — two AI reviewers; 7 P1 + 3 small fixes applied:

- **P1 Alembic absent:** repo uses `Base.metadata.create_all` startup. Task 1 rewritten — model edit + raw SQL migration script under `backend/scripts/migrations/` + Railway runbook note. No Alembic introduced.
- **P1 Device fixture field:** all `role="child"` swapped to `mode=DeviceMode.child` with explicit `from backend.app.db.models.device import DeviceMode` import in every test file.
- **P1 AgentLoop test API:** mock `gemini.chat` (not generate); construct real `AgentInput` (not bare MagicMock).
- **P1 D1/D3 gating bypass in multi-action:** added explicit pre-check loop in `_stage_legacy_actions` — if any action has missing duration or unconfirmed >24h, route THAT action through eager `_handle_gemini_action` so D1/D3 surfaces. Siblings re-emerge from Gemini next round.
- **P1 AnyCodable nested decode:** Step 0 of Task 13 swaps in a recursive AnyCodable that handles `[AnyCodable]` and `[String: AnyCodable]` plus a unit test in MultiActionStagingTests.
- **P1 U1 single-active list/all routing:** kind-specific `ResolvedAction` branches added — list_name for "list", target_all=true for "all", category_hint for "category", default for "exactApp".
- **P1 `userMessageThatTriggeredCard` placeholder:** replaced with `lastUserMessageForCard` private var on ChatViewModel, captured inside `sendMessage()` before `dispatchChat()`.
- **P2 simulator name:** `iPhone 15` → `iPhone 16e` everywhere.
- **P2 E2E prereq:** Task 20 now states the lazy-tagging plan must be deployed first.
- **P3 LazyTagRequest spec:** explicit struct definition with id / proposalToken / rowIndex / target / kind, replacing the "if needed" hand-wave.

## Out of scope (explicit)

- ask_pick tool implementation (Phase 2)
- ManagedSettings shieldExceptions for "shield A but not B inside same category"
- ActionExecutor verify-before-success (catching stale ApplicationToken silent no-op)
- Replacing legacy hardcoded D1/D2/D3/D4/A1/B1/E1/F1 cards with ask_pick
- Apple's 15-min DeviceActivitySchedule minimum UX clamp

---

**End of Phase 1 plan. 19 implementation tasks + 1 manual E2E.**
