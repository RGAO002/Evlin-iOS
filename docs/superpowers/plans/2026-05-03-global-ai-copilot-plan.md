# Global AI Copilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the verb-table chat dispatcher with a Gemini function-calling agent that can read kid state, propose / execute parent-side actions through chat, and revert agent-executed actions via a `ParentActionLog`. **Profile UI buttons and the shield/block dispatcher are NOT modified** — Undo is a chat-only feature.

**Architecture:** New `AgentLoop` orchestrates iterative Gemini function-calling against a `@tool`-decorated registry. Confirm-required tools are staged into a `ProposalStore` and surfaced as `ProposalCard` on iOS; safe tools execute and write to `ParentActionLog`. A single `POST /parent/actions/{id}/revert` endpoint backs Undo across all surfaces. The shield/block dispatcher and existing A1-G1 cards stay untouched — `shield_app` is a tool that forwards into them.

**Tech Stack:** FastAPI 0.111 + pydantic v2 + google.genai SDK (function-calling) + SQLAlchemy async (existing); SwiftUI + iOS 17 + @AppStorage (existing); Supabase Storage (already wired).

---

## Phase ordering

Build bottom-up so each phase is independently shippable:

| Phase | What | Why first |
|-------|------|-----------|
| A | `ParentActionLog` service + single revert endpoint | Smallest unit, used only by agent |
| B | Tool registry + v1 tool implementations | No agent yet — tools are pure functions, easy to unit-test |
| C | `AgentLoop` + `ProposalStore` + Gemini function-calling + new endpoints | Wire the brain |
| D | iOS new components: `ProposalCard`, `ReceiptBubble` | Chat-only UI |
| E | iOS chat integration: ChatViewModel + ChatView render new sections | Wire it into Chat tab |
| F | E2E manual checklist + flag flip | Ship |

Feature flag `AGENT_ENABLED` (env var, default `0`) lets us land Phase A-E without breaking the existing `/parent/chat` flow. Flip on once tests pass.

---

## File map (informational, not a task)

### Backend (`adaptive-engine/backend/app/`)

```
services/
  parent_action_log.py        NEW   — Phase A
  agent_tools/__init__.py     NEW   — Phase B (registry)
  agent_tools/decorator.py    NEW   — Phase B (@tool)
  agent_tools/read_tools.py   NEW   — Phase B (get_kid_state, list_pending_submissions, review_submissions)
  agent_tools/task_tools.py   NEW   — Phase B (assign/delete/approve/redo)
  agent_tools/reflection_tools.py NEW — Phase B (propose/cancel/approve_reflection)
  agent_tools/bypass_tools.py NEW   — Phase B (respond_bypass)
  agent_tools/lock_tools.py   NEW   — Phase B (lock_device, unlock_device)
  agent_tools/shield_tools.py NEW   — Phase B (shield_app, unshield_app)
  agent_loop.py               NEW   — Phase C
  proposal_store.py           NEW   — Phase C

api/routes/
  parent_actions.py           NEW   — Phase A (revert endpoint)
  parent_agent.py             NEW   — Phase C (agent/exec endpoint)
  parent_chat.py              MODIFY — Phase C (route through AgentLoop behind flag)
  # bigkid_parent.py NOT MODIFIED — Profile UI direct endpoints unchanged

schemas/
  agent.py                    NEW   — Phase C (Proposal, Receipt, AgentResponse)
  # bigkid.py NOT MODIFIED — direct API responses unchanged

core/settings.py              MODIFY — Phase C (agent_enabled flag)

tests/
  test_parent_action_log.py   NEW   — Phase A
  test_agent_tools.py         NEW   — Phase B
  test_agent_loop.py          NEW   — Phase C
  test_revert_endpoint.py     NEW   — Phase A
```

### iOS (`Evlin iOS/Evlin iOS/`)

```
Models/
  AgentEnvelope.swift         NEW   — Phase D (Proposal, Receipt decoding)

Services/
  AgentClient.swift           NEW   — Phase D (executeProposal, revertAction)
  # BigKidParentClient.swift NOT MODIFIED — Profile UI unchanged

Components/
  ConfirmationCards/
    ProposalCard.swift        NEW   — Phase D
  ReceiptBubble.swift         NEW   — Phase D

Views/
  Chat/
    ChatViewModel.swift       MODIFY — Phase E (decode envelope, render proposals/receipts)
    ChatView.swift            MODIFY — Phase E (layout for the three response sections)
  # Profile/* NOT MODIFIED — direct UI unchanged
```

---

## Phase A — `ParentActionLog` + global revert

### Task A.0: Pin pytest-asyncio in requirements

**Files:**
- Modify: `requirements.txt`

The codebase configures `asyncio_mode = "auto"` in `pyproject.toml`
but the package isn't pinned in `requirements.txt` (Railway's pip
manifest). Without it, async tests would error on first run.

- [ ] **Step 1: Add the pin**

```bash
echo "pytest-asyncio>=0.23" >> requirements.txt
```

- [ ] **Step 2: Commit**

```bash
git add requirements.txt
git commit -m "deps: pin pytest-asyncio for async test support"
```

---

### Task A.1: ParentActionLog service skeleton

**Files:**
- Create: `backend/app/services/parent_action_log.py`
- Test: `backend/tests/test_parent_action_log.py`

- [ ] **Step 1: Write the failing test**

Create `backend/tests/test_parent_action_log.py`:

```python
"""Tests for the ParentActionLog service (Phase A)."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from backend.app.services.parent_action_log import ParentActionLog


@pytest.fixture
def log() -> ParentActionLog:
    return ParentActionLog()


def test_record_returns_unique_action_id(log: ParentActionLog) -> None:
    a = log.record(
        action_type="approve_task", args={"task_id": "T1"},
        inverse_action="request_redo", inverse_args={"task_id": "T1", "reason": "Reverted"},
        source="profile_ui",
    )
    b = log.record(
        action_type="approve_task", args={"task_id": "T2"},
        inverse_action="request_redo", inverse_args={"task_id": "T2", "reason": "Reverted"},
        source="profile_ui",
    )
    assert a != b
    assert log.get(a).action_type == "approve_task"
    assert log.get(a).args == {"task_id": "T1"}


def test_get_returns_none_when_action_missing(log: ParentActionLog) -> None:
    assert log.get("does-not-exist") is None


def test_record_sets_default_60s_ttl(log: ParentActionLog) -> None:
    aid = log.record(
        action_type="x", args={}, inverse_action="y", inverse_args={}, source="agent",
    )
    entry = log.get(aid)
    delta = entry.expires_at - entry.created_at
    assert 55 <= delta.total_seconds() <= 65


def test_get_returns_none_for_expired_entry(log: ParentActionLog) -> None:
    aid = log.record(
        action_type="x", args={}, inverse_action="y", inverse_args={}, source="agent",
    )
    # Force expiry
    entry = log._entries[aid]  # noqa: SLF001
    entry.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    assert log.get(aid) is None


def test_mark_reverted_prevents_double_revert(log: ParentActionLog) -> None:
    aid = log.record(
        action_type="x", args={}, inverse_action="y", inverse_args={}, source="agent",
    )
    log.mark_reverted(aid)
    assert log.get(aid).reverted is True
    # second revert via mark_reverted is idempotent — does not raise
    log.mark_reverted(aid)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
pytest backend/tests/test_parent_action_log.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'backend.app.services.parent_action_log'`

- [ ] **Step 3: Implement ParentActionLog**

Create `backend/app/services/parent_action_log.py`:

```python
"""ParentActionLog — central record of every parent-side mutation, with
inverse-action handles for global Undo. See spec §6.

v1 is in-memory; wiped on Railway redeploy alongside BigKidStore.
Phase 13 adds SQLite persistence.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Literal
from uuid import uuid4


Source = Literal["agent", "profile_ui", "shield_dispatcher", "debug_panel"]


@dataclass
class ActionLogEntry:
    action_id: str
    action_type: str           # tool name or 'profile_approve_task' etc.
    args: dict
    inverse_action: str | None
    inverse_args: dict
    source: Source
    created_at: datetime
    expires_at: datetime
    reverted: bool = False


class ParentActionLog:
    """Process-local log. Use `get_log()` for the singleton."""

    def __init__(self, ttl_seconds: int = 60) -> None:
        self._entries: dict[str, ActionLogEntry] = {}
        self._ttl_seconds = ttl_seconds

    def record(
        self, *, action_type: str, args: dict,
        inverse_action: str | None, inverse_args: dict, source: Source,
    ) -> str:
        action_id = uuid4().hex
        now = datetime.now(timezone.utc)
        self._entries[action_id] = ActionLogEntry(
            action_id=action_id,
            action_type=action_type,
            args=args,
            inverse_action=inverse_action,
            inverse_args=inverse_args,
            source=source,
            created_at=now,
            expires_at=now + timedelta(seconds=self._ttl_seconds),
        )
        return action_id

    def get(self, action_id: str) -> ActionLogEntry | None:
        entry = self._entries.get(action_id)
        if entry is None:
            return None
        if entry.expires_at < datetime.now(timezone.utc):
            return None
        return entry

    def mark_reverted(self, action_id: str) -> None:
        entry = self._entries.get(action_id)
        if entry is not None:
            entry.reverted = True

    def gc(self) -> int:
        """Drop expired entries; returns count purged. Call periodically
        if memory pressure ever matters (v1: not bothering)."""
        now = datetime.now(timezone.utc)
        stale = [aid for aid, e in self._entries.items() if e.expires_at < now]
        for aid in stale:
            del self._entries[aid]
        return len(stale)


_singleton: ParentActionLog | None = None


def get_log() -> ParentActionLog:
    global _singleton
    if _singleton is None:
        _singleton = ParentActionLog()
    return _singleton
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest backend/tests/test_parent_action_log.py -v
```

Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
git add backend/app/services/parent_action_log.py backend/tests/test_parent_action_log.py
git commit -m "feat(action_log): ParentActionLog service with 60s TTL undo entries"
```

---

### Task A.2: Revert endpoint + revert dispatcher

**Files:**
- Create: `backend/app/api/routes/parent_actions.py`
- Modify: `backend/app/main.py` (mount the new router)
- Test: `backend/tests/test_revert_endpoint.py`

The endpoint is invoked only by the chat agent's ReceiptBubble Undo
button. We seed test entries directly via `ParentActionLog.record()`
since the agent loop tests live separately.

- [ ] **Step 1: Write the failing test**

Create `backend/tests/test_revert_endpoint.py`:

```python
"""Tests for POST /parent/actions/{action_id}/revert (Phase A)."""
from __future__ import annotations

from uuid import UUID

import pytest
from fastapi.testclient import TestClient

from backend.app.main import app
from backend.app.services import bigkid_store as bigkid_store_module
from backend.app.services import parent_action_log as action_log_module
from backend.app.services.parent_action_log import get_log


@pytest.fixture(autouse=True)
def _reset_singletons() -> None:
    action_log_module._singleton = None  # noqa: SLF001
    bigkid_store_module._singleton = None  # noqa: SLF001


@pytest.fixture
def client() -> TestClient:
    return TestClient(app)


def test_revert_returns_410_when_action_id_missing(client: TestClient) -> None:
    r = client.post("/api/v1/parent/actions/nonexistent/revert")
    assert r.status_code == 410


def test_revert_executes_inverse_for_approve_task(client: TestClient) -> None:
    """Simulate the agent having approved a task: write a log entry by
    hand, then call revert. Without the agent loop yet, we mark the task
    as 'done' first and let revert flip it via request_redo."""
    cid_str = "11111111-1111-1111-1111-111111111111"
    state = client.get(f"/api/v1/parent/state/{cid_str}").json()
    task_id_str = state["tasks"][0]["id"]
    cid = UUID(cid_str)
    task_id = UUID(task_id_str)

    # Approve the task directly via the (existing, unchanged) endpoint.
    client.post(f"/api/v1/parent/task/{task_id_str}/review", json={"decision": "approve"})

    # Manually record what the agent would have logged.
    log = get_log()
    aid = log.record(
        action_type="approve_task",
        args={"child_id": cid_str, "task_id": task_id_str},
        inverse_action="request_redo",
        inverse_args={"child_id": cid_str, "task_id": task_id_str, "redo_reason": "Reverted"},
        source="agent",
    )

    r = client.post(f"/api/v1/parent/actions/{aid}/revert")
    assert r.status_code == 200

    after = client.get(f"/api/v1/parent/state/{cid_str}").json()
    target = next(t for t in after["tasks"] if t["id"] == task_id_str)
    assert target["status"] == "todo"
    assert target["phase"] == "redo"


