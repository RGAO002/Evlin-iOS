# Multi-Action Staging + Unlock Disambiguation + ask_pick Primitive — Design Spec

**Date:** 2026-05-07
**Status:** Draft awaiting review
**Branch:** `feat/three-tier-lock`

## Problem

Three pain points compound into a degraded chat UX:

1. **Multi-action commands silently drop work.** When a parent says "lock 知乎 and 懂球帝 for 15 min" or "shield entertainment but not bilibili", Gemini emits two parallel `shield_app` / `unshield_app` tool calls in one turn. The agent loop short-circuits on the first call's `legacy_gemini_action` (`agent_loop.py:167-175`), returns immediately, and the second call is discarded. Result: only the first target gets locked/unlocked; the parent has no signal that the second was lost.

2. **Bare unlock requests are unactionable.** When a parent has 2+ active shields (e.g. Entertainment category + Instagram app + a saved list) and says "unlock", there is no UI for picking which to lift. Today `unshield_app` requires a target; without one, dispatch fails or routes ambiguously.

3. **No primitive for AI-driven dynamic choices.** Hardcoded confirmation cards (D1/D2/D3/D4/A1/B1/E1/F1) cover high-frequency parameter choices, but compound ad-hoc situations ("which of these 5 categories should I allow through?", "assign to which of 3 children?") have no surface — Gemini can't show the parent a contextual checkbox.

App icons are also missing throughout the receipt and proposal UI — names render as plain text where `Label(token)` would render Apple's actual app icon next to the name.

## Goals

- A parent can say "lock A and B" and both apps stage as proposals in one bundled card; `tag` flow per-row works inside that card.
- A parent can say "unlock" with N active shields and get a static U1 card listing each shield with its type label, icon, and a checkbox; "Unlock selected" and "Unlock everything" both work.
- Future AI-driven custom choices can be expressed via a generic `ask_pick` tool that the agent calls when it judges the situation warrants user disambiguation.
- Every chat surface that names an app or category renders Apple's icon alongside the name via `Label(token)`.

## Non-goals

- `ManagedSettings.shieldExceptions` for "shield A but not B inside same category". Out of scope (separate task).
- Replacing legacy hardcoded cards (D1/D2/D3/etc.) with `ask_pick`. They stay; `ask_pick` augments for dynamic-list scenarios.
- Two-device production receipt fidelity beyond what the existing ack-status pipeline provides.
- Apple's 15-minute minimum DeviceActivitySchedule clamp UX (separate task — surface "Apple's minimum is 15 min, locked for 15 instead").

## Architecture

Four components, layered:

```
                    ┌──────────────────────────────┐
                    │ 1. agent_loop multi-action   │  ← base primitive
                    │    (remove short-circuit)    │
                    └──────────────────────────────┘
                              ↑           ↑
        ┌─────────────────────┘           └─────────────────────┐
        │                                                       │
┌───────────────────┐                                  ┌─────────────────┐
│ 2. U1 unlock card │                                  │ 3. ask_pick     │
│    (hardcoded,    │                                  │    tool         │
│    chat_resolver  │                                  │    (AI-driven)  │
│    triggered)     │                                  │                 │
└───────────────────┘                                  └─────────────────┘
                              ↑
                              │
                    ┌──────────────────────────────┐
                    │ 4. App icon everywhere       │
                    │    (Label(token).iconOnly /  │
                    │    .titleAndIcon)            │
                    └──────────────────────────────┘
```

Component 1 is a prerequisite for 2 and 3 (both can resolve to N tool calls in one turn). Component 4 is orthogonal — touches every view that displays an app/category name.

## Component 1 — Agent Loop Multi-Action Staging

### Backend changes

**`backend/app/services/agent_loop.py`**

Replace the short-circuit (lines ~160-175) with accumulation:

```python
legacy_actions: list[dict] = []
ask_pick_payloads: list[dict] = []   # Component 3 hooks in here
for call in resp.tool_calls:
    # ... existing tool dispatch
    result = await self.registry.call(call.name, call.args)
    # ...
    if isinstance(result.public, dict):
        if result.public.get("legacy_gemini_action"):
            legacy_actions.append(result.public["legacy_gemini_action"])
            continue
        if result.public.get("ask_pick_payload"):
            ask_pick_payloads.append(result.public["ask_pick_payload"])
            continue
    # Non-legacy, non-ask_pick tool: existing receipts/proposals path
    receipts.append(...)

# After the for-loop:
if legacy_actions or ask_pick_payloads:
    return AgentResponse(
        message="",  # bundled summary built downstream by parent_chat
        proposals=proposals,
        receipts=receipts,
        legacy_gemini_actions=legacy_actions,
        ask_pick_payloads=ask_pick_payloads,
    )
```

**`AgentResponse` model** (`backend/app/services/agent_models.py` or wherever it lives):
- Add `legacy_gemini_actions: list[dict] = []` (new plural field).
- Keep existing `legacy_gemini_action: dict | None = None` as a derived alias = `legacy_gemini_actions[0] if len == 1 else None` for any caller still on the singular path. (Mark deprecated; remove after parent_chat fully migrates.)

