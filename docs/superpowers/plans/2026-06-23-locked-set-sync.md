# Locked-Set Backend Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bridge the local "Locked set" `FamilyActivitySelection` to the backend as a `ChildCatalogList` named "Locked set" so `lockSelected` finds it and `isEarnedTimeReady` can be satisfied.

**Architecture:** Add `syncLockedSetToBackend(deviceID:apiClient:)` as a free function in a new file `LockedSetBackendSync.swift`; add a `saveLockedSetListAliasKey` / `lockedSetListAliasKey` pair to `EarnedTimeStore` so the upsert path (update vs. create) works across launches; fire the sync (a) from `AppControlsV2View.onSave` and (b) lazily before `lockSelected` in `ProfileView.toggleDeviceLock`.

**Tech Stack:** Swift 5.9 / iOS 16+, FamilyControls, XCTest, `xcodebuild`

## Global Constraints

- Uploaded list name MUST be exactly `DefaultLockGroup.shared.name` → `"Locked set"` (case-sensitive, matches `DEFAULT_LOCK_GROUP_NAME` on the backend via `func.lower()`)
- Backend status is always `"active"` (set by the upload endpoint — client does not send it)
- Members come from `LocalAliasStore.shared.catalogListMembers(for:)` — no new mapping logic
- `createControlList` / `updateControlList` are the ONLY API methods used — no new endpoints
- Do NOT regress `SavedListPickerView`, per-app-limit, `AppControlsV2View` bind/rebind flows
- Build flag required: `ENABLE_USER_SCRIPT_SANDBOXING=NO` (Sentry dSYM script false-fails otherwise)
- Commit message: `fix(ios): sync local "Locked set" → backend ChildCatalogList so lock-selected + earned-time find it`

---

### Task 1: Persist the Locked-set backend list alias key in EarnedTimeStore

**Files:**
- Modify: `Evlin iOS/Services/EarnedTimeStore.swift`
- Test: `Evlin iOSTests/EarnedTimeStoreTests.swift` (add cases; do NOT remove existing tests)

**Interfaces:**
- Produces:
  - `EarnedTimeStore.lockedSetListAliasKey: UUID?` (read)
  - `EarnedTimeStore.saveLockedSetListAliasKey(_ key: UUID)` (write)
  - Key string literal: `"earned.lockedSetListAliasKey"` in the `group.com.evlin.ios` App Group suite

**Why:** `syncLockedSetToBackend` needs to know whether the backend already has a list (upsert: update vs. create). Without persisting the `alias_key` from the first `createControlList` response, every app launch creates a duplicate list.

- [ ] **Step 1: Read EarnedTimeStoreTests to understand existing test pattern**

Run: `cat "/Users/fred/Desktop/Evlin/Evlin iOS/Evlin iOSTests/EarnedTimeStoreTests.swift" | head -60`

Expected: see `setUp`/`tearDown` pattern using `EarnedTimeStore().reset()` or `removeAll`.

- [ ] **Step 2: Write the failing tests**

Open `Evlin iOSTests/EarnedTimeStoreTests.swift`. At the end of the file (before the closing `}`), add:

```swift
// MARK: - Locked-set list alias key (Task: locked-set-sync)

func test_lockedSetListAliasKey_isNilByDefault() {
    let store = EarnedTimeStore()
    XCTAssertNil(store.lockedSetListAliasKey)
}

func test_saveLockedSetListAliasKey_roundTrips() {
    let store = EarnedTimeStore()
    let key = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    store.saveLockedSetListAliasKey(key)
    XCTAssertEqual(store.lockedSetListAliasKey, key)
}

func test_saveLockedSetListAliasKey_overwritesPreviousValue() {
    let store = EarnedTimeStore()
    let key1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let key2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    store.saveLockedSetListAliasKey(key1)
    store.saveLockedSetListAliasKey(key2)
    XCTAssertEqual(store.lockedSetListAliasKey, key2)
}
```

- [ ] **Step 3: Run the tests to confirm they fail**

```bash
xcodebuild test \
  -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_lockedSetListAliasKey_isNilByDefault" \
  ENABLE_USER_SCRIPT_SANDBOXING=NO 2>&1 | tail -20
```

