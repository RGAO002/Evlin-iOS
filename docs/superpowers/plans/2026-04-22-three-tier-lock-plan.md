# Three-Tier App Locking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build end-to-end parental control locking — parent types in Chat, child's app gets blocked — via three-tier strategy (bundle ID direct / saved list / category fallback), with correct concurrent lock semantics, a redesigned onboarding flow for both parent and child modes, and a receipt/ack system.

**Architecture:**
- **iOS**: `ActiveLockStore` actor holds union of all active locks; `ActionExecutor` translates commands → shield calls; `DeviceActivityMonitor` extension removes expired locks and recomputes. Onboarding split into Parent / Child flows with Maximum (Child Apple ID) / Standard (passcode) branches.
- **Backend** (FastAPI): resolver maps Chat intent to a tier (saved list → catalog → category); commands queue per-device; ephemeral `PendingBlob` relays Max-mode selections without long-term storage.
- **Delivery**: foreground poll for MVP; APNs silent push added in Phase 5.

**Tech Stack:** Swift/SwiftUI, FamilyControls, ManagedSettings, DeviceActivity, FastAPI, SQLAlchemy, Postgres, Gemini, pytest, XCTest.

**Reference:** spec at `docs/superpowers/specs/2026-04-22-three-tier-lock-design.md`.

---

## File Structure

### iOS files (under `Evlin iOS/Evlin iOS/`)

**New:**
```
Models/
  LockTier.swift
  ActiveLock.swift
  CommandModels.swift
  ReceiptState.swift
Services/
  ActiveLockStore.swift       (actor)
  LocalAliasStore.swift
  ActionExecutor.swift
  CommandPoller.swift
Components/
  ReceiptCard.swift
Views/Onboarding/             (rebuild — see Phase 4)
  OnboardingCoordinator.swift
  Shared/WelcomeStep.swift
  Shared/ModeSelectStep.swift
  Parent/{many steps}.swift
  Child/{many steps}.swift
```

**Modified:**
```
Services/APIClient.swift                          (new endpoints)
Services/ScreenTimeManager.swift                   (delegate to ActiveLockStore)
Views/Chat/ChatView.swift                          (insert ReceiptCard)
Views/Chat/ChatViewModel.swift                     (new action types)
Views/Home/HomeSettingsSheet.swift                 (saved lists + active locks section)
EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift (ActiveLockStore hook)
```

**Deleted:**
```
Views/Onboarding/OnboardingView.swift   (replaced)
Views/Onboarding/SetupView.swift        (replaced)
```

### Backend files (under `adaptive-engine/backend/app/`)

**New:**
```
db/models/
  family.py
  device.py
  pairing.py
  saved_list.py
  command.py
services/
  chat_resolver.py
  app_catalog.py
data/
  app_catalog.json
api/routes/
  family.py
  parent_commands.py
```

**Modified:**
```
api/routes/parent_chat.py    (add resolver, return command_id)
api/routes/child_device.py    (add commands / ack / pending-blob)
```

---

# Phase 0 — Spike (real-device validation)

**Purpose:** Validate the critical iOS API assumptions before writing production code. Outputs a 1-page spike report that gates Phase 4 Max-mode design.

**Pre-req:** A test iPhone with Evlin iOS installed, FamilyControls authorized, and ideally a second account or family-sharing setup available.

### Task 0.1: Create spike view in existing app

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Debug/SpikeView.swift`
- Modify: `Evlin iOS/Evlin iOS/Views/Home/HomeSettingsSheet.swift` (add nav link to SpikeView, debug-only)

- [ ] **Step 1: Create SpikeView scaffolding**

```swift
// Evlin iOS/Evlin iOS/Views/Debug/SpikeView.swift
import SwiftUI
import FamilyControls
import ManagedSettings

struct SpikeView: View {
    @State private var log: [String] = []
    private let store = ManagedSettingsStore()

    var body: some View {
        NavigationStack {
            List {
                Section("Bundle ID block") {
                    Button("Block Instagram") { blockInstagram() }
                    Button("Block Roblox") { blockRoblox() }
                    Button("Clear all blocks") { clearBlocks() }
                }
                Section("denyAppRemoval") {
                    Button("Enable") { setDenyRemoval(true) }
                    Button("Disable") { setDenyRemoval(false) }
                }
                Section("Log") {
                    ForEach(log, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("Spike tests")
        }
    }

    private func record(_ line: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .standard)) \(line)", at: 0)
        print("[Spike] \(line)")
    }

    private func blockInstagram() {
        let app = Application(bundleIdentifier: "com.burbn.instagram")
        var current = store.application.blockedApplications ?? []
        current.insert(app)
        store.application.blockedApplications = current
        record("blockedApplications = \(current.count) entries (added IG)")
    }

    private func blockRoblox() {
        let app = Application(bundleIdentifier: "com.roblox.robloxmobile")
        var current = store.application.blockedApplications ?? []
        current.insert(app)
        store.application.blockedApplications = current
        record("blockedApplications = \(current.count) entries (added Roblox)")
    }

    private func clearBlocks() {
        store.application.blockedApplications = nil
        record("blockedApplications = nil")
    }

    private func setDenyRemoval(_ flag: Bool) {
        store.application.denyAppRemoval = flag
        record("denyAppRemoval = \(flag)")
    }
}
```

- [ ] **Step 2: Wire SpikeView from Settings (under a "Debug" section)**

In `HomeSettingsSheet.swift`, locate the Form and append:

```swift
#if DEBUG
Section("Debug") {
    NavigationLink("Spike tests") { SpikeView() }
}
#endif
```

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Debug/SpikeView.swift" "Evlin iOS/Evlin iOS/Views/Home/HomeSettingsSheet.swift"
git commit -m "feat(debug): SpikeView for Phase 0 validation"
```

### Task 0.2: Spike — validate bundle-id block

- [ ] **Step 1: Run app, tap "Block Instagram", verify behavior**

Expected manual test (on device):
1. Open Instagram from home screen → iOS should show "Instagram is Not Allowed" system dialog.
2. Tap "Clear all blocks" → reopen Instagram → should launch normally.

- [ ] **Step 2: Record finding in spike report**

Create `docs/superpowers/specs/2026-04-22-spike-notes.md` with initial section:

```markdown
# Phase 0 Spike Notes — 2026-04-22

## Test 1: `Application(bundleIdentifier:)` blocks app launch
- Device: [fill in model + iOS version]
- Authorization: `.individual`
- Result: [PASS / FAIL]
- Observations: [what the dialog looked like; whether icon dimmed on home screen]
```

Fill in observations after manual test.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-04-22-spike-notes.md
git commit -m "docs(spike): bundle-id block result"
```

### Task 0.3: Spike — validate `denyAppRemoval`

- [ ] **Step 1: Tap Enable, try to uninstall Evlin from home screen**

Expected: Long-press Evlin icon → "Remove App" or similar option should be unavailable or gated.
(Note: `denyAppRemoval` historically only applies under `.child` auth; record whether it works under `.individual` today.)

- [ ] **Step 2: Append to spike notes**

```markdown
## Test 2: `denyAppRemoval` prevents Evlin uninstall
- Auth: `.individual` (no Child Apple ID in test)
- denyAppRemoval flag accepted by store: [PASS / FAIL on setting]
- Uninstall actually prevented: [PASS / FAIL on attempt]
- Observations: [behavior description]
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-04-22-spike-notes.md
git commit -m "docs(spike): denyAppRemoval result"
```

### Task 0.4: Spike — Max-mode token transferability (defer if no Child Apple ID)

If no real Child Apple ID is available, record this test as **BLOCKED — pending Child Apple ID**.

If available:

- [ ] **Step 1: On parent device with `.child` auth, open FamilyActivityPicker, pick 1-2 apps**
- [ ] **Step 2: Encode selection to Data, base64, print to console**
- [ ] **Step 3: Decode on child device, apply `shield.applications`, open a blocked app**

Record whether the shield actually activates. This is the **crucial question** that determines whether Max mode can relay blobs or must degrade.

- [ ] **Step 4: Append to spike notes and commit**

```markdown
## Test 3: Parent-device picker tokens work on child device
- Blocked: [YES, Child Apple ID not available]
  OR
- Result: [PASS / FAIL]
- If FAIL: Max mode degrades to child-device picker (spec §2 Tier B). Phase 4 adapts accordingly.
```

### Task 0.5: Spike report finalization

- [ ] **Step 1: Write the "Decisions" section at the top of spike notes**

```markdown
## Decisions (inform Phase 1 onward)
- Use `blockedApplications` with `Application(bundleIdentifier:)` for Tier A: [CONFIRMED / NEEDS WORKAROUND]
- Set `denyAppRemoval` at Phase 4 Max onboarding: [CONFIRMED / DEFER]
- Max-mode token relay architecture: [BLOB RELAY / DEGRADE TO CHILD PICKER]
```

- [ ] **Step 2: Commit and proceed to Phase 1**

```bash
git add docs/superpowers/specs/2026-04-22-spike-notes.md
git commit -m "docs(spike): decisions for Phase 1+"
```

---

# Phase 1 — iOS foundation: ActiveLockStore + ActionExecutor

**Purpose:** Build the heart of the lock system in isolation before any networking. Everything is unit-testable with in-memory stubs.

### Task 1.1: Model types

**Files:**
- Create: `Evlin iOS/Evlin iOS/Models/LockTier.swift`
- Create: `Evlin iOS/Evlin iOS/Models/CommandModels.swift`
- Create: `Evlin iOS/Evlin iOS/Models/ActiveLock.swift`
- Create: `Evlin iOS/Evlin iOS/Models/ReceiptState.swift`

- [ ] **Step 1: Create LockTier.swift**

```swift
import Foundation

enum LockTier: String, Codable, Sendable {
    case exactBundle = "exact_bundle"
    case savedList = "saved_list"
    case category = "category"
}
```

- [ ] **Step 2: Create CommandModels.swift**

```swift
import Foundation

enum CommandAction: String, Codable, Sendable {
    case lock
    case unlock
    case unlockAll = "unlock_all"
    case expandLibrary = "expand_library"
}

struct CommandTarget: Codable, Sendable {
    var bundleID: String?
    var listName: String?
    var hasPendingBlob: Bool = false
    var categoryHint: String?
    var originalRequest: String
    var targetDisplay: String?
}

struct LockCommand: Codable, Sendable, Identifiable {
    let id: UUID                   // command_id
    let action: CommandAction
    let tier: LockTier?            // nil for unlock_all etc.
    let target: CommandTarget
    let durationMinutes: Int?      // nil = permanent
    let issuedAt: Date
    var expiresAt: Date? {
        guard let m = durationMinutes else { return nil }
        return issuedAt.addingTimeInterval(TimeInterval(m * 60))
    }
}

enum AckResult: Codable, Sendable, Equatable {
    case confirmedExact(displayName: String)
    case confirmedFallback(displayName: String, category: String, origRequest: String)
    case failed(AckFailure)
}

enum AckFailure: Codable, Sendable, Equatable {
    case notAuthorized
    case listNotFound(String)
    case categoryNotConfigured(String)
    case nothingToUnlock
    case malformed
    case execution(String)
}
```

- [ ] **Step 3: Create ActiveLock.swift**

```swift
import Foundation
import FamilyControls
import ManagedSettings

struct ActiveLock: Codable, Sendable, Identifiable {
    let id: UUID                   // same as commandID
    let tier: LockTier
    let blockedBundleIDs: Set<String>
    let shieldAppTokens: Set<ApplicationToken>
    let shieldCategoryTokens: Set<ActivityCategoryToken>
    let issuedAt: Date
    let expiresAt: Date?
    let originalRequest: String
    let displayName: String
}
```

- [ ] **Step 4: Create ReceiptState.swift**

```swift
import Foundation

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
```

- [ ] **Step 5: Build the app**

Run: `xcodebuild -scheme "Evlin iOS" -destination 'generic/platform=iOS' build` from the project root, or Cmd+B in Xcode.
Expected: SUCCESS (no compile errors).

- [ ] **Step 6: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Models/"
git commit -m "feat(models): LockTier, CommandModels, ActiveLock, ReceiptState"
```

### Task 1.2: LocalAliasStore

**Files:**
- Create: `Evlin iOS/Evlin iOS/Services/LocalAliasStore.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import FamilyControls
import ManagedSettings

/// Local-device persistence for category tokens and saved-list selections.
/// Backed by App Group UserDefaults — shared with DeviceActivityMonitor extension.
final class LocalAliasStore: @unchecked Sendable {
    static let shared = LocalAliasStore()

    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let categoryKey = "evlin.categoryTokens"
    private let listKey = "evlin.savedListTokens"

    // MARK: - Categories

    func saveCategoryToken(_ token: ActivityCategoryToken, forName name: String) {
        var dict = loadCategoryDict()
        if let data = try? PropertyListEncoder().encode(token) {
            dict[name.lowercased()] = data
            persistCategoryDict(dict)
        }
    }

    func categoryToken(forName name: String) -> ActivityCategoryToken? {
        let dict = loadCategoryDict()
        guard let data = dict[name.lowercased()] else { return nil }
        return try? PropertyListDecoder().decode(ActivityCategoryToken.self, from: data)
    }

    // MARK: - Saved Lists

    func saveList(_ selection: FamilyActivitySelection, named name: String) {
        var dict = loadListDict()
        if let data = try? PropertyListEncoder().encode(selection) {
            dict[name.lowercased()] = data
            persistListDict(dict)
        }
    }

    func savedList(named name: String) -> FamilyActivitySelection? {
        let dict = loadListDict()
        guard let data = dict[name.lowercased()] else { return nil }
        return try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    func allListNames() -> [String] {
        Array(loadListDict().keys)
    }

    // MARK: - Private

    private func loadCategoryDict() -> [String: Data] {
        (defaults?.dictionary(forKey: categoryKey) as? [String: Data]) ?? [:]
    }

    private func persistCategoryDict(_ dict: [String: Data]) {
        defaults?.set(dict, forKey: categoryKey)
    }

    private func loadListDict() -> [String: Data] {
        (defaults?.dictionary(forKey: listKey) as? [String: Data]) ?? [:]
    }

    private func persistListDict(_ dict: [String: Data]) {
        defaults?.set(dict, forKey: listKey)
    }
}
```

- [ ] **Step 2: Build and commit**

```bash
git add "Evlin iOS/Evlin iOS/Services/LocalAliasStore.swift"
git commit -m "feat(ios): LocalAliasStore for category tokens and saved lists"
```

### Task 1.3: ActiveLockStore (core union/recompute logic)

**Files:**
- Create: `Evlin iOS/Evlin iOS/Services/ActiveLockStore.swift`

- [ ] **Step 1: Create ActiveLockStore.swift**

```swift
import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

/// Single source of truth for active locks on this device. Every add/remove/sweep
/// triggers a full recompute of the union and writes to ManagedSettingsStore.
actor ActiveLockStore {
    static let shared = ActiveLockStore()

    private var locks: [UUID: ActiveLock] = [:]
    private let store = ManagedSettingsStore()
    private let storageKey = "evlin.activeLocks"
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")

    init() {
        restore()
    }

    // MARK: - Public API

    func add(_ lock: ActiveLock) {
        locks[lock.id] = lock
        persist()
        recomputeAndApply()
    }

    func remove(commandID: UUID) {
        locks.removeValue(forKey: commandID)
        persist()
        recomputeAndApply()
    }

    func removeAll() {
        locks.removeAll()
        persist()
        recomputeAndApply()
    }

    /// Returns IDs of locks removed due to expiry.
    @discardableResult
    func sweepExpired(now: Date = Date()) -> [UUID] {
        let expired = locks.values
            .filter { ($0.expiresAt ?? .distantFuture) <= now }
            .map(\.id)
        guard !expired.isEmpty else { return [] }
        for id in expired { locks.removeValue(forKey: id) }
        persist()
        recomputeAndApply()
        return expired
    }

    /// Removes locks whose displayName or bundle IDs match the target.
    @discardableResult
    func removeMatching(_ target: CommandTarget) -> [UUID] {
        let matched = locks.values.filter { lock in
            if let bid = target.bundleID, lock.blockedBundleIDs.contains(bid) { return true }
            if let display = target.targetDisplay,
               lock.displayName.caseInsensitiveCompare(display) == .orderedSame { return true }
            if let list = target.listName,
               lock.displayName.caseInsensitiveCompare(list) == .orderedSame { return true }
            return false
        }.map(\.id)
        for id in matched { locks.removeValue(forKey: id) }
        if !matched.isEmpty {
            persist()
            recomputeAndApply()
        }
        return matched
    }

    func current() -> [ActiveLock] { Array(locks.values) }

    // MARK: - Core

    private func recomputeAndApply() {
        if locks.isEmpty {
            store.application.blockedApplications = nil
            store.shield.applications = nil
            store.shield.applicationCategories = nil
            return
        }

        let allBundleIDs = Set(locks.values.flatMap(\.blockedBundleIDs))
        let bundleApps = Set(allBundleIDs.map { Application(bundleIdentifier: $0) })
        store.application.blockedApplications = bundleApps.isEmpty ? nil : bundleApps

        let allAppTokens = Set(locks.values.flatMap(\.shieldAppTokens))
        store.shield.applications = allAppTokens.isEmpty ? nil : allAppTokens

        let allCategoryTokens = Set(locks.values.flatMap(\.shieldCategoryTokens))
        store.shield.applicationCategories = allCategoryTokens.isEmpty
            ? nil
            : .specific(allCategoryTokens)
    }

    private func persist() {
        guard let data = try? PropertyListEncoder().encode(locks) else { return }
        defaults?.set(data, forKey: storageKey)
    }

    private func restore() {
        guard let data = defaults?.data(forKey: storageKey),
              let decoded = try? PropertyListDecoder().decode([UUID: ActiveLock].self, from: data)
        else { return }
        locks = decoded
    }
}
```

- [ ] **Step 2: Build**

Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Services/ActiveLockStore.swift"
git commit -m "feat(ios): ActiveLockStore actor with union/recompute semantics"
```

### Task 1.4: Unit tests for ActiveLockStore

**Files:**
- Create: `Evlin iOS/Evlin iOSTests/ActiveLockStoreTests.swift`

- [ ] **Step 1: Create the test file**

Note: FamilyControls tokens can't be constructed directly in tests — we assert on bundleID-only locks (Tier A) and skip tests that need real tokens. Token-based tests are integration (device).

```swift
import XCTest
@testable import Evlin_iOS

final class ActiveLockStoreTests: XCTestCase {
    func test_add_then_remove_clearsStore() async {
        let store = ActiveLockStore()
        let lock = Self.makeBundleLock(id: UUID(), bundles: ["com.x.y"])
        await store.add(lock)
        var cur = await store.current()
        XCTAssertEqual(cur.count, 1)

        await store.remove(commandID: lock.id)
        cur = await store.current()
        XCTAssertEqual(cur.count, 0)
    }