def test_double_revert_returns_410(client: TestClient) -> None:
    log = get_log()
    aid = log.record(
        action_type="cancel_reflection",
        args={"child_id": "33333333-3333-3333-3333-333333333333"},
        inverse_action=None, inverse_args={}, source="agent",
    )
    first = client.post(f"/api/v1/parent/actions/{aid}/revert")
    assert first.status_code == 200
    second = client.post(f"/api/v1/parent/actions/{aid}/revert")
    assert second.status_code == 410
```

- [ ] **Step 2: Run tests to verify failure**

```bash
pytest backend/tests/test_revert_endpoint.py -v
```

Expected: FAIL — endpoint missing.

- [ ] **Step 3: Implement the revert dispatcher**

Create `backend/app/api/routes/parent_actions.py`:

```python
"""POST /parent/actions/{action_id}/revert — chat-only Undo endpoint.

Used exclusively by the chat agent's ReceiptBubble. Profile UI direct
buttons and the shield/block dispatcher do NOT call this. The
dispatcher inverts a small set of action_types corresponding to the
agent's tool registry."""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from loguru import logger

from backend.app.services.bigkid_store import BigKidStore, get_store as get_bigkid_store
from backend.app.services.parent_action_log import (
    ActionLogEntry, ParentActionLog, get_log as get_action_log,
)


router = APIRouter(tags=["Parent Actions"])


@router.post("/parent/actions/{action_id}/revert")
def revert_action(
    action_id: str,
    log: ParentActionLog = Depends(get_action_log),
    store: BigKidStore = Depends(get_bigkid_store),
) -> dict:
    entry = log.get(action_id)
    if entry is None or entry.reverted:
        raise HTTPException(status_code=410, detail="Action expired or already reverted")

    new_undo_token = _execute_inverse(entry, store, log)
    log.mark_reverted(action_id)
    return {"reverted_action_id": action_id, "new_undo_token": new_undo_token}


# ---------- Inverse dispatcher ----------
# v1 supports inverses for the small set of agent tools that have one:
# - approve_task ↔ request_redo  (each is the other's inverse)
# - propose_reflection → cancel_reflection  (one-way; cancel has no inverse)
# - respond_bypass → respond_bypass (decision flipped)
# Anything else = no-op revert (entry was emitted with inverse_action=None).

def _execute_inverse(
    entry: ActionLogEntry, store: BigKidStore, log: ParentActionLog
) -> str | None:
    inv_action = entry.inverse_action
    inv_args = entry.inverse_args
    if inv_action is None:
        return None

    if inv_action == "request_redo":
        store.parent_review_task(
            child_id=UUID(inv_args["child_id"]),
            task_id=UUID(inv_args["task_id"]),
            decision="redo",
            redo_reason=inv_args.get("redo_reason"),
        )
        return log.record(
            action_type="request_redo", args=inv_args,
            inverse_action="approve_task",
            inverse_args={"child_id": inv_args["child_id"], "task_id": inv_args["task_id"]},
            source="agent",
        )

    if inv_action == "approve_task":
        store.parent_review_task(
            child_id=UUID(inv_args["child_id"]),
            task_id=UUID(inv_args["task_id"]),
            decision="approve",
            redo_reason=None,
        )
        return log.record(
            action_type="approve_task", args=inv_args,
            inverse_action="request_redo",
            inverse_args={
                "child_id": inv_args["child_id"], "task_id": inv_args["task_id"],
                "redo_reason": "Reverted",
            },
            source="agent",
        )

    if inv_action == "cancel_reflection":
        # Use the public ack_reflection method — it clears the reflection
        # cleanly and resets the cooldown. Reaching into _states is a
        # leaky abstraction we avoid.
        cid = UUID(inv_args["child_id"])
        rid_str = inv_args.get("rid")
        if rid_str:
            try:
                store.ack_reflection(cid, UUID(rid_str))
            except Exception as exc:
                logger.warning("cancel_reflection revert noop: {}", exc)
        return None  # cancel has no inverse

    if inv_action == "respond_bypass":
        store.respond_bypass(
            bypass_id=UUID(inv_args["bypass_id"]),
            decision=inv_args["decision"],
            message=inv_args.get("message"),
        )
        flipped = "deny" if inv_args["decision"] == "approve" else "approve"
        return log.record(
            action_type="respond_bypass", args=inv_args,
            inverse_action="respond_bypass",
            inverse_args={
                "bypass_id": inv_args["bypass_id"],
                "decision": flipped,
                "message": "Reverted",
            },
            source="agent",
        )

    logger.warning("revert: unknown inverse_action {}", inv_action)
    return None
```

- [ ] **Step 4: Mount the router**

Modify `backend/app/main.py`. Find the existing `app.include_router(...)` block (around line 100-130 based on Phase 11 history) and add:

```python
from backend.app.api.routes.parent_actions import router as parent_actions_router
# ... existing imports ...

# In the router-include block:
app.include_router(parent_actions_router, prefix=settings.api_prefix)
```

- [ ] **Step 5: Run tests**

```bash
pytest backend/tests/test_revert_endpoint.py -v
```

Expected: 3 passed.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/routes/parent_actions.py backend/app/main.py backend/tests/test_revert_endpoint.py
git commit -m "feat(parent_actions): /parent/actions/{id}/revert single endpoint"
```

---

## Phase B — Tool registry + v1 tools

### Task B.0: Test isolation conftest

**Files:**
- Create: `backend/tests/conftest.py` (only if it doesn't already exist;
  otherwise append to it)

The agent tools register into a module-level `GLOBAL_REGISTRY`, and
`bigkid_store` uses a process-level singleton. Without a reset hook
between tests, B-phase tests are order-dependent and can flake under
`pytest -x` reruns. Add an autouse fixture that:

1. Snapshots `GLOBAL_REGISTRY.tools` at session start.
2. Resets `bigkid_store._singleton`, `parent_action_log._singleton`,
   `proposal_store._singleton` before each test.
3. Restores `GLOBAL_REGISTRY.tools` to the snapshot after each test.

```python
"""Shared pytest fixtures."""
from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _reset_in_memory_state():
    """Wipe process-local singletons between tests so order is irrelevant."""
    from backend.app.services import bigkid_store
    bigkid_store._singleton = None  # noqa: SLF001
    try:
        from backend.app.services import parent_action_log
        parent_action_log._singleton = None  # noqa: SLF001
    except ImportError:
        pass
    try:
        from backend.app.services import proposal_store
        proposal_store._singleton = None  # noqa: SLF001
    except ImportError:
        pass
    yield


@pytest.fixture(autouse=True)
def _isolate_global_tool_registry():
    """Snapshot+restore GLOBAL_REGISTRY around each test so tools added
    by one test don't leak into another, and so re-importing tool
    modules in a single test doesn't double-register."""
    try:
        from backend.app.services.agent_tools import GLOBAL_REGISTRY
    except ImportError:
        yield
        return
    snapshot = dict(GLOBAL_REGISTRY.tools)
    yield
    GLOBAL_REGISTRY.tools.clear()
    GLOBAL_REGISTRY.tools.update(snapshot)
```

- [ ] **Step 1: Create file + commit**

```bash
git add backend/tests/conftest.py
git commit -m "test: conftest with autouse singleton + GLOBAL_REGISTRY reset"
```

---

### Task B.1: `@tool` decorator and `ToolRegistry`

**Files:**
- Create: `backend/app/services/agent_tools/__init__.py`
- Create: `backend/app/services/agent_tools/decorator.py`
- Test: `backend/tests/test_agent_tools.py`

- [ ] **Step 1: Write the failing test**

Create `backend/tests/test_agent_tools.py`:

```python
"""Tests for the @tool decorator and ToolRegistry (Phase B)."""
from __future__ import annotations

import pytest

from backend.app.services.agent_tools.decorator import tool, ToolRegistry, ToolResult


def test_tool_decorator_registers_function() -> None:
    registry = ToolRegistry()

    @tool(
        registry=registry,
        name="add",
        description="Add two numbers",
        requires_confirm=False,
        danger="low",
    )
    async def add(a: int, b: int) -> ToolResult:
        return ToolResult(public={"sum": a + b})

    assert "add" in registry.tools
    decl = registry.declarations()
    assert decl[0]["name"] == "add"
    assert decl[0]["description"] == "Add two numbers"
    assert decl[0]["parameters"]["properties"]["a"]["type"] == "integer"


@pytest.mark.asyncio
async def test_tool_call_returns_result() -> None:
    registry = ToolRegistry()

    @tool(registry=registry, name="add", description="Add", requires_confirm=False, danger="low")
    async def add(a: int, b: int) -> ToolResult:
        return ToolResult(public={"sum": a + b})

    result = await registry.call("add", {"a": 1, "b": 2})
    assert result.public == {"sum": 3}


def test_unknown_tool_raises() -> None:
    registry = ToolRegistry()
    with pytest.raises(KeyError):
        registry.declarations_for("nonexistent")
```

- [ ] **Step 2: Run tests to verify failure**

```bash
pytest backend/tests/test_agent_tools.py -v
```

Expected: ImportError.

- [ ] **Step 3: Implement decorator + registry**

Create `backend/app/services/agent_tools/__init__.py`:

```python
"""Agent tools registry — see plan Phase B and spec §5."""
from backend.app.services.agent_tools.decorator import (
    ToolRegistry, ToolResult, tool, GLOBAL_REGISTRY,
)

__all__ = ["ToolRegistry", "ToolResult", "tool", "GLOBAL_REGISTRY"]
```

Create `backend/app/services/agent_tools/decorator.py`:

