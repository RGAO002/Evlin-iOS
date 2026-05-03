# Global AI Copilot — Design Spec

**Date:** 2026-05-03
**Status:** Draft, pending review
**Scope:** Backend (`adaptive-engine`) + iOS (`Evlin iOS`)

---

## 1. Goal

Replace the current verb-table chat dispatcher (one Python branch per
new chat capability) with a **tool-calling agent** that can:

- Execute any parent-side action through chat — same surface as the
  Profile UI, plus things the UI can't do (batch ops, conditional
  logic, photo-judged review).
- Read full child state and answer naturally without forcing action
  proposals on the parent.
- Stay restrained — default to listening / informing; only propose
  action when the parent's intent is clear or the situation strongly
  warrants it (specifically: misbehavior narration → reflection card).
- Compose multi-step plans across multiple tools in one chat turn.

Plus an **agent-receipt Undo** safety net: every action executed by
the chat agent surfaces an Undo button on its receipt bubble for 60s,
backed by a `ParentActionLog` service. **Profile UI direct buttons
and the shield/block dispatcher are NOT modified** — they keep their
current behavior with no inline toasts. Undo is a chat-only feature.

## 2. Non-goals (v1)

- Migrating the existing shield/block dispatcher away from cards
  A1/B1/C1/D1-4/E1-4/F1/G1. Those are stable. The agent calls
  `shield_app` as a tool that **forwards** to the existing dispatcher;
  if the dispatcher returns a legacy card, iOS renders it via the
  existing `CardDispatcher`.
- Replacing in-memory `BigKidStore` with persistent storage. (Phase 13
  follow-up; see §11.)
- Surfacing tools for Profile-mock domains (Rules, Events, Calendar).
  The architecture supports adding them later by registering a new
  `@tool`-decorated function — no changes to the agent loop or iOS
  beyond optional typed cards.
- Web companion / non-iOS clients.

## 3. Architecture overview

```
┌──────────────────────────────────────────────────────────────────┐
│  POST /parent/chat   (existing endpoint, internals rewritten)    │
└──────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  AgentLoop (max 3 iterations)                                    │
│                                                                  │
│   build prompt = system + history + state_snapshot + user_msg    │
│   → Gemini.chat(tools=TOOL_REGISTRY.declarations(), tool_choice="auto") │
│                                                                  │
│   if response.tool_calls:                                        │
│     for call in tool_calls:                                      │
│       if tool.requires_confirm and not _was_authorized(history): │
│         proposal_token = stage(call); proposals.append(...)      │
│         feed back ToolResult(status="awaiting_user_confirm")     │
│       else:                                                      │
│         result = await tool.fn(**call.args)                      │
│         action_id = ParentActionLog.record(...)                  │
│         receipts.append(Receipt(..., undo_token=action_id))      │
│         feed back ToolResult(status="ok", data=result.public)    │
│     loop                                                         │
│   else:                                                          │
│     return final response                                        │
└──────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  Tool Registry (Python) — see §5 for v1 catalog                  │
└──────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  ParentActionLog — also called by direct API endpoints (§6)      │
└──────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  Response envelope (extended ChatResponse):                      │
│   {                                                              │
│     message: "...",                                              │
│     proposals: [{tool, args, label, danger, token}],             │
│     receipts:  [{tool, args, result, undo_token}],               │
│     legacy_card: {id, context} | null,    // shield/block        │
│     // existing fields kept for back-compat                      │
│   }                                                              │
└──────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  iOS Chat                                                        │
│   - render message bubble                                        │
│   - render each proposal as ProposalCard (Confirm / Skip)        │
│   - render each receipt as ReceiptBubble (Undo with countdown)   │
│   - render legacy_card via existing CardDispatcher (unchanged)   │
└──────────────────────────────────────────────────────────────────┘
```

Two new endpoints support the proposal/revert flows:

- `POST /parent/agent/exec` — parent confirms a ProposalCard. Body:
  `{ token: "..." }`. Server retrieves staged tool call, executes,
  returns receipt with new `undo_token`.
- `POST /parent/actions/{action_id}/revert` — single global revert
  endpoint, used by chat receipts AND Profile UI toasts AND
  shield/block ReceiptCard.

## 4. AgentLoop

Rewrite of `parent_chat.parent_chat()` internals. iOS contract on the
endpoint stays compatible: same `ChatRequest` body, response is a
strict superset of the existing `ChatResponse`.

### 4.1 Pseudocode

```python
async def run_agent(req: ChatRequest, session: AsyncSession) -> AgentResponse:
    history = req.history
    state_snapshot = await _read_kid_state(req.child_device_id)
    proposals: list[Proposal] = []
    receipts: list[Receipt] = []
    last_tool_results: list[ToolResult] = []

    for iteration in range(MAX_ITERATIONS := 3):
        gemini_resp = await gemini_function_calling(
            system_prompt=AGENT_SYSTEM_PROMPT,
            state_snapshot=state_snapshot,
            history=history,
            user_message=req.message if iteration == 0 else None,
            tool_results=last_tool_results if iteration > 0 else None,
            tools=TOOL_REGISTRY.declarations(),
        )

        if not gemini_resp.tool_calls:
            return AgentResponse(
                message=gemini_resp.text,
                proposals=proposals,
                receipts=receipts,
                legacy_card=None,
            )

        last_tool_results = []
        for call in gemini_resp.tool_calls:
            tool = TOOL_REGISTRY[call.name]
            if tool.requires_confirm and not _was_authorized(history, call):
                token = ProposalStore.stage(call)
                proposals.append(Proposal(
                    tool=call.name, args=call.args,
                    label=tool.label_for(call.args), danger=tool.danger,
                    token=token,
                ))
                last_tool_results.append(
                    ToolResult(call_id=call.id, status="awaiting_user_confirm")
                )
                continue

            try:
                result = await tool.fn(**call.args)
                action_id = ParentActionLog.record(
                    action_type=call.name, args=call.args,
                    inverse_action=tool.revert_tool, inverse_args=tool.revert_args(call.args, result),
                    source="agent",
                )
                receipts.append(Receipt(
                    tool=call.name, args=call.args,
                    result_summary=result.public_summary,
                    undo_token=action_id,
                ))
                last_tool_results.append(
                    ToolResult(call_id=call.id, status="ok", data=result.public)
                )
            except Exception as exc:
                last_tool_results.append(
                    ToolResult(call_id=call.id, status="error", error=str(exc))
                )

    return AgentResponse(
        message="I tried a few approaches but couldn't finalize. What would you like me to do?",
        proposals=proposals, receipts=receipts, legacy_card=None,
    )
```

### 4.2 System prompt outline

```
You are Evlin, an AI parental copilot. The parent is having a chat
with you about their child(ren). You have access to tools that read
and modify the child's state.

CURRENT STATE (auto-injected each turn):
{json.dumps(state_snapshot)}

DEFAULT POSTURE: listen and inform. Most parent messages are venting,
asking questions, or thinking out loud. Do NOT propose actions
unless one of:
- Parent describes a specific bad thing the child did (e.g. "she hit
  her sister", "he was scrolling past bedtime"). In that case, call
  propose_reflection with a kid-facing rephrasing of the action.
- Parent explicitly asks for help / action ("approve A", "lock his
  iPad", "what should I do about Y" — for Y, propose; for ambiguous
  questions, ask).
- Parent reviews are explicitly invited ("look at today's tasks").

AMBIGUITY HANDLING:
- Multi-child family + parent uses pronoun without naming → ask which
  child in natural language, do NOT pick one.
- Single-child family + pronoun → resolve to that child silently.
- Missing required arg → ask in chat, do NOT call the tool.

TOOL CONFIRMATION:
- Tools marked requires_confirm=True are wrapped in a confirmation
  card before they actually run. You can call them as if they ran,
  but the parent will see a "Confirm" / "Skip" UI before execution.
- If the parent has explicitly authorized a batch ("yes do all three",
  "approve everything") in their previous message, you may skip
  per-item confirmation by including authorize_batch=True in the call.

EMPATHY:
When the parent describes frustration, anger, or sadness, acknowledge
it before any tool call. One sentence is enough. Don't lecture.
```