    func test_sweepExpired_removesOnlyExpired() async {
        let store = ActiveLockStore()
        let live = Self.makeBundleLock(id: UUID(), bundles: ["a"], expiresAt: .distantFuture)
        let dead = Self.makeBundleLock(id: UUID(), bundles: ["b"], expiresAt: Date().addingTimeInterval(-1))
        await store.add(live)
        await store.add(dead)

        let removed = await store.sweepExpired()
        XCTAssertEqual(removed, [dead.id])
        let remaining = await store.current().map(\.id)
        XCTAssertEqual(remaining, [live.id])
    }

    func test_addPermanent_hasNoExpiry() async {
        let store = ActiveLockStore()
        let permanent = Self.makeBundleLock(id: UUID(), bundles: ["x"], expiresAt: nil)
        await store.add(permanent)
        let removed = await store.sweepExpired()
        XCTAssertTrue(removed.isEmpty)
    }

    func test_removeMatching_byBundleID() async {
        let store = ActiveLockStore()
        let igLock = Self.makeBundleLock(id: UUID(), bundles: ["com.burbn.instagram"])
        let ttLock = Self.makeBundleLock(id: UUID(), bundles: ["com.zhiliaoapp.musically"])
        await store.add(igLock)
        await store.add(ttLock)

        var target = CommandTarget(originalRequest: "IG")
        target.bundleID = "com.burbn.instagram"
        let removed = await store.removeMatching(target)
        XCTAssertEqual(removed, [igLock.id])
        let remaining = await store.current().map(\.id)
        XCTAssertEqual(remaining, [ttLock.id])
    }

    // MARK: helpers
    private static func makeBundleLock(id: UUID, bundles: [String], expiresAt: Date? = .distantFuture) -> ActiveLock {
        ActiveLock(
            id: id,
            tier: .exactBundle,
            blockedBundleIDs: Set(bundles),
            shieldAppTokens: [],
            shieldCategoryTokens: [],
            issuedAt: Date(),
            expiresAt: expiresAt,
            originalRequest: bundles.first ?? "",
            displayName: bundles.first ?? ""
        )
    }
}
```

- [ ] **Step 2: Run the tests**

In Xcode, Cmd+U. Expected: all pass. If no test target exists yet, create one named `Evlin iOSTests`.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Evlin iOSTests/ActiveLockStoreTests.swift"
git commit -m "test(ios): ActiveLockStore add/remove/sweep/match"
```

### Task 1.5: ActionExecutor

**Files:**
- Create: `Evlin iOS/Evlin iOS/Services/ActionExecutor.swift`

- [ ] **Step 1: Write ActionExecutor**

```swift
import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

final class ActionExecutor: @unchecked Sendable {
    static let shared = ActionExecutor()

    private let activityCenter = DeviceActivityCenter()

    func execute(_ cmd: LockCommand, blob: Data? = nil) async -> AckResult {
        guard ScreenTimeManager.shared.isAuthorized else {
            return .failed(.notAuthorized)
        }

        switch cmd.action {
        case .unlockAll:
            await ActiveLockStore.shared.removeAll()
            cancelAllScheduled()
            return .confirmedExact(displayName: "All locks cleared")

        case .unlock:
            let removed = await ActiveLockStore.shared.removeMatching(cmd.target)
            removed.forEach(cancelScheduled)
            if removed.isEmpty { return .failed(.nothingToUnlock) }
            return .confirmedExact(displayName: cmd.target.targetDisplay ?? cmd.target.originalRequest)

        case .expandLibrary:
            // Handled by UI flow (picker). Return failed for now; Phase 3 wires the UI.
            return .failed(.execution("expand_library handled in UI"))

        case .lock:
            break
        }

        do {
            let lock = try buildLock(from: cmd, blob: blob)
            await ActiveLockStore.shared.add(lock)
            if cmd.durationMinutes != nil {
                try scheduleRelock(commandID: lock.id, expiresAt: lock.expiresAt!)
            }
            switch cmd.tier {
            case .category:
                return .confirmedFallback(
                    displayName: lock.displayName,
                    category: cmd.target.categoryHint ?? "unknown",
                    origRequest: cmd.target.originalRequest
                )
            default:
                return .confirmedExact(displayName: lock.displayName)
            }
        } catch let err as ExecuteError {
            return .failed(err.ackFailure)
        } catch {
            return .failed(.execution(error.localizedDescription))
        }
    }

    private func buildLock(from cmd: LockCommand, blob: Data?) throws -> ActiveLock {
        guard let tier = cmd.tier else { throw ExecuteError.malformed }
        switch tier {
        case .exactBundle:
            guard let bid = cmd.target.bundleID else { throw ExecuteError.malformed }
            return ActiveLock(
                id: cmd.id, tier: .exactBundle,
                blockedBundleIDs: [bid],
                shieldAppTokens: [], shieldCategoryTokens: [],
                issuedAt: cmd.issuedAt, expiresAt: cmd.expiresAt,
                originalRequest: cmd.target.originalRequest,
                displayName: cmd.target.targetDisplay ?? bid
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
            return ActiveLock(
                id: cmd.id, tier: .savedList,
                blockedBundleIDs: [],
                shieldAppTokens: sel.applicationTokens,
                shieldCategoryTokens: sel.categoryTokens,
                issuedAt: cmd.issuedAt, expiresAt: cmd.expiresAt,
                originalRequest: cmd.target.originalRequest,
                displayName: cmd.target.listName ?? "saved list"
            )
        case .category:
            guard let hint = cmd.target.categoryHint,
                  let tok = LocalAliasStore.shared.categoryToken(forName: hint)
            else { throw ExecuteError.categoryNotConfigured(cmd.target.categoryHint ?? "unknown") }
            return ActiveLock(
                id: cmd.id, tier: .category,
                blockedBundleIDs: [],
                shieldAppTokens: [],
                shieldCategoryTokens: [tok],
                issuedAt: cmd.issuedAt, expiresAt: cmd.expiresAt,
                originalRequest: cmd.target.originalRequest,
                displayName: hint.capitalized
            )
        }
    }

    // MARK: - DeviceActivity scheduling

    private func scheduleRelock(commandID: UUID, expiresAt: Date) throws {
        let calendar = Calendar.current
        let now = Date()
        let startComp = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComp = calendar.dateComponents([.hour, .minute, .second], from: expiresAt)
        let schedule = DeviceActivitySchedule(intervalStart: startComp, intervalEnd: endComp, repeats: false)
        let name = DeviceActivityName("evlin.lock.\(commandID.uuidString)")
        try activityCenter.startMonitoring(name, during: schedule)
    }

    private func cancelScheduled(_ commandID: UUID) {
        let name = DeviceActivityName("evlin.lock.\(commandID.uuidString)")
        activityCenter.stopMonitoring([name])
    }

    private func cancelAllScheduled() {
        activityCenter.stopMonitoring()
    }
}

enum ExecuteError: Error {
    case malformed
    case listNotFound(String)
    case categoryNotConfigured(String)

    var ackFailure: AckFailure {
        switch self {
        case .malformed: return .malformed
        case .listNotFound(let n): return .listNotFound(n)
        case .categoryNotConfigured(let n): return .categoryNotConfigured(n)
        }
    }
}
```

- [ ] **Step 2: Build**

Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Services/ActionExecutor.swift"
git commit -m "feat(ios): ActionExecutor with three tiers + DeviceActivity scheduling"
```

### Task 1.6: Integrate DeviceActivityMonitor extension with ActiveLockStore

**Files:**
- Modify: `Evlin iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`

- [ ] **Step 1: Replace contents with ActiveLockStore integration**

Read existing file first; the replacement looks like:

```swift
import Foundation
import DeviceActivity
import ManagedSettings

class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let storageKey = "evlin.activeLocks"
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let store = ManagedSettingsStore()

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        // Name format: "evlin.lock.<uuid>"
        let rawName = activity.rawValue
        guard rawName.hasPrefix("evlin.lock."),
              let idStr = rawName.split(separator: ".").last,
              let cmdID = UUID(uuidString: String(idStr))
        else { return }

        removeLockAndRecompute(commandID: cmdID)
    }

    private func removeLockAndRecompute(commandID: UUID) {
        guard let data = defaults?.data(forKey: storageKey),
              var locks = try? PropertyListDecoder().decode([UUID: ActiveLock].self, from: data)
        else { return }

        locks.removeValue(forKey: commandID)

        if let updated = try? PropertyListEncoder().encode(locks) {
            defaults?.set(updated, forKey: storageKey)
        }

        // Recompute union and apply
        if locks.isEmpty {
            store.application.blockedApplications = nil
            store.shield.applications = nil
            store.shield.applicationCategories = nil
            return
        }

        let allBundleIDs = Set(locks.values.flatMap(\.blockedBundleIDs))
        let bundleApps = Set(allBundleIDs.map { ManagedSettings.Application(bundleIdentifier: $0) })
        store.application.blockedApplications = bundleApps.isEmpty ? nil : bundleApps

        let allAppTokens = Set(locks.values.flatMap(\.shieldAppTokens))
        store.shield.applications = allAppTokens.isEmpty ? nil : allAppTokens

        let allCategoryTokens = Set(locks.values.flatMap(\.shieldCategoryTokens))
        store.shield.applicationCategories = allCategoryTokens.isEmpty
            ? nil : .specific(allCategoryTokens)
    }
}
```

Also ensure `ActiveLock.swift` is included in the extension target membership (Xcode file inspector → Target Membership → EvlinDeviceActivityMonitor).

- [ ] **Step 2: Build extension target**

Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift"
git commit -m "feat(extension): DeviceActivityMonitor removes lock from ActiveLockStore on expiry"
```