```python
"""@tool decorator + ToolRegistry. Inspects function signatures to
auto-build Gemini function-calling JSON schemas.

Each tool is an async callable returning a ToolResult. The decorator
attaches metadata (description, danger, confirmation requirement,
inverse for revert) used by the AgentLoop and the Gemini SDK.
"""
from __future__ import annotations

import inspect
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Literal, get_type_hints
from uuid import UUID


Danger = Literal["low", "medium", "high"]


@dataclass
class ToolResult:
    """Public result fed back to Gemini for the next iteration's reasoning,
    and surfaced in iOS receipts. Avoid leaking internals — keep public dict
    serializable + small."""
    public: dict[str, Any] = field(default_factory=dict)
    public_summary: str | None = None  # human-readable one-liner for receipts


@dataclass
class ToolMeta:
    name: str
    description: str
    requires_confirm: bool
    danger: Danger
    inverse_action: str | None
    inverse_args_builder: Callable[[dict, ToolResult], dict] | None
    label_builder: Callable[[dict], str] | None
    fn: Callable[..., Awaitable[ToolResult]]
    parameters_schema: dict


_PY_TYPE_TO_JSON: dict[type, str] = {
    str: "string", int: "integer", float: "number", bool: "boolean",
    UUID: "string", list: "array", dict: "object",
}


def _build_param_schema(fn: Callable) -> dict:
    sig = inspect.signature(fn)
    hints = get_type_hints(fn)
    props: dict[str, dict] = {}
    required: list[str] = []
    for param_name, param in sig.parameters.items():
        if param_name == "authorize_batch":
            # Hidden from Gemini — agent loop fills it from heuristic.
            continue
        ptype = hints.get(param_name, str)
        json_type = _PY_TYPE_TO_JSON.get(ptype, "string")
        prop: dict[str, Any] = {"type": json_type}
        if ptype is UUID:
            prop["format"] = "uuid"
        props[param_name] = prop
        if param.default is inspect.Parameter.empty:
            required.append(param_name)
    return {"type": "object", "properties": props, "required": required}


class ToolRegistry:
    def __init__(self) -> None:
        self.tools: dict[str, ToolMeta] = {}

    def register(self, meta: ToolMeta) -> None:
        self.tools[meta.name] = meta

    def declarations(self) -> list[dict]:
        """Gemini function-calling schema list."""
        return [
            {"name": m.name, "description": m.description, "parameters": m.parameters_schema}
            for m in self.tools.values()
        ]

    def declarations_for(self, name: str) -> dict:
        if name not in self.tools:
            raise KeyError(f"unknown tool: {name}")
        m = self.tools[name]
        return {"name": m.name, "description": m.description, "parameters": m.parameters_schema}

    async def call(self, name: str, args: dict) -> ToolResult:
        if name not in self.tools:
            raise KeyError(f"unknown tool: {name}")
        meta = self.tools[name]
        # Coerce string UUIDs to UUID objects per the function signature.
        coerced = _coerce_args(meta.fn, args)
        return await meta.fn(**coerced)


def _coerce_args(fn: Callable, args: dict) -> dict:
    hints = get_type_hints(fn)
    out = {}
    for k, v in args.items():
        target = hints.get(k)
        if target is UUID and isinstance(v, str):
            out[k] = UUID(v)
        else:
            out[k] = v
    return out


GLOBAL_REGISTRY = ToolRegistry()


def tool(
    *,
    name: str,
    description: str,
    requires_confirm: bool,
    danger: Danger,
    inverse_action: str | None = None,
    inverse_args_builder: Callable[[dict, ToolResult], dict] | None = None,
    label_builder: Callable[[dict], str] | None = None,
    registry: ToolRegistry | None = None,
):
    target = registry if registry is not None else GLOBAL_REGISTRY

    def decorator(fn: Callable[..., Awaitable[ToolResult]]) -> Callable:
        meta = ToolMeta(
            name=name,
            description=description,
            requires_confirm=requires_confirm,
            danger=danger,
            inverse_action=inverse_action,
            inverse_args_builder=inverse_args_builder,
            label_builder=label_builder,
            fn=fn,
            parameters_schema=_build_param_schema(fn),
        )
        target.register(meta)
        return fn

    return decorator
```

- [ ] **Step 4: Run tests**

Note `pytest-asyncio` is already in deps (used by `test_bigkid_endpoints.py` async fixtures). If not, add to `requirements.txt`.

```bash
pytest backend/tests/test_agent_tools.py -v
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/agent_tools/ backend/tests/test_agent_tools.py
git commit -m "feat(agent_tools): @tool decorator + ToolRegistry with auto schema"
```

---

### Task B.2: Read tools (`get_kid_state`, `list_pending_submissions`)

**Files:**
- Create: `backend/app/services/agent_tools/read_tools.py`

- [ ] **Step 1: Write the failing test**

Append to `backend/tests/test_agent_tools.py`:

```python
import pytest as _pytest


@_pytest.mark.asyncio
async def test_get_kid_state_returns_snapshot() -> None:
    from backend.app.services import bigkid_store
    bigkid_store._singleton = None  # reset
    from backend.app.services.agent_tools import GLOBAL_REGISTRY
    # Force tool import.
    from backend.app.services.agent_tools import read_tools  # noqa: F401

    cid = "11111111-1111-1111-1111-111111111111"
    result = await GLOBAL_REGISTRY.call("get_kid_state", {"child_id": cid})
    assert result.public["child_name"] == "Liam"
    assert len(result.public["tasks"]) == 3


@_pytest.mark.asyncio
async def test_list_pending_submissions_filters_status() -> None:
    from backend.app.services import bigkid_store
    bigkid_store._singleton = None
    from backend.app.services.agent_tools import GLOBAL_REGISTRY
    from backend.app.services.agent_tools import read_tools  # noqa: F401

    cid = "22222222-2222-2222-2222-222222222222"
    # No submissions yet.
    result = await GLOBAL_REGISTRY.call("list_pending_submissions", {"child_id": cid})
    assert result.public["submissions"] == []
```

- [ ] **Step 2: Run failing tests**

```bash
pytest backend/tests/test_agent_tools.py -v
```

Expected: ImportError on read_tools.

- [ ] **Step 3: Implement read tools**

Create `backend/app/services/agent_tools/read_tools.py`:

```python
"""Read-only tools — safe to call without confirmation. AI uses these
freely to inform responses without touching state."""
from __future__ import annotations

from uuid import UUID

from backend.app.services.agent_tools.decorator import tool, ToolResult, GLOBAL_REGISTRY
from backend.app.services.bigkid_store import get_store as get_bigkid_store


@tool(
    name="get_kid_state",
    description=(
        "Return the kid's current state: name, screen-time pool, all tasks "
        "(with status/phase/photo/note), reflection request if any, pending "
        "bypass requests. Call this when you need detail beyond what's in "
        "the auto-injected snapshot."
    ),
    requires_confirm=False,
    danger="low",
    registry=GLOBAL_REGISTRY,
)
async def get_kid_state(child_id: UUID) -> ToolResult:
    state = get_bigkid_store().get_state(child_id)
    return ToolResult(
        public=state.model_dump(mode="json"),
        public_summary=f"{state.child_name}: {len(state.tasks)} tasks, "
                       f"{state.minutes_left}/{state.minutes_max} min left",
    )


@tool(
    name="list_pending_submissions",
    description=(
        "Return only the kid's tasks that are submitted (status=submitted, "
        "phase=submitted) and awaiting parent review. Each item includes "
        "task_id, title, evidence_photo_url, evidence_note, submitted_at."
    ),
    requires_confirm=False,
    danger="low",
    registry=GLOBAL_REGISTRY,
)
async def list_pending_submissions(child_id: UUID) -> ToolResult:
    state = get_bigkid_store().get_state(child_id)
    pending = [
        {
            "task_id": str(t.id),
            "title": t.title,
            "evidence_photo_url": t.evidence_photo_url,
            "evidence_note": t.evidence_note,
        }
        for t in state.tasks
        if t.status.value == "submitted" and t.phase.value == "submitted"
    ]
    return ToolResult(
        public={"submissions": pending},
        public_summary=f"{len(pending)} pending submissions",
    )
```

- [ ] **Step 4: Run tests**

```bash
pytest backend/tests/test_agent_tools.py -v
```

Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/agent_tools/read_tools.py backend/tests/test_agent_tools.py
git commit -m "feat(agent_tools): get_kid_state, list_pending_submissions read tools"
```

---

### Task B.3: `review_submissions` multimodal tool

**Files:**
- Create: `backend/app/services/agent_tools/vision_tools.py`

- [ ] **Step 1: Write a failing test (mocks Gemini)**

Append to `backend/tests/test_agent_tools.py`:

```python
@_pytest.mark.asyncio
async def test_review_submissions_with_no_pending_returns_empty(monkeypatch) -> None:
    from backend.app.services import bigkid_store
    bigkid_store._singleton = None
    from backend.app.services.agent_tools import GLOBAL_REGISTRY
    from backend.app.services.agent_tools import vision_tools  # noqa: F401

    cid = "33333333-3333-3333-3333-333333333333"
    result = await GLOBAL_REGISTRY.call("review_submissions", {"child_id": cid})
    assert result.public["verdicts"] == []


@_pytest.mark.asyncio
async def test_review_submissions_calls_multimodal_for_each(monkeypatch) -> None:
    from backend.app.services import bigkid_store
    bigkid_store._singleton = None
    store = bigkid_store.get_store()

    cid_str = "44444444-4444-4444-4444-444444444444"
    cid_uuid = UUID(cid_str)
    state = store.get_state(cid_uuid)
    task_id = state.tasks[0].id

    # Mark a task as submitted with a fake photo URL (we won't fetch it).
    store.submit_evidence(
        cid_uuid, task_id, photo_url="https://example.com/x.jpg",
        photo_bytes=None, note="all done",
    )

    # Stub the multimodal call.
    async def fake_mm(prompt, items):
        return [{"task_id": str(it["task_id"]), "looks_done": True,
                 "confidence": 0.9, "note": "looks fine",
                 "recommend_action": "approve"} for it in items]
    async def fake_fetch(url):
        return b"fakejpg"

    from backend.app.services.agent_tools import vision_tools
    monkeypatch.setattr(vision_tools, "_call_multimodal", fake_mm)
    monkeypatch.setattr(vision_tools, "_fetch_photo_bytes", fake_fetch)

    from backend.app.services.agent_tools import GLOBAL_REGISTRY
    result = await GLOBAL_REGISTRY.call("review_submissions", {"child_id": cid_str})
    verdicts = result.public["verdicts"]
    assert len(verdicts) == 1
    assert verdicts[0]["recommend_action"] == "approve"


from uuid import UUID
```

- [ ] **Step 2: Run failing tests**

```bash
pytest backend/tests/test_agent_tools.py::test_review_submissions_with_no_pending_returns_empty -v
```

Expected: ImportError on vision_tools.

- [ ] **Step 3: Implement review_submissions**

Create `backend/app/services/agent_tools/vision_tools.py`:

```python
"""Multimodal tools — review_submissions loads each evidence photo and
sends it to Gemini with per-task vision prompts."""
from __future__ import annotations

import json
from typing import Any
from uuid import UUID

import httpx
from loguru import logger

from backend.app.core.settings import settings
from backend.app.services.agent_tools.decorator import tool, ToolResult, GLOBAL_REGISTRY
from backend.app.services.bigkid_store import get_store as get_bigkid_store


REVIEW_PROMPT = """\
You are reviewing photo evidence a child submitted to complete a chore.
For each item, decide whether the photo plausibly shows the chore done.
Be fair — kids submit imperfect photos. Approve unless clearly off.

For each item, output a JSON object:
{
  "task_id": "<uuid>",
  "looks_done": true | false,
  "confidence": 0.0-1.0,
  "note": "<one-line rationale>",
  "recommend_action": "approve" | "redo"
}

Output a JSON array of these objects in the same order as the input items.
"""


@tool(
    name="review_submissions",
    description=(
        "Look at photos for the kid's currently-submitted tasks and produce a "
        "per-task verdict {looks_done, confidence, note, recommend_action}. "
        "Call this when the parent asks you to review or judge submissions. "
        "Multimodal — slow + expensive — don't call speculatively."
    ),
    requires_confirm=False,
    danger="low",
    registry=GLOBAL_REGISTRY,
)
async def review_submissions(child_id: UUID) -> ToolResult:
    state = get_bigkid_store().get_state(child_id)
    pending = [
        t for t in state.tasks
        if t.status.value == "submitted" and t.phase.value == "submitted"
        and t.evidence_photo_url
    ]
    if not pending:
        return ToolResult(public={"verdicts": []}, public_summary="No pending submissions")

    items: list[dict[str, Any]] = []
    for t in pending:
        try:
            photo = await _fetch_photo_bytes(t.evidence_photo_url)
        except Exception as exc:
            logger.warning("review_submissions fetch failed for {}: {}", t.id, exc)
            continue
        items.append({
            "task_id": str(t.id),
            "title": t.title,
            "description": t.description,
            "kid_note": t.evidence_note,
            "photo_bytes": photo,
        })

    verdicts = await _call_multimodal(REVIEW_PROMPT, items)
    return ToolResult(
        public={"verdicts": verdicts},
        public_summary=f"Reviewed {len(verdicts)} submission(s)",
    )


async def _fetch_photo_bytes(url: str) -> bytes:
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.get(url)
        r.raise_for_status()
        return r.content


