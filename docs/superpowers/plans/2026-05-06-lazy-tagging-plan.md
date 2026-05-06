# Lazy Tagging Implementation Plan v4

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let parents say "lock IG" in chat and have iOS resolve "Instagram" → ApplicationToken → shield, with a one-tap Tag-before-Confirm flow when iOS doesn't yet know an app name.

**Architecture (Path 1 — Proposal-first):** `shield_app` for `target_kind ∈ {app, category}` does NOT short-circuit the agent loop with `legacy_gemini_action` anymore. Instead, parent_chat stages it as a `Proposal` carrying minimal chat context (`message`, `family_id`, `child_name`, `child_device_id`, `reasoning` — only fields defined on ChatRequest) to re-run dispatcher later. iOS gets `resp.proposals`, runs LocalAliasStore pre-flight, blocks Confirm until any miss is tagged. On Confirm, `/parent/agent/exec` detects the staged-legacy entry and forwards to the existing `_handle_gemini_action` dispatcher, returning the normal `ChatResponse.action` (with `command_id`) iOS already knows how to render via `startAckPoll`.

**Tech Stack:** Python 3.13 / FastAPI / Pydantic on backend; Swift 5 / SwiftUI / FamilyControls / ManagedSettings / XCTest on iOS. Single-device test mode + `.child` Max mode only — std two-device alias sync deferred.

**Spec:** `docs/superpowers/specs/2026-05-06-lazy-tagging-design.md`

---

## File Structure

**Backend create:** none.

**Backend modify (3 files):**
- `adaptive-engine/backend/app/services/proposal_store.py` — store optional `chat_context: dict` alongside `(tool, args)`.
- `adaptive-engine/backend/app/api/routes/parent_chat.py` — intercept `agent_resp.legacy_gemini_action` for shield_app app/category targets; stage as Proposal carrying chat context; return `ChatResponse(proposals=[...])`.
- `adaptive-engine/backend/app/api/routes/parent_agent.py` — `/parent/agent/exec` detects staged-legacy entries and forwards to `_handle_gemini_action`; response schema accommodates legacy `ChatAction`.

**iOS create (4 files):**
- `Evlin iOS/Models/AliasKind.swift`
- `Evlin iOS/Models/LazyTagRequest.swift`
- `Evlin iOS/Services/LazyTagPersistence.swift`
- `Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift`

**iOS modify (4 files):**
- `Evlin iOS/Services/AgentClient.swift` — `executeProposal` returns enum union `(.receipt | .legacyAction)`.
- `Evlin iOS/Views/Chat/ChatViewModel.swift` — pre-flight, alias-miss state, hard guard, tag callbacks, legacy-exec path.
- `Evlin iOS/Components/ConfirmationCards/ProposalCard.swift` — alias-miss UI.
- `Evlin iOS/Views/Chat/ChatView.swift` — props + `.sheet(item:)`.

**iOS test create (1 file):**
- `Evlin iOSTests/LazyTagTests.swift`

---

# Phase 0 — Backend (Path 1 enabling)

## Task 0.1: ProposalStore stores chat context

**Files:**
- Modify: `adaptive-engine/backend/app/services/proposal_store.py`

Without chat context attached to a proposal, `/parent/agent/exec` can't reconstruct the dispatcher call. We extend the entry tuple with an optional `chat_context: dict | None`.

- [ ] **Step 1: Replace the file**

```python
# adaptive-engine/backend/app/services/proposal_store.py
"""ProposalStore — in-memory staging of tool calls awaiting parent
confirmation. 10-min TTL so stale proposals get garbage-collected.

`chat_context` is the carrier for legacy-shield staging: when the agent
emits a shield_app legacy_gemini_action that we want gated by Tag-before-
Confirm, parent_chat stages a proposal with the originating ChatRequest's
context (only fields actually defined on ChatRequest).
On exec, the route re-runs `_handle_gemini_action` with that context so
the dispatcher path is identical to the eager (non-staged) flow.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import uuid4


class ProposalStore:
    def __init__(self, ttl_seconds: int = 600) -> None:
        # token -> [tool_name, args_dict, expires_at, chat_context]
        self._entries: dict[str, list] = {}
        self._ttl = ttl_seconds

    def stage(
        self,
        *,
        tool: str,
        args: dict,
        chat_context: dict[str, Any] | None = None,
    ) -> str:
        token = uuid4().hex
        self._entries[token] = [
            tool,
            args,
            datetime.now(timezone.utc) + timedelta(seconds=self._ttl),
            chat_context,
        ]
        return token

    def pop(self, token: str) -> tuple[str, dict, dict[str, Any] | None] | None:
        entry = self._entries.pop(token, None)
        if entry is None:
            return None
        tool, args, expires_at, chat_context = entry
        if expires_at < datetime.now(timezone.utc):
            return None
        return (tool, args, chat_context)


_singleton: ProposalStore | None = None


def get_proposal_store() -> ProposalStore:
    global _singleton
    if _singleton is None:
        _singleton = ProposalStore()
    return _singleton
```

- [ ] **Step 2: Update the existing exec endpoint to unpack the new 3-tuple**

Edit `adaptive-engine/backend/app/api/routes/parent_agent.py` line 44:

```python
# Old:
    popped = proposal_store.pop(body.token)
    if popped is None:
        raise HTTPException(...)
    tool_name, args = popped

# New:
    popped = proposal_store.pop(body.token)
    if popped is None:
        raise HTTPException(
            status_code=410, detail="proposal expired or already used",
        )
    tool_name, args, chat_context = popped
```

