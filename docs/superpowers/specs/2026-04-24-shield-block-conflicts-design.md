# Shield / Block Conflict Resolution + Confirmation Cards

**Date**: 2026-04-24
**Status**: Design approved, ready for plan
**Supersedes**: data-model portions of `2026-04-22-three-tier-lock-design.md`
**Scope**: Redesign of ActiveLockStore + conflict resolution + confirmation card catalog + Std/Max behavior delta + Gemini prompt contract + receipt grammar

---

## 1. Problem Statement

The Phase 1 `ActiveLock` model was indexed by `commandID`. That made "multiple shield commands on the same target" semantically undefined — it would create two records for the same target, both surviving in the store. Users have since clarified:

1. Shield semantics need explicit merging rules (same `(tier, target)` merges; different `(tier, target)` coexist even if they cover the same app).
2. There are now **two distinct actions**: `shield` (time-limited overlay) and `block` (permanent icon-hiding). They must never be implicitly inter-converted.
3. Every mutation needs honest receipts that report not just what changed but **what the target is still subject to** (effective state).
4. Users will frequently be missing info (no duration, ambiguous target) or their intent will conflict with existing state. The system needs a small, orthogonal **confirmation card catalog**.
5. Gemini's verb→intent mapping must be strict — no fuzzy assumptions that lead to accidental destructive actions.

This spec replaces the data-model and confirmation parts of the older three-tier design.

---

## 2. Key Decisions (summary)

| # | Decision |
|---|---|
| D1 | Two actions: `shield` (overlay, time-limited or permanent) and `block` (hide icon, always permanent until `unblock`). No implicit conversion. |
| D2 | `ActiveLockStore` holds **ShieldRecord** (indexed by stable `recordKey = tier:targetKey`) and **BlockRecord** (indexed by `bundleID`) separately. Multiple ShieldRecords can cover the same app — they coexist. |
| D3 | Effective state for any app is computed at runtime via `effectiveState(for: AppQuery)`. No persisted coverage cache. |
| D4 | Shield merges on same `(tier, targetKey)`: same→max-expiry, timed→permanent auto-upgrades, permanent→timed requires user confirmation. |
| D5 | **Creating** a block is Max-only. Std cannot create blocks. **Removing** blocks (`unblock` / `unblockAll`) works in BOTH modes — otherwise a device downgraded from Max to Std would have orphaned, unreachable blocks. `denyAppRemoval` is available to both via a default-on onboarding toggle with clear side-effect copy. |
| D6 | Receipts always report effective state after mutation. `"Unlocked IG. Still shielded by Social until 17:30."` |
| D7 | 17 confirmation scenarios collapse to **8 reusable card templates** driven by payload. |
| D8 | Dispatcher routes by **user-verb-first**, not by resolver-first. `block` in Std hits Max-feature card, not Std-can't-shield card. |
| D9 | Gemini hard-block verbs limited to `block` / `hide` / `ban`. All other destructive-sounding verbs trigger `confirmation_required`. |
| D10 | Multi-child families: dispatcher asks which child(ren) via a checkbox card when ≥2 children exist and the family's message didn't name one. |

---

## 3. Data Model

### 3.1 Types

```swift
enum ShieldTier: String, Codable {
    case exactApp    // single app via ApplicationToken — Max only
    case savedList   // whole selection (apps + categories + web domains)
    case category    // single category via ActivityCategoryToken
    case all         // shield.applicationCategories = .all() + shield.webDomainCategories = .all()
}

struct ShieldRecord: Codable {
    /// Stable identity. Same (tier, targetKey) is the SAME record across mutations.
    /// mutations update fields in place; adding a shield on the same (tier, target)
    /// merges, not creates a new record.
    let recordKey: String          // "exactApp:<b64-token>" | "savedList:<listID>" | "category:social" | "all"
    let tier: ShieldTier
    let targetKey: String          // canonical: b64-token / listID / "social" / "all"
    var displayName: String        // "Instagram" / "list 1" / "Social" / "All Apps" — UI only

    var lastCommandID: UUID        // audit: latest mutation source

    var appTokens: Set<ApplicationToken>
    var categoryTokens: Set<ActivityCategoryToken>
    var webDomainTokens: Set<WebDomainToken>
    var appliesToAll: Bool         // true iff tier == .all

    let issuedAt: Date
    var expiresAt: Date?           // nil = permanent
    let originalRequest: String    // parent's original phrasing
    var targetChildID: UUID        // which child this record applies to
}

struct BlockRecord: Codable {
    let bundleID: String           // unique key
    let displayName: String
    let blockedAt: Date
    let lastCommandID: UUID
    let originalRequest: String
    let targetChildID: UUID
    // No expiresAt — blocks are always permanent until explicit unblock.
}
```

### 3.2 recordKey / targetKey format

| Tier | `targetKey` format | `recordKey` format |
|---|---|---|
| `exactApp` | `base64(plistEncode(ApplicationToken))` | `"exactApp:\(targetKey)"` |
| `savedList` | `listID.uuidString` (from SavedListMeta) | `"savedList:\(targetKey)"` |
| `category` | canonical category key (lowercase: `"social"`, `"games"`, etc.) | `"category:\(targetKey)"` |
| `all` | constant `"all"` | `"all"` |

DeviceActivity schedule names use a SHA-256 hash of `recordKey` (first 16 bytes hex) to fit iOS name-length constraints:

```
DeviceActivityName("evlin.shield.\(recordKey.sha256Prefix16Hex)")
```

### 3.3 Store API

