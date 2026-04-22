# Three-Tier App Locking + Saved Lists + Onboarding Redesign

**Date**: 2026-04-22 (revised after Codex review + Phase 0 spike)
**Status**: Design approved, ready for plan. Dual-path: **Max is the default/recommended onboarding**; Std is the fallback for users who don't want to configure a Child Apple ID. Future monetization may differentiate the two as premium/free tiers.
**Scope**: Core parental control — locking child apps from parent's Chat, onboarding flow for both modes, Saved Lists, receipt/confirmation system, active-lock union semantics

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
- Correctly handle **overlapping and expiring locks** — a lock expiring must not release apps held by other active locks.
- Support both single-device testing (parent/child mode toggle on one phone) and multi-device production (pairing code links two phones to one family).

## 2. Three-Tier Lock Strategy

Every lock command from Chat resolves to exactly one of three tiers:

### Tier A: Bundle ID Direct Lock

**Mechanism**: `ManagedSettingsStore.application.blockedApplications ⊇ [Application(bundleIdentifier: "com.burbn.instagram")]`

**Used when**: The target matches an entry in the backend's curated **App Catalog** (approx. 60 common apps shipped in v1).

**Characteristics** (verified in Phase 0 spike):
- No picker required, no prior setup.
- Works for well-known apps worldwide.
- **Primary UX: icon hiding.** Blocked apps disappear from the home screen and App Library entirely. Confirmed in spike Test 1.
- Secondary UX: if launched via deep link or alternate path, iOS shows a system "not available" dialog.
- App is not uninstalled — only visually hidden. Icon reappears instantly when the block is cleared.
- Cannot verify whether the app is actually installed on the child's phone (iOS does not report this). The block rule applies regardless; if the app is ever installed + launched it will be blocked.

### Tier B: Saved List (Picker Token) Lock

**Mechanism**: `ManagedSettingsStore.shield.applications ⊇ savedList.applicationTokens; .applicationCategories ⊇ .specific(savedList.categoryTokens)`

**Used when**: The parent has previously created a Saved List (e.g. "list 1", "bedtime apps", "games") by opening `FamilyActivityPicker` and selecting apps/categories/websites.

**Characteristics**:
- 100% precise — only the specific apps the parent chose are locked.
- Shows Evlin's custom shield screen (via `ShieldConfigurationDataSource` extension, planned).
- Lists persist across app launches.
- No hard upper limit on list count (see **Design note**).

**Design note on scale**: Saved Lists are resolved in Chat via fuzzy-match against user intent. Empirically, list counts beyond ~30 per family start to degrade match accuracy. We do not enforce a hard cap; if a family accumulates many lists, the UI should surface a soft warning and encourage list consolidation. A hard cap may be added later based on observed usage.

**Where the tokens live and how they travel** (dual path):

