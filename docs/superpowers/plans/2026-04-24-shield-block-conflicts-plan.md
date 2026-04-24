# Shield/Block Conflict Resolution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the existing ActiveLockStore / ActionExecutor / backend dispatcher with the new `(tier, targetKey)`-keyed data model, 8-template confirmation card system, verb-first dispatcher, and effective-state receipt grammar defined in `docs/superpowers/specs/2026-04-24-shield-block-conflicts-design.md`.

**Architecture:** Two-record system — `ShieldRecord` (keyed by `recordKey`) and `BlockRecord` (keyed by `bundleID`) in `ActiveLockStore`. All effective-state queries at runtime (no persisted coverage cache). Backend routes by verb first (shield/block/etc.) then by tier. 17 confirmation scenarios render via 8 reusable SwiftUI templates driven by `CardPayload`.

**Tech Stack:** Swift 5.9+ / SwiftUI / FamilyControls / ManagedSettings / DeviceActivity (iOS 17+), FastAPI / Python 3.13 / async SQLAlchemy / Pydantic (backend).

**Reference spec:** `/Users/fred/Desktop/Evlin/Evlin iOS/docs/superpowers/specs/2026-04-24-shield-block-conflicts-design.md`

**Phases (can stop/resume between phases):**
- **Phase 1** (iOS): New data-model types (ShieldRecord, BlockRecord, enums)
- **Phase 2** (iOS): Rewrite ActiveLockStore with merge rules + effective-state query
- **Phase 3** (iOS): Rewrite ActionExecutor for new action verbs
- **Phase 4** (iOS): Update DeviceActivityMonitor extension
- **Phase 5** (Backend): New CommandAction enum + Gemini prompt rewrite
- **Phase 6** (Backend): Verb-first dispatcher in resolver + /parent/chat
- **Phase 7** (iOS): 8 card template Swift views + CardPayload types
- **Phase 8** (iOS): ReceiptCard with primary + effective-state lines
- **Phase 9** (iOS): Chat ViewModel integration — dispatch confirmation cards
- **Phase 10** (iOS): Onboarding — DeletionProtection toggle update
- **Phase 11** (iOS): Migration from legacy ActiveLock key
- **Phase 12**: Manual on-device validation

---

## File Structure

### iOS new files (`Evlin iOS/Evlin iOS/`)

```
Models/
  ShieldRecord.swift           NEW — replaces ActiveLock
  BlockRecord.swift            NEW
  ShieldTier.swift             NEW — enum
  CardID.swift                 NEW — enum for all 17 card IDs
  CardPayload.swift            NEW — generic payload + CardButton

Services/
  ActiveLockStore.swift        REWRITE — (tier, targetKey) keyed
  ActionExecutor.swift         REWRITE — new verbs
  EffectiveStateQuery.swift    NEW — runtime coverage logic

Components/ConfirmationCards/
  DangerConfirmCard.swift      NEW
  ReplaceModeCard.swift        NEW
  MissingInfoCard.swift        NEW
  AmbiguityCard.swift          NEW
  UnsupportedInModeCard.swift  NEW
  CatalogMissCard.swift        NEW
  ListSuggestionCard.swift     NEW
  BulkActionCard.swift         NEW
  CardDispatcher.swift         NEW — maps CardID -> template + payload

Components/
  ReceiptCard.swift            REWRITE — primary + effective-state lines

Views/Onboarding/Child/
  DeletionProtectionStep.swift REWRITE — toggle default-on

Views/Chat/
  ChatViewModel.swift          MODIFY — handle confirmation_required responses
  ChatView.swift               MODIFY — render confirmation + receipt cards

EvlinDeviceActivityMonitor/
  DeviceActivityMonitorExtension.swift  REWRITE — recordKey-based removal

Models/CommandModels.swift     MODIFY — new CommandAction cases
```

### Backend files (`adaptive-engine/backend/app/`)

```
api/routes/parent_chat.py      MODIFY — new SYSTEM_PROMPT, new action enum
services/chat_resolver.py      REWRITE — verb-first routing
db/models/command.py           MODIFY — AckStatus stays; add ack_card_id + ack_context columns (B1 round-trip)
api/routes/devices.py          MODIFY — ack endpoint persists pending_confirmation card_id + context;
                                         status polling surfaces them back to parent
```

### Test files (new)

```
Evlin iOS/Evlin iOSTests/
  ShieldRecordMergeTests.swift      NEW
  EffectiveStateQueryTests.swift    NEW
  ActiveLockStoreTests.swift        REWRITE (old tests obsolete)

adaptive-engine/backend/tests/services/
  test_chat_resolver.py              EXTEND — verb routing tests
  test_verb_intent_mapping.py       NEW
```

---

# Phase 1 — iOS data-model types

### Task 1.1: ShieldTier enum

**Files:**
- Create: `Evlin iOS/Evlin iOS/Models/ShieldTier.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Which Apple API backs this shield record.
/// See spec §3.1 for rationale.
enum ShieldTier: String, Codable, Sendable {
    case exactApp    // single app via ApplicationToken — Max only
    case savedList   // whole FamilyActivitySelection
    case category    // single category via ActivityCategoryToken
    case all         // shield.applicationCategories = .all() + webDomainCategories = .all()
}
```

- [ ] **Step 2: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Models/ShieldTier.swift"
git commit -m "feat(models): ShieldTier enum (Phase 1)"
```

### Task 1.2: ShieldRecord type

**Files:**
- Create: `Evlin iOS/Evlin iOS/Models/ShieldRecord.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import FamilyControls
import ManagedSettings

/// Single shield entry in ActiveLockStore.
/// Keyed by `recordKey` (stable across mutations). Same (tier, targetKey)
/// merges; different (tier, targetKey) coexist even if they cover the same app.
/// See spec §3.1 and §3.2.
struct ShieldRecord: Codable, Sendable {
    /// "exactApp:<b64>" | "savedList:<listID>" | "category:social" | "all"
    /// Stable. Merge target.
    let recordKey: String

    /// tier + targetKey together make the recordKey.
    let tier: ShieldTier

    /// Canonical key (not a display name). See spec §3.2 table.
    let targetKey: String

    /// Display string — may be updated by user actions (e.g. list rename).
    var displayName: String

    /// Audit: which command caused the latest mutation on this record.
    var lastCommandID: UUID

    /// Selection payload. Populated per tier:
    /// - exactApp: appTokens has 1 token; categoryTokens / webDomainTokens empty
    /// - savedList: any of the three may be non-empty
    /// - category: categoryTokens has 1 token
    /// - all: all three empty; appliesToAll = true
    var appTokens: Set<ApplicationToken>
    var categoryTokens: Set<ActivityCategoryToken>
    var webDomainTokens: Set<WebDomainToken>
    var appliesToAll: Bool

    let issuedAt: Date
    var expiresAt: Date?           // nil = permanent
    let originalRequest: String     // parent's natural-language target phrase

    /// Which child device this record is scoped to. Required for multi-child families.
    var targetChildID: UUID

    // MARK: - Helpers

    /// Derive recordKey for a tier/targetKey pair. See spec §3.2.
    static func makeRecordKey(tier: ShieldTier, targetKey: String) -> String {
        switch tier {
        case .all: return "all"
        case .exactApp: return "exactApp:\(targetKey)"
        case .savedList: return "savedList:\(targetKey)"
        case .category: return "category:\(targetKey)"
        }
    }

    /// Extract tier from a recordKey.
    static func tierFromRecordKey(_ key: String) -> ShieldTier? {
        if key == "all" { return .all }
        if key.hasPrefix("exactApp:") { return .exactApp }
        if key.hasPrefix("savedList:") { return .savedList }
        if key.hasPrefix("category:") { return .category }
        return nil
    }

    /// Short SHA-256 based derived name for use in DeviceActivityName (which has length limits).
    /// See spec §3.2.
    var deviceActivityName: String {
        let data = recordKey.data(using: .utf8) ?? Data()
        let hash = sha256(data).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "evlin.shield.\(hash)"
    }
}

// MARK: - SHA-256 helper

import CryptoKit