```swift
actor ActiveLockStore {
    static let shared = ActiveLockStore()

    // MARK: Shield operations

    enum AddShieldResult {
        case added
        case upgradedToPermanent(previousExpiry: Date)
        case extendedTimed(newExpiry: Date)
        case noOpShorterThanExisting
        case noOpAlreadyPermanent
        case needsConfirmation(NeedsConfirmationReason)
    }

    func addShield(_ record: ShieldRecord) async -> AddShieldResult
    func removeShield(recordKey: String) async -> RemovedShield?
    func unshieldAll() async -> [ShieldRecord]    // clears shields only; preserves blocks

    // MARK: Block operations

    enum AddBlockResult { case added; case alreadyBlocked }

    func addBlock(_ record: BlockRecord) async -> AddBlockResult
    func removeBlock(bundleID: String) async -> RemovedBlock?
    func unblockAll() async -> [BlockRecord]    // always requires upstream confirmation

    // MARK: Queries

    func effectiveState(for query: AppQuery) async -> EffectiveState
    func allCurrent() async -> (shields: [ShieldRecord], blocks: [BlockRecord])

    // MARK: Time management

    func sweepExpired() async -> [ShieldRecord]  // shields only; blocks never expire

    // MARK: Private

    private var shieldRecords: [String: ShieldRecord] = [:]  // keyed by recordKey
    private var blockRecords: [String: BlockRecord] = [:]    // keyed by bundleID
    private func recomputeAndApply()
}

struct AppQuery {
    var bundleID: String? = nil
    var token: ApplicationToken? = nil
    var categoryHint: String? = nil
}

struct EffectiveState {
    var isBlocked: Bool
    var shieldsCovering: [ShieldRecord]
    var earliestFullyUnrestricted: Date?  // nil if any permanent shield or block exists
}

struct RemovedShield {
    let record: ShieldRecord
    let stillCovered: [ShieldRecord]
    let blockedAfter: Bool
}

struct RemovedBlock {
    let record: BlockRecord
    let stillShieldedBy: [ShieldRecord]
}

enum NeedsConfirmationReason: Codable {
    case downgradePermanentToTimed(existing: ShieldRecord, new: ShieldRecord)
    // (room for future confirmation reasons driven from the store)
}
```

### 3.4 Shield merge rule (same `(tier, targetKey)`)

```
def mergeShield(existing, new):
  # Both permanent
  if existing.expiresAt is None and new.expiresAt is None:
    return .noOpAlreadyPermanent

  # Existing permanent, new timed → needs confirmation (D4 / Q4.1b)
  if existing.expiresAt is None and new.expiresAt is not None:
    return .needsConfirmation(.downgradePermanentToTimed(existing, new))

  # Existing timed, new permanent → auto-upgrade (Q4.1a)
  if existing.expiresAt is not None and new.expiresAt is None:
    update existing: expiresAt = nil, lastCommandID = new.id
    return .upgradedToPermanent(previousExpiry: existing.expiresAt)

  # Both timed → keep whichever ends later
  if new.expiresAt > existing.expiresAt:
    update existing: expiresAt = new.expiresAt, lastCommandID = new.id
    return .extendedTimed(newExpiry: new.expiresAt)
  else:
    return .noOpShorterThanExisting
```

### 3.5 Effective state query

Runtime-only, no persisted cache.

```
def effectiveState(query):
  result = {isBlocked: false, shieldsCovering: [], earliestFullyUnrestricted: null}

  # Block check
  if query.bundleID and query.bundleID in blockRecords:
    result.isBlocked = true

  # Shield coverage
  for record in shieldRecords.values():
    covered = False
    match record.tier:
      case .all:
        covered = True
      case .exactApp:
        if query.token and record.appTokens.contains(query.token): covered = True
      case .savedList:
        if query.token and record.appTokens.contains(query.token): covered = True
        # savedList never falls back to bundleID — tokens are the only authority
      case .category:
        if query.categoryHint and record.targetKey == query.categoryHint: covered = True
        # category doesn't fall back to bundleID either — category tokens opaque
    if covered: result.shieldsCovering.append(record)

  # earliestFullyUnrestricted
  if result.isBlocked or any(s.expiresAt is None for s in result.shieldsCovering):
    result.earliestFullyUnrestricted = null  # never auto-unrestricted
  elif result.shieldsCovering:
    result.earliestFullyUnrestricted = max(s.expiresAt for s in result.shieldsCovering)

  return result
```

### 3.6 Recompute & apply

Every add/remove/sweep triggers a full recompute:

```
def recomputeAndApply():
  # Blocks
  bundles = {Application(bundleIdentifier: r.bundleID) for r in blockRecords.values()}
  store.application.blockedApplications = bundles if non-empty else nil

  # Shields — check for 'all' first
  if any(r.appliesToAll for r in shieldRecords.values()):
    store.shield.applicationCategories = .all()
    store.shield.webDomainCategories = .all()
    store.shield.applications = nil
    store.shield.webDomains = nil
    return

  # Otherwise union tokens
  allAppTokens = union(r.appTokens for r in shieldRecords.values())
  allCatTokens = union(r.categoryTokens for r in shieldRecords.values())
  allWebTokens = union(r.webDomainTokens for r in shieldRecords.values())

  store.shield.applications = allAppTokens if non-empty else nil
  store.shield.applicationCategories = .specific(allCatTokens) if non-empty else nil
  store.shield.webDomains = allWebTokens if non-empty else nil
  store.shield.webDomainCategories = nil  # only used in .all mode
```

### 3.7 DeviceActivityMonitor extension integration

When a schedule's `intervalDidEnd` fires, the extension decodes recordKey from the DeviceActivityName, removes that ShieldRecord from the persisted store (App Group UserDefaults), and runs the same recompute logic above. It reads/writes the same shieldRecords dictionary the main app uses.