### Task 1.7: Manual validation on device

- [ ] **Step 1: Add a temporary "Test lock" button to SpikeView**

```swift
Section("ActionExecutor") {
    Button("Lock IG for 1 min") {
        Task {
            let cmd = LockCommand(
                id: UUID(),
                action: .lock,
                tier: .exactBundle,
                target: CommandTarget(
                    bundleID: "com.burbn.instagram",
                    originalRequest: "IG",
                    targetDisplay: "Instagram"
                ),
                durationMinutes: 1,
                issuedAt: Date()
            )
            let result = await ActionExecutor.shared.execute(cmd)
            await MainActor.run { record("result: \(result)") }
        }
    }
    Button("Unlock all") {
        Task {
            let cmd = LockCommand(id: UUID(), action: .unlockAll, tier: nil,
                                   target: CommandTarget(originalRequest: "all"),
                                   durationMinutes: nil, issuedAt: Date())
            let r = await ActionExecutor.shared.execute(cmd)
            await MainActor.run { record("result: \(r)") }
        }
    }
}
```

- [ ] **Step 2: Run on device, tap "Lock IG for 1 min", try opening Instagram, wait 1 minute**

Expected:
- Instagram launch blocked immediately.
- After ~1 min, DeviceActivity fires `intervalDidEnd`, store is updated, Instagram launches normally.

Record result in `docs/superpowers/specs/2026-04-22-spike-notes.md` under a new "Phase 1 validation" section.

- [ ] **Step 3: Commit spike notes update**

```bash
git add docs/superpowers/specs/2026-04-22-spike-notes.md
git commit -m "docs(spike): Phase 1 ActionExecutor device validation"
```

---

# Phase 2 — Backend minimal (commands + ack)

**Purpose:** Wire the backend to accept Chat messages, resolve to a tier, queue a command, and let child poll + ack. Foreground-poll only; APNs deferred.

### Task 2.1: DB models — Family, Device, PairingCode

**Files:**
- Create: `adaptive-engine/backend/app/db/models/family.py`
- Create: `adaptive-engine/backend/app/db/models/device.py`
- Create: `adaptive-engine/backend/app/db/models/pairing.py`

- [ ] **Step 1: Create family.py**

```python
from __future__ import annotations
import enum
from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import DateTime, Enum as SAEnum
from sqlalchemy.orm import Mapped, mapped_column

from backend.app.db.base import Base


class ProtectionMode(str, enum.Enum):
    max = "max"
    std = "std"


class Family(Base):
    __tablename__ = "family"
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    protection_mode: Mapped[ProtectionMode] = mapped_column(
        SAEnum(ProtectionMode, name="protection_mode"), default=ProtectionMode.std
    )
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
```

- [ ] **Step 2: Create device.py**

```python
from __future__ import annotations
import enum
from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import DateTime, Enum as SAEnum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from backend.app.db.base import Base


class DeviceMode(str, enum.Enum):
    parent = "parent"
    child = "child"


class Device(Base):
    __tablename__ = "device"
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    family_id: Mapped[UUID] = mapped_column(ForeignKey("family.id"), index=True)
    mode: Mapped[DeviceMode] = mapped_column(SAEnum(DeviceMode, name="device_mode"))
    label: Mapped[str] = mapped_column(String(120))
    apns_token: Mapped[str | None] = mapped_column(String(200), nullable=True)
    last_heartbeat: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
```

- [ ] **Step 3: Create pairing.py**

```python
from __future__ import annotations
from datetime import datetime, timedelta
from uuid import UUID

from sqlalchemy import Boolean, DateTime, Enum as SAEnum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from backend.app.db.base import Base
from backend.app.db.models.family import ProtectionMode


class PairingCode(Base):
    __tablename__ = "pairing_code"
    code: Mapped[str] = mapped_column(String(6), primary_key=True)
    family_id: Mapped[UUID] = mapped_column(ForeignKey("family.id"))
    protection_mode: Mapped[ProtectionMode] = mapped_column(
        SAEnum(ProtectionMode, name="protection_mode_pair")
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow() + timedelta(minutes=10)
    )
    used: Mapped[bool] = mapped_column(Boolean, default=False)
```

- [ ] **Step 4: Commit**

```bash
git add adaptive-engine/backend/app/db/models/family.py \
        adaptive-engine/backend/app/db/models/device.py \
        adaptive-engine/backend/app/db/models/pairing.py
git commit -m "feat(db): Family, Device, PairingCode models"
```

### Task 2.2: DB models — SavedListMeta, Command, PendingBlob

**Files:**
- Create: `adaptive-engine/backend/app/db/models/saved_list.py`
- Create: `adaptive-engine/backend/app/db/models/command.py`

- [ ] **Step 1: saved_list.py**

```python
from __future__ import annotations
import enum
from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import DateTime, Enum as SAEnum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from backend.app.db.base import Base


class SavedListMode(str, enum.Enum):
    parent_device = "parent_device"
    child_device = "child_device"


class SavedListMeta(Base):
    __tablename__ = "saved_list_meta"
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    family_id: Mapped[UUID] = mapped_column(ForeignKey("family.id"), index=True)
    name: Mapped[str] = mapped_column(String(120))
    description: Mapped[str | None] = mapped_column(String(500), nullable=True)
    mode: Mapped[SavedListMode] = mapped_column(SAEnum(SavedListMode, name="saved_list_mode"))
    owning_device_id: Mapped[UUID] = mapped_column(ForeignKey("device.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=datetime.utcnow, onupdate=datetime.utcnow
    )
```

- [ ] **Step 2: command.py**

```python
from __future__ import annotations
import enum
from datetime import datetime, timedelta
from uuid import UUID, uuid4

from sqlalchemy import DateTime, Enum as SAEnum, ForeignKey, LargeBinary, JSON
from sqlalchemy.orm import Mapped, mapped_column

from backend.app.db.base import Base


class AckStatus(str, enum.Enum):
    pending = "pending"
    confirmed_exact = "confirmed_exact"
    confirmed_fallback = "confirmed_fallback"
    failed = "failed"
    timeout = "timeout"


class Command(Base):
    __tablename__ = "command"
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    family_id: Mapped[UUID] = mapped_column(ForeignKey("family.id"), index=True)
    target_device_id: Mapped[UUID] = mapped_column(ForeignKey("device.id"), index=True)
    payload: Mapped[dict] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, index=True)
    picked_up_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    acked_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    ack_status: Mapped[AckStatus] = mapped_column(
        SAEnum(AckStatus, name="ack_status"), default=AckStatus.pending
    )
    ack_detail: Mapped[dict | None] = mapped_column(JSON, nullable=True)


class PendingBlob(Base):
    __tablename__ = "pending_blob"
    command_id: Mapped[UUID] = mapped_column(ForeignKey("command.id"), primary_key=True)
    blob: Mapped[bytes] = mapped_column(LargeBinary)
    expires_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.utcnow() + timedelta(minutes=10)
    )
```

- [ ] **Step 3: Commit**

```bash
git add adaptive-engine/backend/app/db/models/saved_list.py adaptive-engine/backend/app/db/models/command.py
git commit -m "feat(db): SavedListMeta, Command, PendingBlob models"
```

### Task 2.3: Create DB tables (dev mode — no alembic for now)

**Files:**
- Modify: `adaptive-engine/backend/app/db/base.py` (add create-all helper)
- Modify: `adaptive-engine/backend/app/main.py` (call on startup, dev only)

- [ ] **Step 1: Update base.py**

```python
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    pass


def create_all(engine) -> None:
    """Dev helper: import all models and create tables. Replace with alembic in prod."""
    # Import side-effect registers mappers
    from backend.app.db.models import family, device, pairing, saved_list, command  # noqa: F401
    Base.metadata.create_all(engine)
```

- [ ] **Step 2: In main.py, call it on startup**

Locate the FastAPI app creation and add:

```python
from backend.app.db.engine import engine  # existing
from backend.app.db.base import create_all


@app.on_event("startup")
def _create_tables() -> None:
    create_all(engine)
```

- [ ] **Step 3: Run backend once to create tables**

Run: `cd adaptive-engine/backend && uvicorn app.main:app --reload`
Expected: startup succeeds, tables are created (check with `psql` or Postgres GUI).

- [ ] **Step 4: Commit**

```bash
git add adaptive-engine/backend/app/db/base.py adaptive-engine/backend/app/main.py
git commit -m "feat(db): dev auto-create tables on startup"
```

### Task 2.4: App catalog JSON seed

**Files:**
- Create: `adaptive-engine/backend/app/data/app_catalog.json`

- [ ] **Step 1: Create file with v1 catalog**

Copy the full JSON from spec §9 (60 entries, starting with Instagram). The exact content is listed in the spec file.

- [ ] **Step 2: Commit**

```bash
git add adaptive-engine/backend/app/data/app_catalog.json
git commit -m "feat(data): v1 app catalog with 60 entries"
```

### Task 2.5: App catalog loader + lookup

**Files:**
- Create: `adaptive-engine/backend/app/services/app_catalog.py`

- [ ] **Step 1: Write loader**

```python
from __future__ import annotations
import json
from functools import lru_cache
from pathlib import Path
from typing import NamedTuple


class CatalogEntry(NamedTuple):
    names: list[str]
    bundle_id: str
    category_hint: str


@lru_cache(maxsize=1)
def load_catalog() -> list[CatalogEntry]:
    path = Path(__file__).parent.parent / "data" / "app_catalog.json"
    data = json.loads(path.read_text())
    return [CatalogEntry(e["names"], e["bundle_id"], e["category_hint"]) for e in data]


def lookup(query: str) -> CatalogEntry | None:
    """Case-insensitive alias match against the catalog."""
    q = query.strip().lower()
    for entry in load_catalog():
        for alias in entry.names:
            if alias.lower() == q:
                return entry
    return None
```

- [ ] **Step 2: Add basic test**

Create `adaptive-engine/backend/tests/services/test_app_catalog.py`:

```python
from backend.app.services.app_catalog import lookup


def test_lookup_instagram_by_alias():
    assert lookup("IG").bundle_id == "com.burbn.instagram"
    assert lookup("Instagram").bundle_id == "com.burbn.instagram"
    assert lookup("insta").bundle_id == "com.burbn.instagram"


def test_lookup_case_insensitive():
    assert lookup("tiktok") is not None
    assert lookup("TIKTOK") is not None


def test_lookup_miss():
    assert lookup("totallyunknownapp") is None
```

- [ ] **Step 3: Run tests**

Run: `cd adaptive-engine && pytest backend/tests/services/test_app_catalog.py -v`
Expected: 3 passed.

- [ ] **Step 4: Commit**

```bash
git add adaptive-engine/backend/app/services/app_catalog.py adaptive-engine/backend/tests/services/test_app_catalog.py
git commit -m "feat(backend): app catalog loader + tests"
```

### Task 2.6: Chat resolver

**Files:**
- Create: `adaptive-engine/backend/app/services/chat_resolver.py`
- Create: `adaptive-engine/backend/tests/services/test_chat_resolver.py`

- [ ] **Step 1: Write tests first**

```python
# tests/services/test_chat_resolver.py
import pytest
from uuid import uuid4

from backend.app.services.chat_resolver import resolve


@pytest.fixture
def family_id():
    return uuid4()


def test_catalog_hit_IG(family_id):
    result = resolve(
        family_id=family_id,
        target_request="IG",
        target_kind_hint=None,
        saved_list_names=[],
    )
    assert result.tier == "exact_bundle"
    assert result.bundle_id == "com.burbn.instagram"
    assert result.target_display == "Instagram"


def test_saved_list_fuzzy_match(family_id):
    result = resolve(
        family_id=family_id,
        target_request="list 1",
        target_kind_hint=None,
        saved_list_names=["list 1", "bedtime apps"],
    )
    assert result.tier == "saved_list"
    assert result.list_name == "list 1"


def test_category_direct(family_id):
    result = resolve(
        family_id=family_id,
        target_request="games",
        target_kind_hint="category",
        saved_list_names=[],
    )
    assert result.tier == "category"
    assert result.category_hint == "games"


def test_category_inferred_from_unknown(family_id):
    # AI may classify "abcd" as a game (we simulate via target_kind_hint="category")
    result = resolve(
        family_id=family_id,
        target_request="abcd",
        target_kind_hint="category",
        saved_list_names=[],
        category_hint_from_ai="games",
    )
    assert result.tier == "category"
    assert result.category_hint == "games"


def test_total_miss_requires_confirmation(family_id):
    result = resolve(
        family_id=family_id,
        target_request="totallyunknown",
        target_kind_hint=None,
        saved_list_names=[],
    )
    assert result.confirmation_required is True
```

- [ ] **Step 2: Run (should fail)**

Run: `pytest backend/tests/services/test_chat_resolver.py -v`
Expected: ImportError on `chat_resolver`.

- [ ] **Step 3: Write chat_resolver.py**

