# Three-Tier App Locking + Saved Lists + Onboarding Redesign

**Date**: 2026-04-22
**Status**: Design approved, ready for plan
**Scope**: Core parental control — locking child apps from parent's Chat, onboarding flow for both modes, Saved Lists, receipt/confirmation system

---

## 1. Problem Statement

Evlin's core value proposition is "parent types in Chat, child's app is locked." Three constraints make this non-trivial:

1. iOS deliberately does not let third-party apps enumerate installed apps on the device (privacy wall). There is no legal bypass (screenshot/OCR/private API all ruled out).
2. The most natural lock API (`shield.applications`) requires `ApplicationToken`s that can only be produced by `FamilyActivityPicker` user interaction.
3. A second lock API (`blockedApplications` with `Application(bundleIdentifier:)`) accepts bundle IDs directly — no picker required — but has a different UX (system block dialog vs custom shield screen).

The design must:
- Allow "lock IG" to work immediately after onboarding without requiring the user to pre-pick Instagram.
- Allow a parent to save a curated set of apps ("list 1", "bedtime apps") once and lock them by name from Chat repeatedly.
- Gracefully degrade for unknown apps ("abcd") to category-level locking.
- Always return a clear receipt showing what actually got locked, with collateral disclosure when applicable.
- Support both single-device testing (parent/child mode toggle on one phone) and multi-device production (pairing code links two phones to one family).

## 2. Three-Tier Lock Strategy

Every lock command from Chat resolves to exactly one of three tiers:

### Tier A: Bundle ID Direct Lock

**Mechanism**: `ManagedSettingsStore.application.blockedApplications = [Application(bundleIdentifier: "com.burbn.instagram")]`

**Used when**: The target matches an entry in the backend's curated **App Catalog** (approx. 60 common apps shipped in the first release).

**Characteristics**:
- No picker required, no prior setup.
- Works for well-known apps worldwide.
- Lock shows iOS's system-level "not available" dialog on launch (not Evlin's custom shield screen).
- Cannot verify whether the app is actually installed on the child's phone (iOS does not report this). Block rule still applies — if the app is ever launched it will be blocked.

### Tier B: Saved List (Picker Token) Lock

**Mechanism**: `ManagedSettingsStore.shield.applications = savedList.applicationTokens; .applicationCategories = .specific(savedList.categoryTokens)`

**Used when**: The parent has previously created a Saved List (e.g. "list 1", "bedtime apps", "games") by opening `FamilyActivityPicker` once and selecting apps/categories/websites.

**Characteristics**:
- 100% precise — only the specific apps the parent chose are locked.
- Shows Evlin's custom shield screen (via `ShieldConfigurationDataSource` extension, planned).
- Lists persist across app launches.
- No upper limit on list count.

**Where the tokens live and how they travel**:

- **Max mode (Child Apple ID + `.child` auth)**:
  - Picker runs on parent device (Family Sharing exposes child's apps to parent picker).
  - Parent device encodes the `FamilyActivitySelection` as `Data` (PropertyListEncoder) and uploads it to backend: `POST /parent/saved-lists { name, selection_blob: base64 }`.
  - When a lock command references this list, backend attaches `selection_blob` to the Command sent to the child device.
  - Child device decodes and applies `shield.applications = selection.applicationTokens` locally.
  - Rationale: Family Sharing tokens are already synced by Apple within the family; routing them as opaque blobs through our backend does not leak app identity to us (we cannot decode them) and is equivalent in effect to Apple's own sync path.
  - **Open technical risk**: Apple does not officially document that tokens produced by a parent-device picker are valid on a child device's `ManagedSettingsStore`. Phase 2 of the implementation plan includes a spike to verify this. If it fails, Max mode degrades to "parent device triggers picker launch remotely on child device" — same storage model as Std mode, but still better UX than manual setup.

- **Std mode (Family Controls passcode only)**:
  - Picker only runs on child device. Parent cannot remotely build Saved Lists.
  - Child device stores the `FamilyActivitySelection` in App Group UserDefaults keyed by list name.
  - Commands reference the list by name only; child device looks up selection locally.
  - Only list metadata (name, description, createdAt) syncs to backend so the parent UI can show available list names; the selection blob never leaves the child device.

### Tier C: Category Fallback Lock

**Mechanism**: `ManagedSettingsStore.shield.applicationCategories = .specific([gamesToken, socialToken, ...])`

**Used when**:
- Target not in catalog AND not in any Saved List.
- AI/parent chose a category name directly ("lock all games").
- Fallback for unrecognized names where AI can infer a category ("abcd" probably a game).

**Characteristics**:
- Catches the target if it's truly in that category.
- Automatically covers any new app of that category installed in the future.
- Has collateral impact — every app in the category is blocked.
- Requires that the child device picked category tokens once during onboarding (Step 5C in Child Onboarding).

**Resolution priority** (AI/backend chooses the first match):
1. Saved List name → Tier B
2. App name in Catalog → Tier A
3. Category name or inferred category → Tier C
4. Total miss → send a confirmation card to parent: `{proposedTier, proposedCategory, originalName}`

---

## 3. Data Model

### 3.1 Backend (FastAPI + Postgres)

```python
# New tables

class Family(Base):
    id = Column(UUID, primary_key=True)
    created_at = Column(DateTime)

class Device(Base):
    id = Column(UUID, primary_key=True)
    family_id = Column(UUID, FK("family.id"), index=True)
    mode = Column(Enum("parent", "child"))
    label = Column(String)           # "Liam's iPhone" / "Mom's iPhone"
    apns_token = Column(String, nullable=True)
    last_heartbeat = Column(DateTime, nullable=True)

class PairingCode(Base):
    code = Column(String(6), primary_key=True)
    family_id = Column(UUID, FK("family.id"))
    expires_at = Column(DateTime)
    used = Column(Boolean, default=False)

class SavedListMeta(Base):
    id = Column(UUID, primary_key=True)
    family_id = Column(UUID, FK("family.id"), index=True)
    name = Column(String)            # "list 1", "bedtime apps" — unique per family
    description = Column(String, nullable=True)
    mode = Column(Enum("parent_device", "child_device"))
    owning_device_id = Column(UUID, FK("device.id"))
    # Max mode only: the encoded FamilyActivitySelection uploaded by parent device.
    # NULL for Std mode (child device keeps selection locally).
    selection_blob = Column(LargeBinary, nullable=True)
    created_at = Column(DateTime)
    updated_at = Column(DateTime)

class Command(Base):
    id = Column(UUID, primary_key=True)
    family_id = Column(UUID, FK("family.id"), index=True)
    target_device_id = Column(UUID, FK("device.id"))
    payload = Column(JSON)           # see Command payload below
    created_at = Column(DateTime)
    picked_up_at = Column(DateTime, nullable=True)
    acked_at = Column(DateTime, nullable=True)
    ack_status = Column(Enum)        # pending, confirmed_exact, confirmed_fallback, failed, timeout
    ack_detail = Column(JSON, nullable=True)
```

**Command payload** (JSON shape):
```json
{
  "command_id": "uuid",
  "action": "lock" | "unlock" | "unlock_all" | "expand_library",
  "tier": "exact_bundle" | "saved_list" | "category",
  "target": {
    "bundle_id": "com.burbn.instagram",        // tier=exact_bundle
    "list_name": "list 1",                     // tier=saved_list
    "category_hint": "games",                  // tier=category
    "original_request": "abcd"                 // always include, for receipt
  },
  "duration_minutes": 30,                      // null = permanent
  "issued_at": "2026-04-22T14:20:00Z"
}
```

### 3.2 Child Device Local Storage (App Group UserDefaults `group.com.evlin.ios`)

```swift
// Tokens never leave the device they were picked on.
struct LocalAliasStore: Codable {
    var categoryTokens: [String: ActivityCategoryToken]   // "games" → token
    var savedListTokens: [String: FamilyActivitySelection] // "list 1" → full selection (apps+cats+websites)
}

// Persisted state:
// - "evlin.localAliases" (Data, plist-encoded LocalAliasStore)
// - "evlin.activeShields" (Data, list of currently-active ShieldHandles for UI display)
```

### 3.3 Parent Device Local Storage (Max mode only)

Same `LocalAliasStore` structure but only `savedListTokens`. Parent device never needs category tokens.

### 3.4 App Catalog (backend, in-memory seeded from JSON)

```json
[
  {"names": ["Instagram", "IG", "insta"], "bundle_id": "com.burbn.instagram", "category_hint": "social"},
  ...
]
```

See §9 for the full v1 catalog.

---

## 4. Architecture

```
┌───────────────────────────────────────┐   ┌──────────────────────────────────┐
│  Parent Device                         │   │  Backend                         │
│                                        │   │                                  │
│  Chat.sendMessage("lock IG 30 min")    │◄─►│  POST /parent/chat               │
│  → APIClient                           │   │  - Gemini parses → action        │
│  → ReceiptCard(pending)                │   │  - Resolve tier (list/cat/catalog)│
│                                        │   │  - Create Command row            │
│  Poll /parent/ack-status?cmd=...       │◄─►│  GET  /parent/ack-status         │
│  → ReceiptCard → confirmed/failed      │   │                                  │
│                                        │   │  GET  /child/commands?device=... │
│  (Max mode only)                       │   │  POST /child/ack                 │
│  ManageLists → FamilyActivityPicker    │   │                                  │
│  → POST /parent/saved-lists            │◄─►│  POST /parent/saved-lists (meta) │
└───────────────────────────────────────┘   └──────────────────────────────────┘
                                                           ▲
                                                           │
                                             ┌─────────────┴────────────────┐
                                             │  Child Device                │
                                             │                              │
                                             │  Poll /child/commands every  │
                                             │  30s (BGAppRefreshTask +     │
                                             │  foreground poll)            │
                                             │                              │
                                             │  ActionExecutor.apply():     │
                                             │    tier=exact_bundle →       │
                                             │      blockedApplications=[…] │
                                             │    tier=saved_list →         │
                                             │      shield.applications=    │
                                             │      store[listName].tokens  │
                                             │    tier=category →           │
                                             │      shield.categories=      │
                                             │      store[hint]             │
                                             │                              │
                                             │  POST /child/ack             │
                                             │                              │
                                             │  DeviceActivityMonitor ext:  │
                                             │    schedules auto-unlock     │
                                             │                              │
                                             │  ManageLists (Std mode only) │
                                             │  → FamilyActivityPicker      │
                                             │  → local store + POST meta   │
                                             └──────────────────────────────┘
```

**Single-device test mode**: Settings toggle flips `UserDefaults["activeMode"]` between `parent` and `child`. Each mode POSTs to backend with its own `device_id` (two devices registered under one family). The HTTP round-trip still happens — it's the real flow, not a shortcut.

---

## 5. Onboarding Flow (complete)

### 5.1 Shared Entry

```
┌────────────────────────┐
│  [1] Welcome            │
│      - Shield icon       │
│      - "The Informed    │
│         Sentinel"        │
│      - [Continue]        │
└─────────────┬──────────┘
              ▼
┌────────────────────────┐
│  [2] Mode Select        │
│   ┌─────┐   ┌─────┐    │
│   │ Par-│   │Child│    │
│   │ ent │   │     │    │
│   └─────┘   └─────┘    │
└──┬─────────────┬───────┘
   │ Parent       │ Child
   ▼              ▼
  Parent Flow    Child Flow
```

### 5.2 Parent Mode Flow

```
[1] Welcome
[2] Mode Select → Parent
    │
    ▼
[3P] Add Child
     Name: [____]        ← required, used in Chat ("Lock Liam's phone")
     Age:  [_]           ← optional
     [Continue]
    │
    ▼
[4P] Pairing Code Display
     ┌────────────────────┐
     │   4 8 2 9 1 7       │   ← generated by POST /family/create
     │                      │
     │   [QR code]          │
     └────────────────────┘
     Status: ⚪ Waiting for Liam's device...
     │
     │ (polling /family/pairing-status?code=…)
     │
     ↓ arrived
     Status: ✓ Liam's phone connected
     [Continue]
    │
    ▼
[5P] Protection Level Select
     ◉ Maximum (recommended)
       · Picker on THIS phone controls Liam's apps
       · Evlin cannot be deleted
       · Requires Child Apple ID (5 min one-time setup)
       [Choose Maximum]
     ○ Standard
       · Picker on Liam's phone only
       · Family Controls passcode protects app deletion
       · No extra account needed
       [Choose Standard]
    │
    ├── Maximum ──▶ [6P-Max]
    └── Standard ─▶ [6P-Std]

[6P-Max-A] Why Child Apple ID
     · 4 bullet benefits with icons:
       - Remote app selection from YOUR phone
       - Blocks Evlin uninstall automatically
       - Can set time limits, bedtime without child's involvement
       - Compliant with Apple Family Sharing
     [Got it — let's set it up]

[6P-Max-B] Create Child Apple ID
     "On THIS phone:
      1. Open Settings → Family
      2. Tap Add Member → Create a Child Account
      3. Follow Apple's prompts (~3 min)"
     [Open Family Settings]  ← tries App-Prefs URLs; falls back to Settings root
     [I've created the account]

[6P-Max-C] Sign In on Child Device
     "On Liam's phone:
      1. Sign out of the existing Apple ID (if any)
      2. Sign in with the Child Apple ID you just made
      3. Return to Evlin (already running there in child mode)"
     [I've signed in on Liam's phone]

[6P-Max-D] Authorize Evlin as Parent
     "Hand Liam's phone here, then tap below."
     [Grant Parent Authorization]  ← calls AuthorizationCenter.requestAuthorization(for: .child)
     │
     ├─ Success ─▶ [6P-Max-E]
     └─ Failure (not a child account) ─▶ Retry / back to [6P-Max-B]

[6P-Max-E] Enable Deletion Protection
     ManagedSettingsStore.application.denyAppRemoval = true
     "✓ Evlin is now protected from deletion."
     [Continue]
    │
    ▼
[7P-Max] First Saved List (optional)
     "Let's make your first Saved List."
     [Open App Picker]  ← FamilyActivityPicker on parent device (Max mode: shows child apps)
     → select apps/websites/categories
     → prompt: Name this list: [_________] e.g. "list 1"
     → save locally + POST meta
     [Skip for now]  ← allowed, can create later
    │
    ▼
[8P] Done
     "Liam is protected. Open Chat to send your first command."
     [Enter Evlin]

─────────────────────────────────────────

[6P-Std-A] Set Family Controls Passcode
     "On Liam's phone:
      1. Open Settings → Screen Time
      2. Lock Screen Time Settings
      3. Set a 4-digit passcode Liam doesn't know"
     [Open Screen Time Settings]
     [I've done this]

[6P-Std-B] Disable App Deletion
     "On Liam's phone, in Screen Time:
      Content & Privacy Restrictions
      → iTunes & App Store Purchases
      → Deleting Apps → Don't Allow"
     [I've done this]

[6P-Std-C] Verification Note
     "⚠ Evlin cannot verify these settings programmatically.
      If you skipped them, Liam can uninstall Evlin."
     [Continue anyway]
    │
    ▼
[7P-Std] → [8P]
   (Saved Lists cannot be created from parent device in Std mode;
    they must be built on child device — step [6C] in child flow.)
```

### 5.3 Child Mode Flow

```
[1] Welcome
[2] Mode Select → Child
    │
    ▼
[3C] Enter Pairing Code
     ┌───────────┐
     │ _ _ _ _ _ _│
     └───────────┘
     │
     │ POST /family/pair {code, device_label}
     │ → returns {family_id, protection_mode, parent_device_id}
     │
     ↓ success
     "Connected to Mom's Evlin ✓"
     [Continue]
    │
    ▼
[4C] Grant Screen Time Permission
     "Evlin needs permission to manage Screen Time on this phone."
     [Grant Permission]
     │
     ├─ protection_mode=max ─▶ AuthorizationCenter.requestAuthorization(for: .child)
     │                         (requires Child Apple ID present on this device)
     └─ protection_mode=std ─▶ AuthorizationCenter.requestAuthorization(for: .individual)
    │
    ▼
[5C] Category Defaults — REQUIRED
     "Pick which categories your parent should be able to control."
     [Open Category Picker]
     → FamilyActivityPicker (selection filter: categoriesOnly where possible)
     → user picks: Social, Games, Entertainment, etc.
     → save each category token to local categoryTokens[name]
     [Continue]
    │
    ▼
[6C] Create First Saved List (Std mode only)
     "Let's make your first Saved List. Your parent can later say
      'lock list 1 for 30 min' in Chat."
     [Open App Picker]
     → FamilyActivityPicker (apps + categories + websites)
     → Name: [list 1]
     → save selection + POST meta
     [Skip for now]
    │
    ▼
[7C] Child Ready Screen
     "Waiting for commands from Mom's Evlin."
     · Shows current lock status
     · Shows last 5 commands received
     · (minimal UI, no tabs)
```

### 5.4 Replacing Existing Code

Current `OnboardingView.swift` (353 LOC) and `SetupView.swift` (311 LOC) do not match this flow and are replaced wholesale:

```
NEW:  Views/Onboarding/OnboardingCoordinator.swift      (replaces OnboardingView)
      Views/Onboarding/Shared/WelcomeStep.swift
      Views/Onboarding/Shared/ModeSelectStep.swift
      Views/Onboarding/Parent/AddChildStep.swift
      Views/Onboarding/Parent/PairingCodeStep.swift
      Views/Onboarding/Parent/ProtectionLevelStep.swift
      Views/Onboarding/Parent/Max/WhyChildAppleIDStep.swift
      Views/Onboarding/Parent/Max/CreateChildAppleIDStep.swift
      Views/Onboarding/Parent/Max/SignInOnChildStep.swift
      Views/Onboarding/Parent/Max/AuthorizeAsParentStep.swift
      Views/Onboarding/Parent/Max/DeletionProtectionStep.swift
      Views/Onboarding/Parent/Std/SetPasscodeStep.swift
      Views/Onboarding/Parent/Std/DisableDeletionStep.swift
      Views/Onboarding/Parent/Std/StdVerificationStep.swift
      Views/Onboarding/Parent/FirstSavedListStep.swift
      Views/Onboarding/Parent/DoneStep.swift
      Views/Onboarding/Child/EnterPairingCodeStep.swift
      Views/Onboarding/Child/GrantPermissionStep.swift
      Views/Onboarding/Child/CategoryDefaultsStep.swift
      Views/Onboarding/Child/FirstSavedListStep.swift
      Views/Onboarding/Child/ChildReadyStep.swift

DELETE: Views/Onboarding/OnboardingView.swift
        Views/Onboarding/SetupView.swift
```

---

## 6. Lock Flow (runtime)

### 6.1 Parent Types a Command

```
Parent: "lock IG for 30 min"
        │
        ▼
ChatView calls POST /parent/chat (existing endpoint)
        │
        ▼
Backend: Gemini system prompt (updated) returns:
{
  "message": "Locking Instagram on Liam's phone for 30 minutes.",
  "reasoning": "Parent requested a specific app lock with duration.",
  "action": {
    "type": "lock",
    "target_request": "IG",
    "duration_minutes": 30
  }
}
        │
        ▼
Backend resolution pipeline (new, before returning to client):
  1. Check if target_request matches any SavedListMeta.name for this family (fuzzy)
     → if yes: tier = "saved_list", list_name = meta.name
           If meta.mode == "parent_device" (Max mode): also attach the stored selection_blob
           If meta.mode == "child_device" (Std mode): no blob; child looks up locally
  2. Check App Catalog for alias match
     → if yes: tier = "exact_bundle", bundle_id = catalog.bundle_id
  3. Ask Gemini to classify "IG" into a category
     → if confident: tier = "category", category_hint = "social"
  4. Else: return action with tier="needs_confirmation"
        │
        ▼
Backend creates Command row, POST to target_device_id's queue:
{
  "command_id": "uuid",
  "action": "lock",
  "tier": "exact_bundle",
  "target": {
    "bundle_id": "com.burbn.instagram",   // tier=exact_bundle
    "list_name": "list 1",                // tier=saved_list
    "selection_blob": "base64..." | null, // tier=saved_list AND mode=parent_device
    "category_hint": "social",            // tier=category
    "original_request": "IG"
  },
  "duration_minutes": 30
}
        │
        ▼
Backend returns to parent client:
{
  "message": "Locking Instagram...",
  "reasoning": "...",
  "action": {
    "type": "lock",
    "command_id": "uuid",
    "tier": "exact_bundle",
    "target_display": "Instagram",
    "duration_minutes": 30
  }
}
        │
        ▼
Parent ChatView inserts ReceiptCard(pending, commandID=uuid)
        │
        ▼
ReceiptCard polls GET /parent/ack-status?command_id=uuid every 1s (up to 10s)
```

### 6.2 Child Device Executes

```
Child ActionPoller (BGAppRefreshTask + foreground NSTimer):
   loops: GET /child/commands?device_id=X
          → if commands, loop through:
              ActionExecutor.execute(command)
              → POST /child/ack
```

**ActionExecutor.execute(command)**:

```swift
func execute(_ cmd: Command) async -> AckResult {
    guard ScreenTimeManager.shared.isAuthorized else {
        return .failed(.notAuthorized)
    }
    do {
        switch cmd.tier {
        case .exactBundle:
            let app = Application(bundleIdentifier: cmd.target.bundleID!)
            var current = store.application.blockedApplications ?? []
            current.insert(app)
            store.application.blockedApplications = current

        case .savedList:
            let selection: FamilyActivitySelection
            if let blobB64 = cmd.target.selectionBlob,     // Max mode: backend provided blob
               let data = Data(base64Encoded: blobB64),
               let decoded = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) {
                selection = decoded
            } else if let local = localStore.savedListTokens[cmd.target.listName!] {
                selection = local                           // Std mode: local lookup
            } else {
                return .failed(.listNotFound(cmd.target.listName!))
            }
            mergeIntoShield(selection)

        case .category:
            guard let catToken = localStore.categoryTokens[cmd.target.categoryHint!] else {
                return .failed(.categoryNotConfigured(cmd.target.categoryHint!))
            }
            var current = store.shield.applicationCategories
            store.shield.applicationCategories = addCategory(catToken, to: current)
        }

        // Schedule auto-unlock if duration set
        if let mins = cmd.durationMinutes {
            scheduleRelock(commandID: cmd.id, minutes: mins)
        }

        // Save current shield handles for UI
        persistActiveShield(cmd)

        return .confirmedExact  // or .confirmedFallback for category
    } catch {
        return .failed(.execution(error.localizedDescription))
    }
}
```

### 6.3 Receipt Card States

```swift
enum ReceiptState {
    case pending                                    // 🟡 animated spinner
    case confirmedExact(displayName: String)        // 🟢 "Instagram locked · Unlocks at 14:53"
    case confirmedFallback(displayName: String,
                          category: String,
                          origRequest: String)      // 🟡 "Games locked (includes 'abcd')"
    case failedPermission                           // 🔴 "Screen Time permission missing on Liam's phone"
    case failedListNotFound(listName: String)       // 🔴 "List '\(listName)' not found"
    case failedTimeout                              // 🔴 "Liam's phone didn't respond in 10s"
    case failedOther(reason: String)                // 🔴 reason
}
```

Receipt card is a new `ChatMessage` type (not just text). Rendered by a new `ReceiptCard` view inside ChatView's message list. Shows:
- Status icon + color
- Primary line (what was locked)
- Secondary line (time, duration, collateral info)
- Footer actions:
  - `.confirmedFallback` → `[Make it precise]` button → triggers Library Expand flow (Step C in §6.4)
  - `.confirmedExact` → `[Unlock now]` button

### 6.4 Library Expand (Tier A/C → B Promotion)

Parent taps `[Make it precise]` on a fallback receipt:

```
Parent Chat:
  → POST /parent/command with action="expand_library", target="abcd"
  → ReceiptCard("Waiting for Liam to add abcd...")

Backend: creates Command with action=expand_library for child device

Child Device:
  → Receives command → shows system notification: "Mom wants to add 'abcd' to Evlin"
  → Opens Evlin → picker screen pre-opened with context
  → User picks app → names it "abcd"
  → saved to localStore.savedListTokens as single-item list
  → POST /child/ack with status=expanded, list_name="abcd"

Parent:
  → ReceiptCard updates: "✓ 'abcd' added. Locking now..."
  → Auto-resubmits original command, now as tier=saved_list
```

---

## 7. Chat Command Grammar

Gemini system prompt updated to emit:

```json
{
  "message": "...",
  "reasoning": "...",
  "action": {
    "type": "lock" | "unlock" | "unlock_all",
    "target_request": "<original user words>",     // "IG", "list 1", "bedtime apps"
    "target_kind_hint": "app" | "list" | "category" | null,
    "duration_minutes": 30 | null,                  // null = permanent lock
    "confirmation_required": false                  // true if ambiguous
  }
}
```

**Backend resolver** (new module, `parent_chat_resolver.py`):
1. **Fuzzy match Saved Lists** (levenshtein ≤ 2, case-insensitive) → tier=saved_list
2. **Fuzzy match Catalog aliases** → tier=exact_bundle
3. **If `target_kind_hint == "category"` OR AI-infer category** → tier=category
4. **Else** → return `confirmation_required=true, suggestions=[...]`

**Target examples**:
| Parent says | Resolved tier | Target |
|---|---|---|
| "lock IG for 30 min" | exact_bundle | Instagram/30m |
| "lock ig and tiktok" | Parse as 2 commands | 2× exact_bundle |
| "ban list 1 for 2 hours" | saved_list | "list 1"/120m |
| "lock bedtime apps" | saved_list | "bedtime apps"/null(permanent) |
| "lock all games" | category | "games"/null |
| "lock games for 1 hour" | category | "games"/60m |
| "lock abcd" | category (AI guesses) OR confirmation | games/null OR ask |
| "unlock everything" | unlock_all | — |
| "unlock IG" | unlock specific | Instagram (reverse the blockedApplications) |

---

## 8. Tamper Detection (deferred, but stubbed in this design)

Out of scope for this spec but noted for future extension:
- Heartbeat: child device POSTs `/child/heartbeat` every N minutes via BGAppRefreshTask.
- Backend: if no heartbeat for X minutes → APNs push to parent: "⚠ Evlin on Liam's phone hasn't checked in."
- Anti-bypass: compare `shield.applications` against last applied; if reset, re-apply + notify parent.

The `Device.last_heartbeat` column and the `/child/heartbeat` endpoint are defined in the data model above so future work doesn't require a migration.

---

## 9. App Catalog (v1)

Initial `app_catalog.json` shipped with backend. Format:

```json
[
  {"names": ["Instagram", "IG", "insta"], "bundle_id": "com.burbn.instagram", "category_hint": "social"},
  {"names": ["TikTok", "抖音", "tt"], "bundle_id": "com.zhiliaoapp.musically", "category_hint": "social"},
  {"names": ["Snapchat", "snap"], "bundle_id": "com.toyopagroup.picaboo", "category_hint": "social"},
  {"names": ["Twitter", "X"], "bundle_id": "com.atebits.Tweetie2", "category_hint": "social"},
  {"names": ["Facebook", "fb"], "bundle_id": "com.facebook.Facebook", "category_hint": "social"},
  {"names": ["Reddit"], "bundle_id": "com.reddit.Reddit", "category_hint": "social"},
  {"names": ["Discord"], "bundle_id": "com.hammerandchisel.discord", "category_hint": "social"},
  {"names": ["WhatsApp"], "bundle_id": "net.whatsapp.WhatsApp", "category_hint": "social"},
  {"names": ["Telegram"], "bundle_id": "ph.telegra.Telegraph", "category_hint": "social"},
  {"names": ["Messenger"], "bundle_id": "com.facebook.Messenger", "category_hint": "social"},

  {"names": ["微信", "WeChat"], "bundle_id": "com.tencent.xin", "category_hint": "social"},
  {"names": ["QQ"], "bundle_id": "com.tencent.mqq", "category_hint": "social"},
  {"names": ["微博", "Weibo"], "bundle_id": "com.sina.weibo", "category_hint": "social"},
  {"names": ["小红书", "RED", "Xiaohongshu"], "bundle_id": "com.xingin.discover", "category_hint": "social"},
  {"names": ["快手", "Kuaishou"], "bundle_id": "com.jsh.kwai", "category_hint": "entertainment"},
  {"names": ["Bilibili", "B站"], "bundle_id": "tv.danmaku.bilianime", "category_hint": "entertainment"},

  {"names": ["Roblox"], "bundle_id": "com.roblox.robloxmobile", "category_hint": "games"},
  {"names": ["Minecraft"], "bundle_id": "com.mojang.minecraftpe", "category_hint": "games"},
  {"names": ["Fortnite"], "bundle_id": "com.epicgames.fortnite", "category_hint": "games"},
  {"names": ["PUBG", "PUBG Mobile"], "bundle_id": "com.tencent.ig", "category_hint": "games"},
  {"names": ["Call of Duty", "COD"], "bundle_id": "com.activision.callofduty.shooter", "category_hint": "games"},
  {"names": ["Among Us"], "bundle_id": "com.innersloth.amongus", "category_hint": "games"},
  {"names": ["Clash Royale"], "bundle_id": "com.supercell.laser", "category_hint": "games"},
  {"names": ["Clash of Clans"], "bundle_id": "com.supercell.magic", "category_hint": "games"},
  {"names": ["Candy Crush"], "bundle_id": "com.midasplayer.apps.candycrushsaga", "category_hint": "games"},
  {"names": ["Subway Surfers"], "bundle_id": "com.kiloo.subwaysurf", "category_hint": "games"},
  {"names": ["Genshin Impact", "原神"], "bundle_id": "com.miHoYo.GenshinImpact", "category_hint": "games"},
  {"names": ["Honor of Kings", "王者荣耀"], "bundle_id": "com.tencent.tmgp.sgame", "category_hint": "games"},
  {"names": ["Peace Elite", "和平精英"], "bundle_id": "com.tencent.tmgp.pubgmhd", "category_hint": "games"},
  {"names": ["Brawl Stars"], "bundle_id": "com.supercell.brawlstars", "category_hint": "games"},
  {"names": ["Free Fire"], "bundle_id": "com.dts.freefireth", "category_hint": "games"},

  {"names": ["YouTube", "yt"], "bundle_id": "com.google.ios.youtube", "category_hint": "entertainment"},
  {"names": ["Netflix"], "bundle_id": "com.netflix.Netflix", "category_hint": "entertainment"},
  {"names": ["Disney+", "Disney Plus"], "bundle_id": "com.disney.disneyplus", "category_hint": "entertainment"},
  {"names": ["Hulu"], "bundle_id": "com.hulu.plus", "category_hint": "entertainment"},
  {"names": ["Twitch"], "bundle_id": "tv.twitch", "category_hint": "entertainment"},
  {"names": ["Spotify"], "bundle_id": "com.spotify.client", "category_hint": "entertainment"},
  {"names": ["Apple Music"], "bundle_id": "com.apple.Music", "category_hint": "entertainment"},
  {"names": ["Pandora"], "bundle_id": "com.pandora", "category_hint": "entertainment"},
  {"names": ["SoundCloud"], "bundle_id": "com.soundcloud.TouchApp", "category_hint": "entertainment"},

  {"names": ["Safari"], "bundle_id": "com.apple.mobilesafari", "category_hint": "productivity"},
  {"names": ["Chrome"], "bundle_id": "com.google.chrome.ios", "category_hint": "productivity"},
  {"names": ["Firefox"], "bundle_id": "org.mozilla.ios.Firefox", "category_hint": "productivity"},
  {"names": ["Edge"], "bundle_id": "com.microsoft.msedge", "category_hint": "productivity"},

  {"names": ["Gmail"], "bundle_id": "com.google.Gmail", "category_hint": "productivity"},
  {"names": ["Outlook"], "bundle_id": "com.microsoft.Office.Outlook", "category_hint": "productivity"},
  {"names": ["Slack"], "bundle_id": "com.tinyspeck.chatlyio", "category_hint": "productivity"},
  {"names": ["Zoom"], "bundle_id": "us.zoom.videomeetings", "category_hint": "productivity"},
  {"names": ["Notion"], "bundle_id": "notion.id", "category_hint": "productivity"},

  {"names": ["Google Maps"], "bundle_id": "com.google.Maps", "category_hint": "travel"},
  {"names": ["Waze"], "bundle_id": "com.waze.iphone", "category_hint": "travel"},
  {"names": ["Uber"], "bundle_id": "com.ubercab.UberClient", "category_hint": "travel"},
  {"names": ["Lyft"], "bundle_id": "com.zimride.instant", "category_hint": "travel"},

  {"names": ["Amazon"], "bundle_id": "com.amazon.Amazon", "category_hint": "shopping"},
  {"names": ["Taobao", "淘宝"], "bundle_id": "com.taobao.taobao4iphone", "category_hint": "shopping"},
  {"names": ["Pinduoduo", "拼多多"], "bundle_id": "com.xunmeng.pinduoduo", "category_hint": "shopping"},

  {"names": ["Duolingo"], "bundle_id": "com.duolingo.DuolingoMobile", "category_hint": "education"},
  {"names": ["Khan Academy"], "bundle_id": "org.khanacademy.Khan-Academy", "category_hint": "education"},
  {"names": ["Quizlet"], "bundle_id": "com.quizlet.quizletapp", "category_hint": "education"},
  {"names": ["Photomath"], "bundle_id": "com.microblink.PhotoMath", "category_hint": "education"}
]
```

Total: 60 apps. Bundle IDs should be re-verified before shipping — some in this list are approximate.

---

## 10. Settings Changes (existing code)

`SettingsView.swift` and `HomeSettingsSheet.swift` gain:
- **Active Mode Toggle** (existing, keep) — flips `UserDefaults["activeMode"]`
- **Saved Lists** section — list all `SavedListMeta`, tap to edit, trash to delete
- **Manage Library** section:
  - (Max mode, parent only) "Pick apps from Liam's device" → opens picker
  - (Std mode or child mode) "Add common apps" → opens picker
- **Pairing** section — show current family code, "unpair device" button
- **Protection Level** — show current (Max/Std), button to reconfigure

---

## 11. Test Plan

**Scope for manual testing (single device, parent/child toggle)**:

1. **Onboarding — Parent → Standard path**
   - Fresh install → complete Parent onboarding in Std mode
   - Verify pairing code displays and polling works
   - Skip child setup
   - Toggle to Child mode → enter pairing code → complete Child onboarding → create a Saved List "list 1" with 2-3 apps
2. **Onboarding — Parent → Maximum path**
   - Requires a real Child Apple ID (deferred; test Std path only in v1)
3. **Chat → Tier A (bundle ID)**
   - Parent mode, say "lock IG for 1 min"
   - Verify ReceiptCard shows pending → confirmed
   - Verify Instagram is blocked on device (open Instagram → system dialog)
   - Wait 1 min → verify auto-unlock
4. **Chat → Tier B (saved list)**
   - Parent mode, say "ban list 1 for 30 min"
   - Verify shield applied to the apps in list 1
5. **Chat → Tier C (category fallback)**
   - Parent mode, say "lock abcd" (unknown app)
   - AI infers games category, receipt shows fallback
   - Tap "Make it precise" → verify library expand flow
6. **Unlock**
   - "unlock everything" → all shields cleared
   - "unlock IG" → only Instagram block removed

**Automated tests (future)**:
- Backend resolver unit tests (Catalog match, Saved List fuzzy match, category inference)
- ActionExecutor unit tests (mock ManagedSettingsStore)

---

## 12. Build Order / Dependencies

Rough phase layout (detailed in implementation plan):

**Phase 1 — Backend foundation**
- New tables, migrations
- /family/create, /family/pair, /family/pairing-status
- /parent/saved-lists, /child/saved-lists
- App Catalog seed + resolver module
- Updated /parent/chat with resolver + Command creation

**Phase 2 — Child device execution**
- ActionExecutor with three tiers
- ActionPoller (BGAppRefreshTask + foreground)
- /child/commands + /child/ack
- LocalAliasStore + category seeding on onboarding

**Phase 3 — Parent device UX**
- ReceiptCard component + state machine
- Chat action handling updated
- Saved Lists management UI
- Library Expand flow on fallback receipts

**Phase 4 — Onboarding rebuild**
- OnboardingCoordinator replaces existing
- Shared, Parent, Child sub-flows
- Pairing UX (code display + polling)
- Both protection levels (Max path stubbed; Std path full)

**Phase 5 — Polish**
- Settings page updates
- Error surface hardening
- Test plan execution

---

## 13. Open Questions / Future Work

- **Max mode full validation** — requires a real Child Apple ID test device. For v1, we build the Max UI path but may not be able to fully verify `.child` authorization flow end-to-end.
- **`ShieldConfigurationDataSource` extension** — to make Tier B/C shields show Evlin's custom UI ("Mom locked this · Unlocks at 16:00"). Separate extension target, added in a later phase.
- **Tamper detection** (heartbeat + alerts) — data model stubbed, endpoints deferred.
- **Recurring time windows** ("lock social every day 9pm–7am") — uses `DeviceActivitySchedule` with `repeats: true`. Deferred to a later spec.
- **Bundle ID verification** — the v1 catalog in §9 is approximate; confirm each bundle ID against the App Store before release.