(Final system prompt will be longer and include examples; this is the
shape.)

### 4.3 `_was_authorized` heuristic

Scans the last 1-2 parent messages for an authorization phrase that
matches the tool category (e.g. parent said "approve all of them"
within the last turn → `approve_task` for any task is authorized).
Conservative: when in doubt, return False so a card still appears.
Implementation can start as keyword match + tool category map; refine
later.

### 4.4 State snapshot

Auto-included so AI doesn't need to call `get_kid_state` on every
turn. Trimmed JSON: child name, time pool, list of tasks (id, title,
status, phase, has_photo, has_note, has_bypass), reflection request
summary (no quiz body), bypass requests, recent receipts (last 5).
Photos are NOT included — `review_submissions` is the gateway for
multimodal.

## 5. Tool registry

### 5.1 Declaration format

```python
@tool(
    name="approve_task",
    description=(
        "Mark a kid's submitted task as completed. The kid sees the green "
        "'Approved!' screen immediately and the time pool may unlock more "
        "screen time."
    ),
    requires_confirm=True,
    danger="medium",
    revert_tool="request_redo",
    label=lambda args: f"Approve task {args['task_id'][:8]}",
)
async def approve_task(child_id: UUID, task_id: UUID, *, authorize_batch: bool = False) -> ToolResult:
    ...
```

`@tool` populates a registry dict. JSON schemas for Gemini's
function-calling protocol are derived from the function signature
(stdlib `inspect` or pydantic-decorator).

### 5.2 v1 catalog

| Tool | Confirm | Danger | Inverse | Notes |
|------|---------|--------|---------|-------|
| `get_kid_state` | no | — | — | Fallback if AI wants more detail than snapshot |
| `list_pending_submissions` | no | — | — | Filtered view |
| `review_submissions` | no | — | — | **Multimodal**. Loads each photo URL, calls Gemini with image bytes, returns per-task verdict |
| `assign_task` | no | low | `delete_task` | Adding a task is reversible |
| `delete_task` | yes | medium | `assign_task` (with original args) | |
| `approve_task` | yes | medium | `request_redo` (reason="Reverted") | |
| `request_redo` | yes | medium | `approve_task` | |
| `propose_reflection` | yes | high | `cancel_reflection` | Replaces current chat R1 path |
| `cancel_reflection` | yes | medium | (none — kid sees relief, no inverse) | |
| `approve_reflection` | yes | medium | (none) | |
| `respond_bypass` | yes | medium | `respond_bypass` (with flipped decision) | |
| `lock_device` | yes | high | `unlock_device` | |
| `unlock_device` | no | low | `lock_device` (best-effort, original duration may be lost) | |
| `shield_app` | depends | — | `unshield_app` | **Forwards to existing dispatcher**. Confirmation, if any, lives in the legacy A1/B1/D1 etc cards. Once the shield Command is created, dispatcher logs to `ParentActionLog` with inverse `unshield_app` so Undo works on shield receipts too (see §6.3). |
| `unshield_app` | no | low | `shield_app` (best-effort, original duration may be lost) | Same dispatcher forward. |

Adding a new tool later (e.g. `add_calendar_event`) is a single
function definition with its decorator — no agent loop changes
required. iOS automatically renders generic ProposalCard / Receipt
unless a typed UI is added on top.

### 5.3 `review_submissions` shape