```python
from __future__ import annotations
from dataclasses import dataclass, field
from uuid import UUID

from backend.app.services.app_catalog import lookup as catalog_lookup


@dataclass
class ResolverResult:
    tier: str | None = None                      # "exact_bundle" | "saved_list" | "category" | None
    bundle_id: str | None = None
    list_name: str | None = None
    category_hint: str | None = None
    target_display: str | None = None
    confirmation_required: bool = False
    suggestions: list[str] = field(default_factory=list)


def _levenshtein(a: str, b: str) -> int:
    if a == b: return 0
    if not a: return len(b)
    if not b: return len(a)
    dp = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        row = [i]
        for j, cb in enumerate(b, 1):
            row.append(min(dp[j] + 1, row[-1] + 1, dp[j - 1] + (ca != cb)))
        dp = row
    return dp[-1]


def resolve(
    *,
    family_id: UUID,
    target_request: str,
    target_kind_hint: str | None,
    saved_list_names: list[str],
    category_hint_from_ai: str | None = None,
) -> ResolverResult:
    """Resolve a parsed parent command to a concrete tier."""
    q = target_request.strip().lower()

    # 1. Saved list fuzzy match (distance ≤ 2, case-insensitive)
    for name in saved_list_names:
        if _levenshtein(q, name.lower()) <= 2:
            return ResolverResult(tier="saved_list", list_name=name)

    # 2. Catalog
    entry = catalog_lookup(target_request)
    if entry is not None:
        return ResolverResult(
            tier="exact_bundle",
            bundle_id=entry.bundle_id,
            target_display=entry.names[0],
            category_hint=entry.category_hint,
        )

    # 3. Category direct
    if target_kind_hint == "category":
        hint = category_hint_from_ai or target_request
        return ResolverResult(tier="category", category_hint=hint.lower())

    # 4. AI-inferred category (if provided)
    if category_hint_from_ai:
        return ResolverResult(tier="category", category_hint=category_hint_from_ai.lower())

    # 5. Miss
    return ResolverResult(
        confirmation_required=True,
        suggestions=saved_list_names[:3] if saved_list_names else ["games", "social"],
    )
```

- [ ] **Step 4: Run tests, fix, commit**

```bash
pytest backend/tests/services/test_chat_resolver.py -v
# Expected: all pass
git add adaptive-engine/backend/app/services/chat_resolver.py adaptive-engine/backend/tests/services/test_chat_resolver.py
git commit -m "feat(backend): chat resolver + tests"
```

### Task 2.7: /family/create and /family/pair endpoints

**Files:**
- Create: `adaptive-engine/backend/app/api/routes/family.py`
- Modify: `adaptive-engine/backend/app/main.py` (include router)

- [ ] **Step 1: Write family.py**

```python
from __future__ import annotations
import random
from datetime import datetime, timedelta
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from backend.app.db.engine import get_session
from backend.app.db.models.family import Family, ProtectionMode
from backend.app.db.models.device import Device, DeviceMode
from backend.app.db.models.pairing import PairingCode

router = APIRouter(prefix="/family", tags=["Family"])


class CreateFamilyRequest(BaseModel):
    child_name: str
    child_age: int | None = None
    protection_mode: ProtectionMode
    parent_device_label: str = "Parent's iPhone"


class CreateFamilyResponse(BaseModel):
    family_id: UUID
    parent_device_id: UUID
    pairing_code: str
    code_expires_at: datetime


def _generate_code() -> str:
    return "".join(str(random.randint(0, 9)) for _ in range(6))


@router.post("/create", response_model=CreateFamilyResponse)
def create_family(req: CreateFamilyRequest, session: Session = Depends(get_session)) -> CreateFamilyResponse:
    family = Family(protection_mode=req.protection_mode)
    session.add(family)
    session.flush()

    parent_device = Device(
        family_id=family.id, mode=DeviceMode.parent, label=req.parent_device_label
    )
    session.add(parent_device)
    session.flush()

    code = _generate_code()
    while session.get(PairingCode, code):  # extremely rare collision
        code = _generate_code()

    pairing = PairingCode(code=code, family_id=family.id, protection_mode=req.protection_mode)
    session.add(pairing)
    session.commit()

    return CreateFamilyResponse(
        family_id=family.id,
        parent_device_id=parent_device.id,
        pairing_code=code,
        code_expires_at=pairing.expires_at,
    )


class PairRequest(BaseModel):
    code: str
    device_label: str = "Child's iPhone"


class PairResponse(BaseModel):
    family_id: UUID
    child_device_id: UUID
    parent_device_id: UUID
    protection_mode: ProtectionMode


@router.post("/pair", response_model=PairResponse)
def pair(req: PairRequest, session: Session = Depends(get_session)) -> PairResponse:
    pairing = session.get(PairingCode, req.code)
    if not pairing:
        raise HTTPException(404, "pairing code not found")
    if pairing.used:
        raise HTTPException(400, "pairing code already used")
    if pairing.expires_at < datetime.utcnow():
        raise HTTPException(400, "pairing code expired")

    child_device = Device(family_id=pairing.family_id, mode=DeviceMode.child, label=req.device_label)
    session.add(child_device)
    pairing.used = True

    parent_device = (
        session.query(Device)
        .filter_by(family_id=pairing.family_id, mode=DeviceMode.parent)
        .one()
    )
    session.commit()

    return PairResponse(
        family_id=pairing.family_id,
        child_device_id=child_device.id,
        parent_device_id=parent_device.id,
        protection_mode=pairing.protection_mode,
    )


class PairingStatusResponse(BaseModel):
    code: str
    used: bool
    child_device_id: UUID | None


@router.get("/pairing-status", response_model=PairingStatusResponse)
def pairing_status(code: str, session: Session = Depends(get_session)) -> PairingStatusResponse:
    pairing = session.get(PairingCode, code)
    if not pairing:
        raise HTTPException(404)
    child = (
        session.query(Device)
        .filter_by(family_id=pairing.family_id, mode=DeviceMode.child)
        .first()
        if pairing.used else None
    )
    return PairingStatusResponse(
        code=code, used=pairing.used, child_device_id=child.id if child else None
    )
```

- [ ] **Step 2: Include router in main.py**

Find the `app.include_router(...)` calls and add:

```python
from backend.app.api.routes.family import router as family_router
app.include_router(family_router, prefix="/api/v1")
```

- [ ] **Step 3: Smoke test**

```bash
# Start backend, then in another terminal:
curl -X POST http://localhost:8000/api/v1/family/create \
  -H "Content-Type: application/json" \
  -d '{"child_name":"Liam","protection_mode":"std"}'
# Expect 200 with pairing_code

# Pair:
curl -X POST http://localhost:8000/api/v1/family/pair \
  -H "Content-Type: application/json" \
  -d '{"code":"<paste code>"}'
# Expect 200 with protection_mode=std
```

- [ ] **Step 4: Commit**

```bash
git add adaptive-engine/backend/app/api/routes/family.py adaptive-engine/backend/app/main.py
git commit -m "feat(api): /family/create, /family/pair, /family/pairing-status"
```

### Task 2.8: /parent/chat with resolver + Command creation

**Files:**
- Modify: `adaptive-engine/backend/app/api/routes/parent_chat.py`

- [ ] **Step 1: Update system prompt to emit new action shape**

Replace `SYSTEM_PROMPT` with:

```python
SYSTEM_PROMPT = """You are Evlin, an AI-powered parental control assistant. Your persona is "The Informed Sentinel" — authoritative, calm, data-driven.

When the parent issues a lock/unlock command, emit a structured action. The backend will resolve it to the correct lock tier.

Response format (ALWAYS valid JSON):
{
  "message": "Natural response to the parent (e.g., 'Locking Instagram on Liam's phone for 30 minutes.')",
  "reasoning": "Brief internal analysis",
  "action": null | {
    "type": "lock" | "unlock" | "unlock_all",
    "target_request": "<the exact words the parent used, e.g. 'IG' or 'list 1'>",
    "target_kind_hint": "app" | "list" | "category" | null,
    "duration_minutes": 30 | null,
    "category_hint_from_ai": "games" | "social" | "entertainment" | "productivity" | "education" | null,
    "confirmation_required": false
  }
}

Rules:
- If the request is a clean lock/unlock command, emit `action` with correct fields.
- If ambiguous or missing info, set confirmation_required=true.
- target_kind_hint: "list" if parent says "list 1"/"bedtime apps", "category" if "all games", "app" if specific app name, null otherwise.
- category_hint_from_ai: your best guess of which category the target belongs to (games/social/entertainment/productivity/education). Used as fallback when the app isn't in the catalog.
- duration_minutes: integer minutes, or null for permanent/until-unlock.
- ALWAYS return valid JSON. No code fences."""
```

- [ ] **Step 2: Rewrite `parent_chat` handler to resolve + queue command**

```python
from __future__ import annotations
import json
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from loguru import logger
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from backend.app.core.settings import settings
from backend.app.db.engine import get_session
from backend.app.db.models.command import Command, AckStatus
from backend.app.db.models.device import Device, DeviceMode
from backend.app.db.models.saved_list import SavedListMeta
from backend.app.services.chat_resolver import resolve

router = APIRouter(prefix="/parent", tags=["Parent Chat"])


class ChatRequest(BaseModel):
    message: str
    family_id: UUID | None = None  # optional for legacy calls (single-family dev)
    child_name: str = "Liam"
    history: list[dict[str, str]] = Field(default_factory=list)


class ChatActionClient(BaseModel):
    type: str
    command_id: UUID | None = None
    tier: str | None = None
    target_display: str | None = None
    duration_minutes: int | None = None
    confirmation_required: bool = False


class ChatResponse(BaseModel):
    message: str
    reasoning: str | None = None
    action: ChatActionClient | None = None


@router.post("/chat", response_model=ChatResponse)
def parent_chat(req: ChatRequest, session: Session = Depends(get_session)) -> ChatResponse:
    if not settings.gemini_api_key:
        raise HTTPException(503, "Gemini API key not configured")

    gemini_action, message, reasoning = _invoke_gemini(req)

    if gemini_action is None:
        return ChatResponse(message=message, reasoning=reasoning, action=None)

    # Fetch saved list names for this family (if family_id provided)
    list_names = []
    if req.family_id:
        list_names = [
            row.name for row in session.query(SavedListMeta)
            .filter_by(family_id=req.family_id).all()
        ]

    resolved = resolve(
        family_id=req.family_id,
        target_request=gemini_action.get("target_request", ""),
        target_kind_hint=gemini_action.get("target_kind_hint"),
        saved_list_names=list_names,
        category_hint_from_ai=gemini_action.get("category_hint_from_ai"),
    )

    if resolved.confirmation_required:
        return ChatResponse(
            message=message,
            reasoning=reasoning,
            action=ChatActionClient(
                type=gemini_action.get("type", "lock"),
                confirmation_required=True,
            ),
        )

    # Find target child device for this family
    if not req.family_id:
        # Legacy dev path: no queue
        return ChatResponse(message=message, reasoning=reasoning, action=None)

    child = session.query(Device).filter_by(family_id=req.family_id, mode=DeviceMode.child).first()
    if not child:
        raise HTTPException(400, "no child device paired to this family")

    # Build command payload
    action_type = gemini_action.get("type", "lock")
    payload = {
        "action": action_type,
        "tier": resolved.tier,
        "target": {
            "bundle_id": resolved.bundle_id,
            "list_name": resolved.list_name,
            "has_pending_blob": False,  # set to True in Max mode by a future endpoint
            "category_hint": resolved.category_hint,
            "original_request": gemini_action.get("target_request", ""),
            "target_display": resolved.target_display,
        },
        "duration_minutes": gemini_action.get("duration_minutes"),
        "issued_at": datetime.utcnow().isoformat(),
    }

    cmd = Command(family_id=req.family_id, target_device_id=child.id, payload=payload)
    session.add(cmd)
    session.commit()
    logger.info("queued command {} for child {}", cmd.id, child.id)

    return ChatResponse(
        message=message,
        reasoning=reasoning,
        action=ChatActionClient(
            type=action_type,
            command_id=cmd.id,
            tier=resolved.tier,
            target_display=resolved.target_display or resolved.list_name or resolved.category_hint,
            duration_minutes=gemini_action.get("duration_minutes"),
        ),
    )


def _invoke_gemini(req: ChatRequest) -> tuple[dict | None, str, str | None]:
    """Returns (action_dict_or_None, message, reasoning)."""
    from google import genai
    from google.genai import types

    history_text = ""
    for h in req.history[-10:]:
        role = "Parent" if h.get("role") == "parent" else "Evlin"
        history_text += f"{role}: {h.get('content', '')}\n"

    user_msg = f"{history_text}Parent: [Child: {req.child_name}] {req.message}"
    full_prompt = f"{SYSTEM_PROMPT}\n\n---\nConversation:\n{user_msg}\n\nRespond in JSON:"

    client = genai.Client(api_key=settings.gemini_api_key)
    resp = client.models.generate_content(
        model=settings.gemini_model,
        contents=full_prompt,
        config=types.GenerateContentConfig(temperature=0.7, response_mime_type="application/json"),
    )
    text = (resp.text or "").strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1].rsplit("```", 1)[0]
    data = json.loads(text)
    return data.get("action"), data.get("message", ""), data.get("reasoning")
```

- [ ] **Step 2.5: Keep SYSTEM_PROMPT at module top** (replace the existing declaration at top of file).

- [ ] **Step 3: Smoke test**

```bash
# First create a family + pair a child
FAMILY_ID=$(curl -s -X POST http://localhost:8000/api/v1/family/create \
  -H "Content-Type: application/json" \
  -d '{"child_name":"Liam","protection_mode":"std"}' | jq -r .family_id)