Blocks never expire → DeviceActivity doesn't schedule anything for them.

---

## 4. Conflict Resolution Matrix

Canonical rules, derived from the Q4 decisions.

### 4.1 Shield × Shield

| Scenario | Action | Card? |
|---|---|---|
| Same `(tier, target)`, both timed, new ≥ old expiry | Extend to new expiry | No |
| Same `(tier, target)`, both timed, new < old expiry | No-op (keep longer) | No |
| Same `(tier, target)`, timed → permanent | Auto-upgrade | No |
| Same `(tier, target)`, permanent → timed | **Card B1** | Yes |
| Same `(tier, target)`, both permanent | No-op (duplicate) | No |
| Different `(tier, target)` both cover X | Both coexist; effective state unions | No |

### 4.2 Block × Block

| Scenario | Action | Card? |
|---|---|---|
| Same app already blocked, new block | No-op + receipt | No (receipt only, R1) |

### 4.3 Shield × Block cross-type

| Scenario | Action | Card? |
|---|---|---|
| X shielded (timed), new `block X` | **Card C1** | Yes |
| X shielded (permanent), new `block X` | **Card C1** | Yes |
| X in shielded list, new `block X` | **Card C2** (list shield stays on others) | Yes |
| X blocked, new `shield X` or `lock X for N` | **Card B2** | Yes |

### 4.4 Partial unlock semantics

**Deterministic rule for `unshield X` (an app target, not a list/category/all)**:

Let N = number of shield records covering X (computed via `effectiveState`).

| Case | Rule |
|---|---|
| **Has an `exactApp` shield on X** (regardless of other covers) | Remove ONLY the `exactApp` record. Effective-state line in receipt discloses any remaining list/category/all coverage. |
| **No `exactApp` shield, exactly 1 higher-tier cover** (one of: list / category / all) | Reject with suggestion: `X is shielded by <list 1>. Unlock the source directly: "unlock list 1".` Receipt only; no card. |
| **No `exactApp` shield, multiple higher-tier covers** | Reject with disambiguation receipt: `X is shielded by 3 sources: list 1 (until 17:30), Social (until 18:00), shield all (until 20:00). Unlock one explicitly.` Receipt only; no card. |
| **Not covered by any shield at all** | Reject with R-variant: `X isn't shielded.` (If blocked, append R2 guidance.) |

This rule **never silently removes a broader shield** via an app target. Broader shields require their own verb (`unlock list 1`, `unlock Social`, `unlock all`).

**For other commands**:

| Scenario | Action |
|---|---|
| `unshield <listName>` / `unshield <categoryName>` / `unshield all` | Remove that specific record by `recordKey`. |
| `unshield X` when X only blocked | Reject with R2 (`"X isn't shielded — it's blocked. Use 'unblock X'"`). |
| `unblock X` when X only shielded | Reject with R3. |
| `unshieldAll` | Remove all shields. Blocks preserved. Receipt says count. |
| `unblockAll` | **Card A3** always (destructive). After confirm, remove all blocks. Shields preserved. |

### 4.5 Coexistence (no conflicts)