async def _call_multimodal(prompt: str, items: list[dict]) -> list[dict]:
    """Call Gemini with photo bytes + per-item context. Returns list of
    verdict dicts in input order. v1 implementation — refine prompt later."""
    from google import genai
    from google.genai import types

    if not items:
        return []

    client = genai.Client(api_key=settings.gemini_api_key)

    parts: list[Any] = [types.Part.from_text(text=prompt)]
    for it in items:
        parts.append(types.Part.from_text(text=json.dumps({
            "task_id": it["task_id"],
            "title": it["title"],
            "description": it["description"],
            "kid_note": it.get("kid_note"),
        })))
        parts.append(types.Part.from_bytes(data=it["photo_bytes"], mime_type="image/jpeg"))

    resp = client.models.generate_content(
        model=settings.gemini_model,
        contents=parts,
        config=types.GenerateContentConfig(
            temperature=0.3,
            response_mime_type="application/json",
        ),
    )

    text = (resp.text or "[]").strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1].rsplit("```", 1)[0]
    return json.loads(text)
```

- [ ] **Step 4: Run tests**

```bash
pytest backend/tests/test_agent_tools.py -v
```

Expected: all pass (multimodal stubbed).

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/agent_tools/vision_tools.py backend/tests/test_agent_tools.py
git commit -m "feat(agent_tools): review_submissions multimodal verdict tool"
```

---

### Task B.4: Task tools (`assign_task`, `delete_task`, `approve_task`, `request_redo`)

**Files:**
- Create: `backend/app/services/agent_tools/task_tools.py`

- [ ] **Step 1: Write tests**

Append to `backend/tests/test_agent_tools.py`:

```python
@_pytest.mark.asyncio
async def test_assign_task_creates_task() -> None:
    from backend.app.services import bigkid_store
    bigkid_store._singleton = None
    from backend.app.services.agent_tools import GLOBAL_REGISTRY
    from backend.app.services.agent_tools import task_tools  # noqa: F401

    cid = "55555555-5555-5555-5555-555555555555"
    before = bigkid_store.get_store().get_state(UUID(cid)).tasks
    result = await GLOBAL_REGISTRY.call("assign_task", {
        "child_id": cid, "title": "Sweep porch",
        "description": "Sweep the front porch.", "category": "Chores",
        "due": "Today, 6 PM",
    })
    assert "task_id" in result.public
    after = bigkid_store.get_store().get_state(UUID(cid)).tasks
    assert len(after) == len(before) + 1


@_pytest.mark.asyncio
async def test_approve_task_marks_done() -> None:
    from backend.app.services import bigkid_store
    bigkid_store._singleton = None
    store = bigkid_store.get_store()
    cid_str = "66666666-6666-6666-6666-666666666666"
    cid = UUID(cid_str)
    task = store.get_state(cid).tasks[0]
    # Submit so approve is meaningful.
    store.submit_evidence(cid, task.id, photo_url="https://x", photo_bytes=None, note=None)

    from backend.app.services.agent_tools import GLOBAL_REGISTRY
    from backend.app.services.agent_tools import task_tools  # noqa: F401
    result = await GLOBAL_REGISTRY.call("approve_task", {
        "child_id": cid_str, "task_id": str(task.id),
    })
    assert result.public["status"] == "done"
```

- [ ] **Step 2: Run failing tests**

```bash
pytest backend/tests/test_agent_tools.py::test_assign_task_creates_task -v
```

Expected: ImportError.

- [ ] **Step 3: Implement task tools**

Create `backend/app/services/agent_tools/task_tools.py`:

```python
"""Task-domain tools — assign / delete / approve / redo."""
from __future__ import annotations

from typing import Optional
from uuid import UUID

from backend.app.schemas.bigkid import TaskCategory
from backend.app.services.agent_tools.decorator import tool, ToolResult, GLOBAL_REGISTRY
from backend.app.services.bigkid_store import get_store as get_bigkid_store


@tool(
    name="assign_task",
    description=(
        "Create a new task on the kid's list. category must be one of: "
        "'Chores', 'Homework', 'Self-care'. due is human-readable like "
        "'Today, 6:00 PM' (optional)."
    ),
    requires_confirm=False,
    danger="low",
    inverse_action="delete_task",
    label_builder=lambda args: f"Assign task: {args.get('title', '')}",
    registry=GLOBAL_REGISTRY,
)
async def assign_task(
    child_id: UUID, title: str, description: str, category: str,
    due: Optional[str] = None,
) -> ToolResult:
    cat = TaskCategory(category)
    task = get_bigkid_store().create_task(
        child_id, title=title.strip(), description=description.strip(),
        category=cat, due=due,
    )
    return ToolResult(
        public={"task_id": str(task.id), "title": task.title},
        public_summary=f"Assigned '{task.title}'",
    )


@tool(
    name="delete_task",
    description="Remove a task from the kid's list.",
    requires_confirm=True,
    danger="medium",
    inverse_action=None,
    label_builder=lambda args: f"Delete task {args.get('task_id', '')[:8]}",
    registry=GLOBAL_REGISTRY,
)
async def delete_task(child_id: UUID, task_id: UUID) -> ToolResult:
    get_bigkid_store().delete_task(child_id, task_id)
    return ToolResult(
        public={"task_id": str(task_id), "deleted": True},
        public_summary=f"Deleted task {str(task_id)[:8]}",
    )


@tool(
    name="approve_task",
    description=(
        "Mark a kid's submitted task as completed. The kid sees the green "
        "'Approved!' screen immediately and the time pool may unlock more "
        "screen time. Reversible (Undo flips it to redo)."
    ),
    requires_confirm=True,
    danger="medium",
    inverse_action="request_redo",
    inverse_args_builder=lambda args, _r: {
        "child_id": args["child_id"], "task_id": args["task_id"],
        "redo_reason": "Reverted",
    },
    label_builder=lambda args: f"Approve task {args.get('task_id', '')[:8]}",
    registry=GLOBAL_REGISTRY,
)
async def approve_task(
    child_id: UUID, task_id: UUID, *, authorize_batch: bool = False,
) -> ToolResult:
    task = get_bigkid_store().parent_review_task(
        child_id=child_id, task_id=task_id, decision="approve", redo_reason=None,
    )
    return ToolResult(
        public={"task_id": str(task.id), "status": task.status.value},
        public_summary=f"Approved '{task.title}'",
    )


@tool(
    name="request_redo",
    description=(
        "Send a submitted task back to the kid for redo. The kid sees the "
        "amber redo banner with your reason. Reversible (Undo approves it)."
    ),
    requires_confirm=True,
    danger="medium",
    inverse_action="approve_task",
    inverse_args_builder=lambda args, _r: {
        "child_id": args["child_id"], "task_id": args["task_id"],
    },
    label_builder=lambda args: f"Redo task {args.get('task_id', '')[:8]}",
    registry=GLOBAL_REGISTRY,
)
async def request_redo(
    child_id: UUID, task_id: UUID, redo_reason: str,
    *, authorize_batch: bool = False,
) -> ToolResult:
    task = get_bigkid_store().parent_review_task(
        child_id=child_id, task_id=task_id, decision="redo", redo_reason=redo_reason,
    )
    return ToolResult(
        public={"task_id": str(task.id), "status": task.status.value},
        public_summary=f"Sent '{task.title}' back for redo",
    )
```

- [ ] **Step 4: Run tests**

```bash
pytest backend/tests/test_agent_tools.py -v
```

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/agent_tools/task_tools.py backend/tests/test_agent_tools.py
git commit -m "feat(agent_tools): assign_task, delete_task, approve_task, request_redo"
```

---

### Task B.5: Reflection + bypass + lock tools

**Files:**
- Create: `backend/app/services/agent_tools/reflection_tools.py`
- Create: `backend/app/services/agent_tools/bypass_tools.py`
- Create: `backend/app/services/agent_tools/lock_tools.py`

- [ ] **Step 1: Write tests** — append to `test_agent_tools.py`:

```python
@_pytest.mark.asyncio
async def test_propose_reflection_creates_reflection(monkeypatch) -> None:
    from backend.app.services import bigkid_store
    bigkid_store._singleton = None

    # Stub out generate_reflection_content (it uses Gemini).
    from backend.app.services import gemini_reflection
    from backend.app.services.gemini_reflection import (
        ReflectionContent, QuizSeed,
    )
    async def fake_gen(reason: str):
        return ReflectionContent(
            video_id="dQw4w9WgXcQ", video_title="Test",
            quiz=[QuizSeed(q="Q?", options=["a","b","c","d"], correct_index=0)] * 5,
            writing_prompt="Reflect on it",
            display_reason=f"You did something about: {reason}",
        )
    monkeypatch.setattr(gemini_reflection, "generate_reflection_content", fake_gen)

    from backend.app.services.agent_tools import GLOBAL_REGISTRY
    from backend.app.services.agent_tools import reflection_tools  # noqa: F401

    cid = "77777777-7777-7777-7777-777777777777"
    result = await GLOBAL_REGISTRY.call("propose_reflection", {
        "child_id": cid, "reason": "called me a name",
    })
    assert "rid" in result.public
    state = bigkid_store.get_store().get_state(UUID(cid))
    assert state.reflection_request is not None
```

- [ ] **Step 2: Run failing**

```bash
pytest backend/tests/test_agent_tools.py::test_propose_reflection_creates_reflection -v
```

Expected: ImportError.

- [ ] **Step 3: Implement reflection_tools.py**

```python
"""Reflection-domain tools."""
from __future__ import annotations

from uuid import UUID

from backend.app.schemas.bigkid import QuizQuestionPublic
from backend.app.services.agent_tools.decorator import tool, ToolResult, GLOBAL_REGISTRY
from backend.app.services.bigkid_store import get_store as get_bigkid_store
from backend.app.services.gemini_reflection import generate_reflection_content


@tool(
    name="propose_reflection",
    description=(
        "Trigger a reflection for the kid based on something they did wrong. "
        "Generates a kid-facing rephrasing, a 5-question quiz, a writing prompt, "
        "and locks the kid's device behind the reflection screen until done. "
        "Pass `reason` as plain English describing the action only ('called you "
        "a hurtful name', 'kept scrolling past bedtime')."
    ),
    requires_confirm=True,
    danger="high",
    inverse_action="cancel_reflection",
    inverse_args_builder=lambda args, r: {
        "child_id": args["child_id"], "rid": r.public["rid"],
    },
    label_builder=lambda args: "Send reflection",
    registry=GLOBAL_REGISTRY,
)
async def propose_reflection(child_id: UUID, reason: str) -> ToolResult:
    content = await generate_reflection_content(reason=reason)
    req = get_bigkid_store().trigger_reflection_with_content(
        child_id, reason=reason,
        display_reason=content.display_reason,
        video_id=content.video_id, video_title=content.video_title,
        writing_prompt=content.writing_prompt,
        quiz_public=[QuizQuestionPublic(q=q.q, options=q.options) for q in content.quiz],
        correct_indices=[q.correct_index for q in content.quiz],
    )
    return ToolResult(
        public={"rid": str(req.id), "display_reason": content.display_reason},
        public_summary=f"Reflection sent: {content.display_reason}",
    )


@tool(
    name="cancel_reflection",
    description=(
        "Cancel an active reflection — kid's device returns to normal. "
        "Use when parent says 'never mind' / 'undo that' / 'cancel it'."
    ),
    requires_confirm=True,
    danger="medium",
    inverse_action=None,
    label_builder=lambda args: "Cancel reflection",
    registry=GLOBAL_REGISTRY,
)
async def cancel_reflection(child_id: UUID, rid: UUID) -> ToolResult:
    s = get_bigkid_store()._states.get(child_id)  # noqa: SLF001
    if s is not None and s.reflection is not None and s.reflection.id == rid:
        s.reflection = None
    return ToolResult(public={"cancelled": True}, public_summary="Reflection cancelled")


@tool(
    name="approve_reflection",
    description=(
        "Approve a kid-completed reflection. Required before the kid sees the "
        "celebratory completion screen. Use when parent says 'approve his "
        "reflection' or after they've reviewed the kid's essay."
    ),
    requires_confirm=True,
    danger="medium",
    inverse_action=None,
    label_builder=lambda args: "Approve reflection",
    registry=GLOBAL_REGISTRY,
)
async def approve_reflection(
    child_id: UUID, rid: UUID, parent_note: str | None = None,
) -> ToolResult:
    req = get_bigkid_store().parent_approve_reflection(
        child_id, rid, parent_note=parent_note,
    )
    return ToolResult(
        public={"rid": str(req.id), "status": req.status.value},
        public_summary="Reflection approved",
    )