CODE=$(curl -s -X POST http://localhost:8000/api/v1/family/create ...)  # save code
# ... pair child ...

# Then send a chat:
curl -X POST http://localhost:8000/api/v1/parent/chat \
  -H "Content-Type: application/json" \
  -d "{\"family_id\":\"$FAMILY_ID\",\"message\":\"lock IG for 30 min\",\"child_name\":\"Liam\"}"
# Expect action with tier=exact_bundle, command_id set
```

- [ ] **Step 4: Commit**

```bash
git add adaptive-engine/backend/app/api/routes/parent_chat.py
git commit -m "feat(api): /parent/chat resolves + queues Commands"
```

### Task 2.9: /child/commands + /child/ack

**Files:**
- Create: `adaptive-engine/backend/app/api/routes/parent_commands.py`
- Modify: `adaptive-engine/backend/app/api/routes/child_device.py`
- Modify: `adaptive-engine/backend/app/main.py`

- [ ] **Step 1: Add commands endpoints to child_device.py**

Append to the file:

```python
from uuid import UUID
from datetime import datetime
from sqlalchemy.orm import Session
from backend.app.db.engine import get_session
from backend.app.db.models.command import Command, AckStatus
from backend.app.db.models.command import PendingBlob


@router.get("/child/commands", tags=["Child Device"])
def list_pending_commands(device_id: UUID, session: Session = Depends(get_session)) -> list[dict]:
    cmds = (
        session.query(Command)
        .filter(Command.target_device_id == device_id, Command.ack_status == AckStatus.pending)
        .order_by(Command.created_at.asc())
        .all()
    )
    now = datetime.utcnow()
    for c in cmds:
        if c.picked_up_at is None:
            c.picked_up_at = now
    session.commit()
    return [{"command_id": str(c.id), **c.payload} for c in cmds]


class AckRequest(BaseModel):
    command_id: UUID
    status: str  # "confirmed_exact" | "confirmed_fallback" | "failed"
    detail: dict | None = None


@router.post("/child/ack", tags=["Child Device"])
def ack_command(req: AckRequest, session: Session = Depends(get_session)) -> dict:
    cmd = session.get(Command, req.command_id)
    if not cmd:
        raise HTTPException(404)
    cmd.acked_at = datetime.utcnow()
    try:
        cmd.ack_status = AckStatus(req.status)
    except ValueError:
        raise HTTPException(400, "invalid status")
    cmd.ack_detail = req.detail
    # Clean up pending blob if any
    session.query(PendingBlob).filter_by(command_id=req.command_id).delete()
    session.commit()
    return {"ok": True}


@router.get("/child/pending-blob", tags=["Child Device"])
def get_pending_blob(command_id: UUID, session: Session = Depends(get_session)) -> dict:
    blob = session.get(PendingBlob, command_id)
    if not blob:
        raise HTTPException(404, "no pending blob")
    import base64
    encoded = base64.b64encode(blob.blob).decode()
    session.delete(blob)
    session.commit()
    return {"command_id": str(command_id), "blob_base64": encoded}
```

- [ ] **Step 2: Add /parent/ack-status endpoint**

Create `adaptive-engine/backend/app/api/routes/parent_commands.py`:

```python
from __future__ import annotations
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from backend.app.db.engine import get_session
from backend.app.db.models.command import Command

router = APIRouter(prefix="/parent", tags=["Parent Commands"])


class AckStatusResponse(BaseModel):
    command_id: UUID
    status: str
    detail: dict | None


@router.get("/ack-status", response_model=AckStatusResponse)
def get_ack_status(command_id: UUID, session: Session = Depends(get_session)) -> AckStatusResponse:
    cmd = session.get(Command, command_id)
    if not cmd:
        raise HTTPException(404)
    return AckStatusResponse(command_id=cmd.id, status=cmd.ack_status.value, detail=cmd.ack_detail)
```

Register in main.py:
```python
from backend.app.api.routes.parent_commands import router as parent_commands_router
app.include_router(parent_commands_router, prefix="/api/v1")
```

- [ ] **Step 3: Smoke test the full loop**

```bash
# (assuming family + child paired; CHILD_ID known)
# 1. Parent sends a chat command → creates a Command row
# 2. Child polls:
curl "http://localhost:8000/api/v1/child/commands?device_id=$CHILD_ID"
# Expect array with the command
# 3. Child acks:
curl -X POST http://localhost:8000/api/v1/child/ack \
  -H "Content-Type: application/json" \
  -d '{"command_id":"<cmd>","status":"confirmed_exact"}'
# 4. Parent fetches ack-status:
curl "http://localhost:8000/api/v1/parent/ack-status?command_id=<cmd>"
# Expect status=confirmed_exact
```

- [ ] **Step 4: Commit**

```bash
git add adaptive-engine/backend/app/api/routes/child_device.py \
        adaptive-engine/backend/app/api/routes/parent_commands.py \
        adaptive-engine/backend/app/main.py
git commit -m "feat(api): /child/commands, /child/ack, /parent/ack-status"
```

---

# Phase 3 — Std mode Saved Lists end-to-end

**Purpose:** First full working experience — build a list on child device, lock it from parent chat, watch it expire. Single-device toggle works; dual-device works.

### Task 3.1: CommandPoller on child device

**Files:**
- Create: `Evlin iOS/Evlin iOS/Services/CommandPoller.swift`
- Modify: `Evlin iOS/Evlin iOS/Services/APIClient.swift`

- [ ] **Step 1: Add APIClient methods**

Append to `APIClient.swift`:

```swift
struct PollCommand: Codable {
    let command_id: UUID
    let action: String
    let tier: String?
    let target: PollTarget
    let duration_minutes: Int?
    let issued_at: String
}

struct PollTarget: Codable {
    let bundle_id: String?
    let list_name: String?
    let has_pending_blob: Bool?
    let category_hint: String?
    let original_request: String
    let target_display: String?
}

extension APIClient {
    func pollCommands(deviceID: UUID) async throws -> [PollCommand] {
        var comps = URLComponents(string: "\(baseURL)/child/commands")!
        comps.queryItems = [URLQueryItem(name: "device_id", value: deviceID.uuidString)]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode([PollCommand].self, from: data)
    }

    func ack(commandID: UUID, status: String, detail: [String: Any]? = nil) async throws {
        let url = URL(string: "\(baseURL)/child/ack")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["command_id": commandID.uuidString, "status": status]
        if let d = detail { body["detail"] = d }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }

    func fetchPendingBlob(commandID: UUID) async throws -> Data? {
        var comps = URLComponents(string: "\(baseURL)/child/pending-blob")!
        comps.queryItems = [URLQueryItem(name: "command_id", value: commandID.uuidString)]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Envelope: Codable { let blob_base64: String }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return Data(base64Encoded: env.blob_base64)
    }

    func fetchAckStatus(commandID: UUID) async throws -> (status: String, detail: [String: Any]?) {
        var comps = URLComponents(string: "\(baseURL)/parent/ack-status")!
        comps.queryItems = [URLQueryItem(name: "command_id", value: commandID.uuidString)]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (json["status"] as? String ?? "pending", json["detail"] as? [String: Any])
    }
}
```

- [ ] **Step 2: Write CommandPoller**

```swift
import Foundation

/// Polls the backend for commands and dispatches to ActionExecutor.
/// Foreground-only for MVP; APNs is Phase 5.
@MainActor
final class CommandPoller: ObservableObject {
    static let shared = CommandPoller()

    private var timer: Timer?
    private var isPolling = false

    func start(deviceID: UUID, apiClient: APIClient) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollOnce(deviceID: deviceID, apiClient: apiClient)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func pollOnce(deviceID: UUID, apiClient: APIClient) async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        do {
            let cmds = try await apiClient.pollCommands(deviceID: deviceID)
            for poll in cmds { await execute(poll: poll, apiClient: apiClient) }
        } catch {
            print("[CommandPoller] error: \(error)")
        }
    }

    private func execute(poll: PollCommand, apiClient: APIClient) async {
        // Decode → LockCommand
        let tier = poll.tier.flatMap(LockTier.init(rawValue:))
        let target = CommandTarget(
            bundleID: poll.target.bundle_id,
            listName: poll.target.list_name,
            hasPendingBlob: poll.target.has_pending_blob ?? false,
            categoryHint: poll.target.category_hint,
            originalRequest: poll.target.original_request,
            targetDisplay: poll.target.target_display
        )
        let action: CommandAction = {
            switch poll.action {
            case "lock": return .lock
            case "unlock": return .unlock
            case "unlock_all": return .unlockAll
            case "expand_library": return .expandLibrary
            default: return .lock
            }
        }()
        let cmd = LockCommand(
            id: poll.command_id,
            action: action,
            tier: tier,
            target: target,
            durationMinutes: poll.duration_minutes,
            issuedAt: ISO8601DateFormatter().date(from: poll.issued_at) ?? Date()
        )

        // Fetch blob if applicable
        var blob: Data? = nil
        if target.hasPendingBlob {
            blob = try? await apiClient.fetchPendingBlob(commandID: cmd.id)
        }

        let result = await ActionExecutor.shared.execute(cmd, blob: blob)

        // Translate to backend ack status
        let (status, detail): (String, [String: Any]?) = {
            switch result {
            case .confirmedExact(let name): return ("confirmed_exact", ["display_name": name])
            case .confirmedFallback(let name, let cat, let orig):
                return ("confirmed_fallback", ["display_name": name, "category": cat, "orig": orig])
            case .failed(let fail): return ("failed", ["reason": String(describing: fail)])
            }
        }()
        try? await apiClient.ack(commandID: cmd.id, status: status, detail: detail)
    }
}
```

- [ ] **Step 3: Start the poller from Child mode entry**

Modify `ContentView.swift` (or wherever `activeMode == .child` is detected) to start the poller on `onAppear`. Detailed wiring depends on existing root-view structure; the addition looks like:

```swift
.onChange(of: activeMode) { _, new in
    if new == .child, let id = currentChildDeviceID {
        CommandPoller.shared.start(deviceID: id, apiClient: apiClient)
    } else {
        CommandPoller.shared.stop()
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Services/CommandPoller.swift" \
        "Evlin iOS/Evlin iOS/Services/APIClient.swift" \
        "Evlin iOS/Evlin iOS/ContentView.swift"
git commit -m "feat(ios): CommandPoller (foreground 5s) + APIClient endpoints"
```

### Task 3.2: Saved List picker UI (child device)

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/SavedListPickerView.swift`

- [ ] **Step 1: Write SavedListPickerView**

```swift
import SwiftUI
import FamilyControls

struct SavedListPickerView: View {
    let onSaved: (String) -> Void
    @State private var selection = FamilyActivitySelection()
    @State private var name: String = ""
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 16) {
            TextField("List name (e.g. list 1)", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Button("Open App Picker") { showPicker = true }
                .buttonStyle(.borderedProminent)
                .familyActivityPicker(isPresented: $showPicker, selection: $selection)

            Text("\(selection.applicationTokens.count) apps, \(selection.categoryTokens.count) categories selected")
                .font(.caption)

            Button("Save") {
                guard !name.isEmpty else { return }
                LocalAliasStore.shared.saveList(selection, named: name)
                onSaved(name)
            }
            .disabled(name.isEmpty || (selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty))
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .padding()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Child/SavedListPickerView.swift"
git commit -m "feat(ios): SavedListPickerView for Std-mode list building"
```

### Task 3.3: POST saved-list meta to backend

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Services/APIClient.swift`
- Modify: `Evlin iOS/Evlin iOS/Views/Child/SavedListPickerView.swift`

- [ ] **Step 1: Add endpoint in backend first**

In `adaptive-engine/backend/app/api/routes/family.py` (or a new `saved_lists.py`), add:

```python
from backend.app.db.models.saved_list import SavedListMeta, SavedListMode

class CreateListRequest(BaseModel):
    family_id: UUID
    owning_device_id: UUID
    name: str
    description: str | None = None
    mode: SavedListMode  # parent_device or child_device

class SavedListResponse(BaseModel):
    id: UUID
    name: str

@router.post("/saved-lists", response_model=SavedListResponse)
def create_saved_list(req: CreateListRequest, session: Session = Depends(get_session)) -> SavedListResponse:
    # upsert by (family_id, name)
    existing = (
        session.query(SavedListMeta)
        .filter_by(family_id=req.family_id, name=req.name)
        .first()
    )
    if existing:
        existing.description = req.description
        existing.mode = req.mode
        session.commit()
        return SavedListResponse(id=existing.id, name=existing.name)
    row = SavedListMeta(
        family_id=req.family_id,
        owning_device_id=req.owning_device_id,
        name=req.name,
        description=req.description,
        mode=req.mode,
    )
    session.add(row)
    session.commit()
    return SavedListResponse(id=row.id, name=row.name)
```

- [ ] **Step 2: Add APIClient method**

```swift
extension APIClient {
    struct CreateListParams {
        let familyID: UUID
        let owningDeviceID: UUID
        let name: String
        let description: String?
        let mode: String  // "child_device" | "parent_device"
    }

    @discardableResult
    func createSavedListMeta(_ p: CreateListParams) async throws -> UUID {
        let url = URL(string: "\(baseURL)/family/saved-lists")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "family_id": p.familyID.uuidString,
            "owning_device_id": p.owningDeviceID.uuidString,
            "name": p.name,
            "description": p.description as Any,
            "mode": p.mode,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        struct R: Codable { let id: UUID }
        return try JSONDecoder().decode(R.self, from: data).id
    }
}
```

- [ ] **Step 3: Wire to SavedListPickerView Save button**

Update the Save button closure to also POST meta (requires `familyID` and `deviceID` injected from caller).

- [ ] **Step 4: Commit**

```bash
git add adaptive-engine/backend/app/api/routes/family.py \
        "Evlin iOS/Evlin iOS/Services/APIClient.swift" \
        "Evlin iOS/Evlin iOS/Views/Child/SavedListPickerView.swift"
git commit -m "feat: POST saved list meta to backend on save"
```

### Task 3.4: Manual E2E test — child creates list 1, parent locks it

- [ ] **Step 1: On device, switch to Child mode → open Saved List picker → pick 2 apps → name "list 1" → save**

Verify:
- `LocalAliasStore.shared.savedList(named: "list 1")` returns the selection.
- Backend has a SavedListMeta row.

- [ ] **Step 2: Switch to Parent mode → Chat: "ban list 1 for 1 min"**

Verify:
- Backend resolver identifies tier=saved_list.
- Command row appears queued.

- [ ] **Step 3: Switch back to Child mode → poller fires within 5s → ActionExecutor applies shield**

Verify:
- The 2 apps in list 1 are now shielded (try launching one).
- After 1 min, shield lifts automatically.

- [ ] **Step 4: Document result in spike notes + commit**

```bash
git add docs/superpowers/specs/2026-04-22-spike-notes.md
git commit -m "docs(spike): Phase 3 Std-mode saved list E2E"
```

---

# Phase 4 — Onboarding rebuild + Max mode

**Purpose:** Replace the old onboarding with the split-by-mode flow from spec §5. Implement Max-mode path (Child Apple ID, `.child` auth, `denyAppRemoval`, parent-device picker with ephemeral blob relay) and Std-mode path (passcode-based).

### Task 4.1: OnboardingCoordinator skeleton

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/OnboardingCoordinator.swift`

- [ ] **Step 1: Write the coordinator**

```swift
import SwiftUI

enum OnboardingMode: String, Codable {
    case parent, child
}

enum OnboardingStep: Equatable {
    case welcome
    case modeSelect
    case parent(ParentStep)
    case child(ChildStep)
    case done

    enum ParentStep: Equatable {
        case addChild, protectionLevel, pairingCode
        case maxWhyChildAppleID, maxCreateChildAppleID, maxSignInOnChild, maxWaitForAuth
        case stdSetPasscode, stdDisableDeletion, stdVerification
        case firstSavedList
    }
    enum ChildStep: Equatable {
        case enterPairingCode, grantPermission, deletionProtection
        case categoryDefaults, firstSavedList, ready
    }
}

struct OnboardingCoordinator: View {
    @State private var step: OnboardingStep = .welcome
    @State private var mode: OnboardingMode? = nil
    @State private var childName: String = ""
    @State private var protectionMode: String = "std"   // "max" or "std"
    @State private var pairingCode: String = ""
    @State private var familyID: UUID? = nil
    @State private var parentDeviceID: UUID? = nil
    @State private var childDeviceID: UUID? = nil
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        Group {
            switch step {
            case .welcome:
                WelcomeStep { step = .modeSelect }
            case .modeSelect:
                ModeSelectStep { selectedMode in
                    mode = selectedMode
                    step = selectedMode == .parent ? .parent(.addChild) : .child(.enterPairingCode)
                }
            case .parent(let s):
                parentBody(s)
            case .child(let s):
                childBody(s)
            case .done:
                Color.clear.onAppear { onboardingComplete = true }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    // parentBody and childBody route to specific Step views (placeholders now)
    @ViewBuilder private func parentBody(_ s: OnboardingStep.ParentStep) -> some View {
        Text("Parent step \(String(describing: s))")
    }
    @ViewBuilder private func childBody(_ s: OnboardingStep.ChildStep) -> some View {
        Text("Child step \(String(describing: s))")
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Onboarding/OnboardingCoordinator.swift"
git commit -m "feat(onboarding): Coordinator skeleton"
```

### Task 4.2: Shared steps — Welcome, ModeSelect

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Shared/WelcomeStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Shared/ModeSelectStep.swift`

- [ ] **Step 1: WelcomeStep**

```swift
import SwiftUI

struct WelcomeStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Circle()
                .fill(Color.evPrimary)
                .frame(width: 80, height: 80)
                .overlay(Image(systemName: "shield.checkered").font(.system(size: 36, weight: .bold)).foregroundStyle(.white))
            Text("Welcome to Evlin").font(.evHeadlineLarge).foregroundStyle(Color.evPrimary)
            Text("The Informed Sentinel").font(.evHeadlineSmall).foregroundStyle(Color.evOnPrimaryContainer)
            Text("AI-powered parental control. Setup takes about 2 minutes.")
                .multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
            Button(action: onContinue) { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
        }
        .padding()
    }
}
```

- [ ] **Step 2: ModeSelectStep**

```swift
import SwiftUI