**`backend/app/api/routes/parent_chat.py`** — replace the singular branch:

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
```

**New `_stage_legacy_actions`** function:

```python
async def _stage_legacy_actions(
    *, proposal_store, actions, req, message, reasoning, session,
) -> ChatResponse:
    # Group by type — homogeneous bundling per design (mixed shield+unshield → 2 cards)
    by_type: dict[str, list[dict]] = defaultdict(list)
    for a in actions:
        # Eligibility check per action; non-eligible (e.g. type=block, target_kind=all)
        # falls back to the eager dispatch path below.
        if _is_lazy_tag_eligible(a, req.force_confirmations):
            by_type[a["type"]].append(a)
        else:
            # Eager dispatch (existing _handle_gemini_action). Returns a
            # ChatResponse; merge action / receipts into the response we build.
            eager_responses.append(await _handle_gemini_action(...))

    proposals: list[Proposal] = []
    for action_type, group in by_type.items():
        proposals.append(
            _stage_bundled_proposal(
                proposal_store=proposal_store,
                action_type=action_type,   # "shield" | "unshield"
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

**`_stage_bundled_proposal`** (replaces `_stage_legacy_shield_proposal`):

```python
def _stage_bundled_proposal(
    *, proposal_store, action_type, actions, req, message, reasoning,
) -> Proposal:
    chat_context = {
        "message": message,
        "reasoning": reasoning,
        "family_id": str(req.family_id) if req.family_id else None,
        "child_name": req.child_name,
        "child_device_id": str(req.child_device_id) if req.child_device_id else None,
        "force_confirmations": list(req.force_confirmations or []),
    }
    is_unshield = action_type == "unshield"
    tool_name = "unshield_app_legacy" if is_unshield else "shield_app_legacy"

    # New args shape: list of actions, NOT singular gemini_action.
    token = proposal_store.stage(
        tool=tool_name,
        args={"actions": actions},   # ← plural
        chat_context=chat_context,
    )

    # Bundled label: "Shield 2 apps for 15 min" / "Unshield 3 items"
    targets = [a.get("target_request") or "?" for a in actions]
    minutes_set = {a.get("duration_minutes") for a in actions if isinstance(a.get("duration_minutes"), int)}
    duration_suffix = (
        f" for {min(minutes_set)} min"
        if len(minutes_set) == 1 and not is_unshield
        else (" (mixed durations)" if not is_unshield and minutes_set else "")
    )
    verb = "Unshield" if is_unshield else "Shield"
    label = (
        f"{verb} {targets[0]}{duration_suffix}"
        if len(actions) == 1
        else f"{verb} {len(actions)} items{duration_suffix}"
    )

    # Each row's per-action alias data goes in args.rows so iOS can render
    # the multi-row card and run pre-flight per row.
    rows = [
        {
            "target": a.get("target_request") or "",
            "target_kind": a.get("target_kind_hint", "app"),
            "minutes": a.get("duration_minutes") if isinstance(a.get("duration_minutes"), int) else None,
        }
        for a in actions
    ]

    return Proposal(
        tool=tool_name,
        args={"rows": rows},   # iOS reads this for rendering + per-row tag UI
        label=label,
        danger="low" if is_unshield else "medium",
        token=token,
    )
```

### Exec path — `parent_agent.py:_exec_legacy_shield`

Read `args["actions"]` (plural), iterate and dispatch each through `_handle_gemini_action`. Collect per-action responses into a single `ExecResponse` carrying a list of `legacy_actions`:

```python
async def _exec_legacy_shield(*, args, chat_context, session) -> ExecResponse:
    actions = args.get("actions") or [args.get("gemini_action")]   # singular fallback for old proposals
    results = []
    for action in actions:
        if action.get("target_kind_hint") == "app":
            action["force_exact_app"] = True
        # Build per-action ChatRequest from chat_context (existing logic)
        chat_response = await _handle_gemini_action(
            gemini_action=action,
            ...,
        )
        results.append({
            "action": chat_response.action.model_dump(mode="json") if chat_response.action else None,
            "message": chat_response.message,
        })
    return ExecResponse(
        legacy_actions=results,   # ← plural
        message=chat_context.get("message", ""),
        reasoning=chat_context.get("reasoning"),
    )
```

`ExecResponse.legacy_actions: list[dict]` is a new field. Old singular `legacy_action` stays for backwards compat (= `results[0].action` if len == 1, else None).

### iOS changes

**`Models/AgentEnvelope.swift` — `ProposalDTO`**

Existing `args: [String: AnyCodable]`. New convention: `args["rows"]` is a JSON array of `{target, target_kind, minutes}`.

**`Components/ConfirmationCards/ProposalCard.swift`** — refactor to support N rows:

- If `proposal.args["rows"]` is missing or has length ≤ 1, render the existing single-target layout.
- If length > 1, render a multi-row layout:
  ```
  ┌─────────────────────────────────────────┐
  │ 🛡 Shield 2 apps for 15 min             │
  ├─────────────────────────────────────────┤
  │ 🟧 知乎              [⚠ Tag 知乎]        │
  ├─────────────────────────────────────────┤
  │ ✅ 懂球帝                                │
  ├─────────────────────────────────────────┤
  │ [Confirm all]   [Skip]                  │
  └─────────────────────────────────────────┘
  ```
- Each row has its own alias-miss detection (calls existing `extractAliasTarget` per row, but expanded to read from `args["rows"][i]` instead of top-level `args`).
- Tap "Tag X" → opens `CustomTokenPickerView` for that row's target → save → row turns green.
- "Confirm all" disabled until every row passes alias check.

**`Views/Chat/ChatViewModel.swift`** — `extractAliasTarget` becomes `extractAliasTargets` returning `[(target, kind)]` (one per row); `pendingAliasMisses` becomes keyed by `(proposalToken, rowIndex)` to track per-row state.

**`AgentClient.swift` / `AgentExecResult`** — add `legacyActions(actions: [APIClient.ChatActionResponse], message: String?, reasoning: String?)` case for plural.

**`ChatViewModel.confirmProposal`** — when receiving `legacyActions`, append one ChatMessage per result, each with its own commandID + start its own ack-poll. Receipts render as separate ReceiptCards.

### Failure handling

Per design choice: **independent per action**. Each sub-action has its own Command, its own ack, its own receipt. One failure doesn't block others; one success doesn't get rolled back if another fails. Parent sees a vertical stack of receipt cards, mixed status (green / red / yellow).

### Edge cases

- **Empty rows after dedup**: shouldn't happen (Gemini won't emit duplicates), but if it does, drop dupes by target + kind in `_stage_bundled_proposal`.
- **All eligible + some non-eligible mixed**: split — eligible go through bundled proposal, non-eligible go through eager dispatch. Both responses merge into one `ChatResponse` with both `proposals` and `action`.
- **D1 (missing duration) on multi-action**: if any one action has `duration_state="missing"`, the WHOLE bundle bounces back as D1 (asks duration once, applies to all). Handled by checking shared duration state before staging.

---

## Component 2 — U1 Unlock Disambiguation Card

### Trigger logic (chat_resolver path)

When `chat_resolver._route_unshield` sees:
- `target_request` is empty / "everything" / "all" with `target_kind_hint` ∈ {"all", None}
- AND backend's last-known kid effective state shows ≥ 2 active shields

→ return `DispatchResult(requires_card="U1", u1_shield_list=[...])` instead of routing to `unshield_all`.

If only 1 active shield, route directly to that specific unshield. If 0, return a `receipt_only_text="Nothing is locked right now."`.

### Backend storage of effective state

The kid posts `effectiveState` with each ack (already wired). Backend persists the **most recent** effectiveState per `child_device_id` (new column on Device or new table `device_effective_state`):

```sql
ALTER TABLE evlin_devices ADD COLUMN last_effective_state JSONB;
ALTER TABLE evlin_devices ADD COLUMN last_effective_state_at TIMESTAMP WITH TIME ZONE;
```

Updated in `child_device.py:ack_command` when `req.detail.effective_state` is present.

`_route_unshield` queries this column for the bundle's `child_device_id`.

### U1 card payload

`CardContext` (Backend → iOS) gets a new field `u1_shield_list`:

```python
class CardContext(BaseModel):
    # ... existing
    u1_shield_list: list[dict] | None = None   # [{kind, display_name, expires_at_iso}]
```

Each shield dict:
```json
{
  "kind": "app" | "category" | "list" | "all",
  "display_name": "Instagram",
  "bundle_id": "com.burbn.instagram",   // optional, for app — helps iOS resolve token
  "expires_at_iso": "2026-05-07T16:19:00Z"   // optional
}
```

### iOS — U1 card rendering

**`Components/ConfirmationCards/U1Card.swift`** (new file):

```
┌─────────────────────────────────────────┐
│ Unlock which one?                       │
├─────────────────────────────────────────┤
│ [✓] 🟦 Instagram                        │
│       App · Unlocks 4:19 PM             │
├─────────────────────────────────────────┤
│ [ ] 🟧 Entertainment                    │
│       Category · Until you unlock        │
├─────────────────────────────────────────┤
│ [ ] 📋 Bedtime apps                     │
│       List · Unlocks 10:00 PM            │
├─────────────────────────────────────────┤
│ [Unlock selected] (disabled if 0 picked)│
│ [Unlock everything]                     │
│ [Cancel]                                │
└─────────────────────────────────────────┘
```

Row layout:
- Big text: `display_name`
- Small grey text below: `<Type> · <Expires line>`
- Leading icon: per `kind`
  - `app` → `Label(token).labelStyle(.iconOnly)` if token resolvable via LocalAliasStore, else `Image(systemName: "app.fill")`
  - `category` → `Image(systemName: "square.grid.2x2.fill")`
  - `list` → `Image(systemName: "list.bullet.rectangle.fill")`
  - `all` → `Image(systemName: "iphone")`
- Trailing: SwiftUI `Toggle` rendered as checkbox style

Buttons:
- **Unlock selected** — primary, disabled when 0 checked. Sends back `force_confirmations=["U1:selected:<idx,idx,...>"]`. Backend re-routes: stages a multi-action proposal with one `unshield_app` per selected item, runs through Component 1's bundled exec path.
- **Unlock everything** — secondary, always enabled (assuming N ≥ 1). Sends back `force_confirmations=["U1:all"]`. Backend routes to `unshield_all`.
- **Cancel** — dismisses card, no chat update.

### Backend round-trip on U1 confirm

iOS sends `POST /parent/chat` with the original message text + `force_confirmations=["U1:selected:0,2"]` (or `["U1:all"]`). Parent_chat parses the U1 marker:

```python
u1_marker = next((fc for fc in req.force_confirmations or [] if fc.startswith("U1:")), None)
if u1_marker:
    return await _handle_u1_confirm(u1_marker, req, session)
```

`_handle_u1_confirm`:
- `U1:all` → dispatch `unshield_all` → queue Command → return ChatResponse with command_id.
- `U1:selected:0,2` → look up the U1 card's stored shield_list (cached in proposal_store under a U1 token, or re-derived from current effectiveState), build N `unshield_app` actions for indices 0 and 2, dispatch each → return ChatResponse with `proposals=[bundled_unshield_proposal]` (Component 1 plumbing).

The U1 card's shield_list **must be cached at U1-display time** so an interleaving shield doesn't shift indices. Use a short-lived (60s) entry in ProposalStore keyed by a U1 token returned in the original card response.

### Edge cases

- **Effective state stale** (kid hasn't acked recently): if `last_effective_state_at` > 5 min old, fall back to listing whatever Commands the backend has issued recently with no `unshield` ack yet. Honest fallback; mark each row with "May be stale" annotation.
- **Concurrent shield while U1 open**: cached list is the source of truth; the new shield isn't shown. Acceptable — parent can re-ask for unlock after dismissing.
- **Parent tags U1 with "everything but X"**: out of scope. Parent uses checkboxes to express it (uncheck X, leave the rest).

---

## Component 3 — `ask_pick` Tool Primitive

### Tool definition

**`backend/app/services/agent_tools/ask_pick_tool.py`** (new):

```python
@tool(
    name="ask_pick",
    description=(
        "Show the parent a list of items with checkboxes and wait for "
        "their selection. Use ONLY when the situation truly requires "
        "user disambiguation (multiple plausible interpretations, no "
        "default). Examples: \n"
        "  - 'Allow which apps through this lock window?'\n"
        "  - 'Assign this routine to which children?'\n"
        "Do NOT use for fixed-option choices (those have hardcoded "
        "cards: D1 duration, D2 'everything' meaning, A1 destructive "
        "confirm). Do NOT use for unlock disambiguation (that's the "
        "U1 card, fired automatically).\n"
        "\n"
        "After the parent picks, you'll see their selection in the "
        "next turn as a system note `ask_pick_result: [...]` with "
        "the indices they checked. Use that to decide what tool calls "
        "to emit next."
    ),
    requires_confirm=False,
    danger="low",
    registry=GLOBAL_REGISTRY,
)
async def ask_pick(
    items: list[dict],   # [{label: str, sublabel: str?, icon_hint: str?, ref: str}]
    instruction: str,
    primary_label: str = "Confirm selection",
    secondary_label: str | None = None,   # optional "Apply to all" / "Pick everything"
    allow_multi: bool = True,
) -> ToolResult:
    """Returns a marker proposal that iOS renders as an ask_pick card.
    On parent action, the pick result is fed back into the next turn
    via the chat-context replay machinery."""
    return ToolResult(
        public={
            "ask_pick_payload": {
                "items": items,
                "instruction": instruction,
                "primary_label": primary_label,
                "secondary_label": secondary_label,
                "allow_multi": allow_multi,
            }
        },
        public_summary="",
    )
```

### `items` shape

Each item:
```json
{
  "label": "Instagram",         // big text
  "sublabel": "App · ~3 hr/day", // grey text below; optional
  "icon_hint": "app:Instagram", // "app:<name>" → resolve via LocalAliasStore; "system:gear" → SF Symbol; "category:games" → category token; null → no icon
  "ref": "ig"                    // opaque ID returned to agent in next turn
}
```

`ref` is what the agent sees back. Agent can encode whatever (bundle id, list name, internal token) — iOS doesn't care.

### Card UI

Same row layout as U1 (big label / grey sublabel / icon / checkbox), but:
- Title from `instruction`
- Bottom buttons:
  - `primary_label` (always present)
  - `secondary_label` (only if non-null)
  - "Cancel"
- If `allow_multi=false`, checkboxes become radio buttons (single-select).

### Round-trip

iOS sends parent's selection back as a normal chat round-trip with a special system-style annotation:

```python
POST /parent/chat
{
    "message": "<original parent text>",
    "ask_pick_result": {
        "ref_token": "<token from original ask_pick proposal>",
        "selected_refs": ["ig", "fb"],
        "secondary_invoked": false,
    }
}
```

`parent_chat` injects this into the next agent turn as a tool-result message:

```python
if req.ask_pick_result:
    # Feed as the previous turn's ask_pick tool result
    prior_tool_results = [{
        "call_id": "...",
        "name": "ask_pick",
        "status": "ok",
        "data": {"selected_refs": [...], "secondary_invoked": ...},
    }]
```

Agent resumes with that context and emits whatever follow-up actions.

### Why not use `ask_pick` for U1?

U1 fires reflexively on a known phrase pattern with deterministic data. Routing it through Gemini (call ask_pick → response → parse → next turn) adds latency and an LLM unpredictability surface for zero benefit. U1 stays static; `ask_pick` covers genuinely-ambiguous-needs-LLM-judgment cases.

### Edge cases

- **Agent abuses `ask_pick`** (asks for trivial choices): tool description sternly says "ONLY when truly required". Monitor in logs. If overused, tighten description or add a guard.
- **Cancel**: agent sees `secondary_invoked: false, selected_refs: []`. Tool description says "an empty selection means the parent cancelled — usually you should reply with a brief acknowledgment, not retry."

---

## Component 4 — App Icon Everywhere

### Pattern

Replace every `Text(displayName)` for an app/category name with:

```swift
@ViewBuilder
private func nameWithIcon(_ name: String, kind: AliasKind = .app) -> some View {
    if kind == .app, let token = LocalAliasStore.shared.applicationToken(forLookupKey: name) {
        Label { Text(name) } icon: { Label(token).labelStyle(.iconOnly) }
            .labelStyle(.titleAndIcon)
    } else if kind == .category, let token = LocalAliasStore.shared.categoryToken(forName: name) {
        Label { Text(name) } icon: { Label(token).labelStyle(.iconOnly) }
            .labelStyle(.titleAndIcon)
    } else {
        Label(name, systemImage: kind == .category ? "square.grid.2x2.fill" : "app.fill")
    }
}
```

### Touchpoints

- `ReceiptCard.swift` — `confirmedExact`, `confirmedFallback`, `failedAppNotConfigured`, `failedCategoryNotConfigured` lines.
- `ProposalCard.swift` — single-target row + multi-row entries (Component 1's refactor).
- `U1Card.swift` (new) — each row.
- `AskPickCard.swift` (new) — each row when `icon_hint` is `app:<name>` or `category:<name>`.
- `AliasManagementView.swift` — Saved tags list (currently text-only; add icons).
- `ReceiptBubble.swift` — agent receipts in chat history.

### Reusable helper

Create `Components/Helpers/NameWithIcon.swift` exposing the function above. Centralizes the LocalAliasStore lookup + Label fallback pattern so a future change (e.g. switching to a token-cache layer) is a one-file edit.

### Caveats

- Apple's `Label(token)` ignores `.font` and `.foregroundColor` modifiers (per developer forum). The text part rendered by Apple uses Apple's defaults. To color the text, render the name as our own `Text(name)` separately and use `Label(token).labelStyle(.iconOnly)` for the icon only — which is what the helper does.
- Token reverse-lookup may miss for tokens that haven't been stored (no hydrate, no prior tag). Fallback to SF Symbol icon. No harm.

---

## Data Flow

### Multi-action shield flow ("lock A and B for 15 min")

```
Parent:  "lock 知乎 and 懂球帝 for 15 min"
   ↓
agent_loop:
    Gemini.generate → tool_calls: [shield_app(知乎,15), shield_app(懂球帝,15)]
    for call: each returns legacy_gemini_action → accumulate
    return AgentResponse(legacy_gemini_actions=[...,...])
   ↓
parent_chat._stage_legacy_actions:
    group by type → both shield → 1 bundle
    _stage_bundled_proposal → 1 token, args.rows = [{知乎, app, 15}, {懂球帝, app, 15}]
   ↓
ChatResponse(proposals=[Proposal{label="Shield 2 apps for 15 min"}])
   ↓
iOS ChatViewModel:
    pre-flight extractAliasTargets (per row) → e.g. 知乎 missing, 懂球帝 has alias
    render multi-row ProposalCard with "Tag 知乎" button on row 1
   ↓
Parent: tap Tag 知乎 → CustomTokenPickerView → select Zhihu → save
   ↓ (row 1 now green; Confirm all enabled)
Parent: tap Confirm all
   ↓
AgentClient.executeProposal(token)
   ↓
parent_agent._exec_legacy_shield:
    args.actions has 2 items
    for each: set force_exact_app=True, _handle_gemini_action → ChatResponse with command_id
   ↓
ExecResponse(legacy_actions=[
    {action: {command_id: c1, duration_minutes: 15, target_display: 知乎}, message: ...},
    {action: {command_id: c2, duration_minutes: 15, target_display: 懂球帝}, message: ...},
])
   ↓
iOS confirmProposal:
    for each result: append ChatMessage(commandID, .pending) + startAckPoll
   ↓
Two ack-polls in flight; receipt cards update independently as each kid-ack arrives.
```

### U1 flow ("unlock" with N=3)

```
Parent: "unlock"
   ↓
parent_chat:
    Gemini → unshield_app(target=None, kind=all) → legacy_gemini_action
   ↓
chat_resolver._route_unshield:
    kind in {all, None} + bare unshield → query device.last_effective_state
    last_effective_state has 3 active shields
    return DispatchResult(requires_card="U1", u1_shield_list=[...])
   ↓
parent_chat:
    cache shield_list in proposal_store under u1_token (60s TTL)
    return ChatResponse(action=ChatAction(card_id="U1", u1_token="..."))
   ↓
iOS CardDispatcher:
    case .U1 → render U1Card with rows from shield_list
   ↓
Parent: check rows 0 and 2, tap "Unlock selected"
   ↓
POST /parent/chat with force_confirmations=["U1:selected:0,2"], original message
   ↓
parent_chat._handle_u1_confirm:
    pop u1_token from proposal_store → shield_list
    build [unshield_app(shield_list[0]), unshield_app(shield_list[2])] gemini_actions
    flow through _stage_legacy_actions (Component 1) → bundled_unshield_proposal
   ↓
iOS renders bundled multi-row unshield ProposalCard. Parent confirms → parallel exec.
```

### ask_pick flow (custom AI question)

```
Parent: "set a 1h study window starting now"
   ↓
agent_loop:
    Gemini reasons: "I should ask which subjects/apps to allow through" → ask_pick(...)
   ↓
ask_pick tool returns ToolResult(public={"ask_pick_payload": {...}})
   ↓
agent_loop sees ask_pick_payload (new branch alongside legacy_gemini_action):
    stage as proposal with tool="ask_pick" and the payload
    return AgentResponse(proposals=[ask_pick_proposal])
   ↓
iOS renders AskPickCard.
   ↓
Parent picks → POST /parent/chat with ask_pick_result={selected_refs: [...]}
   ↓
parent_chat injects ask_pick_result into next agent turn as prior tool result.
   ↓
Agent resumes: "OK they picked maths and reading; emit shield_app for everything else."
   ↓
... continues into Component 1's multi-action staging
```

---

## Error Handling

| Scenario | Behavior |
|---|---|
| Multi-action: row alias miss after picker | Row stays with "Tag X" button, Confirm all disabled |
| Multi-action: one exec fails (kid throws) | That row's receipt → red; siblings continue independently |
| Multi-action: D1 missing on one action | Whole bundle bounces to D1; on confirm, all actions re-stage with the picked duration |
| U1: cached shield_list expired (>60s) | "Unlock list expired, please ask again" + dismiss card |
| U1: kid effective state >5 min stale | Show list with per-row "May be stale" tag; backend logs warning |
| ask_pick: parent cancels | Empty selection passed back; agent description tells it to acknowledge gracefully |
| ask_pick: agent emits malformed items | Validation in tool: required keys (`label`, `ref`), max length 20 items, fail-fast with tool error |
| App icon: token lookup fails | Fall back to SF Symbol — never blocks rendering |

## Testing

### Backend unit tests

- `tests/services/test_agent_loop.py`: 2 shield_app calls in one turn → both accumulate, no short-circuit.
- `tests/api/test_parent_chat_multi_action.py`: bundled proposal returned with `args.rows` length 2; mixed shield+unshield → 2 proposals; D1 fallback when one row missing duration.
- `tests/services/test_chat_resolver_u1.py`: bare unshield + N=3 effective shields → requires_card="U1"; N=1 → direct route; N=0 → receipt-only "Nothing locked".
- `tests/api/test_parent_chat_u1_confirm.py`: U1:all → unshield_all command; U1:selected:0,2 → bundled unshield with 2 rows.
- `tests/api/test_parent_chat_ask_pick.py`: ask_pick tool stages proposal; round-trip via ask_pick_result is fed into next turn.

### iOS unit tests

- `LazyTagTests`: `extractAliasTargets` returns one per row from multi-row proposal.
- `ProposalCardTests` (new): multi-row layout disables Confirm with N misses; enables when all green.
- `U1CardTests` (new): primary disabled when 0 selected; secondary always enabled; Cancel dismisses.
- `AskPickCardTests` (new): single-select mode renders radio buttons; multi-select renders checkboxes.

### Manual E2E

Single-device test mode:
1. Tag IG and Bilibili in Saved tags.
2. Say "lock IG and Bilibili for 15 min" → bundled shield card appears with both rows green → Confirm all → switch to K mode → both apps shielded → switch back to P → both receipts confirmed.
3. With both shielded + Entertainment shielded as category, say "unlock" → U1 card shows 3 rows → check IG only → Unlock selected → only IG unshielded.
4. Say "unlock" → U1 with 2 left → Unlock everything → all clear.

## Migration & Rollout

1. **Backend deploy first** (Component 1 backend changes) — backwards compat: singular `legacy_gemini_action` still served from the new plural list when len == 1.
2. **iOS deploy** (Component 1 iOS changes) — handles both singular and plural exec responses.
3. **U1 backend** (Component 2 backend) — adds `last_effective_state` storage + chat_resolver routing.
4. **U1 iOS** (Component 2 iOS) — new card + dispatcher case.
5. **ask_pick** (Component 3) — backend tool + iOS card. Lower priority; can land in a follow-up.
6. **App icons** (Component 4) — refactor in parallel; one PR per major view.

Order matters: Component 1 must deploy before 2 (U1 confirm depends on multi-action staging) and 3 (ask_pick result can resolve to multiple actions).

## Out of scope (deferred)

- ManagedSettings `shieldExceptions` for "shield A but not B" within a category.
- ActionExecutor verify-before-success (catching stale ApplicationToken silent no-op shields).
- Replacing legacy hardcoded D1/D2/D3/D4/A1/B1/E1/F1 cards with `ask_pick`.
- 5-min lock UX clamp (Apple's 15-min DeviceActivitySchedule minimum).
- Two-device push-based receipt updates (currently parent-side polling only).

## Open questions

None — all design forks have been resolved during brainstorming. Reviewer should flag anything that feels under-specified.