```python
async def review_submissions(child_id: UUID) -> ToolResult:
    state = bigkid_store.get_state(child_id)
    submitted = [t for t in state.tasks if t.phase == "submitted"]
    if not submitted:
        return ToolResult(public={"submissions": []})
    photo_payloads = [download_photo_bytes(t.evidence_photo_url) for t in submitted]
    verdicts = await gemini_multimodal(
        prompt=REVIEW_PROMPT,
        items=[{"task": t.dict(), "photo_bytes": photo_payloads[i]} for i, t in enumerate(submitted)],
    )
    # verdicts: [{task_id, looks_done: bool, confidence: float, note: str, recommend_action: "approve" | "redo"}]
    return ToolResult(public={"submissions": verdicts})
```

The agent then sees these verdicts in the next iteration and can
propose `approve_task` / `request_redo` for each.

## 6. ParentActionLog (Undo for chat-agent receipts)

Scope: only the chat agent writes to and reverts from this log. Profile
UI mutations and the shield/block dispatcher are unaffected.

### 6.1 Service

```python
class ParentActionLog:
    """In-memory log of parent mutations with inverse handles.
    Same v1 caveat as BigKidStore — wiped on Railway restart. Phase 13
    persists alongside it."""

    @dataclass
    class Entry:
        action_id: str
        action_type: str        # tool name or 'profile_approve_task' / 'shield_app'
        args: dict
        inverse_action: str | None
        inverse_args: dict
        source: str             # "agent" | "profile_ui" | "shield_dispatcher"
        created_at: datetime
        expires_at: datetime    # default: created_at + 60s
        reverted: bool = False

    _entries: dict[str, Entry] = {}

    def record(action_type, args, inverse_action, inverse_args, source) -> str: ...
    def revert(action_id: str) -> ToolResult: ...
    def gc(): ...   # purge expired entries
```

### 6.2 Single revert endpoint

```
POST /parent/actions/{action_id}/revert
```

Server:
1. Look up entry; 410 if missing or expired.
2. Mark entry as `reverted=true`.
3. Run the inverse action — internally calls the same code path the
   original would have used (e.g. revert of `approve_task` →
   `bigkid_store.parent_review_task(decision="redo", reason="Reverted")`).
4. Return a new receipt (with its own `undo_token`, so reverts can be
   re-reverted).

## 7. iOS changes (chat only)

### 7.1 New components

- `Components/ConfirmationCards/ProposalCard.swift` — generic. Title +
  body + danger color + Confirm / Skip buttons. Tapping Confirm POSTs
  `/parent/agent/exec` with the proposal token. On success replaces
  the card in-place with a ReceiptBubble.
- `Components/ReceiptBubble.swift` — green check + one-line summary +
  Undo button with 60s countdown. Tapping Undo POSTs
  `/parent/actions/{id}/revert`. Greys to "Done" on expiry.

### 7.2 Modified files

| File | Change |
|------|--------|
| `Models/ChatModels.swift` | `ChatMessage` gains `proposals: [Proposal]`, `receipts: [Receipt]` |
| `Services/AgentClient.swift` (new) | `executeProposal(token)`, `revertAction(actionID)` |
| `Services/APIClient.swift` | `ChatResponse` gains optional `proposals`, `receipts`, `cancelled_proposals` fields |
| `Views/Chat/ChatViewModel.swift` | Decode new envelope; render proposal cards + receipt bubbles below message bubble |
| `Views/Chat/ChatView.swift` | Layout for the three response sections (text → proposals → receipts) |

### 7.3 Behavior unchanged

- Profile UI direct buttons (Approve / Redo / Create / Allow Bypass)
  stay exactly as they are. No toast, no Undo. They write to
  BigKidStore directly via `/parent/task/...` etc. and return their
  existing response shapes — the Phase 12 wiring is not touched.
- The shield/block dispatcher and its Receipt cards stay as-is; no
  Undo button.
