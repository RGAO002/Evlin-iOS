# Lazy Tagging — Design Spec

**Date:** 2026-05-06
**Branch:** feat/three-tier-lock
**Author:** Claude (with extensive design discussion)

## Problem

Apple's FamilyControls framework gives apps `ApplicationToken` — an opaque blob that uniquely identifies an installed app. The token can be passed to `ManagedSettingsStore.shield.applications` to actually shield the app. But the token does NOT come with a name or bundle ID accessible to the main app:

- `Application(token:).bundleIdentifier` → always nil in main app and most extension types
- `FamilyActivitySelection.applications[*].localizedDisplayName` → nil on iOS 18 + iPhone XS Max + `.individual` auth (verified empirically)
- `Application.localizedDisplayName` is only non-nil inside `ShieldConfigurationDataSource` extension (per Apple Frameworks Engineer, forum 685498)
- `DeviceActivityReportExtension` can read `localizedDisplayName` / `bundleIdentifier` internally and renders them visibly to the user. Multiple cross-process write-back attempts (App Group UserDefaults, shared file via FileManager.containerURL, CFPreferences) returned empty data on our iOS 18 / iPhone XS Max test device, and Apple Developer Forums (728044, 742109) report consistent failure for these channels. We do not have a clean E2E disproof, so this spec treats the extension write-back path as **unreliable / not used as a product dependency**, deferred for revisit if Apple documents a supported channel.

So when a parent says "lock Instagram" in chat, the iOS main app receives `target_request="Instagram"` but cannot programmatically locate the matching `ApplicationToken`.

## Goal