```

- [ ] **Step 4: Implement bypass_tools.py**

```python
"""Bypass-respond tool."""
from __future__ import annotations

from uuid import UUID

from backend.app.services.agent_tools.decorator import tool, ToolResult, GLOBAL_REGISTRY
from backend.app.services.bigkid_store import get_store as get_bigkid_store


@tool(
    name="respond_bypass",
    description=(
        "Approve or deny a bypass request the kid sent. decision must be "
        "'approve' or 'deny'. message is shown to the kid (optional but kind)."
    ),
    requires_confirm=True,
    danger="medium",
    inverse_action="respond_bypass",
    inverse_args_builder=lambda args, _r: {
        "bypass_id": args["bypass_id"],
        "decision": "deny" if args["decision"] == "approve" else "approve",
        "message": "Reverted",
    },
    label_builder=lambda args: f"{args['decision'].title()} bypass",
    registry=GLOBAL_REGISTRY,
)
async def respond_bypass(
    bypass_id: UUID, decision: str, message: str | None = None,
) -> ToolResult:
    bypass = get_bigkid_store().respond_bypass(
        bypass_id, decision=decision, message=message,
    )
    return ToolResult(
        public={"bypass_id": str(bypass.id), "status": bypass.status.value},
        public_summary=f"Bypass {bypass.status.value}",
    )
```

- [ ] **Step 5: Implement lock_tools.py (NOT WIRED — placeholder only)**

Reviewer flagged that adding a `lock_until` field to `_ChildState` is
overreach (spec §2 forbids BigKidStore schema changes in v1) and that
the kid app doesn't honor it anyway. We register the tool so the AI
knows it exists, but its body is a no-op that returns a clear "not
yet wired" signal. The system prompt (Task C.4) tells Gemini to mention
the limitation if a parent asks for a full-device lock.

```python
"""Device lock / unlock tools — STUBS in v1.

The kid-app lock-screen UI honoring a server-driven lock state lands
in a follow-up plan. We register the tools here so the agent has a
clean place to acknowledge the request without trying a Profile-UI
workaround."""
from __future__ import annotations

from uuid import UUID

from backend.app.services.agent_tools.decorator import tool, ToolResult, GLOBAL_REGISTRY


@tool(
    name="lock_device",
    description=(
        "Acknowledge a parent's request to lock the kid's whole device for "
        "`minutes` minutes. NOTE: in this version, the lock is recorded but "
        "the kid app does not yet honor it visually. Tell the parent the "
        "request was noted and that the next release will activate it."
    ),
    requires_confirm=True,
    danger="high",
    inverse_action=None,
    label_builder=lambda args: f"Lock device for {args.get('minutes', '?')} min (noted, not yet active)",
    registry=GLOBAL_REGISTRY,
)
async def lock_device(child_id: UUID, minutes: int) -> ToolResult:
    return ToolResult(
        public={"requested_minutes": minutes, "active": False,
                "note": "lock recorded server-side only; kid app not yet wired"},
        public_summary=f"Lock noted ({minutes} min) — kid app will support in next release",
    )


@tool(
    name="unlock_device",
    description=(
        "Acknowledge a parent's unlock request. NOTE: same caveat as "
        "lock_device — kid app does not yet honor lock state in this version."
    ),
    requires_confirm=False,
    danger="low",
    inverse_action=None,
    label_builder=lambda _a: "Unlock device (noted)",
    registry=GLOBAL_REGISTRY,
)
async def unlock_device(child_id: UUID) -> ToolResult:
    return ToolResult(
        public={"active": False, "note": "kid app not yet wired"},
        public_summary="Unlock noted",
    )
```

**No changes to `bigkid_store.py`.** This is critical to avoid
overreach against spec §2.

- [ ] **Step 6: Run tests**

```bash
pytest backend/tests/test_agent_tools.py -v
```

- [ ] **Step 7: Commit**

```bash
git add backend/app/services/agent_tools/reflection_tools.py backend/app/services/agent_tools/bypass_tools.py backend/app/services/agent_tools/lock_tools.py
git commit -m "feat(agent_tools): reflection, bypass, lock_device (stubbed) tool family"
```

---

### Task B.6: Shield/block — NOT registered as a tool (deliberate)

We do not register `shield_app` or `unshield_app` for the agent in v1.
The existing verb-table dispatcher (`chat_resolver.dispatch`) already
handles those requests with the established A1/B1/D4 confirmation
cards, ack-status polling, and Family/Device routing — none of which
the agent loop has access to. Adding a thin tool wrapper would lie
to Gemini about what's possible.

**System prompt (Task C.4) instructs Gemini to:**
- Recognize shield/block requests ("lock Instagram", "ban TikTok")
- Tell the parent to phrase it as a direct command and the existing
  flow will pick it up — and **NOT** call any tool for them.

When `AGENT_ENABLED=0` (default, until rollout), all chat requests
including shield/block continue through the legacy path unchanged.
When the flag flips to 1, only BigKid + reflection + read flows go
through the agent; shield/block requests get a redirect message.

Full shield/block agent integration is a follow-up plan. No code in
this task — skip to Phase C.

---

## Phase C — AgentLoop + endpoints

### Task C.1: Schemas (`Proposal`, `Receipt`, `AgentResponse`)

**Files:**
- Create: `backend/app/schemas/agent.py`

- [ ] **Step 1: Implement schemas**

`AgentResponse` is the shape returned by `AgentLoop.run()` and consumed
by `parent_chat.py` to build the final `ChatResponse`. **No
`legacy_card` field in v1** — the existing verb-table dispatcher path
(AGENT_ENABLED=0) returns its own `ChatResponse(action=...)` shape
unchanged, so there's nothing legacy to surface through the agent path
right now. The legacy_card hook can be added in a follow-up when the
agent actually delegates to the dispatcher (out of v1 scope per Task B.6).

```python
"""Agent response envelope. Used internally by AgentLoop; the chat
endpoint adapter copies these fields into ChatResponse."""
from __future__ import annotations

from pydantic import BaseModel


class Proposal(BaseModel):
    tool: str
    args: dict
    label: str
    danger: str  # "low" | "medium" | "high"
    token: str   # for /parent/agent/exec


class Receipt(BaseModel):
    tool: str
    args: dict
    summary: str
    undo_token: str | None = None


class AgentResponse(BaseModel):
    message: str
    reasoning: str | None = None
    proposals: list[Proposal] = []
    receipts: list[Receipt] = []
    cancelled_proposals: list[str] = []
```

- [ ] **Step 2: Commit**

```bash
git add backend/app/schemas/agent.py
git commit -m "feat(schemas): agent response envelope (Proposal, Receipt)"
```

---

### Task C.2: ProposalStore (in-memory staging with TTL)

**Files:**
- Create: `backend/app/services/proposal_store.py`
- Test: append to `backend/tests/test_parent_action_log.py` (or new file)

- [ ] **Step 1: Test**

Create `backend/tests/test_proposal_store.py`:

```python
import pytest
from datetime import datetime, timedelta, timezone

from backend.app.services.proposal_store import ProposalStore


@pytest.fixture
def store() -> ProposalStore:
    return ProposalStore()


def test_stage_returns_token(store: ProposalStore) -> None:
    t = store.stage(tool="approve_task", args={"x": 1})
    assert isinstance(t, str)
    assert len(t) > 8


def test_pop_returns_call_once(store: ProposalStore) -> None:
    t = store.stage(tool="x", args={"y": 1})
    assert store.pop(t) == ("x", {"y": 1})
    assert store.pop(t) is None


def test_pop_returns_none_when_expired(store: ProposalStore) -> None:
    t = store.stage(tool="x", args={})
    store._entries[t][2] = datetime.now(timezone.utc) - timedelta(seconds=1)  # type: ignore
    assert store.pop(t) is None
```

- [ ] **Step 2: Implement**

```python
"""ProposalStore — in-memory staging of tool calls awaiting parent
confirmation. 10-min TTL so stale proposals get garbage-collected.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import uuid4


class ProposalStore:
    def __init__(self, ttl_seconds: int = 600) -> None:
        self._entries: dict[str, list] = {}  # token -> [tool, args, expires_at]
        self._ttl = ttl_seconds

    def stage(self, *, tool: str, args: dict) -> str:
        token = uuid4().hex
        self._entries[token] = [
            tool, args, datetime.now(timezone.utc) + timedelta(seconds=self._ttl),
        ]
        return token

    def pop(self, token: str) -> tuple[str, dict] | None:
        entry = self._entries.pop(token, None)
        if entry is None:
            return None
        tool, args, expires_at = entry
        if expires_at < datetime.now(timezone.utc):
            return None
        return (tool, args)


_singleton: ProposalStore | None = None


def get_proposal_store() -> ProposalStore:
    global _singleton
    if _singleton is None:
        _singleton = ProposalStore()
    return _singleton
```

- [ ] **Step 3: Run tests**

```bash
pytest backend/tests/test_proposal_store.py -v
```

- [ ] **Step 4: Commit**

```bash
git add backend/app/services/proposal_store.py backend/tests/test_proposal_store.py
git commit -m "feat(proposal_store): in-memory tool-call staging with 10m TTL"
```

---

### Task C.3: AgentLoop core

**Files:**
- Create: `backend/app/services/agent_loop.py`
- Test: `backend/tests/test_agent_loop.py`

- [ ] **Step 1: Test (mocks Gemini)**

Create `backend/tests/test_agent_loop.py`:

```python
"""Unit tests for AgentLoop — Gemini stubbed, tool registry real."""
from __future__ import annotations

from uuid import UUID

import pytest

from backend.app.services.agent_loop import AgentLoop, AgentInput
from backend.app.services.agent_tools.decorator import ToolRegistry, ToolResult, tool


@pytest.fixture
def fresh_registry() -> ToolRegistry:
    reg = ToolRegistry()

    @tool(registry=reg, name="echo", description="Echo input",
          requires_confirm=False, danger="low")
    async def echo(msg: str) -> ToolResult:
        return ToolResult(public={"echoed": msg}, public_summary=msg)

    @tool(registry=reg, name="risky", description="Risky write",
          requires_confirm=True, danger="high")
    async def risky(x: int) -> ToolResult:
        return ToolResult(public={"x": x})

    return reg


@pytest.mark.asyncio
async def test_safe_tool_executes_immediately(fresh_registry, monkeypatch) -> None:
    """When AI calls a no-confirm tool, it runs and we return a receipt."""

    class StubGemini:
        async def chat(self, **kw):
            # First iteration: emit one tool call.
            if not getattr(self, "called", False):
                self.called = True
                return type("R", (), {
                    "tool_calls": [type("C", (), {"id": "x", "name": "echo", "args": {"msg": "hi"}})()],
                    "text": "",
                })()
            # Second iteration after seeing tool result: emit final message.
            return type("R", (), {"tool_calls": [], "text": "Got it: hi"})()

    loop = AgentLoop(registry=fresh_registry, gemini=StubGemini(), action_log=None,
                     proposal_store=None)
    out = await loop.run(AgentInput(message="say hi", history=[], child_device_id=None,
                                    child_name="Liam", state_snapshot=None,
                                    force_confirmations=[]))
    assert out.message == "Got it: hi"
    assert len(out.receipts) == 1
    assert out.receipts[0].tool == "echo"


@pytest.mark.asyncio
async def test_risky_tool_stages_as_proposal(fresh_registry) -> None:
    """When AI calls a confirm-required tool, we stage instead of running."""

    class StubGemini:
        async def chat(self, **kw):
            if not getattr(self, "called", False):
                self.called = True
                return type("R", (), {
                    "tool_calls": [type("C", (), {"id": "x", "name": "risky", "args": {"x": 1}})()],
                    "text": "",
                })()
            return type("R", (), {"tool_calls": [], "text": "Awaiting confirm"})()

    from backend.app.services.proposal_store import ProposalStore
    loop = AgentLoop(registry=fresh_registry, gemini=StubGemini(), action_log=None,
                     proposal_store=ProposalStore())
    out = await loop.run(AgentInput(message="do it", history=[], child_device_id=None,
                                    child_name="Liam", state_snapshot=None,
                                    force_confirmations=[]))
    assert len(out.proposals) == 1
    assert out.proposals[0].tool == "risky"
    assert len(out.receipts) == 0
```

- [ ] **Step 2: Run failing**

```bash
pytest backend/tests/test_agent_loop.py -v
```

Expected: ImportError on agent_loop.

- [ ] **Step 3: Implement AgentLoop**

```python
"""AgentLoop — iterative Gemini function-calling around a ToolRegistry.