Expected: `error: use of unresolved identifier 'lockedSetListAliasKey'` or compile failure.

- [ ] **Step 4: Implement in EarnedTimeStore**

Open `Evlin iOS/Services/EarnedTimeStore.swift`. Add the key constant under the existing private key declarations (after `lockedSetDataKey`):

```swift
private let lockedSetListAliasKeyKey = "earned.lockedSetListAliasKey"
```

Add the read/write pair after `saveLockedSetID(_:tokenData:)`:

```swift
/// The `alias_key` UUID of the "Locked set" `ChildCatalogList` on the backend.
/// Present once `syncLockedSetToBackend` has successfully created or updated the list.
/// Used by the sync function to upsert (update) rather than create a duplicate list.
var lockedSetListAliasKey: UUID? {
    guard let str = defaults?.string(forKey: lockedSetListAliasKeyKey) else { return nil }
    return UUID(uuidString: str)
}

/// Persist the alias_key returned by `createControlList` / `updateControlList`.
func saveLockedSetListAliasKey(_ key: UUID) {
    defaults?.set(key.uuidString, forKey: lockedSetListAliasKeyKey)
    defaults?.synchronize()
}
```

Also add `lockedSetListAliasKeyKey` to the `reset()` / `removeAll` method so tests stay clean. Find the existing `removeAll` array (contains `measurementKey`, `lockedSetIDKey`, etc.) and append `lockedSetListAliasKeyKey`.

- [ ] **Step 5: Run the tests again — all three should pass**

```bash
xcodebuild test \
  -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_lockedSetListAliasKey_isNilByDefault" \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_saveLockedSetListAliasKey_roundTrips" \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_saveLockedSetListAliasKey_overwritesPreviousValue" \
  ENABLE_USER_SCRIPT_SANDBOXING=NO 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Services/EarnedTimeStore.swift" \
        "Evlin iOSTests/EarnedTimeStoreTests.swift"
git commit -m "feat(earned-time): persist lockedSetListAliasKey for upsert path"
```

---

### Task 2: Add `syncLockedSetToBackend` free function

**Files:**
- Create: `Evlin iOS/Services/LockedSetBackendSync.swift`
- Test: `Evlin iOSTests/LockedSetBackendSyncTests.swift`

**Interfaces:**
- Consumes (Task 1): `EarnedTimeStore.lockedSetListAliasKey: UUID?`, `EarnedTimeStore.saveLockedSetListAliasKey(_ key: UUID)`
- Consumes (existing): `DefaultLockGroupStore.load() -> FamilyActivitySelection`, `LocalAliasStore.shared.catalogListMembers(for:) -> [CatalogListMemberUpload]`, `DefaultLockGroup.shared.name -> "Locked set"`, `APIClient.createControlList(_:deviceID:) async throws -> ControlListDTO`, `APIClient.updateControlList(_:deviceID:) async throws -> ControlListDTO`, `ControlListInput(aliasKey:listName:aliases:members:selectionBlobBase64:)`
- Produces:
  - `syncLockedSetToBackend(deviceID: UUID, apiClient: APIClient) async throws -> ControlListDTO?`
  - Returns `nil` when the local selection is empty (no members to upload); returns the DTO when upload succeeds; throws on network error.

**Semantics:**
1. Load local selection via `DefaultLockGroupStore.load()`
2. Map to members via `LocalAliasStore.shared.catalogListMembers(for: selection)`
3. If members is empty → return nil (nothing to upload; caller should NOT call lockSelected)
4. Build `ControlListInput(aliasKey: EarnedTimeStore.shared.lockedSetListAliasKey, listName: DefaultLockGroup.shared.name, aliases: [DefaultLockGroup.shared.name], members: members, selectionBlobBase64: nil)`
5. If `aliasKey` is nil → `createControlList`; else → `updateControlList`
6. On success → `EarnedTimeStore.shared.saveLockedSetListAliasKey(dto.aliasKey)` → return dto

- [ ] **Step 1: Write the failing test file**