- **Max mode (Child Apple ID + `.child` auth) — default / recommended**:
  - Picker runs on parent device (Family Sharing exposes child's installed apps to parent picker).
  - Unique capability: parent can build and edit Saved Lists from their own phone, without physical access to the child's device.
  - Parent device encodes the resulting `FamilyActivitySelection` as `Data` (PropertyListEncoder). When a lock command references this list, parent device attaches the blob ephemerally via `POST /parent/commands/attach-blob { command_id, selection_blob_b64 }`. Backend stores in `PendingBlob` with short TTL (10 min). Child device fetches once via `GET /child/pending-blob?command_id=...`; backend deletes row on fetch or TTL expiry.
  - **Blobs are never persisted in `SavedListMeta`**; only metadata (name, description, createdAt) is synced.
  - **Open technical risk**: Apple does not officially document that parent-device picker tokens are interchangeable on a child device's `ManagedSettingsStore`. Phase 0 spike Test 3 is BLOCKED pending Child Apple ID access. If tokens are not transferable when tested, Max mode degrades to "parent device sends a remote trigger; child device prompts user to open picker" (same storage model as Std, but still with a remote-initiation UX benefit). The spec is written assuming transferability; the plan notes the degrade path.

- **Std mode (Family Controls passcode only) — fallback for parents not using Child Apple ID**:
  - Picker only runs on child device. Parent cannot remotely build Saved Lists.
  - Child device stores the `FamilyActivitySelection` in App Group UserDefaults keyed by list name.
  - Commands reference the list by name only; child device looks up selection locally.
  - Only list metadata syncs to backend. **Tokens never leave the child device.**

**Both modes share (verified in Phase 0 spike Test 2)**:
- `blockedApplications` with `Application(bundleIdentifier:)` works identically.
- `denyAppRemoval` works identically — Std mode gets deletion protection without requiring Child Apple ID.
- Same `ActiveLockStore` union/recompute semantics.

**Monetization note** (informational, not a technical decision): the two modes create a natural product tiering. Max mode's "remote picker on parent device" is worth a premium tier; Std mode's "install on both phones, manage in person" can remain free. This influences neither the technical design nor the onboarding order — both are fully implemented in v1.

### Tier C: Category Fallback Lock

**Mechanism**: `ManagedSettingsStore.shield.applicationCategories ⊇ .specific([gamesToken, socialToken, ...])`

**Used when**:
- Target not in catalog AND not in any Saved List.
- AI/parent chose a category name directly ("lock all games").
- Fallback for unrecognized names where AI can infer a category ("abcd" probably a game).

**Characteristics**:
- Catches the target if it's truly in that category.
- Automatically covers any new app of that category installed in the future.
- Has collateral impact — every app in the category is blocked.
- Requires that the child device picked category tokens once during onboarding (Child Step 5C).

**Resolution priority** (backend chooses the first match):
1. Saved List name → Tier B
2. App name in Catalog → Tier A
3. Category name or AI-inferred category → Tier C
4. Total miss → `confirmation_required=true` with proposed category

---

## 3. Data Model

### 3.1 Backend (FastAPI + Postgres)

```python
class Family(Base):
    id = Column(UUID, primary_key=True)
    protection_mode = Column(Enum("max", "std"))  # chosen at parent onboarding
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
    protection_mode = Column(Enum("max", "std"))  # locked at code generation
    expires_at = Column(DateTime)
    used = Column(Boolean, default=False)

class SavedListMeta(Base):
    id = Column(UUID, primary_key=True)
    family_id = Column(UUID, FK("family.id"), index=True)
    name = Column(String)            # "list 1", "bedtime apps" — unique per family
    description = Column(String, nullable=True)
    mode = Column(Enum("parent_device", "child_device"))
    owning_device_id = Column(UUID, FK("device.id"))
    # NOTE: selection blobs are NEVER persisted here. Tokens stay on the owning device
    # (Std) or relay ephemerally through PendingBlob (Max). Only metadata is synced.
    created_at = Column(DateTime)
    updated_at = Column(DateTime)

class Command(Base):
    id = Column(UUID, primary_key=True)
    family_id = Column(UUID, FK("family.id"), index=True)
    target_device_id = Column(UUID, FK("device.id"))
    payload = Column(JSON)           # see Command payload below — blob NOT stored here
    created_at = Column(DateTime)
    picked_up_at = Column(DateTime, nullable=True)
    acked_at = Column(DateTime, nullable=True)
    ack_status = Column(Enum)        # pending, confirmed_exact, confirmed_fallback, failed, timeout
    ack_detail = Column(JSON, nullable=True)

class PendingBlob(Base):
    """Ephemeral relay for Max-mode selection blobs. Short-lived.
    Inserted when parent device POSTs a command with selection_blob.
    Fetched exactly once by the child device.
    Deleted on ack or at expires_at (whichever first).
    """
    command_id = Column(UUID, FK("command.id"), primary_key=True)
    blob = Column(LargeBinary)
    expires_at = Column(DateTime)    # default now() + 10 min
```

**Command payload** (JSON — NO blob inline; blob is fetched via separate endpoint):
```json
{
  "command_id": "uuid",
  "action": "lock" | "unlock" | "unlock_all" | "expand_library",
  "tier": "exact_bundle" | "saved_list" | "category",
  "target": {
    "bundle_id": "com.burbn.instagram",   // tier=exact_bundle
    "list_name": "list 1",                // tier=saved_list
    "has_pending_blob": true,             // tier=saved_list AND Max mode
    "category_hint": "social",            // tier=category
    "original_request": "IG"
  },
  "duration_minutes": 30,                 // null = permanent
  "issued_at": "2026-04-22T14:20:00Z"
}
```

Child device, on seeing `has_pending_blob: true`, makes a one-shot `GET /child/pending-blob?command_id=...` to fetch the blob. Backend returns blob + deletes the `PendingBlob` row on successful response.

### 3.2 Child Device Local Storage (App Group UserDefaults `group.com.evlin.ios`)

```swift
struct LocalAliasStore: Codable {
    var categoryTokens: [String: ActivityCategoryToken]   // "games" → token
    var savedListTokens: [String: FamilyActivitySelection] // "list 1" → full selection (Std mode only)
}

struct ActiveLock: Codable {
    let commandID: UUID
    let tier: Tier                                        // .exactBundle / .savedList / .category
    let blockedBundleIDs: Set<String>                     // tier=exact_bundle
    let shieldAppTokens: Set<ApplicationToken>            // tier=saved_list
    let shieldCategoryTokens: Set<ActivityCategoryToken>  // tier=saved_list or category
    let issuedAt: Date
    let expiresAt: Date?                                  // nil = permanent
    let originalRequest: String                           // for UI / receipt
    let displayName: String                               // "Instagram", "list 1", "Games"
}

struct ActiveLockStore: Codable {
    var locks: [UUID: ActiveLock]
}
```

Persisted under:
- `evlin.localAliases` (plist-encoded `LocalAliasStore`)
- `evlin.activeLocks` (plist-encoded `ActiveLockStore`)

### 3.3 Parent Device Local Storage

Stores only non-token metadata:
- Parent's view of SavedListMeta (name, description) — cached from backend for Chat UI.
- Current child's name, protection_mode, pairing status.

In Max mode, parent device temporarily holds picked `FamilyActivitySelection` in memory just long enough to POST it with a command. No long-term on-device persistence.

### 3.4 App Catalog (backend, in-memory seeded from JSON)

See §9 for the full v1 catalog.

---

## 4. Architecture

```
┌───────────────────────────────────────┐   ┌──────────────────────────────────┐
│  Parent Device                         │   │  Backend                         │
│                                        │   │                                  │
│  Chat.sendMessage("lock IG 30 min")    │◄─►│  POST /parent/chat               │
│  → APIClient                           │   │  - Gemini parses → action        │
│  → ReceiptCard(pending)                │   │  - Resolver: pick tier            │
│                                        │   │  - Create Command row            │
│                                        │   │  - Trigger APNs silent push      │
│  Poll /parent/ack-status?cmd=...       │◄─►│  GET  /parent/ack-status         │
│  → ReceiptCard → confirmed/failed      │   │                                  │
│                                        │   │  GET  /child/commands?device=... │
│  (Max mode only)                       │   │  GET  /child/pending-blob        │
│  ManageLists → FamilyActivityPicker    │   │  POST /child/ack                 │
│  → POST /parent/saved-lists (meta)     │◄─►│  POST /parent/saved-lists (meta) │
│  (blob travels per-command, not here)  │   │  APNs push → child device        │
└───────────────────────────────────────┘   └──────────────────────────────────┘
                                                           ▲
                                                           │ APNs silent push
                                             ┌─────────────┴────────────────┐
                                             │  Child Device                │
                                             │                              │
                                             │  Command delivery (3 tiers): │
                                             │  1) APNs silent push (1°)    │
                                             │  2) foreground poll (2°)     │
                                             │  3) BGAppRefreshTask (3°)    │
                                             │                              │
                                             │  ActionExecutor.apply():     │
                                             │    → ActiveLockStore.add()   │
                                             │    → recompute union         │
                                             │    → write ManagedSettings   │
                                             │                              │
                                             │  POST /child/ack             │
                                             │                              │
                                             │  DeviceActivityMonitor ext:  │
                                             │    on intervalEnd →          │
                                             │    ActiveLockStore.remove()  │
                                             │    + recompute union         │
                                             │                              │
                                             │  ManageLists (Std mode only) │
                                             │  → FamilyActivityPicker      │
                                             │  → local aliasStore          │
                                             │  → POST meta                 │
                                             └──────────────────────────────┘
```

**Command delivery layers** (ordered by reliability):
1. **APNs silent push** — backend pushes `aps: {content-available: 1}` to child device when a command is queued. Child wakes briefly, fetches queue. **Primary path.** Not 100% guaranteed (iOS throttles), but best-effort real-time.
2. **Foreground polling** — when child app is foreground, `NSTimer` polls `/child/commands` every 5 seconds. Covers the "child using their phone" case with low latency.
3. **BGAppRefreshTask** — opportunistic catch-up, scheduled for every ~1h. Not relied on for correctness; acts as a sweep for missed pushes.

**MVP constraint**: APNs requires backend integration (APNs key, push certificate). To avoid blocking early progress, Phase 2 uses foreground polling only; APNs is added in Phase 5. During that window, commands only apply when the child app is running in foreground — acceptable for single-device testing and early demos, not for production.

**Single-device test mode**: Settings toggle flips `UserDefaults["activeMode"]` between `parent` and `child`. Each mode POSTs to backend with its own `device_id` (two devices registered under one family). HTTP round-trips happen identically to real two-device flows.

---

## 5. Onboarding Flow (MVP — Std-mode-only)

### 5.1 Shared Entry

```
[1] Welcome
    - Shield icon
    - "The Informed Sentinel" tagline
    - [Continue]

[2] Mode Select
    ┌────────────────┐   ┌────────────────┐
    │  I'm the parent │   │  I'm the child  │
    └───────┬────────┘   └────────┬───────┘
            ▼                      ▼
       Parent Flow            Child Flow
```

### 5.2 Parent Mode Flow

**Protection Level is chosen BEFORE the pairing code is generated, so the code carries the protection_mode atomically. Max is presented as the default / recommended option.**

```
[1] Welcome
[2] Mode Select → Parent
[3P] Add Child
     Name: [____]        ← required
     Age:  [_]           ← optional
     [Continue]

[4P] Protection Level Select
     ◉ Maximum (recommended — default selection)
       · You can build & edit Saved Lists from THIS phone (see child's apps)
       · Evlin cannot be uninstalled from Liam's phone
       · Requires Child Apple ID (5 min one-time setup)
       [Choose Maximum]
     ○ Standard
       · You build Saved Lists on Liam's phone (need physical access occasionally)
       · Evlin still cannot be uninstalled (programmatic protection)
       · No extra account needed — simpler setup
       [Choose Standard]

[5P] Pairing Code Display
     ┌────────────────────┐
     │   4 8 2 9 1 7       │   ← POST /family/create returns code with protection_mode baked in
     │   [QR code]          │
     └────────────────────┘
     Status: ⚪ Waiting for Liam's device...
     │  (poll /family/pairing-status?code=…)
     ↓ Liam joined
     Status: ✓ Liam's phone connected
     [Continue]

[6P] Protection Instructions (different content by mode)

     ┌─ Maximum mode ──────────────────────────────────┐
     │  [6P-Max-A] Why Child Apple ID                  │
     │     · Lets you build Saved Lists from here      │
     │     · Enables remote list edits                 │
     │     · Required for Ask-to-Buy + content filters │
     │     · Fully compliant with Apple Family Sharing │
     │     [Got it, let's set it up]                   │
     │                                                 │
     │  [6P-Max-B] Create Child Apple ID                │
     │     "On THIS phone: Settings → Family →         │
     │      Add Member → Create a Child Account"       │
     │     [Open Family Settings]                      │
     │     [I've created the account]                  │
     │                                                 │
     │  [6P-Max-C] Sign In on Child Device              │
     │     "On Liam's phone, sign in with the Child    │
     │      Apple ID you just created."                │
     │     [I've signed in on Liam's phone]            │
     │                                                 │
     │  [6P-Max-D] Waiting for Authorization           │
     │     "Pick up Liam's phone. Evlin there will     │
     │      request parent authorization; approve when │
     │      iOS prompts you."                          │
     │     Status: ⚪ Waiting for child device...       │
     │     (polls backend for auth_status=granted)     │
     │     ↓                                            │
     │     Status: ✓ Parent authorization granted      │
     │     [Continue]                                  │
     └─────────────────────────────────────────────────┘

     ┌─ Standard mode ─────────────────────────────────┐
     │  [6P-Std-A] Set Screen Time Passcode            │
     │     "On Liam's phone: Settings → Screen Time →  │
     │      Lock Screen Time Settings → Set Passcode"  │
     │     (Protects Screen Time itself from being     │
     │      modified by Liam. Evlin's own deletion     │
     │      protection is automatic, no passcode dance.)│
     │     [Open Screen Time Settings]                 │
     │     [I've set the passcode]                     │
     └─────────────────────────────────────────────────┘

[7P] First Saved List (Max mode only — optional)
     "Make your first Saved List from YOUR phone."
       [Open App Picker]  ← FamilyActivityPicker on parent device (Max mode: shows child apps)
       → select apps/categories/websites → name it "list 1"
       → selection cached locally on parent device; POST meta to backend
       [Skip for now]
     (Std mode: skipped here — lists are built on child device at Child Step 7C.)

[8P] Done
     "Liam is protected. Open Chat to send your first command."
     [Enter Evlin]
```

### 5.3 Child Mode Flow

**Key change: `.child` authorization (Max mode) and `denyAppRemoval` (both modes) are invoked on the child device. Parent is expected to be physically present for the auth/protection steps.**

```
[1] Welcome
[2] Mode Select → Child
[3C] Enter Pairing Code
     ┌───────────┐
     │ _ _ _ _ _ _│
     └───────────┘
     POST /family/pair {code, device_label}
     → returns {family_id, protection_mode, parent_device_id}
     → "Connected to Mom's Evlin ✓"
     [Continue]

[4C] Grant Screen Time Permission
     "Evlin needs Screen Time permission on this phone."
     [Grant Permission]
     ├─ protection_mode=max →
     │    1. AuthorizationCenter.requestAuthorization(for: .child)
     │       (iOS surfaces approval prompt on parent's device via Family Sharing;
     │        parent approves there, this call resolves)
     │    2. On success: POST /family/auth-status/grant
     │    3. If failure ("not a child account"): show remediation —
     │       Child Apple ID not signed in on this device.
     │       [Retry] / [Switch to Standard mode]
     │
     └─ protection_mode=std →
          AuthorizationCenter.requestAuthorization(for: .individual)
          (no parent approval needed)
     [Continue]

[5C] Enable Deletion Protection — BOTH modes
     "Evlin will now block itself from being deleted on this phone."
     [Enable Protection]
     → ManagedSettingsStore.application.denyAppRemoval = true
     → Verify: re-read store, confirm flag is set.
     "✓ Evlin is now protected from deletion. Liam cannot uninstall Evlin
      even if they learn the device passcode."
     [Continue]
     (Verified in Phase 0 spike Test 2: denyAppRemoval works under both
      `.individual` and `.child` authorization — same mechanism for both paths.)

[6C] Category Defaults — REQUIRED
     "Pick which categories your parent should be able to control."
     [Open Category Picker]
     → FamilyActivityPicker (user picks: Social, Games, Entertainment, etc.)
     → save tokens to local categoryTokens
     [Continue]

[7C] Create First Saved List (Std mode only; Max mode skips because parent built it in [7P])
     "Make your first Saved List. Your parent can say 'lock list 1 for 30 min' in Chat."
     [Open App Picker]
     → FamilyActivityPicker (apps + categories + websites)
     → Name: [list 1]
     → save to local savedListTokens
     → POST /family/saved-lists {name, description} (metadata only)
     [Skip for now]

[8C] Child Ready Screen
     "Waiting for commands from Mom's Evlin."
     · Shows active lock status (from ActiveLockStore)
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
      Views/Onboarding/Parent/ProtectionLevelStep.swift
      Views/Onboarding/Parent/PairingCodeStep.swift
      Views/Onboarding/Parent/Max/WhyChildAppleIDStep.swift
      Views/Onboarding/Parent/Max/CreateChildAppleIDStep.swift
      Views/Onboarding/Parent/Max/SignInOnChildStep.swift
      Views/Onboarding/Parent/Max/WaitForAuthorizationStep.swift
      Views/Onboarding/Parent/Std/SetPasscodeStep.swift
      Views/Onboarding/Parent/FirstSavedListStep.swift     (Max only)
      Views/Onboarding/Parent/DoneStep.swift
      Views/Onboarding/Child/EnterPairingCodeStep.swift
      Views/Onboarding/Child/GrantPermissionStep.swift
      Views/Onboarding/Child/DeletionProtectionStep.swift  (BOTH modes — moved from Max-only)
      Views/Onboarding/Child/CategoryDefaultsStep.swift
      Views/Onboarding/Child/FirstSavedListStep.swift       (Std only)
      Views/Onboarding/Child/ChildReadyStep.swift

DELETE: Views/Onboarding/OnboardingView.swift
        Views/Onboarding/SetupView.swift
```

**Key differences from pre-spike spec**:
- Std mode lost the "DisableDeletion" and "StdVerification" steps (`denyAppRemoval` handles it programmatically now).
- Child `DeletionProtectionStep` is now **always** reached, not Max-only.
- Max is presented as the default/recommended choice in `[4P]` instead of equal weighting.

---

## 6. Lock Flow (runtime)

### 6.1 Parent Types a Command

```
Parent: "lock IG for 30 min"
        │
        ▼
ChatView → POST /parent/chat
        │
        ▼
Backend:
  1. Gemini parses: {target_request:"IG", target_kind_hint:"app", duration_minutes:30}
  2. Resolver pipeline:
     a. Fuzzy-match Saved Lists → miss
     b. Catalog lookup "IG" → hit: com.burbn.instagram, social
     c. Tier = exact_bundle
  3. Create Command row with payload
  4. (Max saved-list commands only) If parent device attached selection_blob,
     INSERT PendingBlob row with TTL=10min
  5. Schedule APNs silent push to target child device (future Phase 5)
  6. Return to parent client:
     {
       "message": "Locking Instagram for 30 min.",
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
ReceiptCard polls GET /parent/ack-status?command_id=uuid every 1s (up to 10s timeout)
```

### 6.2 Child Device Executes

```
Child (on APNs silent push OR foreground poll OR BG refresh):
  GET /child/commands?device_id=X&since=<timestamp>
  → returns unacked commands
  For each:
    if payload.target.has_pending_blob:
      blob ← GET /child/pending-blob?command_id=...
      (backend serves + deletes row)
    result ← ActionExecutor.execute(cmd, blob)
    POST /child/ack {command_id, status, detail}
```

### 6.3 ActiveLockStore — Union & Recompute Semantics (CRITICAL)

Multiple concurrent locks must compose correctly. A lock expiring must release *only its own contributions*. Achieved by holding all active locks in a single store and **recomputing the full union on every change.**

```swift
actor ActiveLockStore {
    private var locks: [UUID: ActiveLock] = [:]
    private let store = ManagedSettingsStore()
    private let storageKey = "evlin.activeLocks"

    // MARK: - API

    func add(_ lock: ActiveLock) {
        locks[lock.commandID] = lock
        persist()
        recomputeAndApply()
    }

    func remove(commandID: UUID) {
        locks.removeValue(forKey: commandID)
        persist()
        recomputeAndApply()
    }

    func sweepExpired(now: Date = Date()) -> [UUID] {
        let expired = locks.values
            .filter { ($0.expiresAt ?? .distantFuture) <= now }
            .map(\.commandID)
        for id in expired { locks.removeValue(forKey: id) }
        if !expired.isEmpty {
            persist()
            recomputeAndApply()
        }
        return expired
    }

    func current() -> [ActiveLock] { Array(locks.values) }

    // MARK: - Core

    /// Recomputes union of ALL active locks and writes to ManagedSettingsStore.
    /// This is the single source of truth — no incremental diffs, no partial updates.
    private func recomputeAndApply() {
        if locks.isEmpty {
            store.application.blockedApplications = nil
            store.shield.applications = nil
            store.shield.applicationCategories = nil
            return
        }

        // Union Tier A contributions
        let allBundleIDs = locks.values.flatMap(\.blockedBundleIDs)
        let bundleApps = Set(allBundleIDs.map { Application(bundleIdentifier: $0) })
        store.application.blockedApplications = bundleApps.isEmpty ? nil : bundleApps

        // Union Tier B app tokens
        let allAppTokens = Set(locks.values.flatMap(\.shieldAppTokens))
        store.shield.applications = allAppTokens.isEmpty ? nil : allAppTokens

        // Union Tier B + C category tokens
        let allCategoryTokens = Set(locks.values.flatMap(\.shieldCategoryTokens))
        store.shield.applicationCategories = allCategoryTokens.isEmpty
            ? nil
            : .specific(allCategoryTokens)
    }

    private func persist() {
        let dict = ActiveLockStore.StoredPayload(locks: locks)
        if let data = try? PropertyListEncoder().encode(dict) {
            UserDefaults(suiteName: "group.com.evlin.ios")?.set(data, forKey: storageKey)
        }
    }
    // restore() on init — symmetric

    private struct StoredPayload: Codable { let locks: [UUID: ActiveLock] }
}
```

**Expiry orchestration**:
- When `add(_:)` is called with `expiresAt != nil`, schedule a `DeviceActivitySchedule` keyed by `commandID`.
- When `DeviceActivityMonitor.intervalDidEnd(DeviceActivityName)` fires (the extension), decode `commandID` from the name, call `ActiveLockStore.shared.remove(commandID: id)`.
- `sweepExpired()` runs as a safety net on app foreground and on every APNs wake — catches drift if extension missed a fire.

**Unlock commands**:
- `action=unlock, target=IG` → find lock(s) in store whose `displayName == "Instagram"` OR `blockedBundleIDs` contains `com.burbn.instagram` → remove those.
- `action=unlock_all` → clear entire store.

### 6.4 ActionExecutor

```swift
final class ActionExecutor {
    static let shared = ActionExecutor()

    func execute(_ cmd: Command, blob: Data? = nil) async -> AckResult {
        guard ScreenTimeManager.shared.isAuthorized else {
            return .failed(.notAuthorized)
        }

        // Handle non-lock commands
        switch cmd.action {
        case .unlockAll:
            await ActiveLockStore.shared.removeAll()
            return .confirmedExact(displayName: "All locks cleared")

        case .unlock:
            // Remove any matching locks
            let matched = await ActiveLockStore.shared.removeMatching(cmd.target)
            return matched.isEmpty
                ? .failed(.nothingToUnlock)
                : .confirmedExact(displayName: cmd.target.originalRequest)

        case .expandLibrary:
            return await runExpandLibraryFlow(cmd)  // see §6.6

        case .lock:
            break
        }

        // Build ActiveLock from command + blob
        do {
            let lock = try buildLock(from: cmd, blob: blob)
            await ActiveLockStore.shared.add(lock)

            // Schedule auto-unlock via DeviceActivity if duration set
            if let mins = cmd.durationMinutes {
                try scheduleRelock(commandID: lock.commandID, minutes: mins)
            }

            switch cmd.tier {
            case .exactBundle, .savedList:
                return .confirmedExact(displayName: lock.displayName)
            case .category:
                return .confirmedFallback(
                    displayName: lock.displayName,
                    category: cmd.target.categoryHint ?? "unknown",
                    origRequest: cmd.target.originalRequest
                )
            }
        } catch let err as ExecuteError {
            return .failed(err.ackReason)
        } catch {
            return .failed(.execution(error.localizedDescription))
        }
    }

    private func buildLock(from cmd: Command, blob: Data?) throws -> ActiveLock {
        switch cmd.tier {
        case .exactBundle:
            guard let bid = cmd.target.bundleID else { throw ExecuteError.malformed }
            return ActiveLock(
                commandID: cmd.id, tier: .exactBundle,
                blockedBundleIDs: [bid],
                shieldAppTokens: [], shieldCategoryTokens: [],
                issuedAt: cmd.issuedAt,
                expiresAt: cmd.expiresAt,
                originalRequest: cmd.target.originalRequest,
                displayName: cmd.target.targetDisplay ?? bid
            )

        case .savedList:
            let selection: FamilyActivitySelection = try decodeSelection(cmd: cmd, blob: blob)
            return ActiveLock(
                commandID: cmd.id, tier: .savedList,
                blockedBundleIDs: [],
                shieldAppTokens: selection.applicationTokens,
                shieldCategoryTokens: selection.categoryTokens,
                issuedAt: cmd.issuedAt,
                expiresAt: cmd.expiresAt,
                originalRequest: cmd.target.originalRequest,
                displayName: cmd.target.listName ?? "saved list"
            )

        case .category:
            guard let hint = cmd.target.categoryHint,
                  let tok = LocalAliasStore.shared.categoryToken(forName: hint)
            else { throw ExecuteError.categoryNotConfigured(cmd.target.categoryHint ?? "unknown") }
            return ActiveLock(
                commandID: cmd.id, tier: .category,
                blockedBundleIDs: [],
                shieldAppTokens: [],
                shieldCategoryTokens: [tok],
                issuedAt: cmd.issuedAt,
                expiresAt: cmd.expiresAt,
                originalRequest: cmd.target.originalRequest,
                displayName: hint.capitalized
            )
        }
    }

    private func decodeSelection(cmd: Command, blob: Data?) throws -> FamilyActivitySelection {
        if let blob = blob,
           let decoded = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: blob) {
            return decoded  // Max mode: provided blob
        }
        if let listName = cmd.target.listName,
           let local = LocalAliasStore.shared.savedList(named: listName) {
            return local   // Std mode: local lookup
        }
        throw ExecuteError.listNotFound(cmd.target.listName ?? "(unnamed)")
    }
}
```

### 6.5 Receipt Card States

```swift
enum ReceiptState {
    case pending
    case confirmedExact(displayName: String, unlocksAt: Date?)
    case confirmedFallback(displayName: String, category: String, origRequest: String)
    case failedPermission
    case failedListNotFound(listName: String)
    case failedCategoryNotConfigured(category: String)
    case failedTimeout
    case failedOther(reason: String)
}
```

Receipt card is a new `ChatMessage` subtype rendered by `ReceiptCard` view. Displays:
- Status icon + color (🟡🟢🔴⚪)
- Primary line: "Instagram locked"
- Secondary line: time + duration + collateral count
- Footer actions:
  - `.confirmedFallback` → `[Make it precise]` → Library Expand flow (§6.6)
  - `.confirmedExact` → `[Unlock now]` → sends `action=unlock` command

### 6.6 Library Expand (Tier A/C → B Promotion)

```
Parent taps [Make it precise] on fallback receipt:
  → POST /parent/command {action: expand_library, target: "abcd"}
  → ReceiptCard("Waiting for Liam to add abcd...")

Backend: creates Command with action=expand_library for child device

Child Device:
  → Receives command (APNs / foreground poll / BG)
  → Shows system notification: "Mom wants to add 'abcd' to Evlin"
  → Tap → opens Evlin with picker pre-launched
  → User picks app → names it "abcd"
  → Saved to LocalAliasStore.savedListTokens["abcd"]
  → POST /child/ack {status: expanded, list_name: "abcd"}

Parent:
  → ReceiptCard updates: "✓ 'abcd' added. Locking now..."
  → Auto-resubmits original command, now as tier=saved_list
```

---

## 7. Chat Command Grammar

Gemini system prompt emits:
```json
{
  "message": "...",
  "reasoning": "...",
  "action": {
    "type": "lock" | "unlock" | "unlock_all",
    "target_request": "<original user words>",
    "target_kind_hint": "app" | "list" | "category" | null,
    "duration_minutes": 30 | null,
    "confirmation_required": false
  }
}
```

**Backend resolver** (new module `parent_chat_resolver.py`):
1. Fuzzy-match Saved List names (Levenshtein ≤ 2, case-insensitive) → tier=saved_list
2. Fuzzy-match Catalog aliases → tier=exact_bundle
3. If `target_kind_hint == "category"` OR AI-inferred category → tier=category
4. Else → `confirmation_required=true` with suggestions

**Examples**:

| Parent says | Resolved tier | Target |
|---|---|---|
| "lock IG for 30 min" | exact_bundle | Instagram/30m |
| "lock ig and tiktok" | 2 commands | 2× exact_bundle |
| "ban list 1 for 2 hours" | saved_list | "list 1"/120m |
| "lock bedtime apps" | saved_list | "bedtime apps"/null (permanent) |
| "lock all games" | category | "games"/null |
| "lock games for 1 hour" | category | "games"/60m |
| "lock abcd" | category (AI guess) OR confirmation | games/null OR ask |
| "unlock everything" | unlock_all | — |
| "unlock IG" | unlock specific | Instagram |

---

## 8. Tamper Detection (deferred — Phase 5)

Data model stubbed now so migrations aren't needed later:
- `Device.last_heartbeat` column exists.
- Child device POSTs `/child/heartbeat` every N minutes via BGAppRefreshTask (Phase 5).
- Backend detects stale heartbeats → APNs push to parent.
- Child can compare `ManagedSettingsStore.shield.applications` against `ActiveLockStore` state — if reset externally (passcode breach), re-apply + alert.

---

## 9. App Catalog (v1)

See `backend/app/data/app_catalog.json` (to be created). Initial 60 entries:

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

Total: 60 apps. Bundle IDs approximate; verify against live App Store entries before release.

---

## 10. Settings Changes

`SettingsView.swift` and `HomeSettingsSheet.swift` gain:
- **Active Mode Toggle** (existing) — flips `UserDefaults["activeMode"]`
- **Saved Lists** section — list all SavedListMeta, tap to edit (if mode == current device), delete with confirmation
- **Manage Library** — (Child/Std only) "Add Saved List" → picker
- **Pairing** — show current family code (if still valid), "unpair" button
- **Protection Level** — show current (Max/Std), "reconfigure" button (re-runs that branch of onboarding)
- **Active Locks** (Child only) — shows current entries in `ActiveLockStore` with remaining time + manual override

---

## 11. Test Plan

Manual (single device, parent/child toggle):

1. **Onboarding — Parent → Standard path**
   - Fresh install → pick Standard → pairing code shown → toggle to child mode → enter code → complete child onboarding including Saved List "list 1" with 2–3 apps.
2. **Onboarding — Parent → Maximum path**
   - Requires real Child Apple ID (deferred; test Std only for MVP).
3. **Tier A (bundle ID)**
   - Parent: "lock IG for 1 min"
   - ReceiptCard: pending → confirmed
   - On device, open Instagram → system block dialog
   - After 1 min → verify auto-unlock
4. **Tier B (saved list)**
   - Parent: "ban list 1 for 30 min"
   - Verify shields applied to the list's apps
5. **Tier C (category fallback)**
   - Parent: "lock abcd"
   - Verify AI infers games → Games category shielded
   - Tap "Make it precise" → library expand flow → verify precise lock
6. **Concurrent locks + expiry**
   - "lock IG for 1 min"
   - Immediately after: "lock TikTok for 5 min"
   - Verify both shielded simultaneously
   - Wait 1 min → IG unlocks, TikTok remains ← **critical ActiveLockStore test**
   - Wait 4 more min → TikTok unlocks
7. **Unlock**
   - "unlock everything" → all cleared
   - "unlock IG" → only Instagram removed (others intact)

Automated (future):
- Resolver unit tests (catalog, fuzzy list match, category inference)
- ActiveLockStore unit tests (add/remove/sweep/union correctness)
- ActionExecutor integration tests (mock ManagedSettingsStore)

---

## 12. Build Order / Phases (revised per Codex review)

**Phase 0 — Spike (real device validation)**
- Verify `Application(bundleIdentifier:)` actually blocks app launch as expected
- Verify `denyAppRemoval` can be set
- Verify Max-mode token transferability: picker on parent device → tokens work when applied on child device's `ManagedSettingsStore`
- Verify `.child` authorization flow with a real Child Apple ID
- **Outcome**: a 1-page spike report in `docs/superpowers/specs/2026-04-22-spike-notes.md` documenting which paths work and what Max mode degrades to if tokens aren't transferable.

**Phase 1 — iOS foundation: ActiveLockStore + ActionExecutor**
- `ActiveLockStore` actor with union/recompute logic
- `ActionExecutor` with all three tiers (bundle_id works immediately; saved_list/category stubs initially)
- `LocalAliasStore` skeleton
- `DeviceActivityMonitor` extension integrated with ActiveLockStore removal
- Unit-testable; no networking yet (commands are constructed in-code for test purposes)

**Phase 2 — Backend minimal: commands + ack**
- Migrations for Family/Device/PairingCode/Command/PendingBlob/SavedListMeta
- Endpoints: `/family/create`, `/family/pair`, `/family/pairing-status`, `/parent/chat` (resolver + Command row creation), `/child/commands`, `/child/ack`, `/parent/ack-status`
- `parent_chat_resolver.py` with Catalog lookup + fuzzy Saved List match + category inference
- App Catalog JSON seed (60 entries)
- Parent client: foreground polling for ack-status
- Child client: foreground polling for commands (5s interval while app foreground)
- **No APNs yet** — commands only apply when child app is foreground. Acceptable for single-device test.

**Phase 3 — Std mode Saved Lists end-to-end**
- Child device FamilyActivityPicker UI for building lists
- POST `/child/saved-lists` meta sync
- Resolver picks up new lists
- Parent Chat can say "ban list 1 for 30 min" → reaches child → shields apply
- Tested single-device (mode toggle) and dual-device (two phones on same family)

**Phase 4 — Onboarding rebuild + Max mode path**
- `OnboardingCoordinator` replacing `OnboardingView`/`SetupView`
- Shared + Parent + Child sub-flows per §5.2/§5.3
- Protection level selection + pairing carrying protection_mode
- Max mode: Child Apple ID guide, `.child` auth on child device, `denyAppRemoval` on child device
- Max mode Saved Lists: parent-device picker + ephemeral blob relay via PendingBlob
- Std mode fully supported (Max path may have placeholder verification if real Child Apple ID unavailable)

**Phase 5 — Production robustness**
- APNs silent push integration (backend + iOS client)
- BGAppRefreshTask as opportunistic sweep
- Heartbeat endpoint + tamper detection
- Receipt card failure modes + retry UX
- Settings page updates (§10)

---

## 13. Open Questions / Future Work

- **Max mode validation** — dependent on Phase 0 spike result. If tokens aren't transferable across devices, Max Saved Lists fall back to child-device picker (same as Std mode).
- **`ShieldConfigurationDataSource` extension** — to make Tier B/C shields show Evlin's custom UI ("Mom locked this · Unlocks at 16:00"). Separate extension target, later phase.
- **Recurring time windows** — "lock social every day 9pm–7am" uses `DeviceActivitySchedule` with `repeats: true`. Deferred to a later spec.
- **Bundle ID verification** — v1 catalog in §9 is approximate; verify each entry against the App Store before shipping.
- **Saved List hard cap** — not enforced in v1. If usage data shows fuzzy-match accuracy suffers past a threshold, introduce a soft warning or hard cap.