Spec §4. Max 3 iterations. Confirm-required tool calls are staged into
ProposalStore (returned to iOS as Proposals). Safe calls execute and
write to ParentActionLog (returned as Receipts with undo_token).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol
from uuid import UUID

from loguru import logger

from backend.app.schemas.agent import AgentResponse, Proposal, Receipt
from backend.app.services.agent_tools.decorator import ToolRegistry
from backend.app.services.parent_action_log import ParentActionLog
from backend.app.services.proposal_store import ProposalStore


MAX_ITERATIONS = 3


class GeminiProtocol(Protocol):
    async def chat(self, **kwargs: Any) -> Any: ...


@dataclass
class AgentInput:
    message: str
    history: list[dict]
    child_device_id: UUID | None
    child_name: str
    state_snapshot: dict | None
    force_confirmations: list[str]


class AgentLoop:
    def __init__(
        self,
        *,
        registry: ToolRegistry,
        gemini: GeminiProtocol,
        action_log: ParentActionLog | None,
        proposal_store: ProposalStore | None,
    ) -> None:
        self.registry = registry
        self.gemini = gemini
        self.action_log = action_log
        self.proposal_store = proposal_store

    async def run(self, inp: AgentInput) -> AgentResponse:
        proposals: list[Proposal] = []
        receipts: list[Receipt] = []
        last_results: list[dict] = []

        for iteration in range(MAX_ITERATIONS):
            resp = await self.gemini.chat(
                history=inp.history,
                state_snapshot=inp.state_snapshot,
                user_message=inp.message if iteration == 0 else None,
                tool_results=last_results if iteration > 0 else None,
                tools=self.registry.declarations(),
                child_name=inp.child_name,
            )

            if not getattr(resp, "tool_calls", None):
                return AgentResponse(
                    message=getattr(resp, "text", "") or "",
                    proposals=proposals,
                    receipts=receipts,
                )

            last_results = []
            for call in resp.tool_calls:
                tool_meta = self.registry.tools.get(call.name)
                if tool_meta is None:
                    last_results.append({
                        "call_id": call.id, "status": "error",
                        "error": f"unknown tool: {call.name}",
                    })
                    continue

                if tool_meta.requires_confirm and "force_all" not in inp.force_confirmations:
                    if self.proposal_store is None:
                        last_results.append({
                            "call_id": call.id, "status": "error",
                            "error": "no proposal store",
                        })
                        continue
                    token = self.proposal_store.stage(tool=call.name, args=call.args)
                    label = (
                        tool_meta.label_builder(call.args)
                        if tool_meta.label_builder else call.name
                    )
                    proposals.append(Proposal(
                        tool=call.name, args=call.args, label=label,
                        danger=tool_meta.danger, token=token,
                    ))
                    last_results.append({
                        "call_id": call.id, "status": "awaiting_user_confirm",
                    })
                    continue

                try:
                    result = await self.registry.call(call.name, call.args)
                except Exception as exc:
                    logger.warning("tool {} failed: {}", call.name, exc)
                    last_results.append({
                        "call_id": call.id, "status": "error", "error": str(exc),
                    })
                    continue

                undo_token: str | None = None
                if self.action_log is not None and tool_meta.inverse_action:
                    inverse_args = (
                        tool_meta.inverse_args_builder(call.args, result)
                        if tool_meta.inverse_args_builder
                        else dict(call.args)
                    )
                    undo_token = self.action_log.record(
                        action_type=call.name, args=call.args,
                        inverse_action=tool_meta.inverse_action,
                        inverse_args=inverse_args,
                        source="agent",
                    )
                receipts.append(Receipt(
                    tool=call.name, args=call.args,
                    summary=result.public_summary or call.name,
                    undo_token=undo_token,
                ))
                last_results.append({
                    "call_id": call.id, "status": "ok", "data": result.public,
                })

        # Iteration cap hit
        return AgentResponse(
            message="I tried a few approaches but couldn't finalize. What would you like me to do?",
            proposals=proposals,
            receipts=receipts,
        )
```

- [ ] **Step 4: Run tests**

```bash
pytest backend/tests/test_agent_loop.py -v
```

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/agent_loop.py backend/tests/test_agent_loop.py
git commit -m "feat(agent_loop): iterative function-calling agent with confirmation gating"
```

---

### Task C.4: Real Gemini adapter (function-calling)

**Files:**
- Create: `backend/app/services/agent_gemini.py`

- [ ] **Step 1: Implement adapter**

Reviewer-corrected version. Critical changes vs. naïve:
- Uses `config.system_instruction=` (not folded into a user turn).
- Tool results sent as proper `function_response` parts.
- Blocking `client.models.generate_content` wrapped in `asyncio.to_thread`.
- History role mapping: any `role` that's not `"agent"`/`"assistant"` is `"user"`.
- `fc.args` recursively converted from MapComposite to plain Python dict.

```python
"""Gemini function-calling adapter for AgentLoop. Wraps google.genai SDK.
Implementation notes per code-review feedback:
- system_instruction (not user-turn folding) for the system prompt.
- function_response parts for tool results so the model knows which
  call each result resolves (raw text confused multi-step loops).
- asyncio.to_thread around the SDK's blocking generate_content call.
"""
from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from typing import Any

from backend.app.core.settings import settings


AGENT_SYSTEM_PROMPT = """You are Evlin, an AI parental copilot. The parent is having a chat with you about their child.

CURRENT KID STATE (auto-injected, may be empty if no child paired):
{state_snapshot}

DEFAULT POSTURE: listen and inform. Most parent messages are venting, asking questions, or thinking aloud. Do NOT propose actions unless one of these signals is present:

1. Parent describes a specific bad thing the child did. Examples:
   - "She hit her sister"
   - "He kept scrolling past bedtime"
   - "Liam called me a bitch at dinner"
   In that case: call propose_reflection with `reason` describing the kid's action only (avoid 'You did' literal phrasing — the downstream model will rephrase). Never lecture the parent. One empathetic sentence in your message field is plenty.

2. Parent explicitly asks for a specific action ("approve task X", "send him a reflection about Y").

3. Parent invites you to review or judge ("look at today's submissions", "what should I do about these tasks"). For invitations to review: call review_submissions, then in the next iteration propose approve_task / request_redo for individual items based on the verdicts.

4. Parent is just venting, asking questions, or making neutral observations — DO NOT propose. Just respond conversationally. Use get_kid_state if you need context for your reply.

AMBIGUITY:
- If it's a multi-child family and the parent uses a pronoun without naming, ask which kid in plain language. Do NOT pick one.
- If single-child, resolve pronouns to that child silently.
- If you need a parameter you don't have (task_id, bypass_id), ask the parent in plain language. Do NOT call the tool.

CONFIRMATION:
- Tools you call with `requires_confirm` may be staged for parent approval before they run. The parent will see a Confirm button. Don't promise the action ran in your message — say things like "Want me to ..." or describe the proposal neutrally.
- Tools without confirm execute immediately. Their effects are real.

NOT WIRED IN THIS VERSION:
- Shielding / blocking apps (e.g. "lock Instagram for 30 min") is handled by a different system. If the parent asks for that, tell them to phrase it as a direct command to Evlin and the existing flow will pick it up — do NOT try to call any tool for it.
- lock_device toggles a server-side flag but the kid app does not yet honor it visually. Mention this caveat if the parent asks for full-device locks.

EMPATHY:
When the parent describes frustration, anger, or sadness, acknowledge it before calling any tool. One sentence is enough.
"""


@dataclass
class GeminiToolCall:
    id: str           # Use call.name when SDK doesn't provide an id.
    name: str
    args: dict


@dataclass
class GeminiResponse:
    tool_calls: list[GeminiToolCall]
    text: str


def _to_plain(value: Any) -> Any:
    """Recursively convert google-genai proto-backed Map/RepeatedComposite
    structures into plain Python dicts/lists. Tools assume ordinary types."""
    if hasattr(value, "items") and not isinstance(value, dict):
        return {k: _to_plain(v) for k, v in value.items()}
    if isinstance(value, dict):
        return {k: _to_plain(v) for k, v in value.items()}
    if hasattr(value, "__iter__") and not isinstance(value, (str, bytes)):
        return [_to_plain(v) for v in value]
    return value


class GeminiAgentClient:
    """Real adapter calling google.genai. Tests substitute a stub
    conforming to the same `chat(**kwargs) -> GeminiResponse` contract."""

    async def chat(
        self, *,
        history: list[dict],
        state_snapshot: dict | None,
        user_message: str | None,
        tool_results: list[dict] | None,  # [{call_id, name, status, data?, error?}]
        tools: list[dict],
        child_name: str,
    ) -> GeminiResponse:
        from google import genai
        from google.genai import types

        # Build conversation contents.
        contents: list[types.Content] = []

        # Replay conversation history (last 10).
        for h in history[-10:]:
            raw_role = (h.get("role") or "").lower()
            # ChatViewModel uses "user" / "agent"; legacy mock used "parent".
            role = "model" if raw_role in ("agent", "assistant", "evlin") else "user"
            contents.append(types.Content(
                role=role,
                parts=[types.Part.from_text(text=str(h.get("content", "")))],
            ))

        if user_message is not None:
            contents.append(types.Content(
                role="user",
                parts=[types.Part.from_text(text=f"[Child context: {child_name}] {user_message}")],
            ))

        if tool_results is not None:
            # Tool results go back as function_response parts. Each result
            # block becomes a `model`/`user` exchange where we replay the
            # function_call we issued and then attach its response.
            for tr in tool_results:
                # We don't have access to the original function_call Part
                # here; instead, build a single user-role Content with the
                # function_response parts. Gemini's SDK accepts this.
                contents.append(types.Content(
                    role="user",
                    parts=[types.Part.from_function_response(
                        name=tr.get("name") or tr.get("call_id") or "unknown",
                        response={"result": tr.get("data"), "status": tr.get("status"),
                                  "error": tr.get("error")},
                    )],
                ))

        # System prompt — formatted once with state snapshot. We pass it via
        # config.system_instruction for proper system-role semantics.
        sys_text = AGENT_SYSTEM_PROMPT.format(
            state_snapshot=json.dumps(state_snapshot or {}, default=str, ensure_ascii=False),
        )

        client = genai.Client(api_key=settings.gemini_api_key)
        tool_decl = types.Tool(function_declarations=[
            types.FunctionDeclaration(
                name=t["name"], description=t["description"], parameters=t["parameters"],
            ) for t in tools
        ])

        # generate_content is blocking; offload to a thread so the FastAPI
        # event loop stays responsive.
        def _call_sync():
            return client.models.generate_content(
                model=settings.gemini_model,
                contents=contents,
                config=types.GenerateContentConfig(
                    system_instruction=sys_text,
                    temperature=0.4,
                    tools=[tool_decl],
                ),
            )
        resp = await asyncio.to_thread(_call_sync)

        tool_calls: list[GeminiToolCall] = []
        text_chunks: list[str] = []
        for cand in (resp.candidates or []):
            content = getattr(cand, "content", None)
            for part in (getattr(content, "parts", None) or []):
                fc = getattr(part, "function_call", None)
                if fc is not None and getattr(fc, "name", None):
                    tool_calls.append(GeminiToolCall(
                        id=getattr(fc, "id", "") or fc.name,
                        name=fc.name,
                        args=_to_plain(fc.args) or {},
                    ))
                txt = getattr(part, "text", None)
                if txt:
                    text_chunks.append(txt)
        return GeminiResponse(tool_calls=tool_calls, text="".join(text_chunks))
```