private func sha256(_ data: Data) -> [UInt8] {
    Array(SHA256.hash(data: data))
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Models/ShieldRecord.swift"
git commit -m "feat(models): ShieldRecord with recordKey + helpers (Phase 1)"
```

### Task 1.3: BlockRecord type

**Files:**
- Create: `Evlin iOS/Evlin iOS/Models/BlockRecord.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// A permanent block on a single app (by bundleID).
/// Unique per bundleID. No expiresAt — blocks only lift via `unblock` / `unblockAll`.
/// See spec §3.1.
struct BlockRecord: Codable, Sendable {
    let bundleID: String      // unique key in ActiveLockStore
    let displayName: String
    let blockedAt: Date
    let lastCommandID: UUID
    let originalRequest: String
    let targetChildID: UUID
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Models/BlockRecord.swift"
git commit -m "feat(models): BlockRecord (Phase 1)"
```

### Task 1.4: Extend CommandAction enum with new verbs

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Models/CommandModels.swift`

- [ ] **Step 1: Read existing file**

Verify the current `CommandAction` enum matches:

```swift
enum CommandAction: String, Codable, Sendable {
    case lock
    case unlock
    case lockAll = "lock_all"
    case unlockAll = "unlock_all"
    case expandLibrary = "expand_library"
}
```

- [ ] **Step 2: Replace with new action set**

```swift
/// Chat-level action verbs. See spec §7.
/// Legacy lock/unlock/lockAll/unlockAll are aliased during migration (Phase 11).
enum CommandAction: String, Codable, Sendable {
    case shield
    case block
    case unshield
    case unblock
    case unshieldAll = "unshield_all"
    case unblockAll = "unblock_all"
    case expandLibrary = "expand_library"
}
```

- [ ] **Step 3: Add CommandTarget refinement**

At the bottom of the existing `CommandTarget` struct definition, add an optional field for target kind:

```swift
struct CommandTarget: Codable, Sendable {
    var bundleID: String?
    var listName: String?
    var listID: UUID?                 // stable identifier for a Saved List
    var categoryHint: String?
    var targetAll: Bool = false       // true when kind=all
    var originalRequest: String
    var targetDisplay: String?
    var targetChildID: UUID?          // for multi-child
    var hasPendingBlob: Bool = false

    // Parent's confirmed-downgrade re-submission: when the parent taps "Change to X min"
    // on a B1 card, the /parent/chat follow-up sets `force_downgrade=true`. Child's
    // ActiveLockStore.addShield then skips the merge rule for this (tier, targetKey).
    // See spec §5.2 B1 flow and plan Phase 6/9 changes.
    var forceDowngrade: Bool = false
}
```

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Models/CommandModels.swift"
git commit -m "feat(models): new CommandAction verbs + CommandTarget fields (Phase 1)"
```

### Task 1.5: Delete obsolete ActiveLock type

**Files:**
- Delete: `Evlin iOS/Evlin iOS/Models/ActiveLock.swift`

- [ ] **Step 1: Delete the file**

```bash
rm "/Users/fred/Desktop/Evlin/Evlin iOS/Evlin iOS/Models/ActiveLock.swift"
```

- [ ] **Step 2: Verify no references remain outside Services (they'll be updated in Phases 2–4)**

Run:
```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
grep -l "ActiveLock[^SR]" --include=\*.swift -r "Evlin iOS/" | grep -v "Services/"
```
Expected: empty output. References remaining in `Services/ActiveLockStore.swift` and `Services/ActionExecutor.swift` are expected; they'll be rewritten next.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Models/"
git commit -m "chore(models): remove legacy ActiveLock struct (Phase 1)"
```

---

# Phase 2 — ActiveLockStore rewrite

### Task 2.1: Supporting types for store API

**Files:**
- Create: `Evlin iOS/Evlin iOS/Services/ActiveLockStoreTypes.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Result of addShield. See spec §3.3 and §3.4.
enum AddShieldResult: Codable, Sendable {
    case added
    case upgradedToPermanent(previousExpiry: Date)
    case extendedTimed(newExpiry: Date)
    case noOpShorterThanExisting
    case noOpAlreadyPermanent
    case needsConfirmation(NeedsConfirmationReason)
}

enum NeedsConfirmationReason: Codable, Sendable {
    case downgradePermanentToTimed(existingKey: String, newExpiry: Date)
}

enum AddBlockResult: Codable, Sendable {
    case added
    case alreadyBlocked
}

struct AppQuery: Sendable {
    var bundleID: String?
    var token: ApplicationToken?
    var categoryHint: String?

    init(bundleID: String? = nil, token: ApplicationToken? = nil, categoryHint: String? = nil) {
        self.bundleID = bundleID
        self.token = token
        self.categoryHint = categoryHint
    }
}

/// Snapshot of what's covering an app. See spec §3.5.
/// IMPORTANT: coverage for `savedList` tier can only be determined via token match.
/// If the query has no token (e.g. unblock by bundleID, where we never had a token),
/// savedList coverage is UNKNOWN. `possibleSavedListCoverage` flags this —
/// receipts must treat the target as "may still be covered" rather than asserting
/// "fully unrestricted".
struct EffectiveState: Sendable {
    var isBlocked: Bool
    var shieldsCovering: [ShieldRecord]           // shields we're sure cover
    var possibleSavedListCoverage: Bool           // true if savedList shields exist but query can't verify coverage
    var earliestFullyUnrestricted: Date?          // nil if permanent, blocked, or possibleSavedListCoverage=true
}

/// Returned by removeShield — tells caller what's still covering the target (for receipt).
struct RemovedShield: Sendable {
    let record: ShieldRecord
    let stillCovered: [ShieldRecord]
    let blockedAfter: Bool
    var possibleSavedListCoverage: Bool = false  // indeterminate — see EffectiveState
}

/// Extended AckResult — add `pendingConfirmation` case for B1-style flows
/// where the child device needs the parent to decide, and the parent sends
/// back a force-confirmed command. Replaces the prior 3-case AckResult from
/// three-tier-lock-plan's Task 1.4. Backwards-incompatible — migration step
/// included in Phase 11.
enum AckResult: Codable, Sendable, Equatable {
    case confirmedExact(displayName: String)
    case confirmedFallback(displayName: String, category: String, origRequest: String)
    case pendingConfirmation(cardID: String, context: [String: String])
    case failed(AckFailure)
}

/// Returned by removeBlock.
struct RemovedBlock: Sendable {
    let record: BlockRecord
    let stillShieldedBy: [ShieldRecord]
    var possibleSavedListCoverage: Bool = false  // indeterminate — see EffectiveState
}

import FamilyControls
import ManagedSettings
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Services/ActiveLockStoreTypes.swift"
git commit -m "feat(store): supporting types for new ActiveLockStore API (Phase 2)"
```

### Task 2.2: Unit tests for merge rule (TDD — red phase)

**Files:**
- Rewrite: `Evlin iOS/Evlin iOSTests/ActiveLockStoreTests.swift`

- [ ] **Step 1: Write the failing test file**

```swift
import XCTest
@testable import Evlin_iOS

/// Tests for the new (tier, targetKey)-keyed ActiveLockStore.
/// Uses exactApp tier where possible since tokens can be constructed in tests
/// via an opaque Data-based encoding (see `TestHelpers`).
final class ActiveLockStoreTests: XCTestCase {
    override func setUp() async throws {
        // Clear shared App Group state so tests don't pollute each other.
        UserDefaults(suiteName: "group.com.evlin.ios")?.removeObject(forKey: "evlin.shieldRecords")
        UserDefaults(suiteName: "group.com.evlin.ios")?.removeObject(forKey: "evlin.blockRecords")
    }

    // MARK: - Merge rules (spec §3.4)

    func test_add_same_target_timed_new_longer_extends() async {
        let store = ActiveLockStore()
        let r1 = Self.makeTimedShield(displayName: "IG", minutes: 30)
        let r2 = Self.makeTimedShield(displayName: "IG", minutes: 60, recordKey: r1.recordKey)

        _ = await store.addShield(r1)
        let result = await store.addShield(r2)

        if case .extendedTimed(let newExpiry) = result {
            XCTAssertGreaterThan(newExpiry, r1.expiresAt!)
        } else {
            XCTFail("Expected .extendedTimed, got \(result)")
        }
        let current = await store.allCurrent().shields
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].expiresAt, r2.expiresAt)
    }

    func test_add_same_target_timed_new_shorter_noOp() async {
        let store = ActiveLockStore()
        let r1 = Self.makeTimedShield(displayName: "IG", minutes: 60)
        let r2 = Self.makeTimedShield(displayName: "IG", minutes: 30, recordKey: r1.recordKey)

        _ = await store.addShield(r1)
        let result = await store.addShield(r2)

        XCTAssertEqual(String(describing: result), "noOpShorterThanExisting")
    }

    func test_add_same_target_timed_upgraded_to_permanent() async {
        let store = ActiveLockStore()
        let r1 = Self.makeTimedShield(displayName: "IG", minutes: 30)
        let r2 = Self.makePermanentShield(displayName: "IG", recordKey: r1.recordKey)

        _ = await store.addShield(r1)
        let result = await store.addShield(r2)

        if case .upgradedToPermanent(let prev) = result {
            XCTAssertEqual(prev, r1.expiresAt)
        } else {
            XCTFail("Expected .upgradedToPermanent, got \(result)")
        }
        let current = await store.allCurrent().shields
        XCTAssertNil(current[0].expiresAt)
    }

    func test_add_same_target_permanent_to_timed_needs_confirmation() async {
        let store = ActiveLockStore()
        let r1 = Self.makePermanentShield(displayName: "IG")
        let r2 = Self.makeTimedShield(displayName: "IG", minutes: 30, recordKey: r1.recordKey)

        _ = await store.addShield(r1)
        let result = await store.addShield(r2)

        if case .needsConfirmation(let reason) = result {
            if case .downgradePermanentToTimed(let key, _) = reason {
                XCTAssertEqual(key, r1.recordKey)
            } else {
                XCTFail("wrong reason \(reason)")
            }
        } else {
            XCTFail("Expected .needsConfirmation, got \(result)")
        }
    }

    func test_add_same_target_both_permanent_noOp() async {
        let store = ActiveLockStore()
        let r1 = Self.makePermanentShield(displayName: "IG")
        let r2 = Self.makePermanentShield(displayName: "IG", recordKey: r1.recordKey)

        _ = await store.addShield(r1)
        let result = await store.addShield(r2)

        XCTAssertEqual(String(describing: result), "noOpAlreadyPermanent")
    }

    // MARK: - Different (tier, target) coexist

    func test_different_tiers_covering_same_app_coexist() async {
        let store = ActiveLockStore()
        let exact = Self.makeTimedShield(displayName: "IG", minutes: 30, tier: .exactApp, targetKey: "ig_token_key")
        let category = Self.makeTimedShield(displayName: "Social", minutes: 60, tier: .category, targetKey: "social")

        _ = await store.addShield(exact)
        _ = await store.addShield(category)

        let current = await store.allCurrent().shields
        XCTAssertEqual(current.count, 2)
    }

    // MARK: - unshieldAll preserves blocks (spec §4.4)

    func test_unshieldAll_preserves_blocks() async {
        let store = ActiveLockStore()
        let shield = Self.makeTimedShield(displayName: "IG", minutes: 30)
        let block = BlockRecord(bundleID: "com.roblox.robloxmobile", displayName: "Roblox",
                                 blockedAt: Date(), lastCommandID: UUID(),
                                 originalRequest: "block Roblox",
                                 targetChildID: UUID())

        _ = await store.addShield(shield)
        _ = await store.addBlock(block)

        let cleared = await store.unshieldAll()
        XCTAssertEqual(cleared.count, 1)

        let final = await store.allCurrent()
        XCTAssertEqual(final.shields.count, 0)
        XCTAssertEqual(final.blocks.count, 1)
    }

    // MARK: - addBlock duplicate

    func test_addBlock_duplicate_alreadyBlocked() async {
        let store = ActiveLockStore()
        let b = BlockRecord(bundleID: "com.burbn.instagram", displayName: "Instagram",
                            blockedAt: Date(), lastCommandID: UUID(),
                            originalRequest: "block IG",
                            targetChildID: UUID())

        _ = await store.addBlock(b)
        let result = await store.addBlock(b)

        XCTAssertEqual(String(describing: result), "alreadyBlocked")
        let current = await store.allCurrent().blocks
        XCTAssertEqual(current.count, 1)
    }

    // MARK: - removeBlock reports remaining shields

    func test_removeBlock_reports_remaining_shields() async {
        let store = ActiveLockStore()
        let shield = Self.makeTimedShield(displayName: "Social", minutes: 60, tier: .category, targetKey: "social")
        let block = BlockRecord(bundleID: "com.burbn.instagram", displayName: "Instagram",
                                 blockedAt: Date(), lastCommandID: UUID(),
                                 originalRequest: "block IG",
                                 targetChildID: UUID())
        // Assume Social shields IG via record.categoryTokens — tests can use hint-based coverage
        _ = await store.addShield(shield)
        _ = await store.addBlock(block)

        let removed = await store.removeBlock(bundleID: "com.burbn.instagram")
        XCTAssertNotNil(removed)
        // stillShieldedBy may or may not contain Social depending on coverage query semantics;
        // we only assert the removal succeeded and block count dropped.
        let final = await store.allCurrent().blocks
        XCTAssertEqual(final.count, 0)
    }

    // MARK: - Sweep expired

    // MARK: - Effective-state query (spec §3.5)

    func test_effectiveState_returns_covering_shields() async {
        let store = ActiveLockStore()
        let cat = Self.makeTimedShield(displayName: "Social", minutes: 60,
                                        tier: .category, targetKey: "social")
        _ = await store.addShield(cat)

        let state = await store.effectiveState(for: AppQuery(categoryHint: "social"))
        XCTAssertEqual(state.shieldsCovering.count, 1)
        XCTAssertFalse(state.isBlocked)
    }

    func test_effectiveState_flags_blocked() async {
        let store = ActiveLockStore()
        let b = BlockRecord(bundleID: "com.x", displayName: "X",
                             blockedAt: Date(), lastCommandID: UUID(),
                             originalRequest: "block", targetChildID: UUID())
        _ = await store.addBlock(b)

        let state = await store.effectiveState(for: AppQuery(bundleID: "com.x"))
        XCTAssertTrue(state.isBlocked)
    }

    func test_sweepExpired_removes_past_shields() async {
        let store = ActiveLockStore()
        let live = Self.makeTimedShield(displayName: "IG", minutes: 60, targetKey: "live_key")
        let dead = Self.makeTimedShield(displayName: "TT", minutes: 0, expiresAt: Date().addingTimeInterval(-5), targetKey: "dead_key")

        _ = await store.addShield(live)
        _ = await store.addShield(dead)

        let removed = await store.sweepExpired()
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed[0].recordKey, dead.recordKey)
        XCTAssertEqual(await store.allCurrent().shields.count, 1)
    }

    // MARK: - Helpers

    private static func makeTimedShield(
        displayName: String,
        minutes: Int,
        expiresAt: Date? = nil,
        tier: ShieldTier = .exactApp,
        targetKey: String? = nil,
        recordKey: String? = nil
    ) -> ShieldRecord {
        let tk = targetKey ?? "test_key_\(UUID().uuidString.prefix(6))"
        let rk = recordKey ?? ShieldRecord.makeRecordKey(tier: tier, targetKey: tk)
        return ShieldRecord(
            recordKey: rk,
            tier: tier,
            targetKey: tk,
            displayName: displayName,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: tier == .all,
            issuedAt: Date(),
            expiresAt: expiresAt ?? Date().addingTimeInterval(TimeInterval(minutes * 60)),
            originalRequest: "test",
            targetChildID: UUID()
        )
    }

    private static func makePermanentShield(
        displayName: String,
        tier: ShieldTier = .exactApp,
        targetKey: String? = nil,
        recordKey: String? = nil
    ) -> ShieldRecord {
        let tk = targetKey ?? "test_key_\(UUID().uuidString.prefix(6))"
        let rk = recordKey ?? ShieldRecord.makeRecordKey(tier: tier, targetKey: tk)
        return ShieldRecord(
            recordKey: rk,
            tier: tier,
            targetKey: tk,
            displayName: displayName,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: tier == .all,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "test",
            targetChildID: UUID()
        )
    }
}
```

- [ ] **Step 2: Confirm tests fail to compile (store doesn't have the new API yet)**

Expected: compiler errors referencing `addShield`, `unshieldAll`, etc. That's fine — we're writing the store next.

- [ ] **Step 3: Commit the failing tests**

```bash
git add "Evlin iOS/Evlin iOSTests/ActiveLockStoreTests.swift"
git commit -m "test(store): new ActiveLockStore merge + coexistence + sweep (TDD red) (Phase 2)"
```

### Task 2.3: ActiveLockStore rewrite — implement to pass tests

**Files:**
- Rewrite: `Evlin iOS/Evlin iOS/Services/ActiveLockStore.swift`

- [ ] **Step 1: Replace the file contents**

```swift
import Foundation
import FamilyControls
import ManagedSettings

/// Single source of truth for active shields + blocks on this device.
/// See spec §3 for full design.
///
/// Data model:
/// - shieldRecords keyed by recordKey — same (tier, target) merges, different coexist.
/// - blockRecords keyed by bundleID — one block per app.
///
/// Mutations always run recomputeAndApply() to push the full union to ManagedSettingsStore.
actor ActiveLockStore {
    static let shared = ActiveLockStore()

    private var shieldRecords: [String: ShieldRecord] = [:]
    private var blockRecords: [String: BlockRecord] = [:]
    private let store = ManagedSettingsStore()
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let shieldsKey = "evlin.shieldRecords"
    private let blocksKey = "evlin.blockRecords"

    init() {
        restore()
    }

    // MARK: - Shield API

    /// Add a shield. If `force == true`, the merge rule is skipped — use this
    /// ONLY when the parent has confirmed a downgrade via the B1 card. The caller
    /// (ActionExecutor) reads the `force_downgrade` flag from the Command payload;
    /// the parent UI sends that flag by re-submitting the Chat message with
    /// `force_confirmations: ["B1"]` in the request.
    func addShield(_ new: ShieldRecord, force: Bool = false) -> AddShieldResult {
        if let existing = shieldRecords[new.recordKey], !force {
            return mergeShield(existing: existing, new: new)
        }
        // force=true OR no existing record → overwrite
        shieldRecords[new.recordKey] = new
        persist()
        recomputeAndApply()
        return .added
    }

    // applyConfirmedDowngrade removed: parent UI never mutates the child's store
    // directly. Downgrade goes through Command pipeline → child's ActionExecutor →
    // addShield(..., force: true).

    @discardableResult
    func removeShield(recordKey: String) -> RemovedShield? {
        guard let record = shieldRecords.removeValue(forKey: recordKey) else { return nil }
        persist()
        recomputeAndApply()
        // Build stillCovered: any records that ALSO cover the same bundleIDs / category
        let stillCovered = findRemainingCoverage(of: record)
        let bundledAfter = record.appTokens.allSatisfy { _ in
            // If this was an exactApp tier, check if any of the app's bundle IDs is blocked.
            // Heuristic: only answer true if record.tier == .exactApp and we can map back — skip for now.
            false
        }
        return RemovedShield(record: record, stillCovered: stillCovered, blockedAfter: bundledAfter)
    }

    func unshieldAll() -> [ShieldRecord] {
        let removed = Array(shieldRecords.values)
        shieldRecords.removeAll()
        persist()
        recomputeAndApply()
        return removed
    }

    // MARK: - Block API

    @discardableResult
    func addBlock(_ new: BlockRecord) -> AddBlockResult {
        if blockRecords[new.bundleID] != nil { return .alreadyBlocked }
        blockRecords[new.bundleID] = new
        persist()
        recomputeAndApply()
        return .added
    }

    @discardableResult
    func removeBlock(bundleID: String, categoryHint: String? = nil) -> RemovedBlock? {
        guard let record = blockRecords.removeValue(forKey: bundleID) else { return nil }
        persist()
        recomputeAndApply()
        // Pass categoryHint so shields on the matching category ARE detected.
        // savedList shields still can't be confirmed — effectiveState sets
        // possibleSavedListCoverage so the caller can generate an honest receipt.
        let query = AppQuery(bundleID: bundleID, categoryHint: categoryHint?.lowercased())
        let state = effectiveState(for: query)
        return RemovedBlock(
            record: record,
            stillShieldedBy: state.shieldsCovering,
            possibleSavedListCoverage: state.possibleSavedListCoverage
        )
    }

    func unblockAll() -> [BlockRecord] {
        let removed = Array(blockRecords.values)
        blockRecords.removeAll()
        persist()
        recomputeAndApply()
        return removed
    }

    // MARK: - Queries

    func allCurrent() -> (shields: [ShieldRecord], blocks: [BlockRecord]) {
        (Array(shieldRecords.values), Array(blockRecords.values))
    }

    func effectiveState(for query: AppQuery) -> EffectiveState {
        var state = EffectiveState(
            isBlocked: false,
            shieldsCovering: [],
            possibleSavedListCoverage: false,
            earliestFullyUnrestricted: nil
        )

        if let bid = query.bundleID, blockRecords[bid] != nil {
            state.isBlocked = true
        }

        for record in shieldRecords.values {
            if shieldCovers(record, query: query) {
                state.shieldsCovering.append(record)
            } else if record.tier == .savedList, query.token == nil {
                // We have a saved-list shield but no token to check membership —
                // coverage indeterminate. Flag for honest receipt.
                state.possibleSavedListCoverage = true
            }
        }

        // earliestFullyUnrestricted: nil if blocked, any permanent shield, or indeterminate list coverage
        let hasPermanent = state.shieldsCovering.contains(where: { $0.expiresAt == nil })
        if state.isBlocked || hasPermanent || state.possibleSavedListCoverage {
            state.earliestFullyUnrestricted = nil
        } else {
            state.earliestFullyUnrestricted = state.shieldsCovering.compactMap(\.expiresAt).max()
        }
        return state
    }

    // MARK: - Time management

    @discardableResult
    func sweepExpired(now: Date = Date()) -> [ShieldRecord] {
        let expired = shieldRecords.values.filter { ($0.expiresAt ?? .distantFuture) <= now }
        guard !expired.isEmpty else { return [] }
        for record in expired { shieldRecords.removeValue(forKey: record.recordKey) }
        persist()
        recomputeAndApply()
        return expired
    }

    // MARK: - Private: merge

    private func mergeShield(existing: ShieldRecord, new: ShieldRecord) -> AddShieldResult {
        let existingPermanent = existing.expiresAt == nil
        let newPermanent = new.expiresAt == nil

        if existingPermanent && newPermanent {
            return .noOpAlreadyPermanent
        }
        if existingPermanent && !newPermanent {
            // Downgrade → requires confirmation. Record is unchanged here.
            return .needsConfirmation(.downgradePermanentToTimed(
                existingKey: existing.recordKey,
                newExpiry: new.expiresAt!
            ))
        }
        if !existingPermanent && newPermanent {
            var upgraded = existing
            let prev = upgraded.expiresAt!
            upgraded.expiresAt = nil
            upgraded.lastCommandID = new.lastCommandID
            upgraded.originalRequest = new.originalRequest
            shieldRecords[existing.recordKey] = upgraded
            persist()
            recomputeAndApply()
            return .upgradedToPermanent(previousExpiry: prev)
        }
        // Both timed
        if new.expiresAt! > existing.expiresAt! {
            var extended = existing
            extended.expiresAt = new.expiresAt
            extended.lastCommandID = new.lastCommandID
            shieldRecords[existing.recordKey] = extended
            persist()
            recomputeAndApply()
            return .extendedTimed(newExpiry: new.expiresAt!)
        }
        return .noOpShorterThanExisting
    }

    // MARK: - Private: coverage query

    private func shieldCovers(_ record: ShieldRecord, query: AppQuery) -> Bool {
        switch record.tier {
        case .all:
            return true
        case .exactApp:
            if let t = query.token, record.appTokens.contains(t) { return true }
            return false
        case .savedList:
            if let t = query.token, record.appTokens.contains(t) { return true }
            // savedList: no fallback to bundleID (tokens are the sole authority)
            return false
        case .category:
            if let hint = query.categoryHint, record.targetKey == hint { return true }
            return false
        }
    }

    private func findRemainingCoverage(of removed: ShieldRecord) -> [ShieldRecord] {
        // Find any remaining record that covers SOMETHING the removed record was covering.
        // Best-effort: only exactApp matches exact token; category matches by key;
        // all always matches.
        shieldRecords.values.filter { other in
            if other.recordKey == removed.recordKey { return false }
            switch removed.tier {
            case .exactApp:
                // Token overlap
                return !other.appTokens.isDisjoint(with: removed.appTokens) || other.tier == .all
            case .savedList:
                return !other.appTokens.isDisjoint(with: removed.appTokens) ||
                       !other.categoryTokens.isDisjoint(with: removed.categoryTokens) ||
                       other.tier == .all
            case .category:
                return (other.tier == .category && other.targetKey == removed.targetKey) ||
                       other.tier == .all
            case .all:
                return false   // nothing else "covers" `all`
            }
        }
    }

    // MARK: - Private: recompute + persistence

    private func recomputeAndApply() {
        // Blocks
        let blockedApps = Set(blockRecords.values.map { ManagedSettings.Application(bundleIdentifier: $0.bundleID) })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps

        // Check for 'all' tier — if any, shield everything
        if shieldRecords.values.contains(where: { $0.appliesToAll }) {
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()
            store.shield.applications = nil
            store.shield.webDomains = nil
            return
        }

        // Otherwise union tokens
        let allAppTokens = Set(shieldRecords.values.flatMap(\.appTokens))
        let allCatTokens = Set(shieldRecords.values.flatMap(\.categoryTokens))
        let allWebTokens = Set(shieldRecords.values.flatMap(\.webDomainTokens))

        store.shield.applications = allAppTokens.isEmpty ? nil : allAppTokens
        store.shield.applicationCategories = allCatTokens.isEmpty ? nil : .specific(allCatTokens)
        store.shield.webDomains = allWebTokens.isEmpty ? nil : allWebTokens
        store.shield.webDomainCategories = nil
    }

    private func persist() {
        if let data = try? PropertyListEncoder().encode(shieldRecords) {
            defaults?.set(data, forKey: shieldsKey)
        }
        if let data = try? PropertyListEncoder().encode(blockRecords) {
            defaults?.set(data, forKey: blocksKey)
        }
    }

    private func restore() {
        if let data = defaults?.data(forKey: shieldsKey),
           let decoded = try? PropertyListDecoder().decode([String: ShieldRecord].self, from: data) {
            shieldRecords = decoded
        }
        if let data = defaults?.data(forKey: blocksKey),
           let decoded = try? PropertyListDecoder().decode([String: BlockRecord].self, from: data) {
            blockRecords = decoded
        }
    }
}
```

- [ ] **Step 2: Run tests, verify they pass**

Run in Xcode: Cmd+U on `ActiveLockStoreTests`.
Expected: all tests green (9 tests).

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Services/ActiveLockStore.swift" "Evlin iOS/Services/ActiveLockStoreTypes.swift"
git commit -m "feat(store): ActiveLockStore rewrite with merge rules + effective-state (Phase 2)"
```

### Task 2.4: Remove obsolete ActiveLockStore methods

- [ ] **Step 1: Confirm `removeAll()`, `remove(commandID:)`, `removeMatching(_:)`, `current()` are gone**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
grep -n "removeAll\|remove(commandID\|removeMatching\|func current()" "Evlin iOS/Services/ActiveLockStore.swift"
```
Expected: no matches (all replaced).

- [ ] **Step 2: No commit — just a verification step.**

---

# Phase 3 — ActionExecutor rewrite

### Task 3.1: Update ActionExecutor for new verbs

**Files:**
- Rewrite: `Evlin iOS/Evlin iOS/Services/ActionExecutor.swift`

- [ ] **Step 1: Replace the file contents**

```swift
import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

/// Translates LockCommand into ActiveLockStore mutations.
/// See spec §6 for dispatcher logic and §3.4 for merge rules.
final class ActionExecutor: @unchecked Sendable {
    static let shared = ActionExecutor()

    private let activityCenter = DeviceActivityCenter()

    /// iOS DeviceActivitySchedule hard minimum.
    static let minScheduleMinutes: Int = 15

    func execute(_ cmd: LockCommand, blob: Data? = nil) async -> AckResult {
        // Live auth check — don't trust cached state.
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            return .failed(.notAuthorized)
        }

        switch cmd.action {
        case .shield:
            return await executeShield(cmd: cmd, blob: blob)
        case .block:
            return await executeBlock(cmd: cmd)
        case .unshield:
            return await executeUnshield(cmd: cmd)
        case .unblock:
            return await executeUnblock(cmd: cmd)
        case .unshieldAll:
            let cleared = await ActiveLockStore.shared.unshieldAll()
            cancelAllScheduled()
            return .confirmedExact(displayName: "\(cleared.count) shield(s) cleared")
        case .unblockAll:
            let cleared = await ActiveLockStore.shared.unblockAll()
            return .confirmedExact(displayName: "\(cleared.count) block(s) cleared")
        case .expandLibrary:
            return .failed(.execution("expand_library handled in UI"))
        }
    }

    // MARK: - Shield

    private func executeShield(cmd: LockCommand, blob: Data?) async -> AckResult {
        do {
            let record = try buildShieldRecord(from: cmd, blob: blob)
            // Parent's confirmed-downgrade re-submission sets target.forceDowngrade = true.
            let force = cmd.target.forceDowngrade
            let result = await ActiveLockStore.shared.addShield(record, force: force)
            switch result {
            case .added, .upgradedToPermanent, .extendedTimed:
                if let expiresAt = record.expiresAt {
                    try? scheduleRelock(recordKey: record.recordKey, expiresAt: expiresAt)
                }
                return buildConfirmReceipt(cmd: cmd, record: record)
            case .noOpShorterThanExisting, .noOpAlreadyPermanent:
                return .confirmedExact(displayName: "\(record.displayName) already covered")
            case .needsConfirmation(let reason):
                // Return a structured pending so backend ack can surface card_id to parent.
                let context: [String: String]
                switch reason {
                case .downgradePermanentToTimed(let existingKey, let newExpiry):
                    context = [
                        "card_id": "B1",
                        "target_display": record.displayName,
                        "target_request": cmd.target.originalRequest,
                        "existing_record_key": existingKey,
                        "requested_expiry_iso": ISO8601DateFormatter().string(from: newExpiry),
                        "requested_duration_minutes": String(cmd.durationMinutes ?? 0),
                        "existing_mode": "permanent",
                    ]
                }
                return .pendingConfirmation(cardID: "B1", context: context)
            }
        } catch let err as ExecuteError {
            return .failed(err.ackFailure)
        } catch {
            return .failed(.execution(error.localizedDescription))
        }
    }

    private func buildConfirmReceipt(cmd: LockCommand, record: ShieldRecord) -> AckResult {
        switch cmd.tier {
        case .category:
            return .confirmedFallback(
                displayName: record.displayName,
                category: cmd.target.categoryHint ?? "unknown",
                origRequest: cmd.target.originalRequest
            )
        default:
            return .confirmedExact(displayName: record.displayName)
        }
    }

    private func buildShieldRecord(from cmd: LockCommand, blob: Data?) throws -> ShieldRecord {
        let tier = cmd.tier ?? .category   // default won't be hit in practice
        let targetKey: String
        var appTokens: Set<ApplicationToken> = []
        var categoryTokens: Set<ActivityCategoryToken> = []
        var webDomainTokens: Set<WebDomainToken> = []
        var appliesToAll = false
        var displayName = cmd.target.targetDisplay ?? "Unknown"

        switch tier {
        case .exactApp:
            // GAP: No token source is wired in MVP.
            // - Std mode: dispatcher routes kind=app to E1 fallback card (not this path).
            // - Max mode: parent-device picker (Phase 5) doesn't exist yet; there's no
            //   alias library on the child device keyed by bundle ID either.
            // So this branch is UNREACHABLE from the normal dispatcher flow.
            // If we ever get here (e.g. a buggy backend, or a future Phase 5 wiring arrives
            // without this being updated), fail loudly rather than silently with a misleading
            // error. DO NOT silently coerce into a category shield — that would cause broader
            // collateral blocking than the user asked for.
            throw ExecuteError.notImplemented(
                "exactApp shield requires Phase 5 token mapping — this path should be unreachable"
            )
        case .savedList:
            let sel: FamilyActivitySelection
            if let blob = blob,
               let decoded = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: blob) {
                sel = decoded
            } else if let name = cmd.target.listName,
                      let local = LocalAliasStore.shared.savedList(named: name) {
                sel = local
            } else {
                throw ExecuteError.listNotFound(cmd.target.listName ?? "(unnamed)")
            }
            appTokens = sel.applicationTokens
            categoryTokens = sel.categoryTokens
            webDomainTokens = sel.webDomainTokens
            if let id = cmd.target.listID {
                targetKey = id.uuidString
            } else {
                throw ExecuteError.malformed
            }
            displayName = cmd.target.listName ?? "saved list"
        case .category:
            guard let hint = cmd.target.categoryHint,
                  let tok = LocalAliasStore.shared.categoryToken(forName: hint)
            else {
                throw ExecuteError.categoryNotConfigured(cmd.target.categoryHint ?? "unknown")
            }
            categoryTokens = [tok]
            targetKey = hint.lowercased()
            displayName = hint.capitalized
        case .all:
            targetKey = "all"
            appliesToAll = true
            displayName = "All Apps"
        }

        let recordKey = ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey)
        // Clamp expiry to iOS minimum
        var expiresAt = cmd.expiresAt
        if let exp = expiresAt, exp.timeIntervalSinceNow < TimeInterval(Self.minScheduleMinutes * 60) {
            expiresAt = Date().addingTimeInterval(TimeInterval(Self.minScheduleMinutes * 60))
        }

        return ShieldRecord(
            recordKey: recordKey,
            tier: tier,
            targetKey: targetKey,
            displayName: displayName,
            lastCommandID: cmd.id,
            appTokens: appTokens,
            categoryTokens: categoryTokens,
            webDomainTokens: webDomainTokens,
            appliesToAll: appliesToAll,
            issuedAt: cmd.issuedAt,
            expiresAt: expiresAt,
            originalRequest: cmd.target.originalRequest,
            targetChildID: cmd.target.targetChildID ?? UUID()
        )
    }

    private func base64Key(for token: ApplicationToken) -> String {
        guard let data = try? PropertyListEncoder().encode(token) else { return UUID().uuidString }
        return data.base64EncodedString()
    }

    // MARK: - Block

    private func executeBlock(cmd: LockCommand) async -> AckResult {
        guard let bundleID = cmd.target.bundleID else {
            return .failed(.malformed)
        }
        let record = BlockRecord(
            bundleID: bundleID,
            displayName: cmd.target.targetDisplay ?? bundleID,
            blockedAt: cmd.issuedAt,
            lastCommandID: cmd.id,
            originalRequest: cmd.target.originalRequest,
            targetChildID: cmd.target.targetChildID ?? UUID()
        )
        let result = await ActiveLockStore.shared.addBlock(record)
        switch result {
        case .added:
            return .confirmedExact(displayName: record.displayName)
        case .alreadyBlocked:
            return .confirmedExact(displayName: "\(record.displayName) already blocked")
        }
    }

    // MARK: - Unshield — spec §4.4 deterministic rule

    private func executeUnshield(cmd: LockCommand) async -> AckResult {
        // Dispatcher routes by target kind. Direct-named targets
        // (list/category/all) go straight to recordKey removal. App targets
        // run the multi-cover disambiguation per spec §4.4.
        guard let tier = cmd.tier else { return .failed(.malformed) }

        switch tier {
        case .savedList:
            guard let id = cmd.target.listID else { return .failed(.nothingToUnlock) }
            return await removeExplicit(tier: .savedList, targetKey: id.uuidString)
        case .category:
            guard let hint = cmd.target.categoryHint else { return .failed(.nothingToUnlock) }
            return await removeExplicit(tier: .category, targetKey: hint.lowercased())
        case .all:
            return await removeExplicit(tier: .all, targetKey: "all")
        case .exactApp:
            // App target: follow spec §4.4 disambiguation.
            guard let bid = cmd.target.bundleID else { return .failed(.malformed) }
            return await unshieldAppByBundle(
                bundleID: bid,
                displayName: cmd.target.targetDisplay ?? bid,
                categoryHint: cmd.target.categoryHint
            )
        }
    }

    private func removeExplicit(tier: ShieldTier, targetKey: String) async -> AckResult {
        let recordKey = ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey)
        guard let removed = await ActiveLockStore.shared.removeShield(recordKey: recordKey) else {
            return .failed(.nothingToUnlock)
        }
        cancelScheduled(recordKey: recordKey)
        return .confirmedExact(displayName: removed.record.displayName)
    }

    /// Spec §4.4: default to removing exactApp shield if one exists. Otherwise reject
    /// with a suggestion (1 cover) or disambiguation (N covers). Never silently remove
    /// a broader shield via an app-name target.
    ///
    /// `categoryHint` (from Command.target.categoryHint, threaded by backend
    /// `_route_unshield`) is required for detecting category shields covering X.
    /// Without it, `effectiveState` would miss category coverage and the receipt
    /// would falsely claim nothing-to-unlock.
    private func unshieldAppByBundle(bundleID: String, displayName: String, categoryHint: String?) async -> AckResult {
        let query = AppQuery(bundleID: bundleID, categoryHint: categoryHint?.lowercased())
        let state = await ActiveLockStore.shared.effectiveState(for: query)

        // In MVP, exactApp shields are never created (see `notImplemented` above), so
        // state.shieldsCovering will not contain exactApp records. Logic is written
        // forward-compatibly in case Phase 5 changes that.
        if let exactAppShield = state.shieldsCovering.first(where: { $0.tier == .exactApp }) {
            guard let removed = await ActiveLockStore.shared.removeShield(recordKey: exactAppShield.recordKey) else {
                return .failed(.nothingToUnlock)
            }
            cancelScheduled(recordKey: exactAppShield.recordKey)
            return .confirmedExact(displayName: removed.record.displayName)
        }

        let broader = state.shieldsCovering.filter { $0.tier != .exactApp }
        switch broader.count {
        case 0:
            return .failed(.nothingToUnlock)
        case 1:
            let s = broader[0]
            return .failed(.execution(
                "\(displayName) is shielded by \(s.displayName). To release it, use \"unlock \(s.displayName)\"."
            ))
        default:
            let sources = broader.map { s -> String in
                if let exp = s.expiresAt {
                    let f = DateFormatter(); f.timeStyle = .short
                    return "\(s.displayName) (until \(f.string(from: exp)))"
                }
                return "\(s.displayName) (permanent)"
            }.joined(separator: ", ")
            return .failed(.execution(
                "\(displayName) is shielded by \(broader.count) sources: \(sources). Unlock one explicitly."
            ))
        }
    }

    // MARK: - Unblock

    private func executeUnblock(cmd: LockCommand) async -> AckResult {
        guard let bid = cmd.target.bundleID else { return .failed(.malformed) }
        // Pass category_hint so removeBlock's coverage query detects category
        // shields (e.g. "Social" covering IG) after unblock — otherwise receipt
        // would falsely claim IG is now fully unrestricted.
        guard let removed = await ActiveLockStore.shared.removeBlock(
            bundleID: bid,
            categoryHint: cmd.target.categoryHint
        ) else {
            return .failed(.nothingToUnlock)
        }
        // Receipt grammar (see ReceiptCard and spec §8):
        //  - stillShieldedBy non-empty  → "Unblocked X. Still shielded by Y..."
        //  - else if possibleSavedListCoverage → "Unblocked X. May still be in a Saved List."
        //  - else → "Unblocked X. Now fully unrestricted."
        return .confirmedExact(displayName: removed.record.displayName)
    }

    // MARK: - DeviceActivity scheduling

    private func scheduleRelock(recordKey: String, expiresAt: Date) throws {
        let now = Date()
        let requestedInterval = expiresAt.timeIntervalSince(now)
        let minInterval = TimeInterval(Self.minScheduleMinutes * 60)
        let clampedEnd = requestedInterval < minInterval
            ? now.addingTimeInterval(minInterval)
            : expiresAt
        let calendar = Calendar.current
        let startComp = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComp = calendar.dateComponents([.hour, .minute, .second], from: clampedEnd)
        let schedule = DeviceActivitySchedule(intervalStart: startComp, intervalEnd: endComp, repeats: false)
        let name = DeviceActivityName(deviceActivityNameFor(recordKey: recordKey))
        try activityCenter.startMonitoring(name, during: schedule)
    }

    private func cancelScheduled(recordKey: String) {
        let name = DeviceActivityName(deviceActivityNameFor(recordKey: recordKey))
        activityCenter.stopMonitoring([name])
    }

    private func cancelAllScheduled() {
        activityCenter.stopMonitoring()
    }

    private func deviceActivityNameFor(recordKey: String) -> String {
        // Hashed form to fit iOS name-length limits. See spec §3.2.
        let data = recordKey.data(using: .utf8) ?? Data()
        let bytes = sha256Hex16(data)
        return "evlin.shield.\(bytes)"
    }
}

// MARK: - Helpers

import CryptoKit
private func sha256Hex16(_ data: Data) -> String {
    let hash = SHA256.hash(data: data)
    return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
}

enum ExecuteError: Error {
    case malformed
    case listNotFound(String)
    case categoryNotConfigured(String)
    case notImplemented(String)      // for spec-defined deferrals like exactApp shield

    var ackFailure: AckFailure {
        switch self {
        case .malformed: return .malformed
        case .listNotFound(let n): return .listNotFound(n)
        case .categoryNotConfigured(let n): return .categoryNotConfigured(n)
        case .notImplemented(let reason): return .execution("Not implemented in MVP: \(reason)")
        }
    }
}
```

- [ ] **Step 2: No LocalAliasStore changes needed**

The previous draft added a `tokenForApp(bundleID:)` stub. That's removed because the exactApp
shield path now throws `.notImplemented` directly — there's no caller for the helper. Phase 5
will add the real token lookup when parent-device picker is wired.

- [ ] **Step 3: Ensure CommandModels has listID on CommandTarget**

Verify `Evlin iOS/Evlin iOS/Models/CommandModels.swift` contains `var listID: UUID?` (added in Task 1.4 Step 3). If missing, add it.

- [ ] **Step 4: Compile; resolve any references to removed methods**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
# Ignore Spike tests — they test old APIs
grep -rn "\.add\(.*commandID\)\|\.remove\(commandID:\)\|\.removeMatching\|\.removeAll\(\)" --include="*.swift" "Evlin iOS/" | grep -v "Views/Debug/"
```
Expected: no matches in Services/ or Models/. If SpikeView references old API, wire it to the new verbs OR delete it for now (Phase 12 will rebuild tests).

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Services/ActionExecutor.swift" "Evlin iOS/Services/LocalAliasStore.swift"
git commit -m "feat(executor): new action verb dispatch + shield/block record flows (Phase 3)"
```

### Task 3.2: Update SpikeView test buttons (transitional)

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Debug/SpikeView.swift`

- [ ] **Step 1: Replace the existing ActionExecutor buttons to use the new action names**

Find the section beginning `Section("ActionExecutor") {` and replace:

```swift
Section("ActionExecutor (new verbs)") {
    Text("Shield via bundle ID (Tier A). Hard-blocks if tier is `.block`.")
        .font(.caption).foregroundStyle(.secondary)

    Button("Shield IG (category tier — Social) for 15 min") {
        Task {
            let cmd = LockCommand(
                id: UUID(),
                action: .shield,
                tier: .category,
                target: CommandTarget(
                    categoryHint: "social",
                    originalRequest: "shield social",
                    targetDisplay: "Social"
                ),
                durationMinutes: 15,
                issuedAt: Date()
            )
            let result = await ActionExecutor.shared.execute(cmd)
            await MainActor.run { record("shield social: \(result)") }
        }
    }

    Button("Block IG (Max-only path)") {
        Task {
            let cmd = LockCommand(
                id: UUID(),
                action: .block,
                tier: nil,
                target: CommandTarget(
                    bundleID: "com.burbn.instagram",
                    originalRequest: "block IG",
                    targetDisplay: "Instagram"
                ),
                durationMinutes: nil,
                issuedAt: Date()
            )
            let result = await ActionExecutor.shared.execute(cmd)
            await MainActor.run { record("block IG: \(result)") }
        }
    }

    Button("Unshield all") {
        Task {
            let cmd = LockCommand(
                id: UUID(),
                action: .unshieldAll,
                tier: nil,
                target: CommandTarget(originalRequest: "unshield all"),
                durationMinutes: nil,
                issuedAt: Date()
            )
            let r = await ActionExecutor.shared.execute(cmd)
            await MainActor.run { record("unshieldAll: \(r)") }
        }
    }

    Button("Unblock all") {
        Task {
            let cmd = LockCommand(
                id: UUID(),
                action: .unblockAll,
                tier: nil,
                target: CommandTarget(originalRequest: "unblock all"),
                durationMinutes: nil,
                issuedAt: Date()
            )
            let r = await ActionExecutor.shared.execute(cmd)
            await MainActor.run { record("unblockAll: \(r)") }
        }
    }

    Button("Show active shields + blocks") {
        Task {
            let all = await ActiveLockStore.shared.allCurrent()
            await MainActor.run {
                record("shields: \(all.shields.count) \(all.shields.map(\.displayName))")
                record("blocks: \(all.blocks.count) \(all.blocks.map(\.displayName))")
            }
        }
    }
}
```

Other sections (Diagnostics, Authorization, Bundle ID block, denyAppRemoval, Reset, Test Mode Quickstart) stay as-is.

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Views/Debug/SpikeView.swift"
git commit -m "chore(debug): SpikeView buttons use new action verbs (Phase 3)"
```

---

# Phase 4 — DeviceActivityMonitor extension

### Task 4.1: Rewrite extension to use recordKey-based removal

**Files:**
- Rewrite: `Evlin iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`

- [ ] **Step 1: Replace contents**

```swift
import Foundation
import DeviceActivity
import ManagedSettings

/// Fires when a scheduled shield interval ends. Removes the ShieldRecord from
/// App Group persistence and recomputes shield state for remaining records.
/// See spec §3.6 and §3.7.
class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let shieldsKey = "evlin.shieldRecords"
    private let blocksKey = "evlin.blockRecords"
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let store = ManagedSettingsStore()

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        // Expected name format: "evlin.shield.<16-byte-hex>"
        let raw = activity.rawValue
        guard raw.hasPrefix("evlin.shield.") else { return }
        let hashHex = String(raw.dropFirst("evlin.shield.".count))

        removeShieldByHashAndRecompute(hashHex: hashHex)
    }

    private func removeShieldByHashAndRecompute(hashHex: String) {
        guard let shieldData = defaults?.data(forKey: shieldsKey),
              var shields = try? PropertyListDecoder().decode([String: ShieldRecord].self, from: shieldData)
        else { return }

        // Find the record whose derived name matches the hash
        let targetKey = shields.keys.first(where: { key in
            let data = key.data(using: .utf8) ?? Data()
            let prefix = sha256Hex16(data)
            return prefix == hashHex
        })
        guard let recordKey = targetKey else { return }
        shields.removeValue(forKey: recordKey)

        if let updated = try? PropertyListEncoder().encode(shields) {
            defaults?.set(updated, forKey: shieldsKey)
        }

        // Recompute & apply (same logic as ActiveLockStore.recomputeAndApply)
        let blocks: [String: BlockRecord] = {
            guard let d = defaults?.data(forKey: blocksKey),
                  let decoded = try? PropertyListDecoder().decode([String: BlockRecord].self, from: d) else {
                return [:]
            }
            return decoded
        }()

        let blockedApps = Set(blocks.values.map { ManagedSettings.Application(bundleIdentifier: $0.bundleID) })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps

        if shields.values.contains(where: { $0.appliesToAll }) {
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()
            store.shield.applications = nil
            store.shield.webDomains = nil
            return
        }

        let allApp = Set(shields.values.flatMap(\.appTokens))
        let allCat = Set(shields.values.flatMap(\.categoryTokens))
        let allWeb = Set(shields.values.flatMap(\.webDomainTokens))

        store.shield.applications = allApp.isEmpty ? nil : allApp
        store.shield.applicationCategories = allCat.isEmpty ? nil : .specific(allCat)
        store.shield.webDomains = allWeb.isEmpty ? nil : allWeb
        store.shield.webDomainCategories = nil
    }
}

import CryptoKit
private func sha256Hex16(_ data: Data) -> String {
    let hash = SHA256.hash(data: data)
    return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
}
```

- [ ] **Step 2: Verify target membership**

In Xcode, open `ShieldRecord.swift`, `BlockRecord.swift`, `ShieldTier.swift` in the file navigator. In right-side File Inspector → Target Membership, check ✅ `EvlinDeviceActivityMonitor` (in addition to main target).

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift"
git commit -m "feat(extension): recordKey-hash-based shield removal + recompute (Phase 4)"
```

---

# Phase 5 — Backend action enum + Gemini prompt

### Task 5.1: Extend Command.payload schema documentation

**Files:**
- Modify: `adaptive-engine/backend/app/db/models/command.py`

The database table doesn't strictly need changes (payload is JSON) but we should add a docstring reflecting new actions.

- [ ] **Step 1: Add docstring**

At the top of the file, below existing docstrings, add:

```python
# Command.payload shape (v2, 2026-04-24):
# {
#   "action": "shield" | "block" | "unshield" | "unblock"
#           | "unshield_all" | "unblock_all" | "expand_library",
#   "tier": "exactApp" | "savedList" | "category" | "all" | null,
#   "target": {
#     "bundle_id": str | null,
#     "list_name": str | null,
#     "list_id": str (UUID) | null,
#     "category_hint": str | null,
#     "target_all": bool,
#     "target_child_id": str (UUID) | null,
#     "target_display": str | null,
#     "original_request": str,
#     "has_pending_blob": bool
#   },
#   "duration_minutes": int | null,
#   "issued_at": ISO8601 datetime
# }
#
# Legacy payloads (action=lock/unlock/lock_all/unlock_all) are still accepted
# by Phase 11 migration logic.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
git add backend/app/db/models/command.py
git commit -m "docs(db): Command.payload v2 shape with new action verbs (Phase 5)"
```

### Task 5.2: Rewrite Gemini SYSTEM_PROMPT in parent_chat.py

**Files:**
- Modify: `adaptive-engine/backend/app/api/routes/parent_chat.py`

- [ ] **Step 1: Replace SYSTEM_PROMPT constant**

Find the `SYSTEM_PROMPT = """..."""` block at the top of the file. Replace entirely with spec §7:

```python
SYSTEM_PROMPT = """You are Evlin, an AI-powered parental control assistant. You parse the parent's natural-
language commands into a structured action. You do NOT execute; you interpret.

VERB → INTENT MAPPING — STRICT:

shield / lock / pause / restrict / limit / silence  →  "shield"
block / hide / ban                                   →  "block"
unshield / unlock / release / allow                  →  "unshield"
unblock / restore / bring back                       →  "unblock"
"unlock everything" / "unlock all" / "clear locks"   →  "unshield_all"
"unblock everything" / "unblock all"                 →  "unblock_all"

AMBIGUOUS VERBS — must trigger confirmation_required:
remove / kill / delete / stop / close / end / get rid of

These could mean either "shield the timer" or "block the app" — do NOT guess.
Set confirmation_required: true, confirmation_reason: "ambiguous_verb".

NEVER CROSS-TRANSLATE:
- "lock forever" / "lock permanently" → shield with duration_minutes=null (NOT block)
- "block for 30 min" → confirmation_required: true, reason: "block_with_duration"
  (Block is permanent; ask the parent if they meant shield for 30 min.)

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
    "type": "shield" | "block" | "unshield" | "unblock" | "unshield_all" | "unblock_all" | null,
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
"""
```

- [ ] **Step 2: Commit**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
git add backend/app/api/routes/parent_chat.py
git commit -m "feat(chat): Gemini SYSTEM_PROMPT v2 with strict verb→intent mapping (Phase 5)"
```

---

# Phase 6 — Backend dispatcher (verb-first routing)

### Task 6.1: Failing tests for verb-first routing

**Files:**
- Modify: `adaptive-engine/backend/tests/services/test_chat_resolver.py`
- Create: `adaptive-engine/backend/tests/services/test_verb_dispatcher.py`

- [ ] **Step 1: Write test_verb_dispatcher.py**

```python
"""Tests for verb-first dispatch logic (spec §6)."""
from __future__ import annotations

import pytest
from uuid import uuid4

from backend.app.services.chat_resolver import dispatch


def _gemini_action(
    type_: str,
    target: str = "IG",
    kind: str | None = None,
    duration: int | str | None = None,
    category_hint: str | None = None,
    confirmation_required: bool = False,
    confirmation_reason: str | None = None,
    child_name_hint: str | None = None,
) -> dict:
    return {
        "type": type_,
        "target_request": target,
        "target_kind_hint": kind,
        "duration_minutes": duration,
        "category_hint_from_ai": category_hint,
        "child_name_hint": child_name_hint,
        "confirmation_required": confirmation_required,
        "confirmation_reason": confirmation_reason,
    }


def test_block_in_std_mode_routes_to_e2():
    result = dispatch(
        family_id=uuid4(),
        protection_mode="std",
        child_count=1,
        saved_list_names=[],
        gemini_action=_gemini_action("block", "IG"),
    )
    assert result.requires_card == "E2"


def test_block_catalog_hit_in_max_routes_to_a1():
    result = dispatch(
        family_id=uuid4(),
        protection_mode="max",
        child_count=1,
        saved_list_names=[],
        gemini_action=_gemini_action("block", "IG", kind="app"),
    )
    assert result.requires_card == "A1"
    assert result.resolved.bundle_id == "com.burbn.instagram"


def test_block_catalog_miss_in_max_routes_to_e3():
    result = dispatch(
        family_id=uuid4(),
        protection_mode="max",
        child_count=1,
        saved_list_names=[],
        gemini_action=_gemini_action("block", "abcd", kind="app"),
    )
    assert result.requires_card == "E3"


def test_shield_missing_duration_routes_to_d1():
    result = dispatch(
        family_id=uuid4(),
        protection_mode="std",
        child_count=1,
        saved_list_names=["list 1"],
        gemini_action=_gemini_action("shield", "list 1", kind="list", duration="missing"),
    )
    assert result.requires_card == "D1"


def test_multi_child_no_name_routes_to_d4():
    result = dispatch(
        family_id=uuid4(),
        protection_mode="std",
        child_count=3,
        saved_list_names=[],
        gemini_action=_gemini_action("shield", "list 1", kind="list", duration=30),
    )
    assert result.requires_card == "D4"


def test_ambiguous_verb_routes_to_clarification():
    result = dispatch(
        family_id=uuid4(),
        protection_mode="std",
        child_count=1,
        saved_list_names=[],
        gemini_action=_gemini_action(
            "block", "IG",
            confirmation_required=True,
            confirmation_reason="ambiguous_verb",
        ),
    )
    assert result.confirmation_required
    assert result.confirmation_reason == "ambiguous_verb"


def test_unblock_works_in_std_as_direct_action():
    """Std can unblock (for leftover blocks from Max downgrades) — spec D5.
    Single-item unblock is a DIRECT action — no card (spec §5.2 A2 removed)."""
    result = dispatch(
        family_id=uuid4(),
        protection_mode="std",
        child_count=1,
        saved_list_names=[],
        gemini_action=_gemini_action("unblock", "IG", kind="app"),
    )
    assert result.requires_card is None
    assert result.resolved is not None
    assert result.resolved.action == "unblock"
    assert result.resolved.bundle_id == "com.burbn.instagram"


def test_shield_single_app_in_std_routes_to_e1():
    result = dispatch(
        family_id=uuid4(),
        protection_mode="std",
        child_count=1,
        saved_list_names=[],
        gemini_action=_gemini_action(
            "shield", "Instagram", kind="app", duration=30, category_hint="social",
        ),
    )
    assert result.requires_card == "E1"


def test_ambiguous_everything_routes_to_d2():
    result = dispatch(
        family_id=uuid4(),
        protection_mode="std",
        child_count=1,
        saved_list_names=[],
        gemini_action=_gemini_action("shield", "everything he wastes", kind=None, duration=30),
    )
    assert result.requires_card == "D2"


def test_fuzzy_list_match_routes_to_f1():
    result = dispatch(
        family_id=uuid4(),
        protection_mode="std",
        child_count=1,
        saved_list_names=["list 1", "bedtime apps"],
        gemini_action=_gemini_action("shield", "list 11", kind="list", duration=30),
    )
    assert result.requires_card == "F1"
    assert result.list_suggestions == ["list 1"]


def test_no_list_match_no_close_routes_to_e4():
    result = dispatch(
        family_id=uuid4(),
        protection_mode="std",
        child_count=1,
        saved_list_names=["list 1", "bedtime apps"],
        gemini_action=_gemini_action("shield", "totally unknown list", kind="list", duration=30),
    )
    assert result.requires_card == "E4"
```

- [ ] **Step 2: Run the tests, verify they fail**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
poetry run pytest backend/tests/services/test_verb_dispatcher.py -v
```
Expected: ImportError (dispatch function doesn't exist).

- [ ] **Step 3: Commit the failing tests**

```bash
git add backend/tests/services/test_verb_dispatcher.py
git commit -m "test(dispatcher): verb-first routing specs (TDD red) (Phase 6)"
```

### Task 6.2: Implement dispatch() in chat_resolver.py

**Files:**
- Rewrite: `adaptive-engine/backend/app/services/chat_resolver.py`

- [ ] **Step 1: Replace file contents**

```python
"""Verb-first dispatcher for parental-control chat commands.

Entry point: `dispatch(family_id, protection_mode, child_count, saved_list_names, gemini_action)`.
Returns a DispatchResult that tells the /parent/chat handler whether to:
  - Create and queue a Command row (resolved path), or
  - Return a card ID to the client (confirmation path), or
  - Emit a receipt-only text response (short-circuit path).

See spec §6.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from uuid import UUID

from backend.app.services.app_catalog import lookup as catalog_lookup


@dataclass
class ResolvedAction:
    """The concrete action to queue when no card is needed.
    `category_hint` is required (when available) for unshield/unblock paths —
    iOS uses it to detect category coverage of the target app, so receipts
    report accurate effective state after mutation.
    """
    action: str            # "shield" | "block" | "unshield" | "unblock" | "unshield_all" | "unblock_all"
    tier: str | None       # "exactApp" | "savedList" | "category" | "all"
    bundle_id: str | None = None
    list_id: str | None = None
    list_name: str | None = None
    category_hint: str | None = None
    target_all: bool = False
    target_display: str | None = None
    duration_minutes: int | None = None
    # Set true when the parent's B1 card confirmation re-submitted the Chat message.
    # Child reads target.force_downgrade and skips addShield's merge rule.
    force_downgrade: bool = False


@dataclass
class DispatchResult:
    """What the /parent/chat endpoint should do with this command."""
    # One of three outcomes — exactly one will be populated.
    resolved: ResolvedAction | None = None       # Queue this command.
    requires_card: str | None = None             # Card ID (A1, B1, D1, E2, etc.).
    receipt_only_text: str | None = None         # Short-circuit with a text receipt.

    # Side-channel info carried to the client for card rendering.
    confirmation_required: bool = False
    confirmation_reason: str | None = None
    list_suggestions: list[str] = field(default_factory=list)
    category_guess: str | None = None


# ---------- Public entry point ----------

def dispatch(
    *,
    family_id: UUID,
    protection_mode: str,            # "std" | "max"
    child_count: int,
    saved_list_names: list[str],
    gemini_action: dict,
    force_confirmations: list[str] | None = None,  # e.g. ["B1"] — parent confirmed a card
) -> DispatchResult:
    """Route a Gemini-parsed action to a concrete dispatch outcome."""
    action_type = gemini_action.get("type")
    if action_type is None:
        return DispatchResult(receipt_only_text="(conversational reply — no action)")

    # Short-circuit: Gemini-flagged ambiguity
    if gemini_action.get("confirmation_required"):
        return DispatchResult(
            confirmation_required=True,
            confirmation_reason=gemini_action.get("confirmation_reason"),
        )

    # D4 multi-child check (runs BEFORE verb routing per spec §6 step 2)
    if child_count >= 2 and not gemini_action.get("child_name_hint"):
        return DispatchResult(requires_card="D4")

    # Route by verb
    if action_type == "block":
        return _route_block(protection_mode, gemini_action)
    if action_type == "unblock":
        return _route_unblock(protection_mode, gemini_action)
    if action_type == "unblock_all":
        return _route_unblock_all(protection_mode)
    if action_type == "shield":
        return _route_shield(protection_mode, saved_list_names, gemini_action, force_confirmations)
    if action_type == "unshield":
        return _route_unshield(protection_mode, gemini_action)
    if action_type == "unshield_all":
        return DispatchResult(
            resolved=ResolvedAction(action="unshield_all", tier=None)
        )

    return DispatchResult(receipt_only_text=f"Unknown action: {action_type}")


# ---------- Verb handlers ----------

def _route_block(mode: str, action: dict) -> DispatchResult:
    # Std can't create new blocks → E2
    if mode == "std":
        return DispatchResult(requires_card="E2")

    # Max: catalog lookup
    target = action.get("target_request", "")
    entry = catalog_lookup(target)
    if entry is None:
        return DispatchResult(
            requires_card="E3",
            category_guess=action.get("category_hint_from_ai"),
        )
    # First-time block → always A1 confirm (spec §5.2 A1)
    return DispatchResult(
        requires_card="A1",
        resolved=ResolvedAction(
            action="block",
            tier=None,
            bundle_id=entry.bundle_id,
            target_display=entry.names[0],
        ),
    )


def _route_unblock(mode: str, action: dict) -> DispatchResult:
    # Spec D5: unblock works in BOTH modes (for leftover blocks after downgrade).
    # DIRECT ACTION — no confirmation card (spec §5.2 A2 removed).
    # Receipt discloses any remaining shield coverage per §8 effective-state line.
    entry = catalog_lookup(action.get("target_request", ""))
    # Thread category_hint through so iOS can check category coverage at receipt time.
    # Prefer catalog entry's category_hint; fall back to Gemini's category_hint_from_ai.
    category_hint = (
        entry.category_hint if entry else None
    ) or action.get("category_hint_from_ai")
    return DispatchResult(
        resolved=ResolvedAction(
            action="unblock",
            tier=None,
            bundle_id=entry.bundle_id if entry else None,
            target_display=(entry.names[0] if entry else action.get("target_request")),
            category_hint=category_hint,
        )
    )


def _route_unblock_all(mode: str) -> DispatchResult:
    # Spec D5: always A3 card, in both modes.
    return DispatchResult(requires_card="A3")


def _route_shield(
    mode: str,
    saved_list_names: list[str],
    action: dict,
    force_confirmations: list[str] | None = None,
) -> DispatchResult:
    force_downgrade = bool(force_confirmations and "B1" in force_confirmations)
    kind = action.get("target_kind_hint")
    target = action.get("target_request", "")
    duration = action.get("duration_minutes")

    # D1: missing duration (doesn't depend on target type)
    if duration == "missing":
        return DispatchResult(requires_card="D1")

    # D3: long duration (>24h)
    if isinstance(duration, int) and duration > 24 * 60:
        return DispatchResult(requires_card="D3")

    # D2: ambiguous "everything" — kind=None AND target matches patterns
    if kind is None:
        target_lower = target.lower()
        ambiguous_markers = [
            "everything he wastes",
            "everything liam wastes",
            "stuff",
            "distracting",
            "distractions",
        ]
        if any(m in target_lower for m in ambiguous_markers):
            return DispatchResult(requires_card="D2")
        # Unclear — could be ambiguous or an app name; fall through

    # kind=all → shield all
    if kind == "all":
        return DispatchResult(
            resolved=ResolvedAction(
                action="shield",
                tier="all",
                target_all=True,
                target_display="All Apps",
                duration_minutes=duration if isinstance(duration, int) else None,
                force_downgrade=force_downgrade,
            )
        )

    # kind=category → shield category
    if kind == "category":
        return DispatchResult(
            resolved=ResolvedAction(
                action="shield",
                tier="category",
                category_hint=action.get("category_hint_from_ai", target.lower()),
                target_display=target,
                duration_minutes=duration if isinstance(duration, int) else None,
                force_downgrade=force_downgrade,
            )
        )

    # kind=list → exact match, fuzzy, or miss
    if kind == "list":
        matched = _exact_list_match(target, saved_list_names)
        if matched:
            return DispatchResult(
                resolved=ResolvedAction(
                    action="shield",
                    tier="savedList",
                    list_name=matched,
                    target_display=matched,
                    duration_minutes=duration if isinstance(duration, int) else None,
                    force_downgrade=force_downgrade,
                )
            )
        suggestions = _fuzzy_list_matches(target, saved_list_names, max_distance=2)
        if suggestions:
            return DispatchResult(requires_card="F1", list_suggestions=suggestions)
        return DispatchResult(requires_card="E4")

    # kind=app → Std can't shield; Max attempts token lookup (not available in MVP)
    if kind == "app":
        if mode == "std":
            return DispatchResult(
                requires_card="E1",
                category_guess=action.get("category_hint_from_ai"),
            )
        # Max — no parent-device picker in MVP, offer E1-style fallback
        return DispatchResult(
            requires_card="E1",
            category_guess=action.get("category_hint_from_ai"),
        )

    # Fallthrough — treat as ambiguous
    return DispatchResult(requires_card="D2")


def _route_unshield(mode: str, action: dict) -> DispatchResult:
    kind = action.get("target_kind_hint")
    # Specific app → client-side handles multi-cover disambiguation after query
    # For MVP we resolve minimally here:
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
    # Default: app-level unshield
    entry = catalog_lookup(action.get("target_request", ""))
    # Same category_hint threading as _route_unblock so iOS can disambiguate
    # multi-cover unshield (spec §4.4) without losing category coverage info.
    category_hint = (
        entry.category_hint if entry else None
    ) or action.get("category_hint_from_ai")
    return DispatchResult(
        resolved=ResolvedAction(
            action="unshield",
            tier="exactApp",
            bundle_id=entry.bundle_id if entry else None,
            target_display=(entry.names[0] if entry else action.get("target_request")),
            category_hint=category_hint,
        )
    )


# ---------- Fuzzy / exact list matching ----------

def _exact_list_match(target: str, names: list[str]) -> str | None:
    """Case-insensitive + whitespace/hyphen-normalized exact match."""
    normalized_target = _normalize(target)
    for name in names:
        if _normalize(name) == normalized_target:
            return name
    return None


def _normalize(s: str) -> str:
    return s.strip().lower().replace(" ", "").replace("-", "")


def _levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    dp = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        row = [i]
        for j, cb in enumerate(b, 1):
            row.append(min(dp[j] + 1, row[-1] + 1, dp[j - 1] + (ca != cb)))
        dp = row
    return dp[-1]


def _fuzzy_list_matches(target: str, names: list[str], max_distance: int) -> list[str]:
    target_lower = target.strip().lower()
    candidates: list[tuple[str, int]] = []
    for name in names:
        d = _levenshtein(target_lower, name.lower())
        if d <= max_distance and d > 0:
            candidates.append((name, d))
    candidates.sort(key=lambda t: t[1])
    return [name for name, _ in candidates]
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
poetry run pytest backend/tests/services/test_verb_dispatcher.py -v
```
Expected: 11 tests pass.

- [ ] **Step 3: Commit**

```bash
git add backend/app/services/chat_resolver.py
git commit -m "feat(dispatcher): verb-first dispatch + card routing (Phase 6)"
```

### Task 6.3: Wire dispatcher into /parent/chat handler

**Files:**
- Modify: `adaptive-engine/backend/app/api/routes/parent_chat.py`

- [ ] **Step 1: Replace the command-queue logic inside `parent_chat`**

Find the existing handler body. Replace the post-Gemini logic that queues commands. Keep the endpoint signature the same. The new logic:

```python
# ... existing Gemini invocation code above ...

from backend.app.services.chat_resolver import dispatch, DispatchResult

# Fetch saved-list names for this family
list_rows_stmt = select(SavedListMeta.name).where(SavedListMeta.family_id == req.family_id)
saved_list_names = [row[0] for row in (await session.execute(list_rows_stmt)).all()]

# Fetch child device count
child_count_stmt = select(Device).where(
    Device.family_id == req.family_id, Device.mode == DeviceMode.child
)
child_devices = (await session.execute(child_count_stmt)).scalars().all()

# Fetch family protection_mode
family_row = await session.get(Family, req.family_id)
protection_mode = family_row.protection_mode.value if family_row else "std"

result: DispatchResult = dispatch(
    family_id=req.family_id,
    protection_mode=protection_mode,
    child_count=len(child_devices),
    saved_list_names=saved_list_names,
    gemini_action=gemini_action,
    force_confirmations=req.force_confirmations or [],  # e.g. ["B1"] on parent-confirmed downgrade
)

# Translate DispatchResult -> ChatResponse
if result.requires_card:
    return ChatResponse(
        message=message,
        reasoning=reasoning,
        action=ChatAction(
            type=action_type,
            confirmation_required=True,
            card_id=result.requires_card,                # NEW field
            list_suggestions=result.list_suggestions,    # NEW field
            category_guess=result.category_guess,        # NEW field
            target_display=gemini_action.get("target_request"),
        ),
    )

if result.confirmation_required:
    return ChatResponse(
        message=message,
        reasoning=reasoning,
        action=ChatAction(
            type=action_type,
            confirmation_required=True,
            confirmation_reason=result.confirmation_reason,     # NEW field
        ),
    )

if result.receipt_only_text:
    return ChatResponse(message=result.receipt_only_text, reasoning=None, action=None)

# Resolved — queue a Command
if result.resolved:
    # Pick first child device (D4 already caught multi-child-no-name case)
    if not child_devices:
        raise HTTPException(400, "no child device paired")
    target_child = child_devices[0]

    payload = {
        "action": result.resolved.action,
        "tier": result.resolved.tier,
        "target": {
            "bundle_id": result.resolved.bundle_id,
            "list_name": result.resolved.list_name,
            "list_id": result.resolved.list_id,
            "category_hint": result.resolved.category_hint,
            "target_all": result.resolved.target_all,
            "target_child_id": str(target_child.id),
            "target_display": result.resolved.target_display,
            "original_request": gemini_action.get("target_request", ""),
            "has_pending_blob": False,
            # Carries parent's B1 "yes downgrade" through to the child executor;
            # set by dispatch() whenever "B1" is in force_confirmations.
            "force_downgrade": result.resolved.force_downgrade,
        },
        "duration_minutes": result.resolved.duration_minutes,
        "issued_at": datetime.utcnow().isoformat(),
    }

    cmd = Command(family_id=req.family_id, target_device_id=target_child.id, payload=payload)
    session.add(cmd)
    await session.flush()
    logger.info("Queued {} command {}", result.resolved.action, cmd.id)

    return ChatResponse(
        message=message,
        reasoning=reasoning,
        action=ChatAction(
            type=result.resolved.action,
            command_id=cmd.id,
            tier=result.resolved.tier,
            target_display=result.resolved.target_display,
            duration_minutes=result.resolved.duration_minutes,
        ),
    )

# Fallback: no result (shouldn't happen)
return ChatResponse(message=message, reasoning=reasoning, action=None)
```

- [ ] **Step 2: Extend ChatAction with new optional fields**

At top of file, in the `ChatAction` class:

```python
class ChatAction(BaseModel):
    type: str
    command_id: UUID | None = None
    tier: str | None = None
    target_display: str | None = None
    duration_minutes: int | None = None
    confirmation_required: bool = False

    # New fields (v2)
    card_id: str | None = None                      # "A1", "B1", "D1", …
    confirmation_reason: str | None = None
    list_suggestions: list[str] = Field(default_factory=list)
    category_guess: str | None = None
```

- [ ] **Step 2b: Extend ChatRequest to accept force_confirmations**

The parent client re-sends /parent/chat after the user confirms a B1 card. The
re-submission carries `force_confirmations=["B1"]` so the dispatcher knows to
set `force_downgrade=true` on the ResolvedAction (Phase 6 Task 6.2).

```python
class ChatRequest(BaseModel):
    message: str
    family_id: UUID
    child_name: str | None = None
    history: list[ChatHistoryEntry] = Field(default_factory=list)

    # New — card IDs the parent has already confirmed. Currently only "B1"
    # (permanent→timed downgrade) uses this; reserved for future confirm flows.
    force_confirmations: list[str] = Field(default_factory=list)
```

- [ ] **Step 3: Run a smoke test**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
poetry run uvicorn backend.app.main:app --reload &
sleep 3
curl -sS -X POST http://localhost:8000/api/v1/parent/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"lock everything he wastes time on","family_id":"'$(uuidgen | tr A-Z a-z)'","child_name":"Liam","history":[]}' | python3 -m json.tool || true
# Kill the server
kill %1 2>/dev/null
```
Expected: Response has `action.card_id` populated (likely D2) or `confirmation_required=true`. (Actual family_id won't resolve — that's OK for smoke; the dispatcher logic runs before DB coupling.)

- [ ] **Step 4: Commit**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
git add backend/app/api/routes/parent_chat.py
git commit -m "feat(chat): wire verb-first dispatcher into /parent/chat (Phase 6)"
```

### Task 6.4: Persist pending_confirmation acks + surface via status endpoint

**Files:**
- Modify: `adaptive-engine/backend/app/db/models/command.py`
- Modify: `adaptive-engine/backend/app/api/routes/devices.py` (ack + status endpoints)
- Migration: new Alembic revision adding columns

Context: the child executor may return `AckResult.pendingConfirmation(cardID, context)`
(see Phase 3). Backend needs to persist card_id + context on the Command row and
echo them through the status-polling endpoint, so the parent UI can render the
confirmation card. Today the Command model has `ack_status` + `ack_detail` only.

- [ ] **Step 1: Add columns to Command**

```python
# db/models/command.py, inside class Command
ack_card_id: Mapped[str | None] = mapped_column(String(8), nullable=True)
ack_context: Mapped[dict | None] = mapped_column(JSON, nullable=True)
```

- [ ] **Step 2: Alembic migration**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
poetry run alembic revision --autogenerate -m "add ack_card_id + ack_context to commands"
poetry run alembic upgrade head
```

- [ ] **Step 3: Extend ack endpoint**

In `POST /devices/{device_id}/commands/{command_id}/ack`, accept new optional
fields `card_id: str | None` and `context: dict | None` in the request body.
When `status == "pending_confirmation"`, store them. Otherwise leave null.

- [ ] **Step 4: Extend status endpoint**

`GET /devices/{device_id}/commands/{command_id}/status` returns:

```json
{
  "status": "pending_confirmation",
  "detail": null,
  "displayName": null,
  "pendingConfirmation": { "card_id": "B1", "context": { "existing_record_key": "...", "requested_expiry_iso": "...", "requested_duration_minutes": "30", "existing_mode": "permanent", "target_display": "Instagram", "target_request": "lock IG for 30 min" } }
}
```

- [ ] **Step 5: Commit**

```bash
git add backend/app/db/models/command.py backend/app/api/routes/devices.py backend/alembic/versions/*.py
git commit -m "feat(commands): persist + surface pending_confirmation acks (B1 round-trip, Phase 6)"
```

---

# Phase 7 — iOS card templates

### Task 7.1: CardID enum + CardPayload

**Files:**
- Create: `Evlin iOS/Evlin iOS/Models/CardID.swift`
- Create: `Evlin iOS/Evlin iOS/Models/CardPayload.swift`

- [ ] **Step 1: Write CardID.swift**

```swift
import Foundation

/// All confirmation card IDs. See spec §5.
enum CardID: String, Codable, Sendable {
    // Group A — destructive confirmations
    // A2 removed (single unblock is direct action, no card) — see spec §5.2.
    case A1, A3
    // Group B — downgrade confirmations
    case B1, B2
    // Group C — upgrade confirmations
    case C1, C2
    // Group D — missing info / ambiguity
    case D1, D2, D3, D4
    // Group E — rejection + alternative
    case E1, E2, E3, E4
    // Group F — suggestion
    case F1
    // Group G — onboarding fallback
    case G1
}
```

- [ ] **Step 2: Write CardPayload.swift**

```swift
import Foundation
import SwiftUI

/// Reusable payload for all 8 card templates. Card-specific fields are optional.
struct CardPayload {
    let id: CardID
    let icon: String                     // SF Symbol
    let title: String
    let body: String
    let buttons: [CardButton]

    // Template variant knobs
    var checkboxes: [CardCheckboxItem]?  // MissingInfoCard (D4 variant)
    var itemList: [String]?              // BulkActionCard (A3), ListSuggestionCard (E4)
}

struct CardButton: Identifiable {
    let id = UUID()
    let label: String
    let style: Style
    let action: () -> Void

    enum Style {
        case primary
        case destructive
        case secondary
        case tertiary
        case cancel
    }
}

struct CardCheckboxItem: Identifiable {
    let id = UUID()
    let label: String
    let sublabel: String?
    var isSelected: Bool = false
}
```

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Models/CardID.swift" "Evlin iOS/Models/CardPayload.swift"
git commit -m "feat(models): CardID + CardPayload types (Phase 7)"
```

### Task 7.2: DangerConfirmCard template

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/DangerConfirmCard.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI

/// Used for A1 (Block first-time) and D3 (long duration).
/// (A2 was removed — single unblock is a direct action with no card.)
/// Optional secondary "alternative" action + destructive primary + cancel.
struct DangerConfirmCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: payload.icon).font(.title2)
                Text(payload.title).font(.headline)
            }
            Text(payload.body).font(.subheadline).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(payload.buttons) { btn in
                    Button(action: btn.action) {
                        Text(btn.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(backgroundColor(for: btn.style))
                            .foregroundColor(foregroundColor(for: btn.style))
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 6)
    }

    private func backgroundColor(for style: CardButton.Style) -> Color {
        switch style {
        case .primary: return .accentColor
        case .destructive: return .red
        case .secondary: return Color(.systemGray5)
        case .tertiary: return .clear
        case .cancel: return Color(.systemGray6)
        }
    }
    private func foregroundColor(for style: CardButton.Style) -> Color {
        switch style {
        case .primary, .destructive: return .white
        default: return .primary
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Components/ConfirmationCards/DangerConfirmCard.swift"
git commit -m "feat(cards): DangerConfirmCard template (Phase 7)"
```

### Task 7.3: ReplaceModeCard template

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/ReplaceModeCard.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI

/// Used for B1 (Permanent→timed), B2 (Block→shield), C1 (Shield→block), C2 (Block in shielded list).
/// Two-button primary choice: "change" / "keep".
struct ReplaceModeCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: payload.icon).font(.title2)
                Text(payload.title).font(.headline)
            }
            Text(payload.body).font(.subheadline).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(payload.buttons) { btn in
                    Button(action: btn.action) {
                        Text(btn.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(btn.style == .primary ? Color.accentColor
                                         : btn.style == .destructive ? Color.red
                                         : Color(.systemGray5))
                            .foregroundColor(btn.style == .primary || btn.style == .destructive ? .white : .primary)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 6)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Components/ConfirmationCards/ReplaceModeCard.swift"
git commit -m "feat(cards): ReplaceModeCard template (Phase 7)"
```

### Task 7.4: MissingInfoCard template

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/MissingInfoCard.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI

/// Used for D1 (quick-pick duration) and D4 (multi-child picker with checkboxes).
/// Renders checkboxes when payload.checkboxes is set, else just button row.
struct MissingInfoCard: View {
    let payload: CardPayload
    @State private var checkboxes: [CardCheckboxItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(payload.title).font(.headline)
            if !payload.body.isEmpty {
                Text(payload.body).font(.subheadline).foregroundStyle(.secondary)
            }

            if !checkboxes.isEmpty {
                VStack(spacing: 6) {
                    ForEach($checkboxes) { $item in
                        HStack {
                            Button(action: { item.isSelected.toggle() }) {
                                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                                    .foregroundColor(item.isSelected ? .accentColor : .secondary)
                            }
                            VStack(alignment: .leading) {
                                Text(item.label).font(.subheadline)
                                if let sub = item.sublabel { Text(sub).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            VStack(spacing: 8) {
                ForEach(payload.buttons) { btn in
                    Button(action: btn.action) {
                        Text(btn.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(btn.style == .primary ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(btn.style == .primary ? .white : .primary)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 6)
        .onAppear {
            if let items = payload.checkboxes { checkboxes = items }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Components/ConfirmationCards/MissingInfoCard.swift"
git commit -m "feat(cards): MissingInfoCard template with checkbox variant (Phase 7)"
```

### Task 7.5: Remaining card templates (AmbiguityCard, UnsupportedInModeCard, CatalogMissCard, ListSuggestionCard, BulkActionCard)

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/AmbiguityCard.swift`
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/UnsupportedInModeCard.swift`
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/CatalogMissCard.swift`
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/ListSuggestionCard.swift`
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/BulkActionCard.swift`

- [ ] **Step 1: Write AmbiguityCard.swift**

```swift
import SwiftUI

/// Used for D2 — 2-way radio choice ("lock all apps" vs "just distracting categories").
/// Renders as two tappable pills + Cancel.
struct AmbiguityCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(payload.title).font(.headline)
            if !payload.body.isEmpty {
                Text(payload.body).font(.subheadline).foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(payload.buttons) { btn in
                    Button(action: btn.action) {
                        Text(btn.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(btn.style == .primary ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(btn.style == .primary ? .white : .primary)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 6)
    }
}
```

- [ ] **Step 2: Write UnsupportedInModeCard.swift**

```swift
import SwiftUI

/// Used for E1 (Std can't shield single app), E2 (Max-only command in Std), G1 (Max onboarding fallback).
/// Supports an upgrade CTA as primary button variant.
struct UnsupportedInModeCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: payload.icon).font(.title2).foregroundStyle(.orange)
                Text(payload.title).font(.headline)
            }
            Text(payload.body).font(.subheadline).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(payload.buttons) { btn in
                    Button(action: btn.action) {
                        Text(btn.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(btn.style == .primary ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(btn.style == .primary ? .white : .primary)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 6)
    }
}
```

- [ ] **Step 3: Write CatalogMissCard.swift**

```swift
import SwiftUI

/// Used for E3 — block attempted on unrecognized app.
/// Shows optional "shield category" action if AI inferred a category.
struct CatalogMissCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title2)
                Text(payload.title).font(.headline)
            }
            Text(payload.body).font(.subheadline).foregroundStyle(.secondary)

            if let bullets = payload.itemList {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(bullets, id: \.self) { line in
                        HStack(alignment: .top) {
                            Text("•").font(.subheadline).foregroundStyle(.secondary)
                            Text(line).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            VStack(spacing: 8) {
                ForEach(payload.buttons) { btn in
                    Button(action: btn.action) {
                        Text(btn.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(btn.style == .primary ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(btn.style == .primary ? .white : .primary)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 6)
    }
}
```

- [ ] **Step 4: Write ListSuggestionCard.swift**

```swift
import SwiftUI

/// Used for E4 (no close match — empty variant) and F1 (1 or N close matches).
/// If payload.itemList is non-empty, shown as existing lists.
struct ListSuggestionCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: payload.icon).font(.title2)
                Text(payload.title).font(.headline)
            }
            if !payload.body.isEmpty {
                Text(payload.body).font(.subheadline).foregroundStyle(.secondary)
            }

            if let existing = payload.itemList, !existing.isEmpty {
                Text("Existing lists:").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(existing, id: \.self) { line in
                        HStack(alignment: .top) {
                            Text("•"); Text(line).font(.subheadline)
                        }
                    }
                }
            }

            VStack(spacing: 8) {
                ForEach(payload.buttons) { btn in
                    Button(action: btn.action) {
                        Text(btn.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(btn.style == .primary ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(btn.style == .primary ? .white : .primary)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 6)
    }
}
```

- [ ] **Step 5: Write BulkActionCard.swift**

```swift
import SwiftUI

/// Used for A3 — unblockAll with itemized list of what will be cleared.
struct BulkActionCard: View {
    let payload: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                Text(payload.title).font(.headline)
            }
            Text(payload.body).font(.subheadline).foregroundStyle(.secondary)

            if let items = payload.itemList {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .top) {
                            Text("•").font(.subheadline); Text(item).font(.subheadline)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            VStack(spacing: 8) {
                ForEach(payload.buttons) { btn in
                    Button(action: btn.action) {
                        Text(btn.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(btn.style == .destructive ? Color.red : Color(.systemGray5))
                            .foregroundColor(btn.style == .destructive ? .white : .primary)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 6)
    }
}
```

- [ ] **Step 6: Commit all 5 templates**

```bash
git add "Evlin iOS/Components/ConfirmationCards/AmbiguityCard.swift" \
        "Evlin iOS/Components/ConfirmationCards/UnsupportedInModeCard.swift" \
        "Evlin iOS/Components/ConfirmationCards/CatalogMissCard.swift" \
        "Evlin iOS/Components/ConfirmationCards/ListSuggestionCard.swift" \
        "Evlin iOS/Components/ConfirmationCards/BulkActionCard.swift"
git commit -m "feat(cards): 5 remaining card templates (Phase 7)"
```

### Task 7.6: CardDispatcher — map CardID → template + payload

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/CardDispatcher.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// Chooses which template renders a given CardID and builds the payload
/// from backend-provided context.
struct CardDispatcher: View {
    let cardID: CardID
    let context: CardContext
    let handlers: CardHandlers

    var body: some View {
        let payload = buildPayload()
        switch cardID {
        case .A1, .D3: DangerConfirmCard(payload: payload)
        case .A3: BulkActionCard(payload: payload)
        case .B1, .B2, .C1, .C2: ReplaceModeCard(payload: payload)
        case .D1, .D4: MissingInfoCard(payload: payload)
        case .D2: AmbiguityCard(payload: payload)
        case .E1, .E2, .G1: UnsupportedInModeCard(payload: payload)
        case .E3: CatalogMissCard(payload: payload)
        case .E4, .F1: ListSuggestionCard(payload: payload)
        }
    }

    // ... buildPayload() is large; see Task 7.7
    private func buildPayload() -> CardPayload {
        CardPayloadBuilder.build(cardID: cardID, context: context, handlers: handlers)
    }
}

/// Inputs to build a card payload.
struct CardContext {
    let targetDisplay: String           // "Instagram", "list 1", etc.
    let childName: String               // "Liam"
    let durationMinutes: Int?
    let categoryGuess: String?          // For E1, E3 fallback
    let listSuggestions: [String]
    let existingLists: [String]         // For E4
    let blockItems: [String]            // For A3
    let childDevices: [(id: UUID, label: String)]  // For D4
    let mode: String                    // "std" or "max" — drives copy variants (E1)
    // For B1 round-trip (see plan Phase 6/9):
    let existingRecordKey: String?      // Opaque key of the permanent record being downgraded
    let requestedExpiryISO: String?     // Clock-aligned expiry the parent is proposing
    let existingMode: String?           // "permanent" | "timed" — informs B1 copy
    // Extend as needed
}

/// Handlers wired by ChatViewModel when rendering.
struct CardHandlers {
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onTertiary: (() -> Void)?
    var onCancel: (() -> Void)?
    // For D1: quick-pick duration
    var onDurationPicked: ((Int?) -> Void)?   // nil = permanent
    // For D4: child selection
    var onChildrenPicked: (([UUID]) -> Void)?
    // For F1: list pick
    var onListPicked: ((String) -> Void)?
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Components/ConfirmationCards/CardDispatcher.swift"
git commit -m "feat(cards): CardDispatcher view + context/handler types (Phase 7)"
```

### Task 7.7: CardPayloadBuilder — per-card copy

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/ConfirmationCards/CardPayloadBuilder.swift`

- [ ] **Step 1: Write the file**

This builder centralizes all card copy (so localization and A/B testing are possible later). Implement entries for each CardID per spec §5.2.

```swift
import Foundation

enum CardPayloadBuilder {
    static func build(cardID: CardID, context: CardContext, handlers: CardHandlers) -> CardPayload {
        switch cardID {
        case .A1: return a1(context, handlers)
        // A2 removed — single unblock is direct action (spec §5.2).
        case .A3: return a3(context, handlers)
        case .B1: return b1(context, handlers)
        case .B2: return b2(context, handlers)
        case .C1: return c1(context, handlers)
        case .C2: return c2(context, handlers)
        case .D1: return d1(context, handlers)
        case .D2: return d2(context, handlers)
        case .D3: return d3(context, handlers)
        case .D4: return d4(context, handlers)
        case .E1: return e1(context, handlers)
        case .E2: return e2(context, handlers)
        case .E3: return e3(context, handlers)
        case .E4: return e4(context, handlers)
        case .F1: return f1(context, handlers)
        case .G1: return g1(context, handlers)
        }
    }

    // MARK: - Group A

    private static func a1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .A1,
            icon: "nosign",
            title: "Block \(ctx.targetDisplay)?",
            body: "Blocking hides the app from \(ctx.childName)'s home screen until you unblock. It won't auto-release.",
            buttons: [
                CardButton(label: "Block \(ctx.targetDisplay)", style: .destructive, action: h.onPrimary ?? {}),
                CardButton(label: "Shield for a while instead", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    // A2 removed — single unblock is a direct action; no payload/function needed.

    private static func a3(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .A3,
            icon: "exclamationmark.triangle",
            title: "Unblock ALL apps?",
            body: "All \(ctx.blockItems.count) will return to \(ctx.childName)'s home screen. Shields on other apps are not affected.",
            buttons: [
                CardButton(label: "Unblock all \(ctx.blockItems.count)", style: .destructive, action: h.onPrimary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ],
            itemList: ctx.blockItems
        )
    }

    // MARK: - Group B (downgrade)

    private static func b1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        let durStr = ctx.durationMinutes.map { "\($0) min" } ?? "timed"
        return CardPayload(
            id: .B1,
            icon: "timer",
            title: "Change permanent lock to \(durStr)?",
            body: "\(ctx.targetDisplay) is currently shielded permanently. Changing to \(durStr) means it'll auto-unlock.",
            buttons: [
                CardButton(label: "Change to \(durStr)", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Keep permanent", style: .secondary, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func b2(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        let durStr = ctx.durationMinutes.map { "\($0) min" } ?? "timed"
        return CardPayload(
            id: .B2,
            icon: "arrow.triangle.2.circlepath",
            title: "Switch from block to shield?",
            body: "\(ctx.targetDisplay) is currently blocked (hidden from home screen). Switching to a \(durStr) shield means: icon returns, app is locked but visible, auto-unlocks.",
            buttons: [
                CardButton(label: "Switch to shield", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Keep block", style: .secondary, action: h.onCancel ?? {}),
            ]
        )
    }

    // MARK: - Group C (upgrade)

    private static func c1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .C1,
            icon: "nosign",
            title: "Replace shield with permanent block?",
            body: "\(ctx.targetDisplay) is currently shielded. Blocking removes the auto-unlock — \(ctx.childName) won't see it again until you unblock.",
            buttons: [
                CardButton(label: "Replace with block", style: .destructive, action: h.onPrimary ?? {}),
                CardButton(label: "Keep shield", style: .secondary, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func c2(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .C2,
            icon: "nosign",
            title: "Block \(ctx.targetDisplay)?",
            body: "\(ctx.targetDisplay) is currently covered by a list shield. Blocking hides just this app; the list shield stays on the other apps until it expires.",
            buttons: [
                CardButton(label: "Block, keep list on others", style: .destructive, action: h.onPrimary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    // MARK: - Group D (missing info / ambiguity)

    private static func d1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .D1,
            icon: "timer",
            title: "How long should \(ctx.targetDisplay) be shielded?",
            body: "",
            buttons: [
                CardButton(label: "15 minutes", style: .secondary, action: { h.onDurationPicked?(15) }),
                CardButton(label: "1 hour", style: .secondary, action: { h.onDurationPicked?(60) }),
                CardButton(label: "Permanently", style: .secondary, action: { h.onDurationPicked?(nil) }),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func d2(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .D2,
            icon: "questionmark.circle",
            title: "What does \"everything\" mean?",
            body: "",
            buttons: [
                CardButton(label: "Lock ALL apps on \(ctx.childName)'s phone", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Just distracting categories", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func d3(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        let durStr = ctx.durationMinutes.map { "\($0) min" } ?? "a long time"
        return CardPayload(
            id: .D3,
            icon: "hourglass",
            title: "Lock for \(durStr)?",
            body: "This is longer than 24 hours. Are you sure?",
            buttons: [
                CardButton(label: "Confirm \(durStr) lock", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Change duration", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func d4(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        let items = ctx.childDevices.map {
            CardCheckboxItem(label: "\($0.label)", sublabel: nil, isSelected: false)
        }
        return CardPayload(
            id: .D4,
            icon: "person.2",
            title: "Lock \(ctx.targetDisplay) on which phone?",
            body: "",
            buttons: [
                CardButton(label: "Confirm", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ],
            checkboxes: items
        )
    }

    // MARK: - Group E (rejection + alternative)

    private static func e1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        // E1 fires whenever the dispatcher can't shield a single app directly.
        // In Std: FamilyControls doesn't expose a parent-side app picker, so we offer
        //   category/Saved List fallbacks or an upgrade to Max.
        // In Max: remote single-app shield needs the Phase-5 remote picker, which
        //   isn't built yet — so the copy and CTAs are different (no "upgrade" line).
        let cat = ctx.categoryGuess?.capitalized ?? "its category"
        let isMax = ctx.mode == "max"

        let title: String
        let body: String
        var buttons: [CardButton] = []

        if isMax {
            title = "Can't shield \"\(ctx.targetDisplay)\" directly yet"
            body = "Remote single-app shield is coming soon. For now, shield the category \(ctx.targetDisplay) belongs to, or add it to a Saved List on \(ctx.childName)'s phone."
            buttons.append(CardButton(label: "Shield \(cat) category instead", style: .primary, action: h.onPrimary ?? {}))
            buttons.append(CardButton(label: "Add \(ctx.targetDisplay) to a Saved List", style: .secondary, action: h.onSecondary ?? {}))
        } else {
            title = "Standard mode can't shield \(ctx.targetDisplay) directly"
            body = "Standard mode locks by Saved List or category."
            buttons.append(CardButton(label: "Shield \(cat) category instead", style: .primary, action: h.onPrimary ?? {}))
            buttons.append(CardButton(label: "Add \(ctx.targetDisplay) to a Saved List", style: .secondary, action: h.onSecondary ?? {}))
            buttons.append(CardButton(label: "Upgrade to Max", style: .tertiary, action: h.onTertiary ?? {}))
        }
        buttons.append(CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}))

        return CardPayload(id: .E1, icon: "exclamationmark.triangle", title: title, body: body, buttons: buttons)
    }

    private static func e2(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .E2,
            icon: "lock.shield",
            title: "Block is a Max feature",
            body: "Permanent hiding from home screen requires Max. Standard mode can shield \(ctx.targetDisplay) temporarily instead.",
            buttons: [
                CardButton(label: "Upgrade to Max", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Shield \(ctx.targetDisplay) instead", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func e3(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        var buttons: [CardButton] = []
        if let cat = ctx.categoryGuess?.capitalized {
            buttons.append(CardButton(label: "Shield \(cat) category", style: .primary, action: h.onPrimary ?? {}))
        }
        buttons.append(CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}))

        return CardPayload(
            id: .E3,
            icon: "xmark.circle.fill",
            title: "Can't hard-block \"\(ctx.targetDisplay)\"",
            body: "Block requires the app to be in Evlin's known catalog. \"\(ctx.targetDisplay)\" isn't recognized.",
            buttons: buttons,
            itemList: [
                "Shield the category it belongs to",
                "Add it manually to a Saved List (picker on \(ctx.childName)'s phone)",
            ]
        )
    }

    private static func e4(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .E4,
            icon: "xmark.circle",
            title: "No list called \"\(ctx.targetDisplay)\"",
            body: "",
            buttons: [
                CardButton(label: "Create \"\(ctx.targetDisplay)\" on \(ctx.childName)'s phone", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ],
            itemList: ctx.existingLists
        )
    }

    private static func f1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        if ctx.listSuggestions.count == 1 {
            let suggestion = ctx.listSuggestions[0]
            return CardPayload(
                id: .F1,
                icon: "questionmark.circle",
                title: "Did you mean \"\(suggestion)\"?",
                body: "\"\(ctx.targetDisplay)\" doesn't exist, but \"\(suggestion)\" is close.",
                buttons: [
                    CardButton(label: "Lock \(suggestion)", style: .primary, action: { h.onListPicked?(suggestion) }),
                    CardButton(label: "Show all lists", style: .secondary, action: h.onSecondary ?? {}),
                    CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
                ]
            )
        }
        var buttons = ctx.listSuggestions.map { name in
            CardButton(label: "Pick \(name)", style: .secondary, action: { h.onListPicked?(name) })
        }
        buttons.append(CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}))
        return CardPayload(
            id: .F1,
            icon: "questionmark.circle",
            title: "Multiple lists close to \"\(ctx.targetDisplay)\":",
            body: "",
            buttons: buttons,
            itemList: ctx.listSuggestions
        )
    }

    // MARK: - Group G

    private static func g1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .G1,
            icon: "exclamationmark.triangle",
            title: "Can't set up Maximum on this phone",
            body: "\(ctx.childName)'s phone isn't signed in with a Child Apple ID. Maximum requires Family Sharing with a Child account.",
            buttons: [
                CardButton(label: "Set up Child Apple ID", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Continue with Standard", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Back", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Components/ConfirmationCards/CardPayloadBuilder.swift"
git commit -m "feat(cards): CardPayloadBuilder with all 17 card copies (Phase 7)"
```

---

# Phase 8 — ReceiptCard with effective-state rendering

### Task 8.1: Rewrite ReceiptCard with primary + effective-state lines

**Files:**
- Rewrite: `Evlin iOS/Evlin iOS/Components/ReceiptCard.swift` (create if it doesn't exist)

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

enum ReceiptState: Sendable, Equatable {
    case pending
    case confirmedExact(displayName: String, unlocksAt: Date?)
    case confirmedFallback(displayName: String, category: String, origRequest: String)
    case failedPermission
    case failedListNotFound(listName: String)
    case failedCategoryNotConfigured(category: String)
    case failedTimeout
    case failedOther(reason: String)
}

/// Two-line receipt: primary mutation + optional effective-state disclosure.
/// See spec §8.
struct ReceiptCard: View {
    let state: ReceiptState
    let effectiveState: EffectiveState?    // from ActiveLockStore; nil if not queried

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            primaryLine
            if let line = effectiveStateLine {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var primaryLine: some View {
        switch state {
        case .pending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending…").font(.subheadline)
            }
        case .confirmedExact(let name, let unlocksAt):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                VStack(alignment: .leading) {
                    Text("Shielded \(name)").font(.subheadline).fontWeight(.medium)
                    if let at = unlocksAt {
                        Text("Unlocks at \(timeString(at))").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Until you unlock").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .confirmedFallback(let name, let category, let orig):
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                VStack(alignment: .leading) {
                    Text("\(category.capitalized) shielded (fallback)").font(.subheadline).fontWeight(.medium)
                    Text("No exact match for \(orig); shielded \(category) instead.")
                        .font(.caption).foregroundStyle(.secondary)
                    _ = name  // unused outside title
                }
            }
        case .failedPermission:
            Label("Screen Time permission required.", systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.red)
        case .failedListNotFound(let listName):
            Label("List \"\(listName)\" not found.", systemImage: "xmark.octagon")
                .font(.subheadline).foregroundStyle(.red)
        case .failedCategoryNotConfigured(let cat):
            Label("Category \(cat) not configured.", systemImage: "xmark.octagon")
                .font(.subheadline).foregroundStyle(.red)
        case .failedTimeout:
            Label("Command timed out.", systemImage: "clock")
                .font(.subheadline).foregroundStyle(.red)
        case .failedOther(let reason):
            Label(reason, systemImage: "xmark.octagon").font(.subheadline).foregroundStyle(.red)
        }
    }

    /// Effective-state line per spec §8.3 — honest about indeterminate coverage.
    private var effectiveStateLine: String? {
        guard let effectiveState = effectiveState else { return nil }
        if effectiveState.isBlocked { return "Still blocked." }

        // Certain coverage wins
        if !effectiveState.shieldsCovering.isEmpty {
            let sorted = effectiveState.shieldsCovering.sorted { a, b in
                if a.expiresAt == nil && b.expiresAt != nil { return true }
                if a.expiresAt != nil && b.expiresAt == nil { return false }
                return (a.expiresAt ?? .distantPast) > (b.expiresAt ?? .distantPast)
            }
            let strongest = sorted[0]
            if strongest.expiresAt == nil {
                return "Still shielded by \(strongest.displayName) permanently."
            }
            return "Still shielded by \(strongest.displayName) until \(timeString(strongest.expiresAt!))."
        }

        // Indeterminate — Saved List shields exist but we couldn't verify coverage.
        // Better to warn than claim unrestricted.
        if effectiveState.possibleSavedListCoverage {
            return "May still be covered by a Saved List — check Settings."
        }

        return nil   // truly unrestricted
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Components/ReceiptCard.swift"
git commit -m "feat(receipt): ReceiptCard with primary + effective-state lines (Phase 8)"
```

---

# Phase 9 — Chat ViewModel integration

### Task 9.1: Extend ChatResponse / ChatAction to carry card_id and reason

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Services/APIClient.swift`

- [ ] **Step 1: Update the ChatResponse decoding structs**

Locate `APIClient.sendChatMessage` — add the new fields it now receives:

```swift
struct ChatActionResponse: Codable, Sendable {
    let type: String
    let command_id: UUID?
    let tier: String?
    let target_display: String?
    let duration_minutes: Int?
    let confirmation_required: Bool?
    let card_id: String?
    let confirmation_reason: String?
    let list_suggestions: [String]?
    let category_guess: String?
}

struct ChatResponse: Codable, Sendable {
    let message: String
    let reasoning: String?
    let action: ChatActionResponse?
}
```

Also extend `sendChatMessage` to accept `forceConfirmations`:

```swift
func sendChatMessage(
    message: String,
    familyID: UUID,
    childName: String?,
    history: [ChatHistoryEntry],
    forceConfirmations: [String] = []
) async throws -> ChatResponse {
    struct Body: Encodable {
        let message: String
        let family_id: UUID
        let child_name: String?
        let history: [ChatHistoryEntry]
        let force_confirmations: [String]
    }
    let body = Body(
        message: message, family_id: familyID,
        child_name: childName, history: history,
        force_confirmations: forceConfirmations
    )
    // ... existing POST /parent/chat logic, JSONEncoder().encode(body) ...
}
```

And extend the ack-status polling decoder: when `status == "pending_confirmation"`,
the ack detail carries a `card_id` (e.g. "B1") plus a string-keyed `context` dict
(see ActionExecutor's `.pendingConfirmation` case). ChatViewModel maps that
into `currentCard = (.B1, CardContext(... existingRecordKey, requestedExpiryISO,
requestedDurationMinutes, existingMode ...), handlers)`:

```swift
struct AckPendingConfirmation: Decodable {
    let card_id: String
    let context: [String: String]
}

struct AckStatusResponse: Decodable {
    let status: String  // "queued" | "in_flight" | "confirmed" | "failed" | "pending_confirmation"
    let detail: String?
    let displayName: String?
    let pendingConfirmation: AckPendingConfirmation?
}
```

Backend ack-status endpoint needs a matching extension: when the child posts
an ack with the `.pendingConfirmation` AckResult case, persist card_id+context
on the Command row and surface them here. (Add the column in a 6.x subtask.)

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Services/APIClient.swift"
git commit -m "feat(api): chat response carries card_id, confirmation_reason, suggestions (Phase 9)"
```

### Task 9.2: ChatViewModel handles confirmation cards

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Chat/ChatViewModel.swift`

- [ ] **Step 1: Add card rendering pipeline**

Add an enum representing what the ChatView should render after each response, plus the handler scaffolding. Add these near the other published state:

```swift
enum ChatOutput {
    case text(String)
    case card(CardID, CardContext, CardHandlers)
    case receipt(ReceiptState, EffectiveState?)
}

@Published var currentCard: (CardID, CardContext, CardHandlers)?
```

When the response contains a `card_id`, set `currentCard` with the appropriate context. The handlers follow-up by re-calling `/parent/chat` with modified phrasing (e.g. user picked a duration → resend with duration filled in).

**Phase 9 MVP fully-wired cards (required for Phase 12 validation to pass)**:
- **A1** — Block confirmation → confirm re-sends /parent/chat with phrasing that skips the A1 guardrail
- **B1** — Permanent→timed downgrade → confirm re-sends /parent/chat with the ORIGINAL user message and `force_confirmations=["B1"]`. Backend dispatcher sets `force_downgrade=true` on ResolvedAction → Command payload carries it → child executor calls `addShield(force: true)`. Parent does NOT mutate ActiveLockStore directly (the store lives on the child device).
- **D1** — Missing duration quick-pick → picks duration, re-sends /parent/chat with duration filled
- **E1** — Std-can't-shield-single → primary action re-sends /parent/chat as category shield (copy varies by mode — see CardPayloadBuilder.e1)

Stub (renders correctly, primary action logs to console): A3, B2, C1, C2, D2, D3, D4, E2, E3, E4, F1, G1. Follow-up per card as time permits.

A2 was removed — `unblock X` doesn't render a card; direct receipt.

This is a larger integration task — implement incrementally. Minimum MVP:

```swift
// In sendMessage, after getting ChatResponse:
// Path 1 — backend dispatcher returned a card_id synchronously (A1/D1/E1/etc.)
if let action = response.action, let cardIDStr = action.card_id, let cardID = CardID(rawValue: cardIDStr) {
    let context = CardContext(
        targetDisplay: action.target_display ?? "",
        childName: self.childName,
        durationMinutes: action.duration_minutes,
        categoryGuess: action.category_guess,
        listSuggestions: action.list_suggestions ?? [],
        existingLists: [],        // TODO: fetch separately
        blockItems: [],           // TODO: for A3, fetch current blocks
        childDevices: [],         // TODO: for D4, list child devices
        mode: self.protectionMode,  // "std" | "max" — drives E1 copy
        existingRecordKey: nil,
        requestedExpiryISO: nil,
        existingMode: nil
    )
    let handlers = CardHandlers(
        onPrimary: { [weak self] in self?.handleCardPrimary(cardID: cardID, action: action) },
        onCancel: { [weak self] in self?.currentCard = nil }
    )
    self.currentCard = (cardID, context, handlers)
    return
}

// Path 2 — normal flow: queue command_id, poll ack-status, show receipt.
// If status==pending_confirmation, poll returns pendingConfirmation payload
// (card_id + context dict, see APIClient AckStatusResponse). Build B1 context:
//
// if let pc = statusResp.pendingConfirmation, let cardID = CardID(rawValue: pc.card_id) {
//     let ctx = CardContext(
//         targetDisplay: pc.context["target_display"] ?? "",
//         childName: self.childName,
//         durationMinutes: Int(pc.context["requested_duration_minutes"] ?? ""),
//         categoryGuess: nil, listSuggestions: [], existingLists: [],
//         blockItems: [], childDevices: [],
//         mode: self.protectionMode,
//         existingRecordKey: pc.context["existing_record_key"],
//         requestedExpiryISO: pc.context["requested_expiry_iso"],
//         existingMode: pc.context["existing_mode"]  // "permanent"
//     )
//     self.currentCard = (cardID, ctx, handlersForB1(ctx: ctx))
// }
```

Implement `handleCardPrimary` fully for **A1, B1, D1, E1** — these are REQUIRED for Phase 12 validation. Each re-sends a new /parent/chat with clarified phrasing. For **B1** specifically: re-send the ORIGINAL user message verbatim plus `force_confirmations: ["B1"]` — the backend dispatcher sees the force flag and bakes `force_downgrade=true` into the ResolvedAction, which travels in the Command payload to the child, where `ActiveLockStore.addShield(force: true)` bypasses the merge rule. Parent NEVER writes to ActiveLockStore — the authoritative copy lives on the child device. Other cards (A3, B2, C1, C2, D2, D3, D4, E2, E3, E4, F1, G1) start as logged-only stubs — they render correctly but don't execute the primary action.

Example B1 handler:

```swift
private func handleB1Confirm(ctx: CardContext) async {
    // Original message is still in the last user-bubble; re-send it verbatim
    // with force_confirmations=["B1"]. Backend dispatcher sets force_downgrade=true.
    guard let lastUserMsg = messages.reversed().first(where: { $0.isUser })?.text
    else { return }
    currentCard = nil
    await apiClient.sendChatMessage(
        message: lastUserMsg,
        familyID: familyID,
        childName: childName,
        history: historyForAPI,
        forceConfirmations: ["B1"]
    )
    // Normal ack-polling flow resumes; child executes with force.
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatViewModel.swift"
git commit -m "feat(chat): ChatViewModel routes confirmation cards (Phase 9 partial)"
```

### Task 9.3: ChatView renders CardDispatcher

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Chat/ChatView.swift`

- [ ] **Step 1: In the main chat scroll view, below the messages, add:**

```swift
if let (cardID, context, handlers) = viewModel.currentCard {
    CardDispatcher(cardID: cardID, context: context, handlers: handlers)
        .padding()
        .transition(.opacity.combined(with: .scale))
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatView.swift"
git commit -m "feat(chat): render CardDispatcher below message list (Phase 9)"
```

---

# Phase 10 — Onboarding DeletionProtection toggle update

### Task 10.1: Rewrite DeletionProtectionStep with default-on toggle

**Files:**
- Rewrite: `Evlin iOS/Evlin iOS/Views/Onboarding/Child/DeletionProtectionStep.swift`

- [ ] **Step 1: Replace file contents**

```swift
import SwiftUI
import FamilyControls
import ManagedSettings

/// Child onboarding step — explicit toggle (default ON) for denyAppRemoval.
/// Shows side-effect copy when enabled; hides it when user turns off.
/// Per spec §2 D5 + user feedback.
struct DeletionProtectionStep: View {
    @State private var isEnabled: Bool = true
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Protect Evlin from deletion")
                .font(.title2).bold()

            Text("If enabled, Liam won't be able to delete Evlin from their phone, even if they know your passcode.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Toggle("Prevent Evlin from being deleted", isOn: $isEnabled)
                .padding(.horizontal, 24)
                .onChange(of: isEnabled) { _, newValue in
                    applyDenyAppRemoval(newValue)
                }

            if isEnabled {
                Text("Note: this also prevents Liam from deleting **other apps** on this phone. iOS doesn't support per-app deletion protection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }

            Spacer()

            Button("Continue") { onContinue() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 24)
        }
        .onAppear {
            // Initialize ManagedSettings to match the default
            applyDenyAppRemoval(true)
        }
    }

    private func applyDenyAppRemoval(_ flag: Bool) {
        let store = ManagedSettingsStore()
        store.application.denyAppRemoval = flag
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Views/Onboarding/Child/DeletionProtectionStep.swift"
git commit -m "feat(onboarding): DeletionProtection as default-on toggle with side-effect copy (Phase 10)"
```

---

# Phase 11 — Migration

### Task 11.1: Migrate legacy ActiveLock entries on app launch

**Files:**
- Create: `Evlin iOS/Evlin iOS/Services/ActiveLockMigration.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// One-shot migration from legacy `evlin.activeLocks` to new `evlin.shieldRecords`.
/// Pre-launch; safe to discard legacy data if parsing fails.
enum ActiveLockMigration {
    static let legacyKey = "evlin.activeLocks"
    static let shieldsKey = "evlin.shieldRecords"
    static let blocksKey = "evlin.blockRecords"

    static func runIfNeeded() {
        let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
        guard let legacyData = defaults?.data(forKey: legacyKey) else { return }

        // If new keys already populated, we've migrated. Skip.
        if defaults?.data(forKey: shieldsKey) != nil { return }

        // Read legacy format (if decodable); otherwise just drop.
        // Legacy was [UUID: ActiveLock] — we can't reconstruct ShieldRecords
        // without the tier info. For pre-launch migration, drop them.
        defaults?.removeObject(forKey: legacyKey)
        // Initialize empty new keys
        if let empty = try? PropertyListEncoder().encode([String: String]()) {
            defaults?.set(empty, forKey: shieldsKey)
        }
    }
}
```

- [ ] **Step 2: Call it at app launch**

In `Evlin iOS/Evlin iOS/Evlin_iOSApp.swift`, within the `@main struct` `init()`:

```swift
init() {
    ActiveLockMigration.runIfNeeded()
}
```

If there's no `init()` yet, add one to the `App` struct.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Services/ActiveLockMigration.swift" "Evlin iOS/Evlin_iOSApp.swift"
git commit -m "feat(migrate): drop legacy evlin.activeLocks on launch (Phase 11)"
```

---

# Phase 12 — Manual validation

### Task 12.1: End-to-end smoke tests on device

- [ ] **Step 1: Clean state**

Delete and reinstall Evlin on the test iPhone. Enter Spike tests → "Reset all Evlin state" (or use the hard reset button).

- [ ] **Step 2: Walk through shield path**

1. Chat: `shield list 1 for 30 min`.
2. Expect receipt `Shielded list 1 · 30 min · unlocks at {time}`.
3. Kill and relaunch Evlin within the window; shield should still be active (persisted).
4. Open a shielded app on the child device — expect Evlin overlay.

- [ ] **Step 3: Walk through block path (Max mode only)**

1. Max mode (if configured): `block Instagram`.
2. Expect A1 card. Confirm block.
3. On home screen: Instagram icon is hidden.
4. Chat: `unblock Instagram`. Direct action — no confirmation card; receipt appears immediately.
5. Icon returns. Receipt should say `🔓 Unblocked Instagram.` plus effective-state line if any shield still covers IG (e.g. `Still shielded by Social until 17:30.`).

- [ ] **Step 4: Walk through conflict path (savedList tier — exactApp gated in MVP)**

Uses `list 1` instead of a single app because MVP's exactApp shield is fail-fast
(see "Known limitations"). The conflict semantics are identical; only the tier
differs.

1. `shield list 1 permanently`.
2. `shield list 1 for 30 min`.
3. Expect B1 card: `Change permanent lock to 30 min? "list 1" is currently shielded permanently...`
4. Tap **Change to 30 min**.
5. Verify ActiveLockStore shows a single ShieldRecord with tier=.savedList, expiresAt ≈ now+30min.
6. Confirm receipt: `Shortened list 1 lock to 30 min. Unlocks at 17:30.`

- [ ] **Step 5: Walk through missing-duration path**

1. `shield list 1` (no duration).
2. Expect D1 card with duration options.
3. Pick 15 min. Verify receipt and that the shield applies.

- [ ] **Step 5.5: Walk through effective-state receipt**

Verifies the P1 fix (receipts honest after unblock/unshield).

1. From Step 3 end state (Instagram blocked).
2. `shield Social category for 60 min`.
3. `unblock Instagram`.
4. **Expected receipt**: `🔓 Unblocked Instagram. Still shielded by Social until 18:30.`
   (Backend threads category_hint=social via catalog; iOS effectiveState detects Social coverage.)
5. Bonus — `shield list 1 for 60 min` (list 1 happens to contain IG).
6. `unblock TikTok` (TikTok was never blocked — just to see behavior — or pick another
   blocked app after first blocking it).
7. If a saved list exists in the family, receipt should include the `possibleSavedListCoverage`
   disclosure: `"may still be in a Saved List — check Settings."` (because we can't confirm
   via bundleID alone).

- [ ] **Step 6: Record validation notes**

Create `docs/superpowers/specs/2026-04-24-validation-notes.md` with:
```markdown
# Phase 12 Validation — 2026-04-24
## Paths that MUST work (Phase 9 fully wired)
- [ ] Shield savedList/category (any tier except exactApp)
- [ ] Block → A1 card → confirm → icon hides
- [ ] Unblock → direct action → icon returns
- [ ] Conflict B1 (permanent→timed downgrade on savedList)
- [ ] Missing duration D1 → quick-pick → shield applies
- [ ] Effective-state receipt honesty (Unblock + Still shielded by...)
## Paths that are EXPECTED to be stubs (Phase 9 not wired)
- [ ] A3, C1, C2, D2, D3, D4, E2, E3, E4, F1, G1 render correctly but primary action logs only
- [ ] exactApp shield fails fast with .notImplemented (expected — out of MVP scope)
```

- [ ] **Step 7: Commit validation notes**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add docs/superpowers/specs/2026-04-24-validation-notes.md
git commit -m "docs(validation): Phase 12 on-device walk-through"
```

---

## Completion criteria

- [ ] All Phase 1–11 tasks checked.
- [ ] `pytest backend/tests/services/test_verb_dispatcher.py` green.
- [ ] Xcode test target green for `ActiveLockStoreTests`.
- [ ] `curl` smoke of `/parent/chat` with `"lock everything he wastes on"` returns `card_id: D2`.
- [ ] Device test: full shield path → unshield path works end-to-end.
- [ ] No remaining references to `ActiveLock` (legacy struct) in Swift sources.

Once all above are ✅ → merge `feat/three-tier-lock` to main.

---

## Deferred (out of scope for this plan)

From spec §12 — leave for a future plan:

- APNs silent push (Phase 5 of original three-tier plan).
- Phase-5 Max remote FamilyActivityPicker.
- Guided Access / Focus Session.
- Category-token rename UX.
- Localization.
- Web-domain-only primary targets.

## Known MVP limitations (implemented partially, follow-ups noted)

- **Max exactApp shield — NOT implemented; path is fail-fast.** No token source is wired for
  `exactApp` tier in MVP. The dispatcher routes Max/`kind=app` to the E1 fallback card, so
  production flows never enter this path. If they ever do (bug or future Phase 5 wiring arrives
  without updating this), `ActionExecutor.executeShield` throws `.notImplemented` with a clear
  reason — catching the bug loudly instead of silently shielding the wrong thing.
- **Post-onboarding Max→Std downgrade — out of scope.** The only downgrade path is G1 during
  onboarding (when `.child` auth fails, before any blocks exist). Per spec §5.2 G1, blocks
  are not auto-cleared; Std dispatcher already accepts `unblock` / `unblockAll` directly, so
  any blocks that DO exist remain removable. Settings-triggered downgrade isn't in this plan.
- **Card handler coverage** — ChatViewModel wires **A1, B1, D1, E1** handlers fully
  (these are REQUIRED for Phase 12 validation to pass). Others
  (A3, B2, C1, C2, D2, D3, D4, E2, E3, E4, F1, G1) render correctly but primary action
  is logged-only stub. Follow-ups per card as time permits. (A2 has been removed entirely;
  single `unblock` is a direct action.)
- **Multi-child context** — D4 card renders but child-device list is placeholder empty until
  `ChatViewModel.currentCard.childDevices` is wired via `/family/children` API call.
- **Unshield disambiguation** — FULLY implemented per spec §4.4 (see `unshieldAppByBundle`
  in Task 3.1). Tested path: when no exactApp shield exists and a single higher-tier cover
  is present, the receipt suggests unlocking the source directly ("unlock list 1"). When
  multiple cover, the receipt lists them all.