Create `Evlin iOSTests/LockedSetBackendSyncTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

/// Unit tests for `syncLockedSetToBackend` pure-logic contract.
///
/// We cannot test the network path (APIClient is not mockable at this layer)
/// but we CAN test:
///   - empty-selection guard → nil
///   - ControlListInput shape (create vs. update alias_key)
///   - list name is exactly DefaultLockGroup.shared.name
///
/// These tests exercise `LockedSetSyncInputBuilder` — the pure extraction of
/// the "build input from local state" step — which IS unit-testable without mocks.
final class LockedSetBackendSyncTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LocalAliasStore.shared.removeAllAliases()
        EarnedTimeStore.shared.removeAll()
    }

    override func tearDown() {
        LocalAliasStore.shared.removeAllAliases()
        EarnedTimeStore.shared.removeAll()
        super.tearDown()
    }

    func test_buildInput_emptySelection_returnsNil() {
        // No tokens in LocalAliasStore → members will be empty → builder returns nil.
        let selection = FamilyActivitySelection()
        let input = LockedSetSyncInputBuilder.build(
            selection: selection,
            existingAliasKey: nil
        )
        XCTAssertNil(input, "Empty selection must produce nil (nothing to sync)")
    }

    func test_buildInput_withKnownMember_returnsCreateInput() {
        // Seed one app alias so catalogListMembers can find it.
        let appID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        LocalAliasStore.shared.saveCatalogAliasKey(appID, targetType: .app, encodedTokenKey: "app-token-1")

        // Build a FamilyActivitySelection that has that token key.
        // catalogListMembers(applicationTokenKeys:categoryTokenKeys:) takes raw
        // encoded key strings — we call the lower overload directly for test isolation.
        let members = LocalAliasStore.shared.catalogListMembers(
            applicationTokenKeys: ["app-token-1"],
            categoryTokenKeys: []
        )
        XCTAssertEqual(members.count, 1, "Precondition: member found")

        let input = LockedSetSyncInputBuilder.build(
            members: members,
            existingAliasKey: nil
        )
        XCTAssertNotNil(input)
        XCTAssertNil(input?.aliasKey, "Create path: aliasKey must be nil")
        XCTAssertEqual(input?.listName, DefaultLockGroup.shared.name)
        XCTAssertEqual(input?.aliases, [DefaultLockGroup.shared.name])
        XCTAssertNil(input?.selectionBlobBase64)
        XCTAssertEqual(input?.members.count, 1)
    }

    func test_buildInput_withExistingAliasKey_returnsUpdateInput() {
        let appID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let existingKey = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        LocalAliasStore.shared.saveCatalogAliasKey(appID, targetType: .app, encodedTokenKey: "app-token-2")
        let members = LocalAliasStore.shared.catalogListMembers(
            applicationTokenKeys: ["app-token-2"],
            categoryTokenKeys: []
        )

        let input = LockedSetSyncInputBuilder.build(
            members: members,
            existingAliasKey: existingKey
        )
        XCTAssertEqual(input?.aliasKey, existingKey, "Update path: aliasKey must equal existing key")
        XCTAssertEqual(input?.listName, "Locked set")
    }

    func test_listName_isExactlyLockedSet() {
        XCTAssertEqual(
            DefaultLockGroup.shared.name,
            "Locked set",
            "Name must match DEFAULT_LOCK_GROUP_NAME on the backend exactly"
        )
    }
}
```

- [ ] **Step 2: Run to confirm compile failure**

```bash
xcodebuild test \
  -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:"Evlin iOSTests/LockedSetBackendSyncTests" \
  ENABLE_USER_SCRIPT_SANDBOXING=NO 2>&1 | grep -E "error:|LockedSetSync" | head -15
```

Expected: `error: cannot find type 'LockedSetSyncInputBuilder'`

- [ ] **Step 3: Create LockedSetBackendSync.swift**

Create `Evlin iOS/Services/LockedSetBackendSync.swift`:

```swift
import FamilyControls

// MARK: - LockedSetSyncInputBuilder

/// Pure helper that converts a local `FamilyActivitySelection` (or a pre-computed
/// `[CatalogListMemberUpload]`) into a `ControlListInput` for the backend upsert.
///
/// Separated from the network call so it is unit-testable without mocks.
enum LockedSetSyncInputBuilder {

    /// Build from a raw member array. Returns nil when `members` is empty.
    static func build(
        members: [CatalogListMemberUpload],
        existingAliasKey: UUID?
    ) -> ControlListInput? {
        guard !members.isEmpty else { return nil }
        let name = DefaultLockGroup.shared.name
        return ControlListInput(
            aliasKey: existingAliasKey,
            listName: name,
            aliases: [name],
            members: members,
            selectionBlobBase64: nil
        )
    }

    /// Build from a `FamilyActivitySelection`. Returns nil when the selection
    /// maps to zero known members (no aliases recorded yet).
    static func build(
        selection: FamilyActivitySelection,
        existingAliasKey: UUID?
    ) -> ControlListInput? {
        let members = LocalAliasStore.shared.catalogListMembers(for: selection)
        return build(members: members, existingAliasKey: existingAliasKey)
    }
}

// MARK: - syncLockedSetToBackend

/// Uploads the local "Locked set" `FamilyActivitySelection` to the backend as a
/// `ChildCatalogList` named `"Locked set"` (upsert: create on first call, update
/// on subsequent calls using the persisted `alias_key`).
///
/// Returns nil when the local selection is empty (no app/category members have
/// been bound in LocalAliasStore yet). Returns the `ControlListDTO` on success.
/// Throws on network error — callers should not propagate to the user unless
/// the subsequent lock call also fails.
///
/// Thread-safety: `@MainActor` is NOT required; this is a pure async function
/// that only touches `EarnedTimeStore` via its own `defaults` (thread-safe).
/// - Parameters:
///   - deviceID: The child device's backend UUID.
///   - apiClient: The shared `APIClient` instance.
@discardableResult
func syncLockedSetToBackend(
    deviceID: UUID,
    apiClient: APIClient
) async throws -> ControlListDTO? {
    let selection = DefaultLockGroupStore.load()
    let existingAliasKey = EarnedTimeStore.shared.lockedSetListAliasKey
    guard let input = LockedSetSyncInputBuilder.build(
        selection: selection,
        existingAliasKey: existingAliasKey
    ) else {
        return nil
    }

    let dto: ControlListDTO
    if existingAliasKey == nil {
        dto = try await apiClient.createControlList(input, deviceID: deviceID)
    } else {
        dto = try await apiClient.updateControlList(input, deviceID: deviceID)
    }
    EarnedTimeStore.shared.saveLockedSetListAliasKey(dto.aliasKey)
    return dto
}
```

- [ ] **Step 4: Run tests — all should pass**