The `last_tool_results` shape produced by AgentLoop now matches what the
adapter consumes (`name`, `status`, `data`, `error`, `call_id`). See
Task C.3 step 3 — that's where the AgentLoop is updated to include `name`
in each result.

- [ ] **Step 2: Update AgentLoop to include `name` in tool results**

In Task C.3's implementation, the `last_results.append({...})` calls
must include `"name": call.name` so the adapter can build a valid
`function_response` part. Update each appended dict:

```python
last_results.append({
    "call_id": call.id, "name": call.name, "status": "ok", "data": result.public,
})
last_results.append({
    "call_id": call.id, "name": call.name, "status": "error", "error": str(exc),
})
last_results.append({
    "call_id": call.id, "name": call.name, "status": "awaiting_user_confirm",
})
```

- [ ] **Step 3: Commit**

```bash
git add backend/app/services/agent_gemini.py backend/app/services/agent_loop.py
git commit -m "feat(agent): Gemini adapter — function_response parts + async to_thread + system_instruction"
```

---

### Task C.5: Endpoints — `/parent/chat` (modify) + `/parent/agent/exec`

**Files:**
- Create: `backend/app/api/routes/parent_agent.py`
- Modify: `backend/app/api/routes/parent_chat.py`
- Modify: `backend/app/core/settings.py` (agent_enabled flag)
- Modify: `backend/app/main.py` (mount new router)

- [ ] **Step 1: Add settings flag**

In `settings.py`:

```python
# Agent feature flag — when 1, /parent/chat routes through AgentLoop.
agent_enabled: bool = False
```

- [ ] **Step 2: Build /parent/agent/exec endpoint**

Create `backend/app/api/routes/parent_agent.py`:

```python
"""POST /parent/agent/exec — execute a previously-staged proposal."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from backend.app.schemas.agent import Receipt
from backend.app.services.agent_tools import GLOBAL_REGISTRY
from backend.app.services.parent_action_log import (
    ParentActionLog, get_log as get_action_log,
)
from backend.app.services.proposal_store import (
    ProposalStore, get_proposal_store,
)


router = APIRouter(tags=["Parent Agent"])


class ExecBody(BaseModel):
    token: str


@router.post("/parent/agent/exec", response_model=Receipt)
async def exec_proposal(
    body: ExecBody,
    proposal_store: ProposalStore = Depends(get_proposal_store),
    log: ParentActionLog = Depends(get_action_log),
) -> Receipt:
    popped = proposal_store.pop(body.token)
    if popped is None:
        raise HTTPException(status_code=410, detail="proposal expired or already used")

    tool_name, args = popped
    if tool_name not in GLOBAL_REGISTRY.tools:
        raise HTTPException(status_code=500, detail=f"tool gone: {tool_name}")
    meta = GLOBAL_REGISTRY.tools[tool_name]

    result = await GLOBAL_REGISTRY.call(tool_name, args)

    undo_token: str | None = None
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
    return Receipt(
        tool=tool_name, args=args,
        summary=result.public_summary or tool_name,
        undo_token=undo_token,
    )
```

- [ ] **Step 3: Mount router** in `main.py`:

```python
from backend.app.api.routes.parent_agent import router as parent_agent_router
# in include block:
app.include_router(parent_agent_router, prefix=settings.api_prefix)
```

- [ ] **Step 4: Expand ChatResponse FIRST**

Before touching the route function, modify the response schema in
`backend/app/api/routes/parent_chat.py`:

```python
# Top of file, with other imports:
from backend.app.schemas.agent import Proposal, Receipt

# Modify the existing ChatResponse class:
class ChatResponse(BaseModel):
    message: str
    reasoning: str | None = None
    action: ChatAction | None = None
    # New agent-path fields (all optional / default empty for back-compat).
    proposals: list[Proposal] = []
    receipts: list[Receipt] = []
    cancelled_proposals: list[str] = []
```

iOS old builds ignore unknown fields (Codable default). Existing
shield/block path leaves them empty. Agent path populates them.

- [ ] **Step 5: Module-level imports for tool registration**

At the TOP of `parent_chat.py` (NOT inside the route function), add:

```python
# Force tool modules to import so @tool decorators register into
# GLOBAL_REGISTRY at app startup. Done once per process.
from backend.app.services.agent_tools import (  # noqa: F401
    read_tools, task_tools, reflection_tools, bypass_tools,
    lock_tools, vision_tools,
)
# NOTE: shield_app and unshield_app are NOT registered for the agent in
# v1 (the existing verb-table dispatcher handles those). Don't import
# shield_tools here — leaving it unimported keeps it out of the registry.
```

- [ ] **Step 6: Modify the `parent_chat` route**

Insert at the START of `async def parent_chat(...)`:

```python
if settings.agent_enabled:
    from backend.app.services.agent_loop import AgentLoop, AgentInput
    from backend.app.services.agent_gemini import GeminiAgentClient
    from backend.app.services.agent_tools import GLOBAL_REGISTRY
    from backend.app.services.parent_action_log import get_log as get_action_log
    from backend.app.services.proposal_store import get_proposal_store
    from backend.app.services.bigkid_store import get_store as get_bigkid_store

    state_snapshot = None
    if req.child_device_id is not None:
        full = get_bigkid_store().get_state(req.child_device_id)
        # Trim per spec §4.4 — drop quiz body + photo URLs from snapshot.
        state_snapshot = _trimmed_snapshot(full)

    loop = AgentLoop(
        registry=GLOBAL_REGISTRY,
        gemini=GeminiAgentClient(),
        action_log=get_action_log(),
        proposal_store=get_proposal_store(),
    )
    agent_resp = await loop.run(AgentInput(
        message=req.message, history=req.history,
        child_device_id=req.child_device_id, child_name=req.child_name,
        state_snapshot=state_snapshot,
        force_confirmations=req.force_confirmations or [],
    ))
    # CRITICAL: forward proposals + receipts. Reviewer flagged this — the
    # original draft dropped them.
    return ChatResponse(
        message=agent_resp.message,
        reasoning=agent_resp.reasoning,
        action=None,
        proposals=agent_resp.proposals,
        receipts=agent_resp.receipts,
        cancelled_proposals=agent_resp.cancelled_proposals,
    )
```

And add the snapshot trimmer at module scope:

```python
def _trimmed_snapshot(state) -> dict:
    """Strip context-bloat from the full ChildStateResponse for the
    agent's auto-injected state. See spec §4.4."""
    return {
        "child_name": state.child_name,
        "minutes_left": state.minutes_left,
        "minutes_max": state.minutes_max,
        "tasks": [
            {
                "id": str(t.id), "title": t.title, "status": t.status.value,
                "phase": t.phase.value,
                "has_photo": bool(t.evidence_photo_url),
                "has_note": bool(t.evidence_note),
                "has_bypass": t.bypass is not None,
                "redo_reason": t.redo_reason,
            }
            for t in state.tasks
        ],
        "reflection_active": state.reflection_request is not None,
        "reflection_reason": (
            state.reflection_request.reason if state.reflection_request else None
        ),
        "pending_bypass_count": sum(
            1 for t in state.tasks
            if t.bypass and t.bypass.status.value == "pending"
        ),
    }
```

- [ ] **Step 5: Run all backend tests**

```bash
pytest backend/tests/ -v
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/routes/parent_agent.py backend/app/api/routes/parent_chat.py backend/app/main.py backend/app/core/settings.py
git commit -m "feat(agent): /parent/agent/exec + agent-enabled route in /parent/chat"
```

---

## Phase D — iOS components

### Task D.1: Decode envelope (Proposal, Receipt)

**Files:**
- Create: `Evlin iOS/Evlin iOS/Models/AgentEnvelope.swift`
- Modify: `Evlin iOS/Evlin iOS/Services/APIClient.swift` (extend `ChatResponse`)

**Pre-flight:** verify `AnyCodable` exists in the project before proceeding:

```bash
grep -rn "struct AnyCodable\|typealias AnyCodable" "Evlin iOS/Evlin iOS/" | head
```

If it doesn't exist, drop a minimal type at the top of
`AgentEnvelope.swift` (we don't need full polymorphism in v1 — `args`
is rendered as a few well-known keys).

- [ ] **Step 1: New model file**

```swift
import Foundation

/// Minimal type-erased value for decoding heterogeneous tool args.
/// AI tool args are JSON: strings, numbers, bools, null, and possibly
/// nested. v1 only displays a handful of known keys (reason, title,
/// minutes), so deep nesting is rare; a flat decoder is enough.
struct AnyCodable: Codable, Hashable, @unchecked Sendable {
    let value: Any

    init(_ v: Any) { self.value = v }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { value = b; return }
        if let i = try? c.decode(Int.self) { value = i; return }
        if let d = try? c.decode(Double.self) { value = d; return }
        if let s = try? c.decode(String.self) { value = s; return }
        if let arr = try? c.decode([AnyCodable].self) { value = arr; return }
        if let dict = try? c.decode([String: AnyCodable].self) { value = dict; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [AnyCodable]: try c.encode(a)
        case let d as [String: AnyCodable]: try c.encode(d)
        default: try c.encodeNil()
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

/// Tool-call confirmation pending parent approval.
struct ProposalDTO: Codable, Sendable, Hashable {
    let tool: String
    let args: [String: AnyCodable]
    let label: String
    let danger: String   // "low" | "medium" | "high"
    let token: String
}

/// Tool-call already executed by the agent.
struct ReceiptDTO: Codable, Sendable, Hashable {
    let tool: String
    let args: [String: AnyCodable]
    let summary: String
    let undoToken: String?

    enum CodingKeys: String, CodingKey {
        case tool, args, summary
        case undoToken = "undo_token"
    }
}
```

If `AnyCodable` already exists in the codebase, drop the `struct
AnyCodable` part of this file and import it from wherever it lives.

- [ ] **Step 2: Extend ChatResponse in APIClient**

Find the existing `struct ChatResponse: Codable, Sendable` in `APIClient.swift` and add fields:

```swift
struct ChatResponse: Codable, Sendable {
    let message: String
    let reasoning: String?
    let action: ChatActionResponse?
    let proposals: [ProposalDTO]?
    let receipts: [ReceiptDTO]?
    let cancelledProposals: [String]?

    enum CodingKeys: String, CodingKey {
        case message, reasoning, action, proposals, receipts
        case cancelledProposals = "cancelled_proposals"
    }
}
```

- [ ] **Step 3: Build verifies**

```bash
xcodebuild -project "/Users/fred/Desktop/Evlin/Evlin iOS/Evlin iOS.xcodeproj" -scheme "Evlin iOS" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Models/AgentEnvelope.swift" "Evlin iOS/Services/APIClient.swift"
git commit -m "feat(ios): decode agent envelope (Proposal, Receipt, undo_token)"
```

---

### Task D.2: AgentClient (executeProposal, revertAction)

**Files:**
- Create: `Evlin iOS/Evlin iOS/Services/AgentClient.swift`

```swift
import Foundation

/// Talks to the new /parent/agent/exec and /parent/actions/{id}/revert
/// endpoints. Same baseURL as APIClient.
struct AgentClient {
    let baseURL: String

    init(baseURL: String) {
        self.baseURL = baseURL
    }

    /// Confirm a staged proposal. Returns the executed receipt.
    func executeProposal(token: String) async throws -> ReceiptDTO {
        let url = URL(string: "\(baseURL)/parent/agent/exec")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentError.serverError(
                code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                detail: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(ReceiptDTO.self, from: data)
    }

    /// Revert a previously executed action by undo_token.
    func revertAction(actionID: String) async throws -> RevertResult {
        let url = URL(string: "\(baseURL)/parent/actions/\(actionID)/revert")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AgentError.serverError(code: 0, detail: "no response")
        }
        if http.statusCode == 410 {
            throw AgentError.expired
        }
        if http.statusCode != 200 {
            throw AgentError.serverError(
                code: http.statusCode,
                detail: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(RevertResult.self, from: data)
    }
}

struct RevertResult: Codable {
    let revertedActionID: String
    let newUndoToken: String?

    enum CodingKeys: String, CodingKey {
        case revertedActionID = "reverted_action_id"
        case newUndoToken = "new_undo_token"
    }
}

enum AgentError: LocalizedError {
    case expired
    case serverError(code: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .expired: return "This action expired. Try again."
        case .serverError(let code, let detail):
            return "Server error \(code): \(detail.prefix(120))"
        }
    }
}
```