- `all` shield + `block X` → coexist. X is blocked; everything else is shielded.
- `all` shield + `category Social` shield → coexist (different expiries may matter).
- `list 1` shield + `exactApp IG` shield → coexist (IG can be independently shielded even if it's also in list 1).
- `category Social` shield + `exactApp IG` shield → coexist (IG can have its own expiry).

---

## 5. Confirmation Card Catalog

### 5.1 Card Templates (8 reusable)

Each template is a single SwiftUI view with payload:

```swift
struct CardPayload {
    let id: CardID                    // A1, B2, D1, etc.
    let icon: String                  // SF Symbol
    let title: String
    let body: String
    let buttons: [CardButton]         // 1–4 buttons
    let variant: Variant              // checkboxes, radio, none, …
}

struct CardButton {
    let label: String
    let style: Style                  // primary / secondary / tertiary / destructive / cancel
    let action: () -> Void
}
```

| Template | Cards covered | Variants |
|---|---|---|
| `DangerConfirmCard` | A1, D3 | optional secondary "alternative action" |
| `ReplaceModeCard` | B1, B2, C1, C2 | transition-with-context text |
| `MissingInfoCard` | D1, D4 | quick-pick (D1) vs checkbox multi-select (D4) |
| `AmbiguityCard` | D2 | A-vs-B radio |
| `UnsupportedInModeCard` | E1, E2, G1 | optional upgrade CTA |
| `CatalogMissCard` | E3 | with optional "try category" action |
| `ListSuggestionCard` | E4, F1 | empty variant (no candidates) vs populated variant |
| `BulkActionCard` | A3 | itemized list + single confirm |

### 5.2 Complete card specs

Every card has: **Trigger**, **Template**, **Content**, **Outcomes**, **Receipt after**.

#### A1 — Block first-time confirmation
- **Trigger**: `block X` when X is not currently blocked.
- **Template**: DangerConfirmCard (with secondary action).
- **Content**:
  - icon: 🚫
  - title: `Block \(displayName)?`
  - body: `Blocking hides the app from \(childName)'s home screen until you unblock. It won't auto-release.`
  - buttons: `[Block \(displayName)]` (destructive), `[Shield for a while instead]` (secondary), `[Cancel]`.
- **Outcomes**:
  - Block → `addBlock(record)` → recompute → receipt.
  - Shield instead → transition to D1 (missing-duration).
  - Cancel → no-op.
- **Receipt**: `🚫 Blocked \(displayName) on \(childName)'s phone · until you unblock.` + effective-state line if applicable.

#### A2 — (REMOVED — direct action, no card)

`unblock X` is a direct action. Rationale: scoped to one app, reversible, and the receipt already discloses any remaining coverage via effective-state line. Card added friction without safety benefit.

Confirmation is still required for the bulk action `unblockAll` (card A3) because it operates on many apps at once.

**Flow**:
- `unblock X` → `removeBlock(bundleID)` → receipt: `🔓 Unblocked \(displayName).` + effective-state line if applicable.

Added to **§5.3 pure-receipt scenarios** as R7 (see end of this section).

#### A3 — UnblockAll
- **Trigger**: `unblock everything` / `unblock all`.
- **Template**: BulkActionCard.
- **Content**:
  - title: `Unblock ALL apps?`
  - body: `This will unblock \(count) apps at once:` + bulleted list of display names
  - footer: `All will return to \(childName)'s home screen. Shields on other apps are not affected.`
  - buttons: `[Unblock all \(count)]` (destructive), `[Cancel]`.
- **Outcomes**: confirm → `unblockAll()`.
- **Receipt**: `🔓 Unblocked \(count) apps: \(names).` + `No shields were changed.`

#### B1 — Permanent → timed downgrade
- **Trigger**: shield `X for N` when `X` already has permanent shield.
- **Template**: ReplaceModeCard.
- **Content**:
  - title: `Change permanent lock to \(duration)?`
  - body: `\(displayName) is currently shielded permanently. Changing to \(duration) means it'll auto-unlock at \(time).`
  - buttons: `[Change to \(duration)]` (primary), `[Keep permanent]` (secondary).
- **Outcomes**: change → update existing record's expiresAt → recompute.
- **Receipt**: `Shortened \(displayName) lock to \(duration). Unlocks at \(time).`

#### B2 — Block → shield
- **Trigger**: `shield X` or `lock X for N` when X is blocked.
- **Template**: ReplaceModeCard.
- **Content**:
  - title: `Switch from block to shield?`
  - body: `\(displayName) is currently blocked (hidden from home screen). Switching to a \(duration) shield means: icon returns to \(childName)'s home screen, app is locked but visible, auto-unlocks at \(time).`
  - buttons: `[Switch to shield]` (primary), `[Keep block]` (secondary).
- **Outcomes**: switch → `removeBlock(bundleID)` + `addShield(record)`.
- **Receipt**: `Switched \(displayName) from block to \(duration) shield. Unlocks at \(time).` + effective-state.

#### C1 — Shield → block upgrade
- **Trigger**: `block X` when X has a shield (timed or permanent).
- **Template**: ReplaceModeCard.
- **Content (existing timed)**:
  - title: `Replace shield with permanent block?`
  - body: `\(displayName) is shielded until \(time). Blocking removes the auto-unlock — \(childName) won't see it again until you unblock.`
  - buttons: `[Replace with block]` (destructive), `[Keep shield]`.
- **Content (existing permanent)**:
  - title: `Upgrade permanent shield to block?`
  - body: `Both lock the app — block additionally hides it from the home screen. Either way it won't auto-unlock.`
  - buttons: `[Upgrade to block]` (destructive), `[Keep shield]`.
- **Outcomes**: confirm → `removeShield(recordKey)` + `addBlock(record)`.
- **Receipt**: `🚫 Blocked \(displayName). Previous shield removed.` + effective-state.

#### C2 — Block X while X in shielded list
- **Trigger**: `block X` while X's exactApp isn't shielded, but X is covered by a savedList or category shield.
- **Template**: ReplaceModeCard.
- **Content**:
  - title: `Block \(displayName)?`
  - body: `\(displayName) is currently shielded as part of "\(coveringName)" (which also covers \(siblingNames)). Block \(displayName): icon hidden, permanent until unblock. "\(coveringName)" shield stays on the others until its natural expiry (\(time)).`
  - buttons: `[Block \(displayName), keep \(coveringName) on others]` (destructive), `[Cancel]`.
- **Outcomes**: confirm → `addBlock(record)`. Covering shield record is untouched.
- **Receipt**: `🚫 Blocked \(displayName). "\(coveringName)" shield continues on \(siblingNames) until \(time).`

#### D1 — Missing duration
- **Trigger**: `shield X` where parsed action has no duration and no "permanently" marker.
- **Template**: MissingInfoCard (quick-pick variant).
- **Content**:
  - title: `How long should \(displayName) be shielded?`
  - buttons: `[15 minutes]`, `[1 hour]`, `[Until bedtime]`† (if configured), `[Permanently]`, `[Cancel]`.
- **Outcomes**: Each button proceeds with that duration.
- **Receipt**: standard shield receipt.
- † "Until bedtime" appears only when family has a bedtime configured (Phase 7 feature; hide in MVP).

#### D2 — "everything" ambiguity
- **Trigger**: Parent says `lock everything he wastes time on` / `stuff` / `his distractions`. Does NOT trigger for `lock all`, `lock all apps`, `lock his phone`, `lock everything` — those go to shield-all main line.
- **Template**: AmbiguityCard.
- **Content**:
  - title: `What does "everything" mean?`
  - buttons: `[Lock ALL apps on \(childName)'s phone]`, `[Just distracting categories (Social + Games + Entertainment)]`, `[Cancel]`.
- **Outcomes**: selected path → D1 for duration.

#### D3 — Long duration (>24h)
- **Trigger**: requested duration > 24 hours.
- **Template**: DangerConfirmCard.
- **Content**:
  - title: `Lock for \(humanDuration)?`
  - body: `This is longer than 24 hours. Locks until: \(date).`
  - buttons: `[Confirm \(humanDuration) lock]` (primary), `[Change duration]` (secondary → D1), `[Cancel]`.

#### D4 — Multi-child target picker
- **Trigger**: Family has ≥ 2 child devices AND parent's message didn't explicitly name a child.
- **Template**: MissingInfoCard (checkbox variant).
- **Content**:
  - title: `\(actionVerb) \(displayName) on which phone?`
  - checkboxes: one per child device (with device label).
  - helper: `[Select all]`.
  - buttons: `[Confirm]` (disabled until ≥1 selected), `[Cancel]`.
- **Outcomes**: confirm → fan out one Command per selected child device.
- **Receipt**: `\(verb) \(displayName) on \(count) phone(s) (\(names)) for \(duration). \(not-selected) not affected.`

#### E1 — Std mode can't shield single app
- **Trigger**: Std mode, `shield X` where X is not in any saved list AND verb is `shield`/`lock` (NOT `block` — that hits E2 first).
- **Template**: UnsupportedInModeCard.
- **Content**:
  - icon: ⚠️
  - title: `Standard mode can't shield \(displayName) directly`
  - body: `Standard mode locks by Saved List or category. \(displayName) is a \(categoryHint) app.`
  - buttons: `[Shield \(categoryHint) category instead]`, `[Add \(displayName) to a Saved List on \(childName)'s phone]`, `[Upgrade to Max]`, `[Cancel]`.
- **Outcomes**:
  - Shield category → D1 → addShield.
  - Add to list → push `expand_library` command to child device.
  - Upgrade → external upgrade flow.

#### E2 — Max-only command in Std mode
- **Trigger**: Std mode, verb is `block` or `unblock`. (Priority over E1.)
- **Template**: UnsupportedInModeCard (upgrade variant).
- **Content**:
  - icon: 🔒
  - title: `Block is a Max feature`
  - body: `Permanent hiding from home screen requires Max. Standard mode can shield \(displayName) temporarily instead.`
  - buttons: `[Upgrade to Max]` (primary), `[Shield \(displayName) instead]` (secondary), `[Cancel]`.
- **Outcomes**:
  - Upgrade → external flow.
  - Shield instead → new shield request. May then trigger E1 if Std can't shield that single app; that's OK (two-step cascade is clear to user).

#### E3 — Catalog miss on block
- **Trigger**: Max mode, `block X` where X isn't in the bundle-ID catalog.
- **Template**: CatalogMissCard.
- **Content**:
  - icon: ❌
  - title: `Can't hard-block "\(requestedName)"`
  - body: `Block requires the app to be in Evlin's known catalog. "\(requestedName)" isn't recognized.`
  - options bullets: `Shield the category it belongs to`, `Add it manually to a Saved List (picker on \(childName)'s phone)`.
  - buttons: `[Shield \(guessedCategory) category]` (only if AI guessed a category), `[Cancel]`.

#### E4 — List not found (no close match)
- **Trigger**: `lock list <name>` where no existing list has Levenshtein distance ≤ 2.
- **Template**: ListSuggestionCard (empty variant).
- **Content**:
  - title: `No list called "\(requestedName)"`
  - body: `Existing lists:` + bulleted list of all current lists (up to 5).
  - buttons: `[Create "\(requestedName)" on \(childName)'s phone]`, `[Cancel]`.
- **Outcomes**: Create → push `expand_library` to child device requesting new list with that name.

#### F1 — List fuzzy suggestion
- **Trigger**: `lock list <name>` with 1+ candidates where Levenshtein ≤ 2.
- **Template**: ListSuggestionCard (populated variant).
- **Content (1 candidate)**:
  - title: `Did you mean "\(candidate)"?`
  - body: `"\(requestedName)" doesn't exist, but "\(candidate)" (\(count) apps) is close.`
  - buttons: `[Lock \(candidate)]`, `[Show all lists]`, `[Cancel]`.
- **Content (multiple candidates)**:
  - title: `Multiple lists close to "\(requestedName)":`
  - bullets: each candidate with app count.
  - buttons: one per candidate, then `[Cancel]`.
- **Outcomes**: Pick → proceed with that list (then D1 if no duration).

#### G1 — Max auth failure (onboarding fallback)
- **Trigger**: Child device `.child` auth fails during Max onboarding.
- **Template**: UnsupportedInModeCard.
- **Content**:
  - icon: ⚠️
  - title: `Can't set up Maximum on this phone`
  - body: `\(childName)'s phone isn't signed in with a Child Apple ID. Maximum requires Family Sharing with a Child account.`
  - buttons: `[Set up Child Apple ID (help guide)]`, `[Continue with Standard instead]`, `[Back]`.
- **Downgrade semantics**: "Continue with Standard" sets `family.protection_mode = std`. Existing `BlockRecord`s on the child device are **NOT auto-cleared** — per D5, Std can still `unblock`/`unblockAll` manually. Any existing `ShieldRecord` with `tier = .exactApp` that was created via Max-mode picker tokens is also preserved; Std dispatcher lets them continue to live (they can be unshielded by `unshield <recordKey>` via Settings UI or by `unshieldAll`), but Std cannot **create new** exactApp shields.

### 5.3 Pure-receipt (no card) scenarios

| ID | Trigger | Receipt |
|---|---|---|
| R1 | `block X` when X already blocked | `\(displayName) is already blocked. No change.` |
| R2 | `unshield X` when X only blocked | `\(displayName) isn't shielded — it's blocked. Use "unblock \(displayName)" instead.` |
| R3 | `unblock X` when X only shielded | `\(displayName) isn't blocked. It's shielded by \(coverName) until \(time). Use "unlock \(displayName)" to release the shield.` |
| R4 | duration < 15 min | `Locked for 15 min (iOS minimum). Unlocks at \(time).` (Receipt reported after auto-clamp.) |
| R5 | permanent-shield duplicate (same target, both permanent) | `\(displayName) is already permanently shielded. No change.` |
| R6 | same target, new timed shorter than existing timed | `Keeping existing \(oldRemaining) shield (longer than requested \(newRequested)).` |
| R7 | `unblock X` when X is currently blocked (direct action, no card) | `🔓 Unblocked \(displayName).` + effective-state line if shields remain. |

---

## 6. Dispatcher Logic

The Chat-command dispatcher routes parent input through these steps **in order**:

```
1. Gemini parses message → action + target_request + target_kind_hint + duration + category_hint_from_ai
2. Check for multi-child ambiguity: if family.childCount ≥ 2 AND parent didn't name a child
   → show D4; abort until user picks.
3. Route by action verb:
   3a. action == block:
        if family.mode == std: → E2, abort.
        lookup target in catalog:
          miss: → E3, abort.
          hit: check existing block/shield state → A1/C1/C2 as applicable; or execute directly.
   3b. action == unblock:
        # Unblock works in BOTH modes — Std devices may have leftover blocks from
        # a previous Max session; they must be able to clear them.
        # DIRECT ACTION — no confirmation card. Receipt discloses remaining coverage.
        if bundle not blocked: → R3 receipt, abort.
        → execute removeBlock directly → R7 receipt.
   3c. action == unblockAll:
        # Also allowed in both modes. Always destructive — always A3 card.
        → A3 card always.
   3d. action == shield:
        if target is a saved list:
          exact match: proceed (check merge rules); no duration → D1.
          fuzzy match: → F1.
          no match: → E4.
        if target is a category: proceed; no duration → D1.
        if target is "all" (explicit) or kind=all: proceed; no duration → D1; >24h → D3.
        if target is ambiguous ("everything he wastes..."): → D2.
        if target is a specific app:
          # Shield.applications requires ApplicationToken — bundle IDs can't shield.
          # Tokens come only from FamilyActivityPicker (child-device alias library,
          # OR parent-device picker in Phase 5 Max mode).
          family.mode == std:
            → E1 always (Std has no exactApp tier).
          family.mode == max:
            a) token available locally (alias library on the device that will execute):
               → exactApp shield record, proceed.
            b) no token BUT category_hint_from_ai resolves to a configured category:
               → E1-style confirmation card offering "Shield <category> instead" / "Add to a list first".
               (Catalog bundle IDs do NOT create exactApp shields — they only power block.)
            c) no token and no category fallback:
               → hard reject: "<X> can't be shielded by name yet. Add it to a Saved List first."
                 (Offer "Add to library" action that pushes expand_library to child device.)
        check merge rule against existing record → B1 if downgrade, else execute.
   3e. action == unshield:
        if target is a specific app X:
          state = effectiveState(AppQuery with token/bundleID for X)
          if state.isBlocked and no shields: → R2 receipt.
          if state.shieldsCovering contains an .exactApp record for X:
            → removeShield(exactAppRecordKey); effective-state receipt.
          elif state.shieldsCovering.count == 1:
            → reject with suggestion to unlock the source directly (list/category/all).
          elif state.shieldsCovering.count > 1:
            → reject with disambiguation listing all covering sources.
          else:  # no coverage
            → R: "X isn't shielded."
        else if target is a list/category/all identifier:
          → removeShield(recordKey for that tier/target); effective-state receipt.
   3f. action == unshieldAll:
        unlock all shields, preserve blocks, receipt with counts.
4. Record mutation result.
5. Build receipt via §8 grammar.
```

Priority note (D8): Step 3a runs before 3d. `block IG` in Std mode hits E2 (Max feature), not E1 (can't shield single app), even though the target might also be unshield-able.

---

## 7. Gemini Prompt Contract

Replacement system prompt for `backend/app/api/routes/parent_chat.py`:

```
You are Evlin, an AI-powered parental control assistant. You parse the parent's natural-
language commands into a structured action. You do NOT execute; you interpret.

VERB → INTENT MAPPING — STRICT:

shield / lock / pause / restrict / limit / silence  →  "shield"
block / hide / ban                                   →  "block"
unshield / unlock / release / allow                  →  "unshield"
unblock / restore / bring back                       →  "unblock"
"unlock everything" / "unlock all" / "clear locks"   →  "unshieldAll"
"unblock everything" / "unblock all"                 →  "unblockAll"

AMBIGUOUS VERBS — must trigger confirmation_required:
remove / kill / delete / stop / close / end / get rid of

These could mean either "shield the timer" or "block the app" — do NOT guess.
Set confirmation_required: true, confirmation_reason: "ambiguous_verb".

NEVER CROSS-TRANSLATE:
- "lock forever" / "lock permanently" → shield with duration_minutes=null (NOT block)
- "block for 30 min" → confirmation_required: true, reason: "block_with_duration"
  (Block is permanent; ask the parent if they meant shield.)

TARGET KIND HINT:
- "list 1" / "bedtime apps" / "homework block"        → kind=list
- "all games" / "social apps" / "entertainment"       → kind=category
- "IG" / "Instagram" / "TikTok" / app name            → kind=app
- "everything" / "all apps" / "his phone" / "all"     → kind=all (EXPLICIT)
- "everything he wastes" / "distracting stuff"        → kind=null (AMBIGUOUS, will trigger D2)

DURATION EXTRACTION:
- "for 30 min" / "for 2 hours" / "for 3 days"         → integer minutes
- "until 8 PM" / "until bedtime"                      → compute minutes from now
- "permanently" / "forever" / "until I unlock"        → duration_minutes: null
- NO duration phrase                                  → duration_minutes: "missing"
                                                        (dispatcher will show D1)

CATEGORY HINT:
Always attempt to provide category_hint_from_ai as a fallback signal, even when kind=app.
Choose from: "social", "games", "entertainment", "productivity", "education".

CHILD NAME DETECTION:
If the parent explicitly names a child ("Liam's", "Emma's"), include child_name_hint.
If family has multiple children and no name is mentioned, leave child_name_hint=null
(dispatcher will show D4 multi-child picker).

RESPONSE FORMAT (always valid JSON):
{
  "message": "conversational reply to the parent",
  "reasoning": "brief internal analysis",
  "action": {
    "type": "shield" | "block" | "unshield" | "unblock" | "unshieldAll" | "unblockAll" | null,
    "target_request": "<parent's original target phrase>",
    "target_kind_hint": "app" | "list" | "category" | "all" | null,
    "duration_minutes": <int> | null | "missing",
    "category_hint_from_ai": "social" | "games" | ... | null,
    "child_name_hint": "<name>" | null,
    "confirmation_required": <bool>,
    "confirmation_reason": "ambiguous_verb" | "block_with_duration" | null
  }
}

If the message isn't a command (e.g. "how is Liam doing?"), set action to null.
```

---

## 8. Receipt Grammar

### 8.1 Global rule (D6)

Every successful mutation generates a receipt with:

1. **Primary mutation line**: what changed.
2. **Effective-state line** (if applicable): what the target is still subject to.

```
Receipt = PrimaryLine [ + EffectiveStateLine ]
```

### 8.2 Primary-line templates

| Action | Template |
|---|---|
| shield, timed | `🛡 Shielded \(displayName) · \(humanDuration) · unlocks at \(time)` |
| shield, permanent | `🛡 Shielded \(displayName) · until you unlock` |
| block | `🚫 Blocked \(displayName)` |
| unshield (single) | `🔓 Unlocked \(displayName)'s \(tier) shield` |
| unblock | `🔓 Unblocked \(displayName)` |
| unshieldAll | `🔓 Cleared \(count) shield(s)` |
| unblockAll | `🔓 Unblocked \(count) app(s): \(names)` |

Never use `formatTime(.distantFuture)` for permanent shields. Branch explicitly on `expiresAt == nil`.

### 8.3 Effective-state line

Computed via `effectiveState(for: AppQuery)`:

```
def effectiveLine(target, state, mutation):
  # For removals
  if mutation.isRemoval:
    if state.isBlocked:
      return "Still blocked."
    if state.shieldsCovering:
      strongest = firstRecord sorted by (permanent first, then latest expiry)
      if strongest.expiresAt is None:
        return "Still shielded by \(strongest.displayName) permanently."
      return "Still shielded by \(strongest.displayName) until \(formatTime(strongest.expiresAt))."
    return None  # fully unrestricted — no line needed (we might say "Now fully available.")

  # For additions (shield or block)
  otherCoverage = state.shieldsCovering.filter(s => s.recordKey != mutation.recordKey)
  if otherCoverage:
    # Briefly note that the target was ALSO already covered
    return "Also covered by \(otherCoverage[0].displayName) until \(…)."
  return None
```

For removals where the target is now fully unrestricted, the receipt ends with `. Now fully available.` to make the finality explicit (avoids "did it really unlock?" confusion).

### 8.4 Examples

```
🛡 Shielded Instagram · 30 min · unlocks at 17:30.
🛡 Shielded Instagram · until you unlock.
🛡 Shielded list 1 · 1 hour · unlocks at 18:00. Also covered by shield all until 20:00.
🚫 Blocked Instagram. Also shielded by Social category until 17:30.
🔓 Unblocked Instagram. Still shielded by Social until 17:30.
🔓 Unlocked Instagram's exactApp shield. Still shielded by list 1 until 18:00.
🔓 Unlocked Instagram's exactApp shield. Now fully available.
🔓 Cleared 3 shields. 2 blocks preserved.
🔓 Unblocked 2 apps: Instagram, TikTok. No shields were changed.
```

---

## 9. Std vs Max Delta Table

| Capability | Std | Max |
|---|---|---|
| Shield single app (exactApp tier) | ❌ (use list/category/all) | ✅ |
| Shield saved list | ✅ | ✅ |
| Shield category | ✅ | ✅ |
| Shield all | ✅ | ✅ |
| Block single app (create) | ❌ (E2) | ✅ |
| Unblock (remove existing block) | ✅ (lets downgraded users clear leftover blocks) | ✅ |
| UnblockAll | ✅ (same rationale) | ✅ |
| denyAppRemoval device protection | ✅ (default-on toggle) | ✅ (same) |
| Screen Time authorization | `.individual` | `.child` (needs Child Apple ID) |
| Parent-side FamilyActivityPicker (Phase 5) | ❌ | 🔶 future |
| All onboarding steps | welcome → modeSelect → enter code (child) → grant permission → deletion toggle → category defaults → (optional) first list → ready | same path + Max-specific parent steps (WhyChildAppleID / CreateChildAppleID / SignInOnChild / WaitForAuth) |

Max mode is gated behind:
- Parent chose "Maximum" at ProtectionLevelStep.
- Child device signed in with Child Apple ID.
- `.child` auth granted (if fails → G1 card offers fallback to Std).

---

## 10. Implementation Impact

### 10.1 iOS code changes

| File | Change |
|---|---|
| `Models/ActiveLock.swift` | Replace with `Models/ShieldRecord.swift` + `Models/BlockRecord.swift`. Remove single-ActiveLock abstraction. |
| `Models/CommandModels.swift` | Add `shield`/`block`/`unshield`/`unblock`/`unshieldAll`/`unblockAll` to `CommandAction`. Remove `lock`/`unlock`/`lockAll`/`unlockAll` or keep as aliases for backwards compatibility during migration. |
| `Services/ActiveLockStore.swift` | Full rewrite per §3.3. New keyed storage, new API, effective-state query. |
| `Services/ActionExecutor.swift` | Update to call new store API. Handle block/unblock paths separately from shield. |
| `Services/ScreenTimeManager.swift` | (unchanged) |
| `Views/Child/ChildModeView.swift` | Status line shows shield count + block count separately (vs single "locked" state). Bullet list shows both. |
| `Views/Chat/ChatView.swift` | Insert ConfirmationCard when backend returns `needs_confirmation=true`. Wire card's button actions to re-submit the correct follow-up command. |
| `Components/ConfirmationCards/` | NEW directory. 8 template Swift files: `DangerConfirmCard.swift`, `ReplaceModeCard.swift`, `MissingInfoCard.swift`, `AmbiguityCard.swift`, `UnsupportedInModeCard.swift`, `CatalogMissCard.swift`, `ListSuggestionCard.swift`, `BulkActionCard.swift`. Plus `CardPayload.swift`, `CardButton.swift`, `CardID.swift`. |
| `Components/ReceiptCard.swift` | Update to render primary + effective-state lines per §8. |
| `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` | Update recordKey-based lookup; remove single ShieldRecord; recompute by full union. |
| `Views/Onboarding/Child/DeletionProtectionStep.swift` | Change from manual button to toggle (default ON) with side-effect copy beneath. |

### 10.2 Backend code changes

| File | Change |
|---|---|
| `backend/app/api/routes/parent_chat.py` | New SYSTEM_PROMPT per §7. New action enum. Emit confirmation_required + confirmation_reason. |
| `backend/app/services/chat_resolver.py` | Extend with verb routing (shield vs block) before tier resolution. Add `needs_confirmation` branches. |
| `backend/app/db/models/command.py` | Extend Command payload schema to carry confirmation_reason. Command.action enum to include new values. |
| `backend/app/api/routes/family.py` | (Unchanged — pairing mechanics stable.) |

### 10.3 New tests

- Backend: resolver verb-routing tests (shield/block/unshield/unblock/ambiguous verbs).
- Backend: multi-child dispatcher (fan-out commands when ≥2 children, single-command when ≥1 with name hint).
- iOS: ActiveLockStore merge tests (permanent + timed combinations per §3.4).
- iOS: effective-state tests (query for bundle covered by multiple records).
- iOS: Receipt grammar tests (primary + effective-state combinations).

---

## 11. Migration Plan

The Phase 1 MVP is pre-launch (no real users). Migration is trivial:

1. On app startup, if `shieldRecords` UserDefaults key doesn't exist but legacy `evlin.activeLocks` does: read legacy entries, migrate each to a ShieldRecord with best-effort recordKey, save under new key.
2. Delete legacy key.
3. Legacy commands are mapped in Command.payload:
   - `action=lock` → `action=shield` (with target kind preserved)
   - `action=lockAll` → `action=shield` with `target_kind_hint="all"`
   - `action=unlock` → `action=unshield`
   - `action=unlockAll` → `action=unshieldAll`

---

## 12. Open Questions / Deferred

- **"Until bedtime" button in D1** (§5.2) depends on a bedtime setting; hide in MVP until that setting exists.
- **Phase 5 remote FamilyActivityPicker** (Max only) is not in scope.
- **Upgrade-to-Max external flow** (E2, E3) is a placeholder link; real subscription flow is separate.
- **Guided Access** (`UIAccessibility.requestGuidedAccessSession`): not part of this spec. Deferred to Phase 6+ under "Focus Session" feature.
- **Receipt-card 长文案 i18n**: current text is English-only. Localization deferred.
- **Web-domain-only actions** (`block tiktok.com`): not modeled explicitly; webDomainTokens are supported in savedList selections but not as a primary target. Can be added later as a new tier.
- **Category-token rename UX**: onboarding stores category tokens with positional names (`category_1`, `category_2`). A Settings page to rename each is deferred.

---

## 13. Appendix: Full card-to-template mapping

| Card | Template | Variant notes |
|---|---|---|
| A1 | DangerConfirmCard | +secondary "shield instead" |
| A2 | **(removed — direct action, no card)** | — |
| A3 | BulkActionCard | itemized list |
| B1 | ReplaceModeCard | permanent → timed |
| B2 | ReplaceModeCard | block → shield |
| C1 | ReplaceModeCard | shield → block (timed or permanent, distinct body) |
| C2 | ReplaceModeCard | block inside shielded list |
| D1 | MissingInfoCard | quick-pick (up to 4 duration options) |
| D2 | AmbiguityCard | 2-way radio |
| D3 | DangerConfirmCard | + "change duration" → reopens D1 |
| D4 | MissingInfoCard | checkbox multi-select with "select all" |
| E1 | UnsupportedInModeCard | 3 alternative actions |
| E2 | UnsupportedInModeCard | upgrade CTA + fallback action |
| E3 | CatalogMissCard | optional "shield category" action |
| E4 | ListSuggestionCard | empty variant |
| F1 | ListSuggestionCard | populated variant (1 or N candidates) |
| G1 | UnsupportedInModeCard | onboarding flow — route to help doc or Std path |

---

END OF SPEC.
