# Lazy Tagging — Design Spec

**Date:** 2026-05-06
**Branch:** feat/three-tier-lock
**Author:** Claude (with extensive design discussion)

## Problem

Apple's FamilyControls framework gives apps `ApplicationToken` — an opaque blob that uniquely identifies an installed app. The token can be passed to `ManagedSettingsStore.shield.applications` to actually shield the app. But the token does NOT come with a name or bundle ID accessible to the main app:

- `Application(token:).bundleIdentifier` → always nil in main app and most extension types
- `FamilyActivitySelection.applications[*].localizedDisplayName` → nil on iOS 18 + iPhone XS Max + `.individual` auth (verified empirically)
- `Application.localizedDisplayName` is only non-nil inside `ShieldConfigurationDataSource` extension (per Apple Frameworks Engineer, forum 685498)
- `DeviceActivityReportExtension` is severely sandboxed; it can read names internally but cannot write them back to the main app via App Group UserDefaults, shared file, CFPreferences, or any other channel (verified empirically + Apple Developer Forums 728044, 742109)

So when a parent says "lock Instagram" in chat, the iOS main app receives `target_request="Instagram"` but cannot programmatically locate the matching `ApplicationToken`.

## Goal

Build the simplest possible UX where:
1. Parent says "lock IG" in chat → AI normalizes to "Instagram" → iOS resolves Instagram → ApplicationToken → shield works
2. The first time iOS doesn't recognize an app name, parent does a 1-tap binding ("Tag Instagram"); after that, every future "lock IG" / "lock Instagram" hits instantly
3. Custom picker UI shows already-known tokens via `Label(token)` (which renders icon + name on user's device), single-select binding
4. Apple's `FamilyActivityPicker` is the fallback to ADD a new token to selection if the parent doesn't see it in the custom list

## Non-Goals

- **Auto-tagging from DeviceActivityReport extension** — Apple's privacy sandbox blocks this categorically. Don't pursue.
- **Bulk OCR onboarding** — Was explored, complex multi-screenshot flow, rejected. May revisit as v2 onboarding accelerator.
- **Std-mode two-device alias sync** — Production std mode (parent + kid on separate physical devices) requires aliases to sync from parent's tag flow to kid's LocalAliasStore. This spec assumes single-device test mode OR `.child` Max mode. Std two-device alias sync is deferred to a separate spec.
- **Multi-target merged tag UI** — When parent says "shield IG and TikTok", v1 produces independent ProposalCards each with their own Tag button. Merging into one wizard is future work.

## Architecture

```
┌─────────────────── Backend ───────────────────┐
│ Gemini shield_app tool                         │
│ - target = formal name (already enforced):     │
│     "ig" → "Instagram", "douyin" → "抖音"       │
│ - target_kind ∈ {app, category, list, all}    │
└────────────────────────────────────────────────┘
                       │
                       ▼ ProposalDTO over /parent/chat
┌──────────────── iOS ChatViewModel ─────────────┐
│ Pre-flight before rendering ProposalCard:      │
│   if target_kind == "app":                     │
│     LocalAliasStore.applicationToken(target)   │
│       hit  → render normal ProposalCard        │
│       miss → render ProposalCard with          │
│              "Tag <target>" button + warning   │
│              + disabled Confirm                │
│   if target_kind == "category":                │
│     LocalAliasStore.categoryToken(target)      │
│       same hit/miss handling                   │
└────────────────────────────────────────────────┘
                       │
                       ▼ Parent taps "Tag Instagram"
┌──────────────── LazyTagFlow ───────────────────┐
│ 1. Present CustomTokenPickerView modally       │
│ 2. View shows existing tokens via Label(token) │
│ 3. Single-select radio binding                 │
│ 4. "+ Add via Apple picker" if not in list     │
│      → opens FamilyActivityPicker              │
│      → snapshots before/after, diff = added    │
│      → custom view re-renders with new tokens  │
│ 5. Parent taps a Label → Save                  │
│ 6. LocalAliasStore.saveApplicationAliases(     │
│      token, displayName: target,               │
│      bundleIdentifier: nil)                    │
│ 7. Notify ChatViewModel → alias miss cleared   │
│      → ProposalCard warning hidden,            │
│        Confirm enabled                         │
└────────────────────────────────────────────────┘
```

## Components

### Backend (already done)

`shield_tools.py` Gemini system prompt enforces `target` as the canonical product name (e.g. "Instagram", "TikTok", "WeChat", "抖音"). Already includes a slang-expansion table. No further backend changes for this spec.

### iOS — modified files

**`Services/LocalAliasStore.swift`** — no API changes. Existing `saveApplicationAliases(token:displayName:bundleIdentifier:)` and `saveCategoryToken(_:forName:)` are sufficient. Existing case-insensitive lookup via `applicationToken(forLookupKey:)` and `categoryToken(forName:)`.

**`Views/Chat/ChatViewModel.swift`** — adds:
- `extractAliasTarget(from: ProposalDTO) -> (target: String, kind: AliasKind)?` — parses `tool == "shield_app"` and pulls `target` + `target_kind` from `args`
- `aliasMissTarget(for: ProposalDTO) -> AliasMiss?` — returns `(target, kind)` if miss, nil if hit or not applicable
- State: a published `Set<String>` of pending alias misses keyed by ProposalDTO token
- After successful tag flow: clears the miss for that proposal, refreshes ProposalCard render

**`Views/Chat/ProposalCard.swift`** — adds optional alias-miss UI:
- A warning row "Evlin doesn't know which app is '<target>' yet"
- A "Tag <target>" button below the warning
- Confirm button is disabled when alias miss is present
- Skip button works as before

### iOS — new files

**`Views/Lazy Tag/CustomTokenPickerView.swift`** — new ~120 line SwiftUI view:
- Inputs: `target: String`, `kind: AliasKind`, `onSelect: (Token) -> Void`, `onCancel: () -> Void`
- Body: header "Which one is '<target>'?" + scrollable list of `Label(token)` rows (radio-style single-select) + "Add via Apple picker" footer
- Uses `screenTimeManager.selectedApps.applicationTokens` (or `.categoryTokens` for category mode) as data source
- Detects `selectedApps` changes after Apple picker dismiss and re-renders the list
- "Save" button enabled only when one row selected; calls `onSelect(token)`

**`Services/LazyTagFlow.swift`** — new ~80 line coordinator:
- `runFlow(target: String, kind: AliasKind) async -> ApplicationToken?`
- Records `screenTimeManager.selectedApps.applicationTokens` snapshot
- Presents `CustomTokenPickerView`
- On parent's selection, persists alias via LocalAliasStore
- On cancel, returns nil (caller leaves miss state intact)
- Handles `.app` and `.category` kinds via shared diff logic

### Data flow on alias miss

```
1. ChatViewModel sees new ProposalDTO arrive
2. Pre-flight extracts target+kind → checks LocalAliasStore
3. If miss, marks proposal in `pendingAliasMisses`
4. ProposalCard reads this, shows Tag button + warning, disables Confirm
5. Parent taps "Tag Instagram"
6. ChatViewModel calls LazyTagFlow.runFlow("Instagram", .app)
7. CustomTokenPickerView opens
   - Lists Label(token) for each token in selectedApps.applicationTokens
   - If user doesn't see it: tap "Add via Apple picker"
     → FamilyActivityPicker opens
     → user picks app → token added to selection
     → custom picker re-renders
   - User taps a row → Save
8. LocalAliasStore.saveApplicationAliases(token, displayName: "Instagram", bundleIdentifier: nil)
9. ChatViewModel removes proposal from pendingAliasMisses
10. ProposalCard re-renders without warning, Confirm enabled
11. Parent taps Confirm → existing shield flow proceeds
```

## Edge cases

| Case | Behavior |
|------|----------|
| Parent dismisses CustomTokenPicker without picking | Miss state preserved; Tag button still shown; Confirm still disabled. Parent can retry. |
| Parent picks 0 apps in Apple picker fallback (just dismisses) | Custom picker re-renders with same content; no diff; no alias saved. |
| Parent picks 2+ apps in Apple picker fallback | All new tokens are added to selection. Custom picker re-renders showing all of them. Parent still does single-select on the binding step. (Multi-token selection at picker time is OK — alias binding is single.) |
| Parent uses Skip on the ProposalCard before tagging | ProposalCard skipped as today; no LocalAliasStore write; no alias built. Next "lock Instagram" will miss again. |
| Parent has already tagged "Instagram" earlier | Pre-flight hits, normal ProposalCard (no Tag button). |
| Multi-target chat ("lock IG and TikTok") | Each ProposalDTO is independent. Each gets its own pre-flight check. Two cards, possibly two separate Tag flows in sequence. Future work: combined wizard. |
| Alias exists for "Instagram" but parent says "instagram" or "INSTAGRAM" | Hit — `LocalAliasStore.applicationToken(forLookupKey:)` is case-insensitive. |
| Parent says "lock 抖音" but alias was saved as "douyin" | Miss — different lookup key. Parent re-tags. (Backend Gemini canonicalization is the long-term solution.) |

## Error handling

- ProposalDTO with no `args.target` → cannot pre-flight; render normal card and let kid-side ActionExecutor surface `applicationNotConfigured` error as today
- LazyTagFlow can't read selectedApps (rare) → shows error inline in CustomTokenPickerView, fallback: "Open Apple picker only" mode
- Apple picker fails to present → standard SwiftUI sheet error, no alias saved

## Testing plan

Manual:
1. Onboard with All Apps & Categories wildcard. Confirm `selectedApps.applicationTokens` is empty.
2. Chat says "lock Instagram". Pre-flight miss. Card shows "Tag Instagram" button.
3. Tap Tag → CustomTokenPicker opens, list is empty.
4. Tap "Add via Apple picker" → Apple picker opens.
5. Pick Instagram only → close picker. Custom picker now shows 1 Label(token) row labeled Instagram (visually).
6. Tap that row → Save.
7. Card warning vanishes, Confirm enabled. Tap Confirm. Shield applies, IG locked.
8. Restart app. Chat says "lock instagram" (lowercase). Pre-flight hits. No Tag button. Confirm directly.
9. Chat says "lock TikTok". Pre-flight miss. Tag flow as steps 3–7 with TikTok.
10. Chat says "lock games" (category mode). Pre-flight miss on category alias. Tag flow opens custom picker with category tokens (none initially) → Apple picker → pick Games row → bind alias.

Unit tests:
- `extractAliasTarget`: returns `(target, kind)` for shield_app proposal, nil for non-shield tools
- LazyTagFlow selection diff: snapshot before, mock new tokens, verify diff returns only new ones
- LocalAliasStore round trip via tag flow: save → lookup hit case-insensitively

## Files Affected

**Modify:**
- `Evlin iOS/Views/Chat/ChatViewModel.swift` (~50 lines)
- `Evlin iOS/Views/Chat/ProposalCard.swift` (~30 lines)
- `Evlin iOS/Models/AgentEnvelope.swift` (maybe — only if we need a typed accessor for shield_app args)

**Create:**
- `Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift` (~120 lines)
- `Evlin iOS/Services/LazyTagFlow.swift` (~80 lines)
- `Evlin iOSTests/LazyTagFlowTests.swift` (~50 lines)

**Total estimated diff:** ~330 lines added, ~80 modified.

## Out of scope (future specs)

- Std-mode two-device alias sync (parent → kid LocalAliasStore over backend)
- Multi-target merged tag wizard
- Onboarding-time bulk auto-tag (e.g. via OCR or `.child` mode metadata if available)
- Tag editing / deletion UI in Settings