Build the simplest possible UX where:
1. Parent says "lock IG" in chat → AI normalizes to "Instagram" → iOS resolves Instagram → ApplicationToken → shield works
2. The first time iOS doesn't recognize an app name, parent does a 1-tap binding ("Tag Instagram"); after that, every future "lock IG" / "lock Instagram" hits instantly
3. Custom picker UI shows already-known tokens via `Label(token)` (which renders icon + name on user's device), single-select binding
4. Apple's `FamilyActivityPicker` is the fallback to ADD a new token to selection if the parent doesn't see it in the custom list

## Scope

This spec delivers the **demo / MVP local path only**:

- ✅ **Single-device test mode** (parent + kid on the same physical iPhone via the existing app-mode toggle) — fully covered.
- ❌ **`.child` Max mode (two-device)** — NOT covered. Parent's tag persists in PARENT device's LocalAliasStore, but shield Command runs on KID device which reads its own (empty) LocalAliasStore. Result: `application_not_configured`. Either alias relay (parent → backend → kid) or token-in-Command transport is required. **Deferred to a separate spec.**
- ❌ **Std two-device production** (parent iPhone + kid iPhone, `.individual` auth) — NOT covered, same reason as Max two-device above.

In short: **v1 is single-device test mode only.** Two-device production (any mode) needs cross-device alias transport — separate spec.

## Non-Goals

- **Auto-tagging from DeviceActivityReport extension** — see Problem section. Treated as unreliable / not a product dependency.
- **Bulk OCR onboarding** — multi-screenshot rendering + Vision OCR was explored. Rejected for v1 due to UX complexity. May revisit as v2 onboarding accelerator.
- **Multi-target merged tag wizard** — When parent says "shield IG and TikTok", v1 produces independent ProposalCards each with their own Tag button. Merging into one step-through wizard is future work.
- **Tag editing / deletion UI in Settings** — future work.

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
┌──────────────── ChatViewModel ─────────────────┐
│ Sets `activeLazyTagRequest = (target, kind,    │
│   proposalToken)` — published @State.          │
│ ChatView observes this and presents a          │
│ `.sheet(item:)` containing CustomTokenPicker.  │
└────────────────────────────────────────────────┘
                       │
                       ▼ Sheet presented
┌──────── CustomTokenPickerView (in sheet) ──────┐
│ 1. Renders `Label(token)` rows for tokens in   │
│    screenTimeManager.selectedApps              │
│    (.applicationTokens or .categoryTokens      │
│     depending on AliasKind)                    │
│ 2. Single-select radio binding                 │
│ 3. "+ Add via Apple picker" footer             │
│      → opens FamilyActivityPicker              │
│      → on dismiss, selectedApps now contains   │
│        new tokens; view re-renders             │
│ 4. Parent taps a Label → "Save"                │
│ 5. Calls onSelect(token) closure               │
└────────────────────────────────────────────────┘
                       │
                       ▼ onSelect callback
┌──────────────── LazyTagPersistence ────────────┐
│ Pure persistence helper (no UI):               │
│ - For .app: validates token is ApplicationToken│
│   → LocalAliasStore.saveApplicationAliases     │
│ - For .category: validates token is            │
│   ActivityCategoryToken                        │
│   → LocalAliasStore.saveCategoryToken          │
│ - Returns success / typed error                │
└────────────────────────────────────────────────┘
                       │
                       ▼ persist done
ChatViewModel clears activeLazyTagRequest +
removes proposal from pendingAliasMisses
→ Sheet dismisses, ProposalCard re-renders
   without warning, Confirm enabled
```

### Critical: data source clarification

The CustomTokenPickerView reads `screenTimeManager.selectedApps` as its data source. Adding via Apple picker fallback does **widen `selectedApps` as a side effect**. This is intentional and acknowledged here:

- Apple's `ManagedSettingsStore.shield.applications` only accepts tokens within the FamilyControls authorization scope, which is established via `FamilyActivityPicker` and persisted in `selectedApps`.
- A token that is bound as an alias but never present in `selectedApps` cannot be shielded. So lazy tag MUST add the token to `selectedApps` to be useful.
- This is reflected in the parent's mental model: "I told Evlin Instagram is this app, and now Evlin can manage it." Adding to managed selection IS the implicit contract of tagging.
- We do NOT add a separate "tagged tokens" store decoupled from `selectedApps`. One source of truth.

## Components

### Backend (already done)

`shield_tools.py` Gemini system prompt enforces `target` as the canonical product name (e.g. "Instagram", "TikTok", "WeChat", "抖音"). Already includes a slang-expansion table. No further backend changes for this spec.

### iOS — modified files

**`Services/LocalAliasStore.swift`** — no API changes. Existing `saveApplicationAliases(token:displayName:bundleIdentifier:)` and `saveCategoryToken(_:forName:)` are sufficient. Existing case-insensitive lookup via `applicationToken(forLookupKey:)` and `categoryToken(forName:)`.

**`Views/Chat/ChatViewModel.swift`** — adds:
- Type alias declared at top of file:
  ```swift
  enum AliasKind { case app, category }
  ```
- `extractAliasTarget(from: ProposalDTO) -> (target: String, kind: AliasKind)?` — parses `tool == "shield_app"` and pulls `target` + `target_kind` from `args`. Returns nil for `target_kind` of `"all"` or `"list"` (no alias needed) or other tool types.
- `aliasHit(for: ProposalDTO) -> Bool` — true if pre-flight resolves; controls Confirm enable.
- Published state:
  ```swift
  @Published var pendingAliasMisses: [String: AliasKind]  // keyed by proposalToken
  @Published var activeLazyTagRequest: LazyTagRequest?    // drives .sheet
  ```
  `proposalToken` is the existing `ProposalDTO.token` field (server-side undo token, also serves as a unique proposal identifier).
- **Hard guard inside `confirmProposal(_:)`** — even if UI is bypassed, refuse to dispatch if `pendingAliasMisses` contains this proposal. Defense in depth against state races and future entry points.
- After successful tag flow: removes proposal from `pendingAliasMisses`, sets `activeLazyTagRequest = nil`, ProposalCard re-renders.

**`Components/ConfirmationCards/ProposalCard.swift`** — modify ProposalCard to accept alias-miss UI:
- Two new parameters with explicit semantics:
  ```swift
  let aliasMissTarget: String?     // nil = no miss, normal card; non-nil = show warning + Tag button
  let onTag: () -> Void            // called when parent taps "Tag <target>"
  ```
- When `aliasMissTarget != nil`:
  - Show warning row: "Evlin doesn't know which app is '<aliasMissTarget>' yet"
  - Show button: "Tag <aliasMissTarget>" → calls `onTag()`
  - Disable Confirm button
- When nil: render exactly as today.

**`Views/Chat/ChatView.swift`** — modify to:
- Wire ProposalCard's `aliasMissTarget` and `onTag` from ChatViewModel state.
- Add `.sheet(item: $vm.activeLazyTagRequest) { req in CustomTokenPickerView(request: req, onSelect: vm.handleTagSelection, onCancel: vm.cancelLazyTag) }`.
- This is the SwiftUI-idiomatic presentation pattern; the persistence service does NOT present.

### iOS — new files

**`Views/LazyTag/CustomTokenPickerView.swift`** — new ~120 line SwiftUI view (note: directory name has no space):
- Inputs: `request: LazyTagRequest` (carries target + kind + proposalToken), `onSelect: (Token) -> Void`, `onCancel: () -> Void`
- Body:
  - Header "Which one is '\(target)'?"
  - For `.app` mode: scrollable list of `Label(token)` rows from `screenTimeManager.selectedApps.applicationTokens`, single-select radio.
  - For `.category` mode: same but rendering category tokens from `screenTimeManager.selectedApps.categoryTokens`.
  - "+ Add via Apple picker" footer:
    - For `.app`: opens `.familyActivityPicker(isPresented:selection:)` with a fresh `FamilyActivitySelection()`.
    - For `.category`: opens `.familyActivityPicker(...)` with `FamilyActivitySelection(includeEntireCategory: true)` (REQUIRED — otherwise category-row taps split into individual app tokens, not category tokens).
    - On dismiss, save `screenTimeManager.saveSelection()` to merge new tokens into the persisted selection so subsequent rebuilds keep them.
  - "Save" button enabled only when one row selected; calls `onSelect(token)`.

**`Services/LazyTagPersistence.swift`** — new ~50 line pure-data helper (no UI):
- `func persistAlias(token: Any, kind: AliasKind, target: String) -> Result<Void, LazyTagError>`
- For `.app`: validates token is `ApplicationToken`, calls `LocalAliasStore.shared.saveApplicationAliases(token: t, displayName: target, bundleIdentifier: nil)`.
- For `.category`: validates token is `ActivityCategoryToken`. Returns error if caller passed an `ApplicationToken` by mistake (e.g. user picked an individual app while we expected a category).
  Calls `LocalAliasStore.shared.saveCategoryToken(t, forName: target)`.
- No presentation responsibility. ChatViewModel calls this from its `handleTagSelection` callback.

**`LazyTagRequest.swift`** (in `Models/`):
```swift
struct LazyTagRequest: Identifiable, Equatable {
    let id: String        // proposalToken — also satisfies Identifiable for .sheet(item:)
    let target: String
    let kind: AliasKind
}
```

### Data flow on alias miss

```
1. ChatViewModel sees new ProposalDTO arrive
2. Pre-flight extracts target+kind → checks LocalAliasStore
3. If miss, marks proposal in `pendingAliasMisses`
4. ProposalCard reads this, shows Tag button + warning, disables Confirm
5. Parent taps "Tag Instagram"
6. ChatViewModel sets `activeLazyTagRequest = LazyTagRequest(id: proposalToken, target: "Instagram", kind: .app)`
7. ChatView's `.sheet(item: $vm.activeLazyTagRequest)` presents CustomTokenPickerView
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
- CustomTokenPickerView can't read `selectedApps` (rare — `screenTimeManager` not injected) → shows error inline, "Open Apple picker only" mode is the only path forward
- LazyTagPersistence receives wrong token type (e.g. ApplicationToken in category mode) → returns typed error; ChatViewModel keeps `pendingAliasMisses` set, sheet stays for retry
- Apple picker fails to present → standard SwiftUI sheet error, no alias saved

## Testing plan

### Manual (recommended onboarding path: parent picks specific apps in onboarding so `selectedApps.applicationTokens` is non-empty)

1. Onboard normally (recommended path picks 5–10 specific apps). Confirm `selectedApps.applicationTokens.count > 0`.
2. Chat says "lock Instagram". Pre-flight miss (assuming no prior tagging). Card shows "Tag Instagram" button + warning, Confirm disabled.
3. Tap Tag → CustomTokenPicker opens with already-selected apps as `Label(token)` rows.
4. Find Instagram visually, tap it → "Save".
5. Card warning vanishes, Confirm enabled. Tap Confirm. Shield applies, IG locked.
6. Restart app. Chat says "lock instagram" (lowercase). Pre-flight hits. No Tag button. Confirm directly.
7. Chat says "lock TikTok". If TikTok already in selection, find via row tap. If not in selection, tap "+ Add via Apple picker" → Apple picker → pick TikTok → close → returns to custom picker → row visible → tap → Save.
8. Chat says "lock games" (category mode). Pre-flight miss on category alias. Tag flow opens with categoryTokens. If empty, Apple picker fallback uses `FamilyActivitySelection(includeEntireCategory: true)` → parent taps Games category row → close → custom picker shows Games category token → tap → Save.

### Edge case manual

9. **Empty wildcard onboarding** (`All Apps & Categories` selected at top): `selectedApps.applicationTokens` is empty. Tag flow shows empty list + "Add via Apple picker" footer. Verify the fallback is the only path forward.
10. **Cancel during tag**: open custom picker, hit Cancel → sheet dismisses, ProposalCard still shows Tag button + warning, Confirm still disabled. Parent can retry.
11. **Skip ProposalCard with miss outstanding**: parent taps Skip without tagging → ProposalCard skipped, no LocalAliasStore write. Next "lock X" hits same miss again.
12. **Hard guard**: simulate ChatViewModel state where `pendingAliasMisses[proposalToken]` is set, then call `confirmProposal(_:)` directly via debug menu. Expect refusal (no command dispatched, error message returned).
13. **Category mismatch**: in category-mode tag flow, parent uses Apple picker fallback and accidentally picks an individual app instead of a category row. New token in diff is `ApplicationToken`, not `ActivityCategoryToken`. Custom picker should not list it (because it iterates `selectedApps.categoryTokens` for category mode). LazyTagPersistence rejects with typed error if it's somehow passed.

### Unit tests

- `extractAliasTarget(from:)`: returns `(target, kind)` for `shield_app` with `target_kind=="app"` or `"category"`; nil for `"all"` / `"list"` / non-shield tools.
- `confirmProposal` hard guard: with proposalToken in `pendingAliasMisses`, dispatch must not be called; assert via mocked AgentClient.
- LazyTagPersistence: `.app` accepts ApplicationToken, rejects ActivityCategoryToken (and vice versa); on success, `LocalAliasStore.applicationToken(forLookupKey: target)` returns the saved token (case-insensitive).

## Files Affected

**Modify:**
- `Evlin iOS/Views/Chat/ChatViewModel.swift` (~70 lines: AliasKind enum, extractAliasTarget, pendingAliasMisses, activeLazyTagRequest, confirmProposal hard guard, handleTagSelection)
- `Evlin iOS/Components/ConfirmationCards/ProposalCard.swift` (~40 lines: aliasMissTarget, onTag params, warning UI, disabled Confirm)
- `Evlin iOS/Views/Chat/ChatView.swift` (~20 lines: wire props through to ProposalCard, .sheet(item:) presenting CustomTokenPickerView)

**Create:**
- `Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift` (~120 lines)
- `Evlin iOS/Services/LazyTagPersistence.swift` (~50 lines)
- `Evlin iOS/Models/LazyTagRequest.swift` (~10 lines)
- `Evlin iOSTests/LazyTagTests.swift` (~80 lines)

**Total estimated diff:** ~390 lines added, ~130 modified across 7 files.