struct ModeSelectStep: View {
    let onSelect: (OnboardingMode) -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text("Which phone is this?").font(.evHeadlineMedium).padding(.top)
            Text("Evlin runs on both the parent's and the child's phone.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 16) {
                modeCard(title: "I'm the parent", systemImage: "person.fill.checkmark") { onSelect(.parent) }
                modeCard(title: "I'm the child", systemImage: "person.fill") { onSelect(.child) }
            }
            .padding()
            Spacer()
        }
    }

    @ViewBuilder private func modeCard(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 42))
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .padding()
            .background(Color.evSurfaceContainer)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Onboarding/Shared/"
git commit -m "feat(onboarding): WelcomeStep, ModeSelectStep"
```

### Task 4.3: Parent steps — AddChild, ProtectionLevel, PairingCode

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/AddChildStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/ProtectionLevelStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/PairingCodeStep.swift`

- [ ] **Step 1: AddChildStep**

```swift
import SwiftUI

struct AddChildStep: View {
    @Binding var name: String
    let onContinue: () -> Void
    @State private var age: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add your child").font(.evHeadlineLarge).padding(.top)
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Liam", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Age (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("8", text: $age).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
            }
            Spacer()
            Button("Continue", action: onContinue).buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(name.isEmpty)
        }
        .padding()
    }
}
```

- [ ] **Step 2: ProtectionLevelStep**

```swift
import SwiftUI

struct ProtectionLevelStep: View {
    @Binding var mode: String   // "max" | "std"
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Protection level").font(.evHeadlineLarge).padding(.top)
            card(
                title: "Maximum (recommended)",
                bullets: ["Picker on YOUR phone controls Liam's apps", "Evlin cannot be uninstalled", "Requires Child Apple ID (5 min setup)"],
                selected: mode == "max",
                onTap: { mode = "max" }
            )
            card(
                title: "Standard",
                bullets: ["Picker on Liam's phone only", "Family Controls passcode protects deletion", "No extra account needed"],
                selected: mode == "std",
                onTap: { mode = "std" }
            )
            Spacer()
            Button("Continue", action: onContinue).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }
        .padding()
    }

    @ViewBuilder
    private func card(title: String, bullets: [String], selected: Bool, onTap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(Color.evPrimary)
                Text(title).font(.headline)
            }
            ForEach(bullets, id: \.self) { b in
                HStack(alignment: .top) {
                    Text("·").fontWeight(.bold); Text(b).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.evPrimaryContainer.opacity(0.3) : Color.evSurfaceContainer)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.evPrimary : Color.clear, lineWidth: 2))
        .cornerRadius(12)
        .onTapGesture(perform: onTap)
    }
}
```

- [ ] **Step 3: PairingCodeStep**

```swift
import SwiftUI

struct PairingCodeStep: View {
    @EnvironmentObject var apiClient: APIClient
    @Binding var childName: String
    @Binding var protectionMode: String
    @Binding var familyID: UUID?
    @Binding var parentDeviceID: UUID?
    @Binding var pairingCode: String

    let onContinue: () -> Void

    @State private var codeExpiresAt: Date?
    @State private var status: String = "Generating…"
    @State private var polling = false
    @State private var childJoined = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Pairing Code").font(.evHeadlineLarge).padding(.top)
            Text("Open Evlin on Liam's phone and enter this code.").multilineTextAlignment(.center)

            Text(pairingCode.isEmpty ? "- - - - - -" : insertSpaces(pairingCode))
                .font(.system(size: 42, weight: .bold, design: .monospaced))

            HStack(spacing: 8) {
                if childJoined { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Text(status).foregroundStyle(.secondary)
            }

            Spacer()
            Button("Continue", action: onContinue).buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(!childJoined)
        }
        .padding()
        .task { await createFamily() }
    }

    private func insertSpaces(_ s: String) -> String { s.map(String.init).joined(separator: " ") }

    private func createFamily() async {
        do {
            let url = URL(string: "\(apiClient.baseURL)/family/create")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["child_name": childName, "protection_mode": protectionMode]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            struct R: Codable { let family_id: UUID; let parent_device_id: UUID; let pairing_code: String; let code_expires_at: Date }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let r = try dec.decode(R.self, from: data)
            familyID = r.family_id
            parentDeviceID = r.parent_device_id
            pairingCode = r.pairing_code
            codeExpiresAt = r.code_expires_at
            status = "Waiting for Liam's device…"
            startPolling()
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    private func startPolling() {
        Task {
            while !childJoined && !Task.isCancelled {
                do {
                    var comps = URLComponents(string: "\(apiClient.baseURL)/family/pairing-status")!
                    comps.queryItems = [URLQueryItem(name: "code", value: pairingCode)]
                    let (data, _) = try await URLSession.shared.data(from: comps.url!)
                    struct R: Codable { let used: Bool }
                    if let r = try? JSONDecoder().decode(R.self, from: data), r.used {
                        childJoined = true
                        status = "Liam's phone connected"
                        break
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Onboarding/Parent/"
git commit -m "feat(onboarding): AddChild, ProtectionLevel, PairingCode steps"
```

### Task 4.4: Parent Max-path steps

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/Max/WhyChildAppleIDStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/Max/CreateChildAppleIDStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/Max/SignInOnChildStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/Max/WaitForAuthStep.swift`

- [ ] **Step 1: WhyChildAppleIDStep (bullet list + Continue)**

Simple informational screen; 4 bullets from spec §5.2 [6P-Max-A]. Template:

```swift
struct WhyChildAppleIDStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Why Child Apple ID?").font(.evHeadlineLarge).padding(.top)
            bullet("person.2.fill", "Select your child's apps remotely from YOUR phone.")
            bullet("lock.shield.fill", "Evlin cannot be uninstalled from Liam's phone.")
            bullet("clock.fill", "Set time limits and bedtime without requiring Liam's involvement.")
            bullet("checkmark.seal.fill", "Official Apple Family Sharing — fully compliant.")
            Spacer()
            Button("Got it, let's set it up", action: onContinue).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }.padding()
    }
    @ViewBuilder private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: icon).foregroundStyle(Color.evPrimary).frame(width: 32)
            Text(text)
        }
    }
}
```

- [ ] **Step 2: CreateChildAppleIDStep and SignInOnChildStep are instructional steps with deep link + "I've done this" button**

Template for each:

```swift
struct CreateChildAppleIDStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Child Apple ID").font(.evHeadlineLarge).padding(.top)
            Text("On THIS phone:\n1. Open Settings → Family\n2. Tap Add Member → Create a Child Account\n3. Follow Apple's prompts (~3 min)")
            Button("Open Family Settings") {
                Task { await ScreenTimeManager.shared.openScreenTimeSettings() }
            }
            Spacer()
            Button("I've created the account", action: onContinue).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }.padding()
    }
}
```

```swift
struct SignInOnChildStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign In on Liam's Phone").font(.evHeadlineLarge).padding(.top)
            Text("On Liam's phone:\n1. Sign out of the existing Apple ID (if any)\n2. Sign in with the Child Apple ID you just created\n3. Return to Evlin (already running there in child mode)")
            Spacer()
            Button("I've signed in on Liam's phone", action: onContinue)
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }.padding()
    }
}
```

- [ ] **Step 3: WaitForAuthStep — polls backend for auth_status=granted**

We add a new backend endpoint in Task 4.5. For now, stub with a "Continue" button to move forward (wire polling in Task 4.5).

```swift
struct WaitForAuthStep: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let onContinue: () -> Void
    @State private var status: String = "Waiting for child device…"
    @State private var granted = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Waiting for Authorization").font(.evHeadlineLarge).padding(.top)
            Text("Pick up Liam's phone. Evlin there will prompt you to authorize as parent. Approve the iOS prompt on your phone when it appears.")
            HStack { if granted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }; Text(status) }
            Spacer()
            Button("Continue", action: onContinue).buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(!granted)
        }.padding()
        .task { await poll() }
    }

    private func poll() async {
        while !granted && !Task.isCancelled {
            do {
                var comps = URLComponents(string: "\(apiClient.baseURL)/family/auth-status")!
                comps.queryItems = [URLQueryItem(name: "family_id", value: familyID.uuidString)]
                let (data, _) = try await URLSession.shared.data(from: comps.url!)
                struct R: Codable { let granted: Bool }
                if let r = try? JSONDecoder().decode(R.self, from: data), r.granted {
                    granted = true; status = "Parent authorization granted"; break
                }
            } catch {}
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Onboarding/Parent/Max/"
git commit -m "feat(onboarding): Max-path parent steps"
```

### Task 4.5: Backend — auth-status endpoint

**Files:**
- Modify: `adaptive-engine/backend/app/api/routes/family.py`

- [ ] **Step 1: Add column and endpoints**

Add `child_auth_granted: bool` column to Device (migration-lite: `ALTER TABLE` via SQL or just recreate dev DB):

```python
# device.py
class Device(Base):
    # ... existing
    child_auth_granted: Mapped[bool] = mapped_column(Boolean, default=False)
```

In family.py:

```python
@router.get("/auth-status")
def auth_status(family_id: UUID, session: Session = Depends(get_session)) -> dict:
    child = (
        session.query(Device)
        .filter_by(family_id=family_id, mode=DeviceMode.child)
        .first()
    )
    return {"granted": bool(child and child.child_auth_granted)}


class GrantAuthRequest(BaseModel):
    child_device_id: UUID

@router.post("/auth-status/grant")
def grant_auth(req: GrantAuthRequest, session: Session = Depends(get_session)) -> dict:
    child = session.get(Device, req.child_device_id)
    if not child: raise HTTPException(404)
    child.child_auth_granted = True
    session.commit()
    return {"ok": True}
```

- [ ] **Step 2: Child device posts to `/auth-status/grant` after `.child` auth succeeds (done in Task 4.7)**

- [ ] **Step 3: Commit**

```bash
git add adaptive-engine/backend/app/api/routes/family.py adaptive-engine/backend/app/db/models/device.py
git commit -m "feat(api): /auth-status endpoints for Max-mode handshake"
```

### Task 4.6: Parent Std-path steps

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/Std/SetPasscodeStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/Std/DisableDeletionStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/Std/StdVerificationStep.swift`

- [ ] **Step 1: Each is an instructional screen following the same pattern as CreateChildAppleIDStep**

Template (e.g. `SetPasscodeStep`):

```swift
struct SetPasscodeStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Family Controls Passcode").font(.evHeadlineLarge).padding(.top)
            Text("On Liam's phone:\n1. Open Settings → Screen Time\n2. Lock Screen Time Settings\n3. Set a 4-digit passcode Liam doesn't know")
            Button("Open Screen Time Settings") {
                Task { await ScreenTimeManager.shared.openScreenTimeSettings() }
            }
            Spacer()
            Button("I've set the passcode", action: onContinue).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }.padding()
    }
}
```

```swift
struct DisableDeletionStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Disable App Deletion").font(.evHeadlineLarge).padding(.top)
            Text("Still on Liam's phone, in Screen Time:\n\nContent & Privacy Restrictions\n→ iTunes & App Store Purchases\n→ Deleting Apps → Don't Allow")
            Button("Open Screen Time Settings") {
                Task { await ScreenTimeManager.shared.openScreenTimeSettings() }
            }
            Spacer()
            Button("I've disabled deletion", action: onContinue)
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }.padding()
    }
}

struct StdVerificationStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verification note").font(.evHeadlineLarge).padding(.top)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title)
                Text("Evlin cannot verify these settings programmatically. If you skipped them, Liam can uninstall Evlin and bypass controls.")
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)
            Spacer()
            Button("Continue anyway", action: onContinue)
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }.padding()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Onboarding/Parent/Std/"
git commit -m "feat(onboarding): Std-path parent steps"
```

### Task 4.7: Child steps — EnterPairingCode, GrantPermission, DeletionProtection

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Child/EnterPairingCodeStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Child/GrantPermissionStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Child/DeletionProtectionStep.swift`

- [ ] **Step 1: EnterPairingCodeStep (6-digit input)**

```swift
import SwiftUI

struct EnterPairingCodeStep: View {
    @EnvironmentObject var apiClient: APIClient
    @Binding var familyID: UUID?
    @Binding var childDeviceID: UUID?
    @Binding var protectionMode: String
    let onContinue: () -> Void

    @State private var code: String = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Enter Pairing Code").font(.evHeadlineLarge).padding(.top)
            TextField("123456", text: $code)
                .keyboardType(.numberPad).font(.system(size: 32, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center).textFieldStyle(.roundedBorder).padding()
                .onChange(of: code) { _, new in
                    if new.count == 6 { Task { await pair() } }
                }
            if let e = error { Text(e).foregroundStyle(.red) }
            Spacer()
        }.padding()
    }

    private func pair() async {
        do {
            let url = URL(string: "\(apiClient.baseURL)/family/pair")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "device_label": UIDevice.current.name])
            let (data, _) = try await URLSession.shared.data(for: req)
            struct R: Codable { let family_id: UUID; let child_device_id: UUID; let protection_mode: String }
            let r = try JSONDecoder().decode(R.self, from: data)
            familyID = r.family_id
            childDeviceID = r.child_device_id
            protectionMode = r.protection_mode
            onContinue()
        } catch {
            self.error = "Invalid code"
        }
    }
}
```

- [ ] **Step 2: GrantPermissionStep — branches on mode**

```swift
struct GrantPermissionStep: View {
    @EnvironmentObject var apiClient: APIClient
    let childDeviceID: UUID
    let protectionMode: String  // "max" | "std"
    let onContinue: () -> Void
    @State private var status: String = "Needed: Screen Time authorization"
    @State private var granted = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Grant Screen Time Permission").font(.evHeadlineLarge).padding(.top)
            Text("Evlin needs Screen Time permission on this phone.")
            Text(status).foregroundStyle(granted ? .green : .secondary)
            Spacer()
            if granted {
                Button("Continue", action: onContinue).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            } else {
                Button("Grant Permission") { Task { await request() } }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
        }.padding()
    }

    private func request() async {
        let mode: FamilyControlsMemberType = protectionMode == "max" ? .child : .individual
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: mode)
            granted = true
            status = "Authorization granted"
            if protectionMode == "max" {
                // Notify backend so parent waitForAuth can proceed
                let url = URL(string: "\(apiClient.baseURL)/family/auth-status/grant")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["child_device_id": childDeviceID.uuidString])
                _ = try await URLSession.shared.data(for: req)
            }
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 3: DeletionProtectionStep — Max mode only**