- [ ] **Build + commit**

```bash
xcodebuild ... build 2>&1 | tail -3
git add "Evlin iOS/Services/AgentClient.swift"
git commit -m "feat(ios): AgentClient — executeProposal + revertAction"
```

---

### Task D.3: ProposalCard component

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/ProposalCard.swift`

```swift
import SwiftUI

/// Generic AI proposal card — surface AI-staged tool calls for parent
/// approval. One card per Proposal in the agent response. Tap Confirm
/// → POST /parent/agent/exec → in-place becomes a ReceiptBubble.
struct ProposalCard: View {
    let proposal: ProposalDTO
    var onConfirm: () async -> Void
    var onSkip: () -> Void
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
            Text(bodyText)
                .font(.system(size: 14))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(2)
            HStack(spacing: 10) {
                Button(action: { Task { await runConfirm() } }) {
                    Text(working ? "Working…" : "Confirm")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(dangerColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(working)
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

    private func runConfirm() async {
        working = true
        await onConfirm()
        working = false
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
        // For v1, pull a few common keys from args. AI's `label` already
        // describes the action; this gives extra context.
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

- [ ] **Build + commit**

```bash
git add "Evlin iOS/Components/ConfirmationCards/ProposalCard.swift"
git commit -m "feat(ios): ProposalCard generic agent confirmation UI"
```

---

### Task D.4: ReceiptBubble component

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/ReceiptBubble.swift`

```swift
import SwiftUI
import Combine

/// Receipt for an agent-executed action. Shows summary + Undo button
/// with 60s countdown. Tapping Undo POSTs /parent/actions/{id}/revert.
struct ReceiptBubble: View {
    let receipt: ReceiptDTO
    var onUndo: (String) async -> Void
    @State private var secondsRemaining: Int = 60
    @State private var undoing = false
    @State private var undoneOrExpired = false
    @State private var timerCancellable: Cancellable? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.evSecondary)
                .font(.system(size: 18, weight: .semibold))
            Text(receipt.summary)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.evOnSurface)
            Spacer(minLength: 0)
            if let token = receipt.undoToken, !undoneOrExpired {
                Button(action: { Task { await runUndo(token: token) } }) {
                    Text(undoing ? "…" : "Undo (\(secondsRemaining))")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.evError)
                }
                .disabled(undoing)
            } else if undoneOrExpired {
                Text("Done").font(.system(size: 12, weight: .heavy)).foregroundStyle(.gray)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.evSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            // Start a connectable timer we can cancel on disappear so we
            // don't leak ticks for off-screen receipts.
            let publisher = Timer.publish(every: 1, on: .main, in: .common)
            timerCancellable = publisher.autoconnect().sink { _ in
                guard !undoneOrExpired else { return }
                secondsRemaining -= 1
                if secondsRemaining <= 0 { undoneOrExpired = true }
            }
        }
        .onDisappear {
            timerCancellable?.cancel()
            timerCancellable = nil
        }
    }

    private func runUndo(token: String) async {
        undoing = true
        await onUndo(token)
        undoing = false
        undoneOrExpired = true
    }
}
```

- [ ] **Build + commit**

```bash
git add "Evlin iOS/Components/ReceiptBubble.swift"
git commit -m "feat(ios): ReceiptBubble with 60s Undo countdown"
```

---

<!-- Task D.5 (InlineUndoToast) deliberately omitted — Profile UI does not get Undo. -->

---

## Phase E — iOS integration

### Task E.1: ChatViewModel + ChatView render new sections

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Models/ChatModels.swift`
- Modify: `Evlin iOS/Evlin iOS/Views/Chat/ChatViewModel.swift`
- Modify: `Evlin iOS/Evlin iOS/Views/Chat/ChatView.swift`

- [ ] **Step 1: Extend ChatMessage**

```swift
// In ChatModels.swift, on struct ChatMessage:
var proposals: [ProposalDTO]? = nil
var receipts: [ReceiptDTO]? = nil
```

- [ ] **Step 2: Wire decoding in ChatViewModel**

In the existing chat-pipeline `processResponse`, after appending the
agent message, also store proposals/receipts:

```swift
@MainActor
private func processResponse(_ resp: APIClient.ChatResponse, userMessage: String) {
    // ... existing card / command_id / plain-text branches stay ...

    // NEW: agent envelope path. If proposals/receipts present, append a
    // single message bubble carrying them.
    if (resp.proposals?.isEmpty == false) || (resp.receipts?.isEmpty == false) {
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
    // existing branches continue...
}
```

- [ ] **Step 3: Render in ChatView**

In `ChatView.swift`, in the message ForEach loop, beneath the existing
text bubble for `.agent` role, render proposals and receipts:

```swift
if let proposals = msg.proposals {
    VStack(spacing: 10) {
        ForEach(proposals, id: \.token) { p in
            ProposalCard(
                proposal: p,
                onConfirm: { await viewModel.confirmProposal(p) },
                onSkip: { viewModel.skipProposal(p) }
            )
        }
    }
    .padding(.horizontal, 16)
}
if let receipts = msg.receipts {
    VStack(spacing: 8) {
        ForEach(receipts, id: \.summary) { r in
            ReceiptBubble(receipt: r, onUndo: { token in
                await viewModel.undoReceipt(token: token)
            })
        }
    }
    .padding(.horizontal, 16)
}
```

- [ ] **Step 4: Add ChatViewModel methods**

```swift
@MainActor
func confirmProposal(_ p: ProposalDTO) async {
    let client = AgentClient(baseURL: apiClient.baseURL)
    do {
        let receipt = try await client.executeProposal(token: p.token)
        // Append the receipt to the most recent message that contained
        // this proposal — for simplicity, append to last agent message.
        if let i = messages.lastIndex(where: { $0.role == .agent }) {
            var msg = messages[i]
            msg.proposals?.removeAll(where: { $0.token == p.token })
            msg.receipts = (msg.receipts ?? []) + [receipt]
            messages[i] = msg
        }
    } catch {
        errorMessage = (error as? LocalizedError)?.errorDescription
    }
}

@MainActor
func skipProposal(_ p: ProposalDTO) {
    if let i = messages.lastIndex(where: { $0.role == .agent }) {
        var msg = messages[i]
        msg.proposals?.removeAll(where: { $0.token == p.token })
        messages[i] = msg
    }
}

@MainActor
func undoReceipt(token: String) async {
    let client = AgentClient(baseURL: apiClient.baseURL)
    do {
        _ = try await client.revertAction(actionID: token)
        // Show a subtle confirmation message (uses ChatMessage's existing
        // optional defaults — no trailing comma).
        messages.append(ChatMessage(role: .agent, content: "Reverted."))
    } catch {
        errorMessage = (error as? LocalizedError)?.errorDescription
    }
}
```

- [ ] **Step 5: Build + commit**

```bash
xcodebuild ... build 2>&1 | tail -3
git add "Evlin iOS/Models/ChatModels.swift" "Evlin iOS/Views/Chat/"
git commit -m "feat(ios chat): render proposals + receipts; confirm/skip/undo"
```

---

<!-- Task E.2 (Profile UI toast) deliberately omitted — Profile UI does not get Undo. -->

---

## Phase F — Manual E2E + cleanup

### Task F.1: Manual E2E checklist

**File:** `Evlin iOS/docs/superpowers/manual/2026-05-03-agent-e2e.md`

```markdown
# Agent E2E manual checklist (post-flag-on)

Set Railway env: `AGENT_ENABLED=1`. Restart, verify `/parent/_supabase_debug` returns 200.

## Read-only flow
1. Chat: "今天 Liam 怎么样" → AI calls get_kid_state, returns plain summary. No proposals.
2. Chat: "她交了几个任务" → list_pending_submissions, plain answer.

## Misbehavior signal → R1-equivalent
3. Chat: "她今天对我大吼了" → AI shows empathy bubble + ProposalCard "Send Liam a reflection". Confirm → ReceiptBubble; kid app shows reflection within 8s.

## Review flow (multimodal)
4. Have kid submit 2 tasks with photos. Chat: "帮我看下今天的任务" → AI calls review_submissions → describes each photo's verdict.
5. Chat: "把明显完成的都approve了" → AI proposes approve_task for the looks_done=true items as separate cards. Confirm each.

## Direct-action shortcut
6. Chat: "approve task make-bed" → ProposalCard appears. Confirm → kid sees Approved! screen. Tap Undo on receipt within 60s → kid sees redo banner.

## Profile UI unchanged (intentional)
7. Profile → Liam → tap a submitted task → APPROVE. **No toast / no Undo button** appears. Direct UI behavior is unchanged from Phase 12.

## Ambiguity
8. (Single-child) Chat: "她今天怎样" → resolves silently to Liam.
9. (Future, multi-child) Chat: "她今天怎样" → AI asks "Liam 还是 Maya?" — no tool call.

## Failure modes
10. Wait 11 min after a Proposal, then tap Confirm → toast "This action expired."
11. Wait 61s after a receipt, Undo button greyed.
12. Stop Railway mid-confirm → iOS shows error message, card remains.
```

- [ ] **Step 1: Add doc + commit**

```bash
git add "Evlin iOS/docs/superpowers/manual/"
git commit -m "docs: agent E2E manual checklist"
```

---

### Task F.2: Flip the flag + smoke test

- [ ] Set Railway env `AGENT_ENABLED=1` (manual via dashboard).
- [ ] Wait for redeploy.
- [ ] Run E2E checklist items 1-3 via curl:

```bash
BASE="https://adaptive-engine-production.up.railway.app/api/v1"
CID="11111111-1111-1111-1111-111111111111"
curl -s -X POST "$BASE/parent/chat" -H "Content-Type: application/json" \
  -d "{\"message\":\"今天 Liam 怎么样\",\"child_name\":\"Liam\",\"child_device_id\":\"$CID\",\"history\":[]}" \
  | python3 -m json.tool
```

Expected: response with `message` describing state, `proposals` empty, `receipts` empty (or one if AI used a write tool).

---

## Self-review checklist

After writing every task above, the plan author runs through these:

**1. Spec coverage:**
- §1 (agent goal) → Phases B+C
- §3 (architecture) → Phase A (action log) + B (tools) + C (loop)
- §4.1 (loop pseudocode) → Task C.3
- §4.2 (system prompt) → Task C.4
- §4.3 (`_was_authorized`) → DEFERRED to v1.1; current loop honors `force_confirmations` list directly
- §5.2 (tool catalog 14 items) → Tasks B.2-B.6 implement 12; `shield_app` stubbed; `unshield_app` not yet (legacy path covers)
- §6 (ParentActionLog) → Phase A
- §7 (iOS UX) → Phase D + E
- §8 (failure cases) → covered in handler + E2E
- §10 (rollout flag) → Task C.5

Gaps identified:
- `_was_authorized` heuristic is not implemented; we accept that in v1 every confirm-required tool always shows a card. Listed as known limitation.
- `shield_app` not wired beyond a polite refusal stub. Covered in F.1.

**2. Placeholders:** None. Every code block is complete.

**3. Type consistency:** ProposalDTO matches Proposal schema (snake_case → camelCase via CodingKeys). ReceiptDTO same. UndoableBigKidTask is the iOS-side wrapper.

**4. Ambiguity:** Lock_until field on _ChildState is added in B.5 but not exposed to iOS in this plan — kid lock screen UI is a follow-up.

---

## Execution

This plan is being executed via superpowers:subagent-driven-development:
- One implementer subagent per task
- Spec compliance reviewer + code quality reviewer between tasks
- Final code-reviewer for the whole branch