```bash
xcodebuild test \
  -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:"Evlin iOSTests/LockedSetBackendSyncTests" \
  ENABLE_USER_SCRIPT_SANDBOXING=NO 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` (the `test_buildInput_emptySelection_returnsNil` test does NOT call the `FamilyActivitySelection` overload because there's no real token; `test_listName_isExactlyLockedSet` and the two member-based tests pass without network.)

- [ ] **Step 5: Add the new file to the Xcode project target**

The file must be a member of the `Evlin iOS` app target. Open `Evlin iOS.xcodeproj/project.pbxproj` and add `LockedSetBackendSync.swift` in the same group as `DefaultLockGroupStore.swift`. The easiest way is:

```bash
# Verify the file exists on disk:
ls "/Users/fred/Desktop/Evlin/Evlin iOS/Evlin iOS/Services/LockedSetBackendSync.swift"
```

Then open Xcode → drag the file into the `Services` group in the Project Navigator → check "Add to targets: Evlin iOS". Alternatively, use `xcodebuild` to verify it compiles after a build (Step 6 does this).

- [ ] **Step 6: Verify the build includes the new file**

```bash
xcodebuild build \
  -scheme "Evlin iOS" \
  -configuration Debug \
  -destination 'id=017845D3-83EB-4493-ADED-9F26A536DC09' \
  ENABLE_USER_SCRIPT_SANDBOXING=NO 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **` with no `unresolved identifier 'syncLockedSetToBackend'` errors. If it fails with "file not in target," add the file via Xcode.

- [ ] **Step 7: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Services/LockedSetBackendSync.swift" \
        "Evlin iOSTests/LockedSetBackendSyncTests.swift" \
        "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "feat(ios): add LockedSetSyncInputBuilder + syncLockedSetToBackend"
```

---

### Task 3: Trigger sync from AppControlsV2View on picker save

**Files:**
- Modify: `Evlin iOS/Views/AppControls/AppControlsV2View.swift`

**Interfaces:**
- Consumes (Task 2): `syncLockedSetToBackend(deviceID: UUID, apiClient: APIClient) async throws -> ControlListDTO?`
- Consumes (existing): `@EnvironmentObject var apiClient: APIClient`, `let childDeviceID: UUID`, `onSelectionChanged` callback

**Why:** After the user adds or removes apps in the picker, the local store is updated. We must mirror that to the backend immediately so the lock button works even if the user doesn't tap Lock.

The sync must be:
- Detached / fire-and-forget (non-blocking UI; save+close must be instant)
- Non-user-visible on failure (upload error ≠ App Controls broken; local alias is always saved first per existing comment)
- Idempotent on retry

- [ ] **Step 1: Locate the exact save closure in AppControlsV2View**

The relevant code is in `AppControlsV2View.swift` around line 140:

```swift
onSave: { newSelection in
    DefaultLockGroupStore.save(mergePreservingNamedApps(newSelection))
    reload()
    onSelectionChanged?()
    showPicker = false
},
```

- [ ] **Step 2: Add the detached sync Task after `DefaultLockGroupStore.save`**

Change the closure to:

```swift
onSave: { newSelection in
    DefaultLockGroupStore.save(mergePreservingNamedApps(newSelection))
    reload()
    onSelectionChanged?()
    showPicker = false
    // Sync the updated "Locked set" to the backend so lockSelected finds it.
    // Fire-and-forget: a failure here only means the lock button may
    // need the lazy sync in toggleDeviceLock — it does NOT affect local controls.
    let deviceID = childDeviceID
    let client = apiClient
    Task.detached {
        _ = try? await syncLockedSetToBackend(deviceID: deviceID, apiClient: client)
    }
},
```

- [ ] **Step 3: Build to verify no compiler errors**

```bash
xcodebuild build \
  -scheme "Evlin iOS" \
  -configuration Debug \
  -destination 'id=017845D3-83EB-4493-ADED-9F26A536DC09' \
  ENABLE_USER_SCRIPT_SANDBOXING=NO 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/AppControls/AppControlsV2View.swift"
git commit -m "feat(ios): sync Locked set to backend on App Controls picker save"
```

---

### Task 4: Lazy sync before lockSelected in ProfileView.toggleDeviceLock

**Files:**
- Modify: `Evlin iOS/Views/Profile/ProfileView.swift`

**Interfaces:**
- Consumes (Task 2): `syncLockedSetToBackend(deviceID: UUID, apiClient: APIClient) async throws -> ControlListDTO?`
- Consumes (existing): `backendChildID: UUID?`, `apiClient: APIClient`, `lockSelected`, `isNoLockedSetError`

**Why:** The user may have apps already set locally (from before this fix was deployed) but never uploaded. The lazy sync handles this brownfield case: just before calling `lockSelected`, ensure the list exists on the backend.

**Exact location:** In `toggleDeviceLock()`, after `lockBusy = true`, before the `do { ... } catch { ... }` block that calls `lockSelected`. The `cid` (child device UUID) is already in scope.

- [ ] **Step 1: Read the current toggleDeviceLock body to identify insertion point**

The current `do { }` block (lines ~789–812) starts with:
```swift
do {
    let resp: APIClient.DeviceLockStateResponse
    if wantLocked {
        resp = try await apiClient.lockSelected(familyID: famID, childDeviceID: cid)
```

- [ ] **Step 2: Insert the lazy sync immediately before the `do { }` block**

Before the `do {` (after `lockError = nil` / `lockNote = nil` setup), add:

```swift
// Lazy sync: if the parent is trying to lock and the local "Locked set"
// has members that haven't been uploaded yet, sync them now.
// This handles the brownfield case (apps set before this fix was deployed).
// We sync only when wantLocked because unlocking works regardless of whether
// the backend list exists.
if wantLocked {
    _ = try? await syncLockedSetToBackend(deviceID: cid, apiClient: apiClient)
}
```

The full context after the edit (to orient the diff):

```swift
lockBusy = true
lockError = nil
lockNote = nil
// Lazy sync: if the parent is trying to lock and the local "Locked set"
// has members that haven't been uploaded yet, sync them now.
// This handles the brownfield case (apps set before this fix was deployed).
// We sync only when wantLocked because unlocking works regardless of whether
// the backend list exists.
if wantLocked {
    _ = try? await syncLockedSetToBackend(deviceID: cid, apiClient: apiClient)
}
do {
    let resp: APIClient.DeviceLockStateResponse
    if wantLocked {
        resp = try await apiClient.lockSelected(familyID: famID, childDeviceID: cid)
```

- [ ] **Step 3: Build to verify no compiler errors**

```bash
xcodebuild build \
  -scheme "Evlin iOS" \
  -configuration Debug \
  -destination 'id=017845D3-83EB-4493-ADED-9F26A536DC09' \
  ENABLE_USER_SCRIPT_SANDBOXING=NO 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Profile/ProfileView.swift"
git commit -m "feat(ios): lazy-sync Locked set before lockSelected in toggleDeviceLock"
```

---

### Task 5: Full build + run existing test suite + final commit

**Files:** No new file changes — this is the verification + final-commit task.

- [ ] **Step 1: Run the full app target test suite**

```bash
xcodebuild test \
  -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  ENABLE_USER_SCRIPT_SANDBOXING=NO 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **` — no regressions in existing tests.

- [ ] **Step 2: Run the specific new tests one more time to confirm**

```bash
xcodebuild test \
  -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_lockedSetListAliasKey_isNilByDefault" \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_saveLockedSetListAliasKey_roundTrips" \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_saveLockedSetListAliasKey_overwritesPreviousValue" \
  -only-testing:"Evlin iOSTests/LockedSetBackendSyncTests" \
  ENABLE_USER_SCRIPT_SANDBOXING=NO 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` with 7 tests total.

- [ ] **Step 3: Device build**

```bash
xcodebuild build \
  -scheme "Evlin iOS" \
  -configuration Debug \
  -destination 'id=017845D3-83EB-4493-ADED-9F26A536DC09' \
  ENABLE_USER_SCRIPT_SANDBOXING=NO 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Final commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add -p   # review all changes; nothing unintended
git commit -m "fix(ios): sync local \"Locked set\" → backend ChildCatalogList so lock-selected + earned-time find it"
```

---

## Self-Review

**1. Spec coverage:**
- [x] `syncLockedSetToBackend` reads local selection + maps members → Task 2
- [x] Upsert semantics (create/update) using persisted alias_key → Task 1 + 2
- [x] List name exactly `"Locked set"` → enforced via `DefaultLockGroup.shared.name` constant
- [x] Trigger (a): App Controls save → Task 3
- [x] Trigger (b): lazy before lockSelected → Task 4
- [x] `applyListIDIfNeeded` is already called from lockSelected response in existing code (lines 797, 835, 855) — no change needed
- [x] Backend contract: list name "Locked set" + status active (set by backend) + members with token_available → members come from `catalogListMembers` which only includes items that have been successfully bound (alias saved) → those bindings always have `token_available=true` + `token_data_base64` in the catalog entry since the kid device uploads them via `ChildAppCatalogUploadApp`

**2. Placeholder scan:** None — all steps have exact code.

**3. Type consistency:**
- `ControlListInput` — used in Tasks 2, 3, 4: matches definition at APIClient.swift:1174
- `ControlListDTO.aliasKey: UUID` — matches `CatalogListUploadResponse.aliasKey`
- `EarnedTimeStore.saveLockedSetListAliasKey(_ key: UUID)` — used in Task 2 impl, defined in Task 1
- `LockedSetSyncInputBuilder.build(selection:existingAliasKey:)` and `build(members:existingAliasKey:)` — both overloads defined in Task 2 impl and referenced in Task 2 tests