```swift
struct DeletionProtectionStep: View {
    let onContinue: () -> Void
    @State private var applied = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Deletion Protection").font(.evHeadlineLarge).padding(.top)
            Text("Evlin will now block itself from being deleted on this phone.")
            Spacer()
            if applied {
                Text("✓ Evlin is now protected from deletion.").foregroundStyle(.green)
                Button("Continue", action: onContinue).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            } else {
                Button("Enable Protection") { enable() }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
        }.padding()
    }

    private func enable() {
        let store = ManagedSettingsStore()
        store.application.denyAppRemoval = true
        applied = true
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Onboarding/Child/"
git commit -m "feat(onboarding): Child EnterPairingCode, GrantPermission, DeletionProtection"
```

### Task 4.8: Child — CategoryDefaults + FirstSavedList + Ready

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Child/CategoryDefaultsStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Child/ChildFirstSavedListStep.swift`
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Child/ChildReadyStep.swift`

- [ ] **Step 1: CategoryDefaultsStep — picker + name each category**

```swift
struct CategoryDefaultsStep: View {
    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Category defaults").font(.evHeadlineLarge).padding(.top)
            Text("Pick which categories your parent should be able to control.")
            Button("Open Category Picker") { showPicker = true }
                .buttonStyle(.borderedProminent)
                .familyActivityPicker(isPresented: $showPicker, selection: $selection)
            Text("\(selection.categoryTokens.count) categories selected")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Continue") {
                saveCategories()
                onContinue()
            }
            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            .disabled(selection.categoryTokens.isEmpty)
        }.padding()
    }

    private func saveCategories() {
        // Map each category token to a default name. User can rename in Settings later.
        // Without Label-to-string access, we use positional names "category_1", "category_2", etc.
        // NOTE: alternative is to prompt the user for each. See spec §5.3 [6C].
        for (i, tok) in selection.categoryTokens.enumerated() {
            LocalAliasStore.shared.saveCategoryToken(tok, forName: "category_\(i+1)")
        }
        // Also save under common names for Chat resolver convenience:
        // We can't know WHICH category is which, but we allow the user to rename them in Settings.
    }
}
```

**Note for engineer**: Category naming is imperfect since SwiftUI's `Label(token)` doesn't expose strings. Ship with default numeric names + a Settings UI that shows `Label(tok)` next to an editable name field. This is acceptable for MVP; refine later.

- [ ] **Step 2: ChildFirstSavedListStep — reuse SavedListPickerView (from Task 3.2) + skip button**

```swift
struct ChildFirstSavedListStep: View {
    let familyID: UUID
    let childDeviceID: UUID
    let onDone: () -> Void

    @State private var created: String? = nil
    @EnvironmentObject var apiClient: APIClient

    var body: some View {
        VStack(spacing: 16) {
            Text("Make your first Saved List").font(.evHeadlineLarge).padding(.top)
            Text("Your parent can say 'lock list 1 for 30 min' in Chat.")
            if let name = created {
                Text("✓ '\(name)' saved").foregroundStyle(.green)
                Button("Done", action: onDone).buttonStyle(.borderedProminent)
            } else {
                SavedListPickerView { name in
                    created = name
                    Task {
                        try? await apiClient.createSavedListMeta(.init(
                            familyID: familyID, owningDeviceID: childDeviceID,
                            name: name, description: nil, mode: "child_device"
                        ))
                    }
                }
                Button("Skip for now", action: onDone).padding(.top)
            }
        }.padding()
    }
}
```

- [ ] **Step 3: ChildReadyStep — entry to child main screen**

```swift
struct ChildReadyStep: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    let onEnter: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 80)).foregroundStyle(.green)
            Text("All set!").font(.evHeadlineLarge)
            Text("Waiting for commands from Mom's Evlin.").foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
            Button("Enter Evlin") { onboardingComplete = true; onEnter() }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).padding()
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Onboarding/Child/"
git commit -m "feat(onboarding): Child Category/FirstSavedList/Ready steps"
```

### Task 4.9: Parent FirstSavedList (Max only) + Done

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/FirstSavedListStep.swift` (Max only)
- Create: `Evlin iOS/Evlin iOS/Views/Onboarding/Parent/DoneStep.swift`

- [ ] **Step 1: Parent FirstSavedList — Max-only picker on parent device**

```swift
struct ParentFirstSavedListStep: View {
    let familyID: UUID
    let parentDeviceID: UUID
    let onDone: () -> Void
    @State private var selection = FamilyActivitySelection()
    @State private var name: String = "list 1"
    @State private var showPicker = false
    @State private var saved = false
    @EnvironmentObject var apiClient: APIClient

    var body: some View {
        VStack(spacing: 16) {
            Text("First Saved List").font(.evHeadlineLarge).padding(.top)
            Text("Make your first Saved List from YOUR phone.")
            TextField("list 1", text: $name).textFieldStyle(.roundedBorder).padding(.horizontal)
            Button("Open App Picker") { showPicker = true }
                .buttonStyle(.borderedProminent)
                .familyActivityPicker(isPresented: $showPicker, selection: $selection)
            Text("\(selection.applicationTokens.count) apps selected").foregroundStyle(.secondary)
            Spacer()
            if saved {
                Button("Done", action: onDone).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            } else {
                HStack {
                    Button("Skip for now", action: onDone)
                    Spacer()
                    Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.isEmpty)
                }
            }
        }.padding()
    }

    private func save() {
        // Cache locally on parent device (used later when parent sends a command)
        LocalAliasStore.shared.saveList(selection, named: name)
        Task {
            try? await apiClient.createSavedListMeta(.init(
                familyID: familyID, owningDeviceID: parentDeviceID,
                name: name, description: nil, mode: "parent_device"
            ))
            saved = true
        }
    }
}
```

**Note**: Max-mode blob relay (per-command) is wired in Task 4.11. This step only caches locally + registers metadata.

- [ ] **Step 2: DoneStep**

```swift
struct DoneStep: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    let onEnter: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 80)).foregroundStyle(Color.evPrimary)
            Text("Liam is protected.").font(.evHeadlineLarge)
            Text("Open Chat to send your first command.").foregroundStyle(.secondary)
            Spacer()
            Button("Enter Evlin") { onboardingComplete = true; onEnter() }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).padding()
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Onboarding/Parent/FirstSavedListStep.swift" "Evlin iOS/Evlin iOS/Views/Onboarding/Parent/DoneStep.swift"
git commit -m "feat(onboarding): Parent FirstSavedList (Max) + Done"
```

### Task 4.10: Wire all steps into OnboardingCoordinator

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Onboarding/OnboardingCoordinator.swift`

- [ ] **Step 1: Replace `parentBody` and `childBody` with real routing**

```swift
@ViewBuilder private func parentBody(_ s: OnboardingStep.ParentStep) -> some View {
    switch s {
    case .addChild:
        AddChildStep(name: $childName) { step = .parent(.protectionLevel) }
    case .protectionLevel:
        ProtectionLevelStep(mode: $protectionMode) { step = .parent(.pairingCode) }
    case .pairingCode:
        PairingCodeStep(
            childName: $childName, protectionMode: $protectionMode,
            familyID: $familyID, parentDeviceID: $parentDeviceID, pairingCode: $pairingCode
        ) {
            step = .parent(protectionMode == "max" ? .maxWhyChildAppleID : .stdSetPasscode)
        }
    case .maxWhyChildAppleID:
        WhyChildAppleIDStep { step = .parent(.maxCreateChildAppleID) }
    case .maxCreateChildAppleID:
        CreateChildAppleIDStep { step = .parent(.maxSignInOnChild) }
    case .maxSignInOnChild:
        SignInOnChildStep { step = .parent(.maxWaitForAuth) }
    case .maxWaitForAuth:
        WaitForAuthStep(familyID: familyID ?? UUID()) { step = .parent(.firstSavedList) }
    case .stdSetPasscode:
        SetPasscodeStep { step = .parent(.stdDisableDeletion) }
    case .stdDisableDeletion:
        DisableDeletionStep { step = .parent(.stdVerification) }
    case .stdVerification:
        StdVerificationStep { step = .done }     // Std skips FirstSavedList (built on child side)
    case .firstSavedList:
        ParentFirstSavedListStep(familyID: familyID!, parentDeviceID: parentDeviceID!) { step = .done }
    }
}

@ViewBuilder private func childBody(_ s: OnboardingStep.ChildStep) -> some View {
    switch s {
    case .enterPairingCode:
        EnterPairingCodeStep(
            familyID: $familyID, childDeviceID: $childDeviceID, protectionMode: $protectionMode
        ) { step = .child(.grantPermission) }
    case .grantPermission:
        GrantPermissionStep(childDeviceID: childDeviceID ?? UUID(), protectionMode: protectionMode) {
            step = .child(protectionMode == "max" ? .deletionProtection : .categoryDefaults)
        }
    case .deletionProtection:
        DeletionProtectionStep { step = .child(.categoryDefaults) }
    case .categoryDefaults:
        CategoryDefaultsStep {
            step = .child(protectionMode == "std" ? .firstSavedList : .ready)
        }
    case .firstSavedList:
        ChildFirstSavedListStep(familyID: familyID!, childDeviceID: childDeviceID!) { step = .child(.ready) }
    case .ready:
        ChildReadyStep { step = .done }
    }
}
```

- [ ] **Step 2: Wire into ContentView root — show OnboardingCoordinator when !onboardingComplete**

Find the existing root gate (likely checking `onboardingComplete`) and replace `OnboardingView()` with `OnboardingCoordinator()`.

- [ ] **Step 3: Delete old files**