(Don't forget to use `chat_context` in Task 0.3 — for now, this is just unblocking the type change.)

- [ ] **Step 3: Run backend tests to discover impact**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
pytest backend/tests/ -k "proposal_store or agent_loop or parent_chat" 2>&1 | tail -20
```

Expected: `test_proposal_store.py` may fail because tests destructure `pop()` as 2-tuple. Don't fix here yet — Task 0.3 Step 3 batches both ProposalStore + parent_agent endpoint test patches. We use this run only to confirm the failure locations.

If `agent_loop` or `parent_chat` tests fail, they're touching `proposal_store.pop()` directly — also handled in Task 0.3 Step 3.

- [ ] **Step 4: Commit**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
git add backend/app/services/proposal_store.py backend/app/api/routes/parent_agent.py
git commit -m "feat(proposal-store): carry optional chat_context for legacy-staged proposals"
```

---

## Task 0.2: parent_chat — stage shield_app as Proposal for app/category targets

**Files:**
- Modify: `adaptive-engine/backend/app/api/routes/parent_chat.py` (around line 404)

When `agent_resp.legacy_gemini_action` represents a `shield` action with `target_kind_hint ∈ {app, category}`, do NOT immediately dispatch. Instead, stage as a Proposal carrying enough chat context to re-run dispatcher later, and return a `ChatResponse(proposals=[...])` for iOS. For `target_kind_hint ∈ {all, list}`, keep the existing eager dispatch path — no alias resolution needed.

- [ ] **Step 1: Add the staging helper**

Above the existing `_handle_gemini_action` definition (around line 429), add:

```python
def _is_lazy_tag_eligible(gemini_action: dict) -> bool:
    """True only for shield calls with app/category target_kind AND a
    concrete int duration. Excludes:
    - `block` (uses bundle-id catalog, not ApplicationToken)
    - `all` / `list` target kinds (no alias lookup needed)
    - duration_minutes == "missing" (dispatcher must show D1 first; after
      parent picks duration, the next round comes back here with int
      duration and stages cleanly).
    - duration_minutes > 24*60 without D3 confirmation (D3 long-duration
      card must show first; parent confirming D3 re-submits with
      force_confirmations=["D3"] which we treat as eligible).
    """
    if gemini_action.get("type") != "shield":
        return False
    if gemini_action.get("target_kind_hint") not in {"app", "category"}:
        return False
    duration = gemini_action.get("duration_minutes")
    # Coerce same way chat_resolver does — protobuf often sends float/str.
    if isinstance(duration, float):
        duration = int(duration)
    elif isinstance(duration, str) and duration.isdigit():
        duration = int(duration)
    if not isinstance(duration, int) or duration <= 0:
        return False
    return True


def _stage_legacy_shield_proposal(
    *,
    proposal_store: ProposalStore,
    gemini_action: dict,
    req: "ChatRequest",
    message: str,
    reasoning: str | None,
) -> "ChatResponse":
    """Park the legacy_gemini_action in ProposalStore with chat context, return
    a ChatResponse carrying a single Proposal so iOS can run pre-flight
    and gate Confirm on alias resolution.

    The chat context stores ONLY fields that actually exist on ChatRequest
    (verified against parent_chat.py:217). Adding fields like child_id /
    protection_mode / parent_id would AttributeError. Dispatcher's
    `_handle_gemini_action` only reads from req what's actually defined.
    """
    chat_context = {
        "message": message,
        "reasoning": reasoning,
        "family_id": str(req.family_id) if req.family_id else None,
        "child_name": req.child_name,
        "child_device_id": str(req.child_device_id) if req.child_device_id else None,
    }
    token = proposal_store.stage(
        tool="shield_app_legacy",
        args={"gemini_action": gemini_action},
        chat_context=chat_context,
    )

    target = gemini_action.get("target_request") or "this app"
    minutes = gemini_action.get("duration_minutes")
    label_minutes = (
        f" for {minutes} min"
        if isinstance(minutes, int) and minutes > 0
        else ""
    )
    label = f"Shield {target}{label_minutes}"

    # Backend Proposal (NOT ProposalDTO — there is no ProposalDTO class).
    proposal = Proposal(
        tool="shield_app_legacy",
        args={
            "target": target,
            "target_kind": gemini_action.get("target_kind_hint", "app"),
            "minutes": minutes if isinstance(minutes, int) else None,
        },
        label=label,
        danger="medium",
        token=token,
    )
    return ChatResponse(
        message=message or f"I'll shield {target} once you confirm.",
        reasoning=reasoning,
        action=None,
        proposals=[proposal],
    )
```

- [ ] **Step 2: Insert the intercept**

Find the existing block at parent_chat.py:404:

```python
        if agent_resp.legacy_gemini_action is not None:
            return await _handle_gemini_action(
                gemini_action=agent_resp.legacy_gemini_action,
                message=agent_resp.message or "",
                reasoning=agent_resp.reasoning,
                req=req, session=session,
            )
```

Replace with:

```python
        if agent_resp.legacy_gemini_action is not None:
            # Lazy-tag eligible (shield_app with app/category target):
            # stage as Proposal so iOS can pre-flight LocalAliasStore and
            # gate Confirm on Tag-before-Confirm. exec endpoint will
            # forward back into _handle_gemini_action on confirm.
            if _is_lazy_tag_eligible(agent_resp.legacy_gemini_action):
                proposal_store = get_proposal_store()
                return _stage_legacy_shield_proposal(
                    proposal_store=proposal_store,
                    gemini_action=agent_resp.legacy_gemini_action,
                    req=req,
                    message=agent_resp.message or "",
                    reasoning=agent_resp.reasoning,
                )
            # Other legacy actions (target_kind=all/list, non-shield): keep
            # eager dispatch — no alias resolution needed.
            return await _handle_gemini_action(
                gemini_action=agent_resp.legacy_gemini_action,
                message=agent_resp.message or "",
                reasoning=agent_resp.reasoning,
                req=req, session=session,
            )
```

- [ ] **Step 3: Add necessary imports at the top of parent_chat.py**

If not already present:

```python
from backend.app.schemas.agent import Proposal
from backend.app.services.proposal_store import (
    ProposalStore, get_proposal_store,
)
```

(`Proposal` is the actual class name — there is no `ProposalDTO` in the backend. `Proposal` is already used in `parent_chat.py` because `ChatResponse.proposals: list[Proposal]` is defined here at line ~256.)

- [ ] **Step 4: Run backend tests**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
pytest backend/tests/api/routes/test_parent_chat.py -v 2>&1 | tail -20
```

Expected: no regressions on existing tests. (We're adding a branch that only fires for shield_app app/category — should not touch other test paths.)

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/routes/parent_chat.py
git commit -m "feat(parent-chat): stage shield app/category as Proposal for Tag-before-Confirm"
```

---

## Task 0.3: /parent/agent/exec — forward staged-legacy proposals to dispatcher

**Files:**
- Modify: `adaptive-engine/backend/app/api/routes/parent_agent.py`

When the popped proposal entry has `tool_name == "shield_app_legacy"` and a non-None `chat_context`, we do NOT call `GLOBAL_REGISTRY.call(tool_name, args)`. Instead we reconstruct a synthetic `ChatRequest` from `chat_context`, call `_handle_gemini_action` with the original `gemini_action`, and return its `ChatResponse` (which carries `action.command_id` / `card_id`) inside a new exec response shape.

- [ ] **Step 1: Update exec response model + handler**

Replace the entire body of `parent_agent.py` `exec_proposal`:

```python
"""POST /parent/agent/exec — execute a previously-staged proposal.

Two paths:
1. Standard tool: pop, call tool, return Receipt under `.receipt` field.
2. shield_app_legacy: pop, reconstruct ChatRequest from stored chat_context,
   forward to _handle_gemini_action(), return its ChatResponse-shape
   under `.legacy_action` etc. iOS distinguishes via which field is non-None.

Note on schemas: ChatRequest / ChatResponse / ChatAction are defined in
`backend.app.api.routes.parent_chat` (no shared schemas.chat module exists).
We import them at function scope to avoid import cycles between routes.
"""
from __future__ import annotations

from typing import Any, TYPE_CHECKING
from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from backend.app.db.engine import get_async_session
from backend.app.schemas.agent import Receipt
from backend.app.services.agent_tools import GLOBAL_REGISTRY
from backend.app.services.parent_action_log import (
    ParentActionLog, get_log as get_action_log,
)
from backend.app.services.proposal_store import (
    ProposalStore, get_proposal_store,
)

# Force tool modules to import so @tool decorators register into
# GLOBAL_REGISTRY at module load.
from backend.app.services.agent_tools import (  # noqa: F401
    read_tools, task_tools, reflection_tools, bypass_tools,
    vision_tools, shield_tools,
)

if TYPE_CHECKING:
    # Avoid circular import at runtime. parent_chat imports parent_agent
    # via routers registration. Use string types in signatures.
    from backend.app.api.routes.parent_chat import ChatAction


router = APIRouter(tags=["Parent Agent"])


class ExecBody(BaseModel):
    token: str


class ExecResponse(BaseModel):
    """Union shape for v2 exec.
    For standard tools, only `.receipt` is set.
    For staged-legacy shield, only `.legacy_action` + `.message` + `.reasoning`
    are set (mirroring the relevant subset of ChatResponse).
    iOS branches on which field is present.

    v1 scope: legacy path returns `ChatAction` with `command_id` (or `card_id`).
    A receipt-only legacy path (e.g. dispatcher returns text only, no action)
    is unsupported in v1 — iOS falls back to displaying `.message` as plain
    text in that case. Future enhancement if needed.
    """
    # Use Any for legacy_action because ChatAction lives in parent_chat.py
    # and importing it eagerly creates an import cycle. Pydantic accepts
    # the dict-form of ChatAction at JSON serialization time.
    receipt: Receipt | None = None
    legacy_action: dict[str, Any] | None = None  # ChatAction dict
    message: str | None = None
    reasoning: str | None = None


@router.post("/parent/agent/exec", response_model=ExecResponse)
async def exec_proposal(
    body: ExecBody,
    proposal_store: ProposalStore = Depends(get_proposal_store),
    log: ParentActionLog = Depends(get_action_log),
    session: AsyncSession = Depends(get_async_session),
) -> ExecResponse:
    popped = proposal_store.pop(body.token)
    if popped is None:
        raise HTTPException(
            status_code=410, detail="proposal expired or already used",
        )
    tool_name, args, chat_context = popped

    # Path 2: legacy shield proposal — forward to dispatcher.
    if tool_name == "shield_app_legacy" and chat_context is not None:
        return await _exec_legacy_shield(
            args=args, chat_context=chat_context, session=session,
        )

    # Path 1: standard tool path (existing behavior).
    if tool_name not in GLOBAL_REGISTRY.tools:
        raise HTTPException(status_code=500, detail=f"tool gone: {tool_name}")
    meta = GLOBAL_REGISTRY.tools[tool_name]

    result = await GLOBAL_REGISTRY.call(tool_name, args)

    undo_token: str | None = None
    undo_expires_iso: str | None = None
    if meta.inverse_action:
        inverse_args = (
            meta.inverse_args_builder(args, result)
            if meta.inverse_args_builder else dict(args)
        )
        undo_token = log.record(
            action_type=tool_name, args=args,
            inverse_action=meta.inverse_action,
            inverse_args=inverse_args,
            source="agent",
        )
        entry = log.get(undo_token)
        if entry is not None:
            undo_expires_iso = entry.expires_at.isoformat()
    receipt = Receipt(
        tool=tool_name, args=args,
        summary=result.public_summary or tool_name,
        undo_token=undo_token,
        undo_expires_at=undo_expires_iso,
    )
    return ExecResponse(receipt=receipt)


async def _exec_legacy_shield(
    *,
    args: dict[str, Any],
    chat_context: dict[str, Any],
    session: AsyncSession,
) -> ExecResponse:
    """Re-run _handle_gemini_action with the chat context captured at
    staging. The gemini_action dict is in args["gemini_action"]; chat_context
    carries the ChatRequest fields that actually exist (no child_id /
    protection_mode / parent_id — they aren't on ChatRequest).
    """
    # Import here to avoid circular dependency between routes.
    from backend.app.api.routes.parent_chat import (
        _handle_gemini_action, ChatRequest,
    )

    gemini_action = args.get("gemini_action") or {}

    # Reconstruct ChatRequest using ONLY fields defined in parent_chat.py:217.
    req_dict: dict[str, Any] = {
        "message": chat_context.get("message", ""),
        "child_name": chat_context.get("child_name") or "Liam",
    }
    if chat_context.get("family_id"):
        req_dict["family_id"] = UUID(chat_context["family_id"])
    if chat_context.get("child_device_id"):
        req_dict["child_device_id"] = UUID(chat_context["child_device_id"])

    req = ChatRequest(**req_dict)

    chat_response = await _handle_gemini_action(
        gemini_action=gemini_action,
        message=chat_context.get("message", ""),
        reasoning=chat_context.get("reasoning"),
        req=req,
        session=session,
    )
    # ChatResponse.action is a ChatAction Pydantic model; serialize to dict
    # so ExecResponse.legacy_action (typed dict[str, Any]) accepts it cleanly.
    action_dict: dict[str, Any] | None = None
    if chat_response.action is not None:
        action_dict = chat_response.action.model_dump(mode="json")
    return ExecResponse(
        legacy_action=action_dict,
        message=chat_response.message,
        reasoning=chat_response.reasoning,
    )
```

- [ ] **Step 2: Verify ChatRequest fields match what we synthesize**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
grep -n "^class ChatRequest" -A 20 backend/app/api/routes/parent_chat.py | head -25
```

Expected: ChatRequest fields are exactly `message, family_id, child_name, history, force_confirmations, child_device_id`. If anything has been renamed, adjust the chat_context synthesis (Task 0.2) AND the `req_dict` construction here in lockstep.

- [ ] **Step 3: Update existing backend tests for new shapes**

The shape changes from this phase break two test files. Run them and patch the assertions:

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
pytest backend/tests/services/test_proposal_store.py backend/tests/api/routes/test_parent_agent_endpoints.py -v 2>&1 | tail -30
```

Expected failures + fixes:

a. `test_proposal_store.py` — `pop()` now returns 3-tuple `(tool, args, chat_context)`. Existing 2-tuple unpacks fail:
   - Replace `tool, args = popped` with `tool, args, _ctx = popped` in tests.
   - Add a focused test: `def test_pop_returns_chat_context_when_staged()`:
     ```python
     def test_pop_returns_chat_context_when_staged():
         store = ProposalStore()
         token = store.stage(tool="t", args={}, chat_context={"hello": 1})
         result = store.pop(token)
         assert result == ("t", {}, {"hello": 1})
     ```

b. `test_parent_agent_endpoints.py` — receipt is now nested under `.receipt`, not at the top level of the response body:
   - Old: `assert resp.json()["tool"] == "x"` and `resp.json()["summary"] == "..."`
   - New: `assert resp.json()["receipt"]["tool"] == "x"` and `resp.json()["receipt"]["summary"] == "..."`
   - `assert resp.json()["legacy_action"] is None` for standard tool path.

Patch the assertions, re-run, confirm green.

- [ ] **Step 4: Run full backend test suite**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
pytest backend/tests/ 2>&1 | tail -10
```

Expected: all green. New legacy shield staging behavior isn't covered by existing tests; that's OK — the iOS E2E in Task 2.8 covers it.

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/routes/parent_agent.py backend/tests/services/test_proposal_store.py backend/tests/api/routes/test_parent_agent_endpoints.py
git commit -m "feat(exec): forward staged-legacy shield proposals to dispatcher; update tests for new shapes"
```

---

## Task 0.4: chat_resolver — exactApp bypass for lazy-tag-confirmed app shields

**Files:**
- Modify: `adaptive-engine/backend/app/services/chat_resolver.py` (around line 266 — the `if kind == "app":` branch)

**Why:** Without this, even a tagged shield never queues an exactApp command. `_route_shield` currently always returns E1 (category-fallback card) for `target_kind == "app"`, regardless of whether iOS has bound an alias. We add a `force_exact_app` flag that the lazy-tag exec path sets — when set, dispatcher trusts that the iOS LocalAliasStore can resolve the target and queues a `tier="exactApp"` Command directly. The Command's `target_display` is the canonical name (e.g. "Instagram"), and ActionExecutor's `resolveExactApp` looks up the token via `LocalAliasStore.applicationToken(forLookupKey:)`.

- [ ] **Step 1: Patch `_route_shield`'s app branch**

Find the existing block at chat_resolver.py:266:

```python
    if kind == "app":
        # Std can't shield single apps; Max remote picker not in MVP → both offer E1 fallback.
        return DispatchResult(
            requires_card="E1",
            category_guess=action.get("category_hint_from_ai"),
            ...
        )
```

Replace with:

```python
    if kind == "app":
        # Lazy-tag confirmed path: when /parent/agent/exec re-submits a
        # staged shield_app_legacy, it sets `force_exact_app=True` so we
        # know iOS has already bound (target_request → ApplicationToken)
        # in LocalAliasStore. Queue a `tier="exactApp"` Command directly;
        # the kid device's ActionExecutor.resolveExactApp(...) resolves
        # the token via LocalAliasStore.applicationToken(forLookupKey:
        # target_display). bundle_id is None — the kid resolves by
        # display-name lookup key.
        if action.get("force_exact_app"):
            return DispatchResult(
                resolved=ResolvedAction(
                    action="shield",
                    tier="exactApp",
                    target_display=target,
                    duration_minutes=duration if isinstance(duration, int) else None,
                    force_downgrade=force_downgrade,
                )
            )
        # Eager (non-lazy-tag) path: still falls back to E1 because the
        # backend has no way to know the right token without iOS-side
        # tagging. Behavior unchanged for non-staged calls.
        return DispatchResult(
            requires_card="E1",
            category_guess=action.get("category_hint_from_ai"),
            # Preserve any other fields from the original line — keep
            # the existing trailing parameters.
        )
```

(Re-verify the existing trailing kwargs of the `requires_card="E1"` branch and preserve them in the fallback. The diff is purely additive — adds the `if action.get("force_exact_app"): ...` branch above the existing fallback.)

- [ ] **Step 2: Set the flag in `_exec_legacy_shield`**

Edit `backend/app/api/routes/parent_agent.py` `_exec_legacy_shield` — between `gemini_action = args.get("gemini_action") or {}` and the `_handle_gemini_action` call, add:

```python
    # Tell the dispatcher this is a tag-confirmed app shield. _route_shield
    # checks this flag and routes to tier="exactApp" instead of returning E1.
    # category target_kind already routes to tier="category" cleanly — no flag.
    if gemini_action.get("target_kind_hint") == "app":
        gemini_action["force_exact_app"] = True
```

- [ ] **Step 3: Add a chat_resolver test for the bypass**

Append to `backend/tests/services/test_chat_resolver.py` (or wherever shield routing is tested):

```python
def test_route_shield_app_with_force_exact_app_returns_exact_app():
    """Lazy-tag-confirmed app shield bypasses E1, queues exactApp command."""
    action = {
        "type": "shield",
        "target_kind_hint": "app",
        "target_request": "Instagram",
        "duration_minutes": 30,
        "force_exact_app": True,
    }
    result = _route_shield(
        mode="std", saved_list_names=[], action=action, force_confirmations=[],
    )
    assert result.requires_card is None
    assert result.resolved is not None
    assert result.resolved.tier == "exactApp"
    assert result.resolved.target_display == "Instagram"
    assert result.resolved.duration_minutes == 30


def test_route_shield_app_without_flag_still_returns_e1():
    """Eager (non-staged) app shields still get E1 fallback — behavior unchanged."""
    action = {
        "type": "shield",
        "target_kind_hint": "app",
        "target_request": "Instagram",
        "duration_minutes": 30,
    }
    result = _route_shield(
        mode="std", saved_list_names=[], action=action, force_confirmations=[],
    )
    assert result.requires_card == "E1"
    assert result.resolved is None
```

(Adjust the import / module path of `_route_shield` to match the test file's existing imports.)

- [ ] **Step 4: Run tests**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
pytest backend/tests/services/test_chat_resolver.py -v 2>&1 | tail -20
```

Expected: 2 new tests pass, no regression on existing tests.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/chat_resolver.py backend/app/api/routes/parent_agent.py backend/tests/services/test_chat_resolver.py
git commit -m "feat(chat-resolver): bypass E1 for lazy-tag-confirmed app shields (force_exact_app flag)"
```

---

# Phase 1 — iOS contract bridge

## Task 1.1: AgentClient.executeProposal returns enum union

**Files:**
- Modify: `Evlin iOS/Services/AgentClient.swift`

Backend now returns either `{receipt: ...}` or `{legacy_action: ..., message: ..., reasoning: ...}` from `/parent/agent/exec`. We model this as a Swift enum so callers branch cleanly.

- [ ] **Step 1: Find current executeProposal**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
grep -n "executeProposal\|ExecResponse" "Evlin iOS/Services/AgentClient.swift"
```

- [ ] **Step 2: Update AgentClient with new response type**

In `Evlin iOS/Services/AgentClient.swift`, find the existing executeProposal method. Replace its return type signature with:

```swift
/// Result of /parent/agent/exec. Backend returns either a tool-style
/// receipt (existing tools) or a legacy ChatAction+message bundle (when
/// the proposal was a staged shield_app_legacy entry — see backend
/// parent_agent.py / parent_chat.py for staging).
///
/// IMPORTANT: legacy action uses `APIClient.ChatActionResponse` — the same
/// type that decodes /parent/chat's `action` field. The other `ChatAction`
/// in `Models/ChatModels.swift` is a legacy enum unrelated to /parent/chat
/// responses; do not use it here.
enum AgentExecResult {
    case receipt(ReceiptDTO)
    case legacyAction(action: APIClient.ChatActionResponse?, message: String?, reasoning: String?)
}

/// Server-side response shape mirroring backend ExecResponse.
private struct ExecResponseDTO: Decodable {
    let receipt: ReceiptDTO?
    let legacy_action: APIClient.ChatActionResponse?
    let message: String?
    let reasoning: String?
}

func executeProposal(token: String) async throws -> AgentExecResult {
    let url = URL(string: "\(baseURL)/parent/agent/exec")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(["token": token])
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
    }
    let decoded = try JSONDecoder().decode(ExecResponseDTO.self, from: data)
    if let receipt = decoded.receipt {
        return .receipt(receipt)
    }
    return .legacyAction(
        action: decoded.legacy_action,
        message: decoded.message,
        reasoning: decoded.reasoning
    )
}
```

(Adjust to match the file's existing style — use whatever URLSession / encoder helpers are conventional in the file. Replace any older `executeProposal` body. `ReceiptDTO` lives in this same file; `APIClient.ChatActionResponse` is in `Services/APIClient.swift` — fully-qualified reference avoids import puzzling.)

- [ ] **Step 3: Build verify**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | tee /tmp/build.log | grep -E "error:" | head -5; if grep -q "^.*error:" /tmp/build.log; then echo "BUILD FAILED"; else echo OK; fi
```

Expected: errors at the existing `confirmProposal` call site (`let receipt = try await client.executeProposal(...)`) because the return type changed. That's expected — Task 1.2 fixes it.

- [ ] **Step 4: Don't commit yet** — Task 1.2 must compile first.

---

## Task 1.2: ChatViewModel.confirmProposal handles legacyAction path

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatViewModel.swift` (line ~647 — existing `confirmProposal`)

When the staged proposal was a legacy shield, the exec response carries a `ChatAction` whose `command_id` (or `card_id`) iOS already knows how to plumb. We hand it off to the existing pathway that processes ChatResponse.action.

- [ ] **Step 1: Locate the existing command_id processing block**

It lives inside `processResponse(_:userMessage:)` near line 190. The relevant pattern (verified against current code):

```swift
if let act = resp.action, let cmdID = act.command_id {
    var msg = ChatMessage(
        role: .agent, content: resp.message, timestamp: Date(),
        reasoning: resp.reasoning, action: nil
    )
    msg.commandID = cmdID
    msg.receiptState = .pending
    messages.append(msg)
    startAckPoll(
        commandID: cmdID,
        messageID: msg.id,
        targetDisplay: act.target_display,
        expiresAt: act.duration_minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
    )
    isThinking = false
    return
}
```

Notes for the legacy-exec path:
- `ChatMessage.init(... action:)` accepts an old enum `ChatAction?` — we always pass `nil`. Don't try to thread the new `APIClient.ChatActionResponse` through that param; it's the wrong type and the message doesn't store it anyway.
- The card_id branch (lines 174–182) is ALSO possible from the dispatcher, but for v1 lazy-tag legacy-exec we only handle command_id. If `act.card_id` is non-nil, fall back to appending the message text only and surface a one-time errorMessage explaining the unsupported branch — avoids silently dropping the response.

- [ ] **Step 2: Replace `confirmProposal(_:)` body**

Find:

```swift
    @MainActor
    func confirmProposal(_ p: ProposalDTO) async {
        let client = AgentClient(baseURL: apiClient.baseURL)
        do {
            let receipt = try await client.executeProposal(token: p.token)
            ...
```

Replace with:

```swift
    @MainActor
    func confirmProposal(_ p: ProposalDTO) async {
        // Hard guard: refuse to dispatch if alias miss is outstanding for
        // this proposal. UI also disables Confirm; this is defense in depth.
        if pendingAliasMisses[p.token] != nil {
            errorMessage = "Tap \"Tag\" first so I know which app you mean."
            return
        }
        let client = AgentClient(baseURL: apiClient.baseURL)
        do {
            let result = try await client.executeProposal(token: p.token)
            switch result {
            case .receipt(let receipt):
                if let i = messages.lastIndex(where: { $0.role == .agent }) {
                    var msg = messages[i]
                    msg.proposals?.removeAll(where: { $0.token == p.token })
                    msg.receipts = (msg.receipts ?? []) + [receipt]
                    messages[i] = msg
                }
            case .legacyAction(let action, let message, let reasoning):
                // Remove the proposal from the previous agent bubble so the
                // ProposalCard disappears. We do NOT thread the legacy action
                // through ChatMessage.init(action:) — that param is for the
                // old ChatAction enum and isn't read by ChatView anyway.
                if let i = messages.lastIndex(where: { $0.role == .agent }) {
                    var msg = messages[i]
                    msg.proposals?.removeAll(where: { $0.token == p.token })
                    messages[i] = msg
                }
                // Mirror processResponse's command_id branch: append a fresh
                // agent bubble carrying message + reasoning, then if the
                // dispatcher gave us a command_id, attach pending state and
                // start ack-poll. The bubble's commandID is what drives
                // ChatView's ReceiptCard rendering + ack updates.
                if let act = action, let cid = act.command_id {
                    var msg = ChatMessage(
                        role: .agent,
                        content: message ?? "",
                        timestamp: Date(),
                        reasoning: reasoning,
                        action: nil    // legacy enum field, intentionally nil
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
                } else if let act = action, act.card_id != nil {
                    // v1 doesn't render dispatcher-staged secondary cards
                    // (D1 duration picker, A1 destructive confirm) on the
                    // legacy-exec path. Surface a clear message instead of
                    // silently dropping. This is rare for confirmed shields
                    // since duration/destructive confirms happen BEFORE the
                    // proposal stage.
                    let bubble = ChatMessage(
                        role: .agent,
                        content: message ?? "(unsupported response)",
                        timestamp: Date(),
                        reasoning: reasoning,
                        action: nil
                    )
                    messages.append(bubble)
                    errorMessage = "Couldn't show the next step. Try again."
                } else {
                    // No command_id, no card — text-only response. Display
                    // it as plain agent message.
                    let bubble = ChatMessage(
                        role: .agent,
                        content: message ?? "",
                        timestamp: Date(),
                        reasoning: reasoning,
                        action: nil
                    )
                    messages.append(bubble)
                }
            }
            NotificationCenter.default.post(name: .bigKidStateInvalidated, object: nil)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
```

The `startAckPoll(...)` signature above is verified against `ChatViewModel.swift` line 487 — exactly the same parameters as the eager-dispatch path uses. No new helper needed.

- [ ] **Step 3: Build verify**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | tee /tmp/build.log | grep -E "error:" | head -5; if grep -q "^.*error:" /tmp/build.log; then echo "BUILD FAILED"; else echo OK; fi
```

Expected: `OK` only. If errors mention undeclared `pendingAliasMisses` — that's ok for now (added in Phase 2 Task 2.3). Move the empty `pendingAliasMisses: [String: AliasKind] = [:]` declaration up to this task and verify build is clean.

If `pendingAliasMisses` is referenced before being declared, add this near the other `@Published` declarations:

```swift
    @Published var pendingAliasMisses: [String: AliasKind] = [:]
```

(Task 2.3 will add `extractAliasTarget` and pre-flight; we declare the state here so the hard guard compiles.)

- [ ] **Step 4: Commit Phase 1**

```bash
git add "Evlin iOS/Services/AgentClient.swift" "Evlin iOS/Views/Chat/ChatViewModel.swift"
git commit -m "feat(agent-exec): handle staged-legacy shield response (legacyAction enum case)"
```

---

# Phase 2 — iOS lazy tag UI

## Task 2.1: AliasKind enum + LazyTagRequest model

**Files:**
- Create: `Evlin iOS/Models/AliasKind.swift`
- Create: `Evlin iOS/Models/LazyTagRequest.swift`

- [ ] **Step 1: Create `AliasKind.swift`**

```swift
// Evlin iOS/Models/AliasKind.swift
//
// Discriminator for lazy-tag flows.
import Foundation

enum AliasKind: Equatable {
    case app
    case category
}
```

- [ ] **Step 2: Create `LazyTagRequest.swift`**

```swift
// Evlin iOS/Models/LazyTagRequest.swift
//
// Drives `.sheet(item:)` in ChatView. `id` is the ProposalDTO.token of the
// proposal that triggered the tag flow (also stable identifier for SwiftUI).
import Foundation

struct LazyTagRequest: Identifiable, Equatable {
    let id: String       // proposalToken
    let target: String   // e.g. "Instagram"
    let kind: AliasKind
}
```

- [ ] **Step 3: Build verify**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | tee /tmp/build.log | grep -E "error:" | head -5; if grep -q "^.*error:" /tmp/build.log; then echo "BUILD FAILED"; else echo OK; fi
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Models/AliasKind.swift" "Evlin iOS/Models/LazyTagRequest.swift"
git commit -m "feat(lazy-tag): AliasKind enum + LazyTagRequest model"
```

---

## Task 2.2: LazyTagPersistence service + tests

**Files:**
- Create: `Evlin iOS/Services/LazyTagPersistence.swift`
- Create: `Evlin iOSTests/LazyTagTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Evlin iOSTests/LazyTagTests.swift`:

```swift
// Evlin iOSTests/LazyTagTests.swift
import XCTest
@testable import Evlin_iOS

final class LazyTagPersistenceTests: XCTestCase {
    func test_persistAlias_rejectsWrongTypeForApp() {
        let result = LazyTagPersistence.persistAlias(
            token: "not a token" as Any,
            kind: .app,
            target: "Instagram"
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType failure")
        }
    }

    func test_persistAlias_rejectsWrongTypeForCategory() {
        let result = LazyTagPersistence.persistAlias(
            token: 42 as Any,
            kind: .category,
            target: "games"
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType failure")
        }
    }

    func test_persistAlias_rejectsEmptyTarget() {
        let result = LazyTagPersistence.persistAlias(
            token: "x" as Any,
            kind: .app,
            target: "   "
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .emptyTarget)
        case .success: XCTFail("expected emptyTarget failure")
        }
    }
}
```

- [ ] **Step 2: Run tests, verify failure**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 16e" test 2>&1 | grep -E "error:|LazyTagPersistence" | head -5
```

Expected: `cannot find 'LazyTagPersistence' in scope`.

- [ ] **Step 3: Implement `LazyTagPersistence.swift`**

```swift
// Evlin iOS/Services/LazyTagPersistence.swift
//
// Pure persistence helper for lazy tag. No UI, no presentation. Validates
// that the token type matches the kind, then delegates to LocalAliasStore.

import Foundation
import FamilyControls
import ManagedSettings

enum LazyTagError: Error, Equatable {
    case wrongTokenType
    case emptyTarget
}

enum LazyTagPersistence {
    static func persistAlias(
        token: Any,
        kind: AliasKind,
        target: String
    ) -> Result<Void, LazyTagError> {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTarget) }

        switch kind {
        case .app:
            guard let appToken = token as? ApplicationToken else {
                return .failure(.wrongTokenType)
            }
            LocalAliasStore.shared.saveApplicationAliases(
                token: appToken,
                displayName: trimmed,
                bundleIdentifier: nil
            )
            return .success(())
        case .category:
            guard let catToken = token as? ActivityCategoryToken else {
                return .failure(.wrongTokenType)
            }
            LocalAliasStore.shared.saveCategoryToken(catToken, forName: trimmed)
            return .success(())
        }
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 16e" test 2>&1 | grep -E "Test Case|FAILED|passed" | head -10
```

Expected: 3 LazyTagPersistenceTests pass.

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Services/LazyTagPersistence.swift" "Evlin iOSTests/LazyTagTests.swift"
git commit -m "feat(lazy-tag): LazyTagPersistence helper + type-rejection tests"
```

---

## Task 2.3: ChatViewModel — extractAliasTarget + alias-miss state + pre-flight

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatViewModel.swift`
- Modify: `Evlin iOSTests/LazyTagTests.swift` (add ExtractAliasTargetTests)

Adds:
1. `nonisolated static func extractAliasTarget(from:)` — testable from XCTest without `@MainActor` isolation drama.
2. `pendingAliasMisses` (already declared in Task 1.2 — verify present).
3. `activeLazyTagRequest` for the sheet driver.
4. Pre-flight loop where ProposalDTOs first arrive, with proposal type `"shield_app_legacy"` (Task 0.2 changed the tool name for staged shields).

- [ ] **Step 1: Write failing tests**

Append to `Evlin iOSTests/LazyTagTests.swift`:

```swift
final class ExtractAliasTargetTests: XCTestCase {
    private func proposal(tool: String, args: [String: Any]) -> ProposalDTO {
        let typed = args.mapValues { AnyCodable($0) }
        return ProposalDTO(
            tool: tool,
            args: typed,
            label: "test",
            danger: "low",
            token: UUID().uuidString
        )
    }

    func test_returnsAppTarget_forShieldAppLegacy_withAppKind() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target": "Instagram",
            "target_kind": "app"
        ])
        let result = ChatViewModel.extractAliasTarget(from: p)
        XCTAssertEqual(result?.target, "Instagram")
        XCTAssertEqual(result?.kind, .app)
    }

    func test_returnsCategoryTarget_forShieldAppLegacy_withCategoryKind() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target": "games",
            "target_kind": "category"
        ])
        let result = ChatViewModel.extractAliasTarget(from: p)
        XCTAssertEqual(result?.target, "games")
        XCTAssertEqual(result?.kind, .category)
    }

    func test_returnsNil_forNonShieldTool() {
        let p = proposal(tool: "propose_reflection", args: [
            "target": "anything"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }

    func test_returnsNil_whenTargetMissing() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target_kind": "app"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }

    func test_returnsNil_forUnknownKind() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target": "x",
            "target_kind": "weird"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }
}
```

- [ ] **Step 2: Run, verify failure**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 16e" test 2>&1 | grep -E "error:" | head -5
```

Expected: `type 'ChatViewModel' has no member 'extractAliasTarget'`.

- [ ] **Step 3: Add state + extractAliasTarget**

In `Evlin iOS/Views/Chat/ChatViewModel.swift`, near the other `@Published` declarations (just below `activePolls` near line 19), add (or confirm — Task 1.2 may have added the first):

```swift
    /// ProposalToken → kind for proposals whose alias didn't resolve at
    /// pre-flight. Drives ProposalCard's "Tag <target>" UI and the
    /// hard guard inside `confirmProposal(_:)`.
    @Published var pendingAliasMisses: [String: AliasKind] = [:]

    /// Non-nil when ChatView should present the lazy-tag sheet.
    @Published var activeLazyTagRequest: LazyTagRequest? = nil
```

Then add a new MARK section above `// MARK: - Agent envelope handlers (Phase E)` (around line 641):

```swift
    // MARK: - Lazy tagging

    /// Pure parser: pull `(target, kind)` out of a ProposalDTO if it's a
    /// `shield_app_legacy` call with a kind that needs alias resolution.
    /// `nonisolated` so XCTest can call without @MainActor isolation drama.
    nonisolated static func extractAliasTarget(
        from proposal: ProposalDTO
    ) -> (target: String, kind: AliasKind)? {
        guard proposal.tool == "shield_app_legacy" else { return nil }
        guard let target = proposal.args["target"]?.value as? String,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        guard let rawKind = proposal.args["target_kind"]?.value as? String else { return nil }
        switch rawKind {
        case "app": return (target, .app)
        case "category": return (target, .category)
        default: return nil
        }
    }

    /// True if the proposal currently has no alias miss outstanding.
    func aliasHit(for proposal: ProposalDTO) -> Bool {
        pendingAliasMisses[proposal.token] == nil
    }

    /// String to render in ProposalCard's miss UI; nil when no miss.
    /// Re-derives via extractAliasTarget so a hit (alias added since
    /// pre-flight) reflects immediately even if pendingAliasMisses
    /// hasn't been swept yet.
    func aliasMissTarget(for proposal: ProposalDTO) -> String? {
        guard pendingAliasMisses[proposal.token] != nil else { return nil }
        return Self.extractAliasTarget(from: proposal)?.target
    }
```

- [ ] **Step 4: Wire pre-flight on incoming proposals**

In `sendMessage`, find the existing block at line ~213:

```swift
        if (resp.proposals?.isEmpty == false) || (resp.receipts?.isEmpty == false) {
            var msg = ChatMessage(...)
            msg.proposals = resp.proposals
            msg.receipts = resp.receipts
            messages.append(msg)
            isThinking = false
            return
        }
```

Replace with:

```swift
        if (resp.proposals?.isEmpty == false) || (resp.receipts?.isEmpty == false) {
            // Pre-flight every proposal: shield_app_legacy with app/category
            // kind needs LocalAliasStore resolution before Confirm.
            for p in resp.proposals ?? [] {
                guard let (target, kind) = Self.extractAliasTarget(from: p) else { continue }
                let aliasResolved: Bool = {
                    switch kind {
                    case .app: return LocalAliasStore.shared.applicationToken(forLookupKey: target) != nil
                    case .category: return LocalAliasStore.shared.categoryToken(forName: target) != nil
                    }
                }()
                if !aliasResolved {
                    pendingAliasMisses[p.token] = kind
                }
            }
            var msg = ChatMessage(
                role: .agent, content: resp.message, timestamp: Date(),
                reasoning: resp.reasoning, action: nil
            )
            msg.proposals = resp.proposals
            msg.receipts = resp.receipts
            messages.append(msg)
            isThinking = false
            return
        }
```

- [ ] **Step 5: Run tests + build**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 16e" test 2>&1 | grep -E "error:|ExtractAliasTargetTests" | head -10
```

Expected: 5 ExtractAliasTargetTests pass, no errors.

- [ ] **Step 6: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatViewModel.swift" "Evlin iOSTests/LazyTagTests.swift"
git commit -m "feat(lazy-tag): pre-flight alias detection in ChatViewModel"
```

---

## Task 2.4: Tag flow callbacks (begin / handleSelection / cancel) + stale-miss sweeping

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatViewModel.swift`

Adds: `beginLazyTag(for:)`, `handleTagSelection(token:request:)`, `cancelLazyTag()`, plus stale-miss sweeping (when one tag succeeds, ALL pending misses with same target+kind clear, so multi-card scenarios resolve at once). Also have `skipProposal` clear that proposal's miss.

- [ ] **Step 1: Append callbacks to the `// MARK: - Lazy tagging` section**

```swift
    @MainActor
    func beginLazyTag(for proposal: ProposalDTO) {
        guard let kind = pendingAliasMisses[proposal.token] else { return }
        guard let (target, _) = Self.extractAliasTarget(from: proposal) else { return }
        activeLazyTagRequest = LazyTagRequest(
            id: proposal.token,
            target: target,
            kind: kind
        )
    }

    @MainActor
    func handleTagSelection(token: Any, request: LazyTagRequest) {
        let result = LazyTagPersistence.persistAlias(
            token: token,
            kind: request.kind,
            target: request.target
        )
        switch result {
        case .success:
            // Clear THIS proposal's miss + sweep any other pending misses
            // for the same (target, kind) — handles multi-card chats like
            // "lock IG and TikTok" where two cards reference Instagram.
            sweepResolvedMisses(target: request.target, kind: request.kind)
            activeLazyTagRequest = nil
        case .failure(let err):
            errorMessage = "Couldn't save the tag: \(err)"
            // Leave activeLazyTagRequest intact so user can retry.
        }
    }

    @MainActor
    func cancelLazyTag() {
        activeLazyTagRequest = nil
    }

    /// Removes any `pendingAliasMisses` entries whose proposal's
    /// (target, kind) match. Called after a successful tag — even if the
    /// chat had multiple cards referencing the same name, they all clear.
    @MainActor
    private func sweepResolvedMisses(target: String, kind: AliasKind) {
        // For each currently-known miss, re-extract its (target, kind) from
        // the latest message containing the proposal. If it matches, drop.
        let normalizedTarget = target.lowercased()
        for token in Array(pendingAliasMisses.keys) {
            if let p = findProposal(byToken: token),
               let (t, k) = Self.extractAliasTarget(from: p),
               k == kind,
               t.lowercased() == normalizedTarget {
                pendingAliasMisses.removeValue(forKey: token)
            }
        }
    }

    private func findProposal(byToken token: String) -> ProposalDTO? {
        for msg in messages.reversed() {
            if let proposals = msg.proposals,
               let found = proposals.first(where: { $0.token == token }) {
                return found
            }
        }
        return nil
    }
```

- [ ] **Step 2: Patch `skipProposal` to also clear its miss**

Find `func skipProposal` (line ~781). Just inside the function add:

```swift
    func skipProposal(_ p: ProposalDTO) {
        // Clear any outstanding alias miss — Skip means "don't do this",
        // which doesn't need a tag. Keeps state tidy.
        pendingAliasMisses.removeValue(forKey: p.token)
        // ... existing body of the function follows unchanged ...
```

- [ ] **Step 3: Build verify**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | tee /tmp/build.log | grep -E "error:" | head -5; if grep -q "^.*error:" /tmp/build.log; then echo "BUILD FAILED"; else echo OK; fi
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatViewModel.swift"
git commit -m "feat(lazy-tag): tag flow callbacks + stale-miss sweep + skip clears miss"
```

---

## Task 2.5: ProposalCard — alias-miss UI

**Files:**
- Modify: `Evlin iOS/Components/ConfirmationCards/ProposalCard.swift`

Adds two parameters: `aliasMissTarget: String?` and `onTag: () -> Void`. When `aliasMissTarget != nil` renders warning + Tag button + disables Confirm. When nil, renders exactly as today.

- [ ] **Step 1: Replace ProposalCard.swift**

```swift
import SwiftUI

/// Generic AI proposal card. When `aliasMissTarget` is non-nil, renders an
/// orange warning row + "Tag <target>" button and disables Confirm — the
/// view model removes the miss after lazy-tag flow saves an alias, at
/// which point the next render unblocks Confirm.
struct ProposalCard: View {
    let proposal: ProposalDTO
    var onConfirm: () async -> Void
    var onSkip: () -> Void
    var aliasMissTarget: String? = nil
    var onTag: () -> Void = {}
    @State private var working = false

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
            if !bodyText.isEmpty {
                Text(bodyText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineSpacing(2)
            }
            if let missTarget = aliasMissTarget {
                aliasMissBlock(target: missTarget)
            }
            HStack(spacing: 10) {
                Button(action: { Task { await runConfirm() } }) {
                    Text(working ? "Working…" : "Confirm")
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
    private func aliasMissBlock(target: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                    .font(.system(size: 13))
                Text("Evlin doesn't know which app is \u{201C}\(target)\u{201D} yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            Button(action: onTag) {
                Text("Tag \(target)")
                    .font(.system(size: 14, weight: .heavy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func runConfirm() async {
        working = true
        await onConfirm()
        working = false
    }

    private var confirmDisabled: Bool { working || aliasMissTarget != nil }

    private var confirmBackground: Color {
        aliasMissTarget != nil ? Color.evOutline : dangerColor
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

    private var bodyText: String {
        if let reason = proposal.args["reason"]?.value as? String {
            return "Reason: \"\(reason)\""
        }
        if let title = proposal.args["title"]?.value as? String {
            return "Title: \(title)"
        }
        if let minutes = proposal.args["minutes"]?.value as? Int {
            return "Duration: \(minutes) min"
        }
        return ""
    }
}
```

- [ ] **Step 2: Build verify**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | tee /tmp/build.log | grep -E "error:" | head -5; if grep -q "^.*error:" /tmp/build.log; then echo "BUILD FAILED"; else echo OK; fi
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Components/ConfirmationCards/ProposalCard.swift"
git commit -m "feat(lazy-tag): ProposalCard renders warning + Tag button when alias miss"
```

---

## Task 2.6: CustomTokenPickerView (with picker diff highlighting)

**Files:**
- Create: `Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift`

Single-select sheet UI. After Apple-picker fallback returns, computes diff (newly-added tokens), bumps them to the top, auto-selects if exactly 1 was added.

- [ ] **Step 1: Create the file**

```swift
// Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift
//
// Single-select picker presented as a `.sheet(item:)` from ChatView when
// ChatViewModel sets `activeLazyTagRequest`. Reads existing tokens from
// `screenTimeManager.selectedApps` and provides an "Add via Apple picker"
// footer to widen selection. After Apple-picker fallback, computes the
// before/after diff: if exactly 1 token was newly added, auto-select it
// (most common case — parent picked just the target app); if multiple,
// surface them at the top of the list.
//
// Note: There's a debug-only `Views/Debug/TokenPickerView.swift` that
// implements a similar primitive — that one is for the Settings probe
// page and is being kept as-is. CustomTokenPickerView is the production
// component. We don't migrate the debug view.
//
// ForEach id note: `Array(sortedApps.enumerated()), id: \.offset` uses
// list position as identity. Sheet lifecycle is short (~seconds per use)
// and the only reorder is once when Apple-picker fallback adds tokens.
// Acceptable risk for v1 — if reuse glitches surface during QA, swap to
// a stable wrapper keyed on `tok.hashValue`.

import SwiftUI
import FamilyControls
import ManagedSettings

struct CustomTokenPickerView: View {
    let request: LazyTagRequest
    let onSelect: (Any, LazyTagRequest) -> Void
    let onCancel: () -> Void

    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAppToken: ApplicationToken? = nil
    @State private var selectedCategoryToken: ActivityCategoryToken? = nil
    @State private var applePickerOpen = false
    @State private var pickerSelection: FamilyActivitySelection = FamilyActivitySelection()

    /// Captured before opening Apple picker so we can compute diff on dismiss.
    @State private var preApplePickerAppTokens: Set<ApplicationToken> = []
    @State private var preApplePickerCategoryTokens: Set<ActivityCategoryToken> = []

    /// Tokens added in the most recent Apple-picker session (rendered at top
    /// of list). Cleared when user picks one from the diff or cancels.
    @State private var newlyAddedAppTokens: Set<ApplicationToken> = []
    @State private var newlyAddedCategoryTokens: Set<ActivityCategoryToken> = []

    private var sortedApps: [ApplicationToken] {
        let all = Array(screenTimeManager.selectedApps.applicationTokens)
        let new = all.filter { newlyAddedAppTokens.contains($0) }
        let rest = all.filter { !newlyAddedAppTokens.contains($0) }
            .sorted { $0.hashValue < $1.hashValue }
        return new.sorted { $0.hashValue < $1.hashValue } + rest
    }
    private var sortedCategories: [ActivityCategoryToken] {
        let all = Array(screenTimeManager.selectedApps.categoryTokens)
        let new = all.filter { newlyAddedCategoryTokens.contains($0) }
        let rest = all.filter { !newlyAddedCategoryTokens.contains($0) }
            .sorted { $0.hashValue < $1.hashValue }
        return new.sorted { $0.hashValue < $1.hashValue } + rest
    }
    private var canSave: Bool {
        switch request.kind {
        case .app: return selectedAppToken != nil
        case .category: return selectedCategoryToken != nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                listBody
                Divider()
                footer
            }
            .navigationTitle(request.kind == .app ? "Tag app" : "Tag category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTapped() }
                        .disabled(!canSave)
                }
            }
            .familyActivityPicker(isPresented: $applePickerOpen, selection: $pickerSelection)
            .onChange(of: applePickerOpen) { _, isOpen in
                if !isOpen { mergePickerIntoSelectedApps() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which one is")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("\u{201C}\(request.target)\u{201D}?")
                .font(.custom("Manrope", size: 24).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
            Text("Tap the \(request.kind == .app ? "app" : "category") below. Evlin will remember it for next time.")
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOutline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
    }

    @ViewBuilder
    private var listBody: some View {
        switch request.kind {
        case .app:
            if sortedApps.isEmpty {
                emptyState(
                    message: "No apps in Managed Apps yet. Tap \u{201C}Add via Apple picker\u{201D} below to add \(request.target)."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(sortedApps.enumerated()), id: \.offset) { _, tok in
                            appRow(token: tok)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
        case .category:
            if sortedCategories.isEmpty {
                emptyState(
                    message: "No categories yet. Tap \u{201C}Add via Apple picker\u{201D} and tap the \(request.target) row."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(sortedCategories.enumerated()), id: \.offset) { _, tok in
                            categoryRow(token: tok)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func emptyState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(Color.evOutline)
            Text(message)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appRow(token: ApplicationToken) -> some View {
        let isSelected = selectedAppToken == token
        let isNew = newlyAddedAppTokens.contains(token)
        return Button {
            selectedAppToken = token
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.evPrimary : Color.evOutline)
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Spacer()
                if isNew {
                    Text("Just added")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.evPrimary)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Color.evPrimary.opacity(0.08) : Color.evSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.evPrimary : Color.evOutline.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func categoryRow(token: ActivityCategoryToken) -> some View {
        let isSelected = selectedCategoryToken == token
        let isNew = newlyAddedCategoryTokens.contains(token)
        return Button {
            selectedCategoryToken = token
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.evPrimary : Color.evOutline)
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Spacer()
                if isNew {
                    Text("Just added")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.evPrimary)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Color.evPrimary.opacity(0.08) : Color.evSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.evPrimary : Color.evOutline.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Don't see \u{201C}\(request.target)\u{201D}?")
                .font(.custom("Inter", size: 12).weight(.semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("Open Apple's picker to add it. New tokens will appear at the top of the list.")
                .font(.custom("Inter", size: 11))
                .foregroundStyle(Color.evOutline)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openApplePicker()
            } label: {
                Label("Open Apple picker", systemImage: "plus.circle")
                    .font(.custom("Inter", size: 13).weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
    }

    private func openApplePicker() {
        // Snapshot before so we can diff on dismiss.
        preApplePickerAppTokens = screenTimeManager.selectedApps.applicationTokens
        preApplePickerCategoryTokens = screenTimeManager.selectedApps.categoryTokens
        // For category mode, the Apple picker MUST be initialized with
        // includeEntireCategory: true — without this, tapping a category row
        // enumerates individual app tokens instead of producing a single
        // ActivityCategoryToken.
        switch request.kind {
        case .app:
            pickerSelection = FamilyActivitySelection()
        case .category:
            pickerSelection = FamilyActivitySelection(includeEntireCategory: true)
        }
        applePickerOpen = true
    }

    /// Apple picker dismissed. Merge into selectedApps (preserves shieldable
    /// authorization scope), compute diff, surface "just added" tokens at
    /// list top, auto-select if exactly one was added.
    private func mergePickerIntoSelectedApps() {
        var merged = screenTimeManager.selectedApps
        merged.applicationTokens.formUnion(pickerSelection.applicationTokens)
        merged.categoryTokens.formUnion(pickerSelection.categoryTokens)
        merged.webDomainTokens.formUnion(pickerSelection.webDomainTokens)
        // NOTE: `selection.applications` and `.categories` are get-only on
        // FamilyActivitySelection — see ScreenTimeManager.swift:49 ("get-only
        // — cannot restore metadata after plist decode"). We can't merge
        // them. The Label(token) view on the merged tokens still renders
        // names if Apple supplies them at view-time (Max .child auth mode);
        // the .applications metadata array isn't required for shield calls.
        screenTimeManager.selectedApps = merged
        screenTimeManager.saveSelection()

        // Compute diff for highlighting + auto-select.
        let nowApps = screenTimeManager.selectedApps.applicationTokens
        let nowCats = screenTimeManager.selectedApps.categoryTokens
        let addedApps = nowApps.subtracting(preApplePickerAppTokens)
        let addedCats = nowCats.subtracting(preApplePickerCategoryTokens)
        newlyAddedAppTokens = addedApps
        newlyAddedCategoryTokens = addedCats

        // Auto-select if exactly one new (the common case: parent picked
        // just the target app).
        switch request.kind {
        case .app where addedApps.count == 1:
            selectedAppToken = addedApps.first
        case .category where addedCats.count == 1:
            selectedCategoryToken = addedCats.first
        default:
            break
        }
    }

    private func saveTapped() {
        switch request.kind {
        case .app:
            guard let tok = selectedAppToken else { return }
            onSelect(tok, request)
            dismiss()
        case .category:
            guard let tok = selectedCategoryToken else { return }
            onSelect(tok, request)
            dismiss()
        }
    }
}
```

- [ ] **Step 2: Build verify**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | tee /tmp/build.log | grep -E "error:" | head -5; if grep -q "^.*error:" /tmp/build.log; then echo "BUILD FAILED"; else echo OK; fi
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift"
git commit -m "feat(lazy-tag): CustomTokenPickerView with diff highlighting + auto-select"
```

---

## Task 2.7: ChatView wiring

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatView.swift`

Pass alias-miss state into ProposalCard, present the lazy-tag sheet.

- [ ] **Step 1: Update ProposalCard call site (~line 76)**

Replace:

```swift
                                        ForEach(proposals, id: \.token) { p in
                                            ProposalCard(
                                                proposal: p,
                                                onConfirm: { await viewModel.confirmProposal(p) },
                                                onSkip: { viewModel.skipProposal(p) }
                                            )
                                        }
```

With:

```swift
                                        ForEach(proposals, id: \.token) { p in
                                            ProposalCard(
                                                proposal: p,
                                                onConfirm: { await viewModel.confirmProposal(p) },
                                                onSkip: { viewModel.skipProposal(p) },
                                                aliasMissTarget: viewModel.aliasMissTarget(for: p),
                                                onTag: { viewModel.beginLazyTag(for: p) }
                                            )
                                        }
```

- [ ] **Step 2: Add the .sheet modifier**

At the bottom of ChatView's body chain (next to other modifiers like `.environmentObject` or `.onAppear`), attach:

```swift
        .sheet(item: $viewModel.activeLazyTagRequest) { req in
            CustomTokenPickerView(
                request: req,
                onSelect: { token, request in
                    viewModel.handleTagSelection(token: token, request: request)
                },
                onCancel: {
                    viewModel.cancelLazyTag()
                }
            )
        }
```

- [ ] **Step 3: Verify screenTimeManager is in environment**

```bash
grep -n "environmentObject(screenTimeManager\|@StateObject.*ScreenTimeManager\|@EnvironmentObject var screenTimeManager" "Evlin iOS/" -r | head -5
```

If injected at app root: nothing more to do. If not, attach `.environmentObject(screenTimeManager)` to the sheet content.

- [ ] **Step 4: Build verify**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | tee /tmp/build.log | grep -E "error:" | head -5; if grep -q "^.*error:" /tmp/build.log; then echo "BUILD FAILED"; else echo OK; fi
```

Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatView.swift"
git commit -m "feat(lazy-tag): ChatView wires alias-miss + presents lazy-tag sheet"
```

---

## Task 2.8: Manual E2E smoke test

**No code changes.** Verify the integrated flow on a real device with the deployed backend.

- [ ] **Step 1: Deploy backend** (if not auto-deployed by CI)

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
git push fred feat/three-tier-lock
# wait for Railway deploy, ~30s
```

- [ ] **Step 2: Install iOS build on device**

Xcode → Run on real iPhone.

- [ ] **Step 3: Test Tag-before-Confirm happy path**

In chat, type: `lock Instagram`
Expected: ProposalCard appears with orange "Evlin doesn't know which app is "Instagram" yet" warning + "Tag Instagram" button. Confirm grey/disabled.

Tap "Tag Instagram". Sheet opens titled "Tag app". List shows already-selected apps. Tap Instagram (or use "Add via Apple picker" → pick IG → close → row appears at top with "Just added" badge, auto-selected). Tap Save.

Sheet dismisses; card warning vanishes; Confirm enabled. Tap Confirm.

Expected: Receipt bubble + IG actually shielded on device. The `legacy_action.command_id` flow drives the existing ack-poll UI.

- [ ] **Step 4: Test repeat-hit (alias persisted)**

In chat, type: `lock instagram` (lowercase).
Expected: Card appears WITHOUT warning. Confirm directly active. Tap Confirm. Works.

- [ ] **Step 5: Test Add via Apple picker fallback**

In chat: `lock Snapchat` (assume not yet tagged + not in selection).
Tap Tag → sheet → list doesn't contain Snapchat → Tap "Open Apple picker" → pick Snapchat → close.
Expected: row appears at top with "Just added" badge, auto-selected. Tap Save.

- [ ] **Step 6: Test Cancel**

In chat: `lock TikTok`.
Card has miss. Tap Tag → sheet opens → tap Cancel.
Expected: sheet dismisses. Card STILL shows warning + Tag. Confirm STILL disabled. Retry possible.

- [ ] **Step 7: Test hard guard via observable error**

Trigger any miss state. In the chat input field, force a quick consecutive Confirm via fast-tapping (or use Xcode debugger to call `viewModel.confirmProposal(p)` directly with miss in `pendingAliasMisses`).
Expected: chat shows error message "Tap "Tag" first so I know which app you mean." No command dispatched.

- [ ] **Step 8: Test category flow**

In chat: `lock games`.
Card with miss. Tap Tag → sheet "Tag category" → list of category tokens (or empty + Apple picker fallback). Apple picker uses `includeEntireCategory: true` so tapping Games row produces a single ActivityCategoryToken.
Save → Confirm → Receipt.

- [ ] **Step 9: Test multi-target sweep**

In chat: `lock IG and TikTok`. Two ProposalCards appear, each with their own miss + Tag buttons. Tag IG normally. After save, the IG card unblocks; TikTok card unaffected (different target). Tag TikTok separately. Both confirm.

If parent says `lock Instagram and Insta` (both reference Instagram, two cards), tagging once should sweep both — verify the second card unblocks automatically after the first save.

- [ ] **Step 10: Smoke test backend Phase 0 path**

Use curl to verify the Proposal-first staging:

```bash
# Replace AUTH_HEADER + family_id with real values
curl -s -X POST https://your-backend/parent/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "lock Instagram", "child_name": "Liam", "family_id": "..."}' | jq
```

Expected: response has non-empty `proposals` array with `tool == "shield_app_legacy"`, NOT `action.command_id` directly. (If `action` is non-null with command_id, Phase 0 staging didn't fire — debug there.)

- [ ] **Step 11: No code commit** unless smoke test surfaced a fix.

---

# Self-Review

**Spec coverage:**
- Pre-flight detection ✓ Task 2.3
- Hard guard ✓ Task 1.2
- Tag callbacks ✓ Task 2.4
- ProposalCard miss UI ✓ Task 2.5
- CustomTokenPickerView with diff highlighting ✓ Task 2.6
- Category mode `includeEntireCategory: true` ✓ Task 2.6
- LazyTagPersistence type validation ✓ Task 2.2
- ChatView .sheet(item:) ✓ Task 2.7
- Backend Proposal staging ✓ Phase 0
- Legacy exec dispatcher forward ✓ Task 0.3
- iOS legacy exec response handling ✓ Task 1.1, 1.2
- Stale-miss sweep ✓ Task 2.4
- Skip clears miss ✓ Task 2.4

**Out of scope (per spec):**
- Std two-device alias sync — separate spec
- Multi-target merged tag wizard — future
- Tag editing/deletion UI — future

**Type consistency:**
- `AliasKind`: `.app` / `.category` everywhere
- `LazyTagRequest.id`: String (proposalToken)
- Tool name `shield_app_legacy` in extractAliasTarget matches the staging name in parent_chat.py Task 0.2 (`tool="shield_app_legacy"`)
- `LazyTagError.wrongTokenType` / `.emptyTarget` consistent between Task 2.2 impl + tests
- `AgentExecResult.receipt` / `.legacyAction` matches backend `ExecResponse.receipt` / `.legacy_action` field names (Swift snake-case decoding handled in DTO)

**R1 fixes incorporated:**
- Simulator name `iPhone 16e`
- Hard guard verification via observable `errorMessage` (no LLDB)
- `mergePickerIntoSelectedApps` only merges token sets (applicationTokens / categoryTokens / webDomainTokens). The `applications` / `categories` metadata arrays are get-only and cannot be merged — see Round-2 reviewer fixes below.

**R2 fixes incorporated:**
- Apple picker diff highlighting + auto-select on single addition (Task 2.6)
- Stale miss sweep on tag success + skipProposal clears miss (Task 2.4)
- `nonisolated static func extractAliasTarget` (Task 2.3)
- TokenPickerView (debug) deprecation note inline in CustomTokenPickerView header

**Round-2 reviewer fixes (post-v2 first draft):**
- `_is_lazy_tag_eligible` now matches `type == "shield"` only — removed `block`. Block uses bundle-id catalog lookup, doesn't benefit from lazy-tagged tokens.
- Backend class is `Proposal` (not `ProposalDTO`). Imported from `backend.app.schemas.agent`.
- `ChatRequest` / `ChatAction` / `ChatResponse` defined in `parent_chat.py` directly (no `schemas.chat` module). Imports done inside function bodies to avoid circular routing.
- `chat_context` only stores fields that exist on ChatRequest: `message`, `family_id`, `child_name`, `child_device_id`, `reasoning`. Removed nonexistent `child_id`, `protection_mode`, `parent_id`.
- Session dependency is `get_async_session` (from `backend.app.db.engine`), not `get_session`.
- `ExecResponse.legacy_action` typed as `dict[str, Any]` (serialized ChatAction) to avoid the cross-route import cycle. iOS still decodes into `APIClient.ChatActionResponse`.
- iOS uses `APIClient.ChatActionResponse` for the legacy action type — NOT `Models/ChatModels.swift::ChatAction` (the latter is an unrelated legacy enum).
- `confirmProposal` legacy path mirrors `processResponse`'s command_id handling exactly: append agent bubble, set `commandID` + `receiptState = .pending`, call `startAckPoll(...)`. Does NOT pass action through `ChatMessage.init(action:)`.
- Card-id branch on legacy path produces a clear errorMessage (v1 doesn't render dispatcher cards from /parent/agent/exec).
- Backend tests for `test_proposal_store.py` and `test_parent_agent_endpoints.py` updated for 3-tuple `pop()` and nested `.receipt` response shape (Task 0.3 Step 3).
- `merged.applications.formUnion` / `merged.categories.formUnion` removed — these are get-only computed properties on `FamilyActivitySelection`.
- ForEach offset-id risk noted; acceptable for sheet lifetime.

**Round-3 reviewer fixes (post-v3):**
- **chat_resolver E1 bypass (Task 0.4)**: `_route_shield`'s `kind == "app"` branch now checks `force_exact_app` flag. When true (set by `_exec_legacy_shield`), returns `ResolvedAction(tier="exactApp", target_display=target, ...)` instead of the E1 fallback card. Without this, lazy-tag confirm would still hit the E1 dead end and never queue an actual shield Command.
- **Duration gating (Task 0.2)**: `_is_lazy_tag_eligible` now also requires `duration_minutes` to be a positive int. Missing-duration shields fall through to eager dispatch (which returns D1 duration card). After parent picks duration, the next round of dispatch produces a shield_app with concrete duration → THIS round stages as lazy-tag → tag flow → exec → exactApp Command. D1 card flow stays in the existing card pipeline, never enters /parent/agent/exec.
- **Build verify commands fixed (P2)**: replaced broken `grep -E "error:" | head -10 && echo OK` pattern (which printed OK when build had errors and silent when it succeeded) with `tee /tmp/build.log; if grep -q "error:" then BUILD FAILED else OK`.
- **Self-review formUnion contradiction (P3)**: cleaned up.