- Existing A1-G1 + R1 confirmation cards STAY. Agent emits
  `legacy_card` for those paths via the `shield_app` tool's forward
  to the dispatcher (handled in `parent_chat.py` adaptation layer).

## 8. Failure / edge cases

| Case | Behavior |
|------|----------|
| AI calls invalid tool / args | Tool raises `ToolValidationError`, fed back to AI as `status=error` next iteration. AI can retry or give up; iteration cap = 3 prevents loop. |
| Iteration cap hit | Return a plain "I couldn't finalize" message + any receipts already produced (don't lose progress). |
| Proposal token expired (10 min) | `/agent/exec` returns 410. iOS shows "This action expired. Try again." — card stays visible (so parent isn't confused by silence). |
| Undo token expired (60 s) | `/actions/{id}/revert` returns 410. iOS shows "Too late to undo." — Undo button greys. |
| Gemini API 5xx / rate limit | httpx retries 3x with backoff. Final failure → response with empty proposals + plain "AI temporarily unavailable" message. Already-executed receipts are preserved. |
| Multi-child ambiguity | AI asks naturally in chat, no tool call. Single-child + pronoun resolves silently. |
| Parent reverses themselves mid-thread | AI sees the new message + history, calls inverse tool or marks an unconfirmed proposal cancelled. New `cancelled_proposals: [token]` field in response — iOS greys the original card. |
| Tool succeeds but kid offline | Out of scope — backend writes succeed regardless of kid device state. Phase 13 persistence is the real fix. |
| Concurrent confirmations | Server processes serially; both produce independent receipts. No locking needed (BigKidStore writes are independent). |
| AI safety filter triggers | Empty tool_calls + empty text from Gemini → fallback message "I couldn't process that. Could you rephrase?" |
| Old iOS build | New fields `proposals` / `receipts` / `legacy_card` / `undo_token` are all optional → old build ignores them, agent falls back to plain message UX. No crash. |

## 9. Out of scope (deferred)

- **Persistent storage** — `BigKidStore`, `ParentActionLog`,
  `ProposalStore` all in memory. Wiped on Railway redeploy. Phase 13.
- **Vision quality / cost optimization** — `review_submissions`
  re-fetches photos every call. Cache layer is a follow-up.
- **Cross-conversation memory** — agent doesn't remember previous
  chats beyond the rolling 10-message history sent per request. Long-
  term memory is out of scope.
- **Calendar / Rules / Events tools** — architecture supports them;
  individual specs to follow.
- **Multi-language prompts** — system prompt is English; AI handles
  Chinese input/output via Gemini natively, no special routing.

## 10. Migration / rollout

1. Land all backend changes behind a feature flag `AGENT_ENABLED`.
   Default off; turning on routes `/parent/chat` to the new
   AgentLoop, off keeps the existing verb-table path.
2. iOS ships the new ProposalCard + ReceiptBubble + Undo UI. With
   flag off, none of the new fields are populated and the new
   components don't render.
3. Internal testing with flag on for a few cycles.
4. Remove the verb-table path + flag once the agent path is stable.
5. The shield/block dispatcher, the R1 card, and all existing
   ConfirmationCards are PRESERVED indefinitely (they implement
   functionality the agent delegates to).

## 11. Known issues called out

- BigKidStore + ParentActionLog both in-memory. Every Railway redeploy
  wipes them. The kid app's local `KidEvidenceCache` partly papers
  this over for photos; nothing papers it over for the parent. Real
  fix: SQLite or Postgres migration. Listed in §9 as deferred.
- 60s Undo window is conservative. Could expand to 5m later. Not
  parameterized in v1 to avoid premature config.
- `_was_authorized` heuristic is best-effort. False positives mean a
  destructive action runs without a card; false negatives mean parent
  has to click Confirm even after saying "yes do them all". Both
  failure modes are recoverable (Undo button still applies). We
  iterate on the heuristic post-launch.