```bash
rm "Evlin iOS/Evlin iOS/Views/Onboarding/OnboardingView.swift"
rm "Evlin iOS/Evlin iOS/Views/Onboarding/SetupView.swift"
```

- [ ] **Step 4: Build + commit**

```bash
git add -A
git commit -m "feat(onboarding): wire Coordinator; remove legacy OnboardingView/SetupView"
```

### Task 4.11: Max-mode per-command blob relay

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Services/APIClient.swift`
- Modify: `adaptive-engine/backend/app/api/routes/parent_chat.py`
- Modify: `Evlin iOS/Evlin iOS/Views/Chat/ChatViewModel.swift`

- [ ] **Step 1: Add backend endpoint to attach blob to a just-created command**

In `parent_chat.py`, add a follow-up endpoint:

```python
from backend.app.db.models.command import PendingBlob

class AttachBlobRequest(BaseModel):
    command_id: UUID
    selection_blob_b64: str

@router.post("/commands/attach-blob")
def attach_blob(req: AttachBlobRequest, session: Session = Depends(get_session)) -> dict:
    cmd = session.get(Command, req.command_id)
    if not cmd: raise HTTPException(404)
    import base64
    blob = base64.b64decode(req.selection_blob_b64)
    session.add(PendingBlob(command_id=req.command_id, blob=blob))
    # Also flip target.has_pending_blob in payload
    payload = dict(cmd.payload)
    target = dict(payload.get("target", {}))
    target["has_pending_blob"] = True
    payload["target"] = target
    cmd.payload = payload
    session.commit()
    return {"ok": True}
```

- [ ] **Step 2: APIClient method**

```swift
extension APIClient {
    func attachSelectionBlob(commandID: UUID, selection: FamilyActivitySelection) async throws {
        let data = try PropertyListEncoder().encode(selection)
        let body: [String: Any] = [
            "command_id": commandID.uuidString,
            "selection_blob_b64": data.base64EncodedString()
        ]
        let url = URL(string: "\(baseURL)/parent/commands/attach-blob")!
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }
}
```

- [ ] **Step 3: In ChatViewModel, after chat returns with tier=saved_list and Max mode, attach blob**

In the send-message result handler:

```swift
if response.action?.tier == "saved_list", protectionMode == "max",
   let cmdID = response.action?.command_id, let listName = response.action?.target_display,
   let selection = LocalAliasStore.shared.savedList(named: listName) {
    try? await apiClient.attachSelectionBlob(commandID: cmdID, selection: selection)
}
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(max): per-command selection_blob relay via PendingBlob"
```

---

# Phase 5 — Polish: APNs + ReceiptCard + Settings

### Task 5.1: ReceiptCard UI

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/ReceiptCard.swift`
- Modify: `Evlin iOS/Evlin iOS/Models/ChatModels.swift`
- Modify: `Evlin iOS/Evlin iOS/Views/Chat/ChatView.swift`
- Modify: `Evlin iOS/Evlin iOS/Views/Chat/ChatViewModel.swift`

- [ ] **Step 1: Add receipt fields to ChatMessage**

In `ChatModels.swift`, add to the message struct:

```swift
var receiptCommandID: UUID?
var receiptState: ReceiptStateSerializable?

struct ReceiptStateSerializable: Codable {
    var raw: String              // "pending", "confirmed_exact", etc.
    var displayName: String?
    var category: String?
    var origRequest: String?
    var unlocksAt: Date?
    var reason: String?
}
```

- [ ] **Step 2: Create ReceiptCard view**

```swift
import SwiftUI

struct ReceiptCard: View {
    let state: ReceiptState
    let onUnlockNow: (() -> Void)?
    let onMakePrecise: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                icon
                Text(primary).font(.headline)
            }
            if let s = secondary { Text(s).font(.caption).foregroundStyle(.secondary) }
            if case .confirmedExact = state, let action = onUnlockNow {
                Button("Unlock now", action: action).font(.caption).padding(.top, 4)
            }
            if case .confirmedFallback = state, let action = onMakePrecise {
                Button("Make it precise", action: action).font(.caption).padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color.evSurfaceContainer)
        .cornerRadius(12)
    }

    private var icon: some View {
        switch state {
        case .pending: return AnyView(ProgressView().scaleEffect(0.7))
        case .confirmedExact: return AnyView(Image(systemName: "lock.fill").foregroundStyle(.green))
        case .confirmedFallback: return AnyView(Image(systemName: "lock.shield").foregroundStyle(.orange))
        default: return AnyView(Image(systemName: "xmark.circle.fill").foregroundStyle(.red))
        }
    }

    private var primary: String {
        switch state {
        case .pending: return "Sending…"
        case .confirmedExact(let d, _): return "\(d) locked"
        case .confirmedFallback(let d, _, _): return "\(d) category locked"
        case .failedPermission: return "Permission missing on child device"
        case .failedListNotFound(let n): return "List '\(n)' not found"
        case .failedCategoryNotConfigured(let c): return "Category '\(c)' not configured"
        case .failedTimeout: return "Child device didn't respond"
        case .failedOther(let r): return r
        }
    }

    private var secondary: String? {
        switch state {
        case .confirmedExact(_, let u):
            if let u { return "Unlocks at \(u.formatted(date: .omitted, time: .shortened))" }
            return "Permanent until you unlock"
        case .confirmedFallback(_, _, let orig):
            return "Includes '\(orig)' and other category members"
        default: return nil
        }
    }
}
```

- [ ] **Step 3: In ChatView, render ReceiptCard for messages with receiptState**

In the message loop, check `message.receiptCommandID != nil` and show the card.

- [ ] **Step 4: ChatViewModel polls ack-status and updates state**

In the send handler, after receiving the ChatResponse with a command_id, start a polling Task that hits `/parent/ack-status` every 1s up to 10s, updating the ChatMessage's `receiptState`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(chat): ReceiptCard with pending/confirmed/failed states"
```

### Task 5.2: Settings — Saved Lists + Active Locks + Protection Level

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Home/HomeSettingsSheet.swift`

- [ ] **Step 1: Add sections**

Insert three new sections in the Form:

```swift
Section("Saved Lists") {
    ForEach(savedLists, id: \.self) { name in
        Text(name)
        // trailing: trash button to delete (local + remote)
    }
}

Section("Active Locks (child mode)") {
    ForEach(activeLocks, id: \.id) { lock in
        VStack(alignment: .leading) {
            Text(lock.displayName)
            if let e = lock.expiresAt {
                Text("Until \(e.formatted(date: .omitted, time: .shortened))").font(.caption)
            }
        }
    }
}

Section("Protection Level") {
    HStack {
        Text(protectionMode == "max" ? "Maximum" : "Standard")
        Spacer()
        Button("Reconfigure") { /* re-launch onboarding at ProtectionLevel step */ }
    }
}
```

Load `savedLists = LocalAliasStore.shared.allListNames()` on appear. Load `activeLocks` via `Task { activeLocks = await ActiveLockStore.shared.current() }`.

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Evlin iOS/Views/Home/HomeSettingsSheet.swift"
git commit -m "feat(settings): Saved Lists + Active Locks + Protection Level sections"
```

### Task 5.3: APNs silent push — backend setup

**Files:**
- Modify: `adaptive-engine/backend/app/core/settings.py`
- Create: `adaptive-engine/backend/app/services/apns.py`
- Modify: `adaptive-engine/backend/app/api/routes/parent_chat.py` (call push after Command insert)
- Modify: `adaptive-engine/backend/app/api/routes/child_device.py` (register APNs token)

- [ ] **Step 1: Add APNs settings**

In `settings.py`:
```python
apns_key_id: str = ""
apns_team_id: str = ""
apns_key_path: str = ""
apns_topic: str = "com.evlin.Evlin-iOS"
```

- [ ] **Step 2: Write apns.py using `aioapns` or raw HTTP/2**

```python
from __future__ import annotations
import asyncio, json, time, jwt, httpx
from pathlib import Path
from loguru import logger
from backend.app.core.settings import settings


async def send_silent_push(apns_token: str) -> bool:
    if not settings.apns_key_path:
        logger.warning("APNs not configured; skipping push")
        return False
    token = _make_jwt()
    url = f"https://api.push.apple.com/3/device/{apns_token}"
    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": settings.apns_topic,
        "apns-push-type": "background",
        "apns-priority": "5",
    }
    payload = {"aps": {"content-available": 1}}
    async with httpx.AsyncClient(http2=True, timeout=5) as client:
        resp = await client.post(url, headers=headers, json=payload)
    if resp.status_code != 200:
        logger.warning("APNs response {}: {}", resp.status_code, resp.text)
        return False
    return True


def _make_jwt() -> str:
    key = Path(settings.apns_key_path).read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": settings.apns_team_id, "iat": now},
        key,
        algorithm="ES256",
        headers={"kid": settings.apns_key_id},
    )
```

- [ ] **Step 3: Register APNs token endpoint and wire push on Command insert**

In `child_device.py`:
```python
class RegisterTokenRequest(BaseModel):
    device_id: UUID
    apns_token: str

@router.post("/child/register-apns", tags=["Child Device"])
def register_apns(req: RegisterTokenRequest, session: Session = Depends(get_session)) -> dict:
    dev = session.get(Device, req.device_id)
    if not dev: raise HTTPException(404)
    dev.apns_token = req.apns_token
    session.commit()
    return {"ok": True}
```

In `parent_chat.py`, after `session.commit()` of the Command:
```python
if child.apns_token:
    import asyncio
    from backend.app.services.apns import send_silent_push
    asyncio.create_task(send_silent_push(child.apns_token))
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(apns): silent-push backend wiring"
```

### Task 5.4: APNs — iOS client

**Files:**
- Modify: `Evlin iOS/Evlin iOS/EvlinApp.swift` (AppDelegate hookup)

- [ ] **Step 1: Request notification permission + register for remote notifications**

In the App entry point:

```swift
import UserNotifications

@main
struct EvlinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // ...
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        // POST /child/register-apns if in child mode
        if UserDefaults.standard.string(forKey: "activeMode") == "child",
           let idStr = UserDefaults.standard.string(forKey: "childDeviceID"),
           let deviceID = UUID(uuidString: idStr) {
            Task {
                try? await APIClient().registerAPNsToken(deviceID: deviceID, token: tokenHex)
            }
        }
    }

    func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // Silent push: fetch commands immediately
        if UserDefaults.standard.string(forKey: "activeMode") == "child",
           let idStr = UserDefaults.standard.string(forKey: "childDeviceID"),
           let deviceID = UUID(uuidString: idStr) {
            await CommandPoller.shared.pollOnce(deviceID: deviceID, apiClient: APIClient())
            return .newData
        }
        return .noData
    }
}
```

- [ ] **Step 2: Enable Background Modes → Remote notifications in Signing & Capabilities (both main target and child mode).**

- [ ] **Step 3: Add APIClient method `registerAPNsToken`**

```swift
extension APIClient {
    func registerAPNsToken(deviceID: UUID, token: String) async throws {
        let url = URL(string: "\(baseURL)/child/register-apns")!
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceID.uuidString, "apns_token": token
        ])
        _ = try await URLSession.shared.data(for: req)
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(apns): iOS registration + silent-push wake handler"
```

### Task 5.5: Heartbeat + tamper detection (stub)

**Files:**
- Create: `adaptive-engine/backend/app/api/routes/heartbeat.py`
- Modify: child iOS to POST heartbeat every 10 min via BGAppRefreshTask

- [ ] **Step 1: Backend heartbeat endpoint**

```python
@router.post("/child/heartbeat", tags=["Child Device"])
def heartbeat(device_id: UUID, session: Session = Depends(get_session)) -> dict:
    dev = session.get(Device, device_id)
    if not dev: raise HTTPException(404)
    dev.last_heartbeat = datetime.utcnow()
    session.commit()
    return {"ok": True}
```

- [ ] **Step 2: iOS BGAppRefreshTask posts heartbeat**

Register a task identifier `com.evlin.heartbeat` in Info.plist → Background Modes → BGTaskScheduler Permitted Identifiers. On each run, call `/child/heartbeat?device_id=...`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(heartbeat): child periodic heartbeat stub"
```

---

## Phase gating

- **Phase 0 → Phase 1**: spike notes committed, Max-mode decision recorded.
- **Phase 1 → Phase 2**: manual validation in Task 1.7 passed.
- **Phase 2 → Phase 3**: smoke test in Task 2.9 end-to-end passes.
- **Phase 3 → Phase 4**: manual E2E test in Task 3.4 passes (list locked + auto-unlocks).
- **Phase 4 → Phase 5**: fresh install → complete Std onboarding → Chat lock works end-to-end on a single-device toggle.

---

## Deferred from spec (explicit)

- **Library Expand flow (spec §6.6)** — the `action=expand_library` command type is defined in the models (Task 1.1) and `.expandLibrary` returns `.failed(.execution("expand_library handled in UI"))` in ActionExecutor (Task 1.5). The UI side that presents "Make it precise" and pre-launches the picker on the child device is NOT implemented in this plan. Add a follow-up plan after Phase 5 if that feature is prioritized. The `[Make it precise]` button in ReceiptCard (Task 5.1) is rendered but its action closure is a no-op placeholder until that follow-up.
- **ShieldConfigurationDataSource extension (spec §13)** — separate extension target for custom shield UI. Not in this plan.
- **Recurring time windows (spec §13)** — `DeviceActivitySchedule` with `repeats: true`. Separate spec.

## Remember

- Commit after every green test or passing manual step. Small commits are easier to revert.
- Phase 2/3 require running Postgres locally. Use the existing Railway dev DB or a local Docker Postgres.
- Phase 0 is gating — don't skip it. If the Max-mode spike fails, the Phase 4 Max path must be adapted per spec §2.
- iOS unit tests for `ActionExecutor` and `ActiveLockStore` should use bundleID-only locks (Tier A) since Token types can't be constructed in-process. Integration testing for Tier B/C requires on-device runs.
- When in doubt, re-read the spec — every design decision has a rationale there.
