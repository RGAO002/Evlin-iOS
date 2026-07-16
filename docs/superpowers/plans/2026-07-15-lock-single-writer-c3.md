# Lock Single-Writer C-3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close conflict C-3 so reflection playback and Home settings locks are represented as durable `ActiveLockStore` records, then remove the two dead direct-write methods.

**Architecture:** `ActiveLockStore` remains the only main-app writer of ManagedSettings shield/block fields. Reflection web access becomes backward-compatible `ShieldRecord.webOpen` state consumed by the store's full-union projection; Home settings owns one stable manual saved-list record and removes only that record. A source-level architecture test prevents the three bypasses from returning.

**Tech Stack:** Swift 5, SwiftUI, FamilyControls, ManagedSettings, XCTest, existing `ActiveLockStore` App Group persistence.

## Global Constraints

- This plan implements rule-book C-3/R-2 and D-2 only; it does not change metering, epoch, override, task, reflection lifecycle, or backend behavior.
- Execute as an independent small work item before Phase 6; it is a Phase 6 prerequisite, not part of Phase 1.
- Preserve wire and persisted-record compatibility. Missing `webOpen` decodes as `false`; existing records must not be discarded.
- `ActiveLockStore` is the only main-app type allowed to assign `ManagedSettingsStore.shield` or `.application.blockedApplications`.
- The Home unlock action removes only the Home settings manual record. It must not call `unshieldAll`, remove automatic sources, clear blocks, change an override, or change accounting.
- Do not add a global flag or a second store. Any new guard must satisfy rule-book §11/R-16 before implementation.
- Do not touch agreement/onboarding/APIClient user changes. Stage exact paths and inspect `git diff --cached` before each commit.
- Do not deploy Render or upload TestFlight without Fred's explicit approval.

---

### Task 1: Make Reflection Web Access Record-Driven

**Files:**
- Modify: `Evlin iOS/Models/ShieldRecord.swift`
- Modify: `Evlin iOS/Services/ActiveLockStore.swift`
- Modify: `Evlin iOS/Services/ReflectionLockApplier.swift`
- Modify: `Evlin iOS/Views/Child/BigKid/Reflection/BigKidVideoView.swift`
- Modify: `Evlin iOSTests/ShieldRecordNormalizationTests.swift`
- Modify: `Evlin iOSTests/ReflectionLockApplierTests.swift`
- Modify: `Evlin iOSTests/ReflectionVideoWebAccessTests.swift`
- Modify: `Evlin iOSTests/ActiveLockStoreTests.swift`

**Interfaces:**
- Produces: `ShieldRecord.webOpen: Bool` with a decode default of `false`.
- Produces: reflection records from `ReflectionLockRecordFactory.make(...)` with `webOpen == true`.
- Removes: `ReflectionVideoWebAccess.allowPlaybackInEmbeddedWebView()` and both call sites.

- [ ] **Step 1: Add failing compatibility and projection tests**

Add tests that pin all four rules:

```swift
func test_missing_webOpen_decodes_false() throws {
    let decoded = try decodeLegacyRecordWithoutWebOpen()
    XCTAssertFalse(decoded.webOpen)
}

func test_reflection_factory_requests_web_open() {
    let record = ReflectionLockRecordFactory.make(
        rid: UUID(), expiresAt: Date(timeIntervalSince1970: 2_000), childID: UUID()
    )
    XCTAssertTrue(record.webOpen)
    XCTAssertEqual(record.tier, .allApps)
}

func test_webOpen_broad_record_wins_only_for_web_projection() {
    let projection = ActiveShieldProjection.make(records: [parentAll, reflectionWebOpen])
    XCTAssertEqual(projection.applications, .all)
    XCTAssertEqual(projection.webDomains, .open)
}

func test_video_source_has_no_direct_managed_settings_write() throws {
    let source = try sourceText("Evlin iOS/Views/Child/BigKid/Reflection/BigKidVideoView.swift")
    XCTAssertFalse(source.contains("ManagedSettingsStore()"))
    XCTAssertFalse(source.contains("allowPlaybackInEmbeddedWebView"))
}
```

`ActiveShieldProjection` is a small internal pure value used by
`recomputeAndApply`; define its app mode as `.all`/`.specific`/`.open` and web
mode as `.all`/`.specific`/`.open`. The test helper resolves repository paths
from `#filePath`, never from the process working directory.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/ShieldRecordNormalizationTests' \
  -only-testing:'Evlin iOSTests/ReflectionLockApplierTests' \
  -only-testing:'Evlin iOSTests/ReflectionVideoWebAccessTests' \
  -only-testing:'Evlin iOSTests/ActiveLockStoreTests'
```

Expected: failures for missing `webOpen`/projection and the existing direct
writer. Existing unrelated assertions remain green.

- [ ] **Step 3: Add backward-compatible record state**

Add `var webOpen: Bool = false` to `ShieldRecord`; add it to `CodingKeys`, encode
it, and decode it with:

```swift
webOpen: try c.decodeIfPresent(Bool.self, forKey: .webOpen) ?? false
```

Preserve the memberwise initializer and pass `webOpen` through every in-file
normalization/re-key copy. Set `webOpen: true` in
`ReflectionLockRecordFactory.make(...)`.

- [ ] **Step 4: Centralize the full-union projection**

Extract the current broad/token union calculation into the pure
`ActiveShieldProjection.make(records:)`. Its precedence is:

```text
applications: any appliesToAll -> all; otherwise union app/category tokens
web: any broad webOpen -> open; else any broad tier .all -> all;
     otherwise union web tokens (empty union -> open)
```

Make `recomputeAndApply()` apply that projection and remain the only writer.
This changes no app shielding: reflection still locks all applications, but its
record explicitly requests the web opening needed by the embedded video.

- [ ] **Step 5: Delete the reflection direct writer**

Remove `ManagedSettings` import, `allowPlaybackInEmbeddedWebView()`, its
diagnostic write, the `.onAppear` call, and the `VideoEmbedView.load` call.
Keep `ReflectionVideoWebAccess.embedURL(...)` unchanged.

- [ ] **Step 6: Run GREEN and compatibility controls**

Run the Step 2 command twice. Then run:

```bash
rg -n 'ManagedSettingsStore\(\)|allowPlaybackInEmbeddedWebView' \
  'Evlin iOS/Views/Child/BigKid/Reflection/BigKidVideoView.swift'
```

Expected: all focused tests pass twice; `rg` exits 1 with no matches.

- [ ] **Step 7: Commit exact files**

```bash
git add -- 'Evlin iOS/Models/ShieldRecord.swift' \
  'Evlin iOS/Services/ActiveLockStore.swift' \
  'Evlin iOS/Services/ReflectionLockApplier.swift' \
  'Evlin iOS/Views/Child/BigKid/Reflection/BigKidVideoView.swift' \
  'Evlin iOSTests/ShieldRecordNormalizationTests.swift' \
  'Evlin iOSTests/ReflectionLockApplierTests.swift' \
  'Evlin iOSTests/ReflectionVideoWebAccessTests.swift' \
  'Evlin iOSTests/ActiveLockStoreTests.swift'
git diff --cached --check
git diff --cached --name-only
git commit -m 'fix: route reflection web access through lock records'
```

---

### Task 2: Route Both Home Settings Buttons Through One Manual Record

**Files:**
- Create: `Evlin iOS/Services/HomeSettingsLockRouting.swift`
- Modify: `Evlin iOS/Views/Home/HomeSettingsSheet.swift`
- Create: `Evlin iOSTests/HomeSettingsLockRoutingTests.swift`

**Interfaces:**
- Produces: `HomeSettingsLockRouting.recordKey == "savedList:home-settings-selected"`.
- Produces: `makeRecord(selection:childID:issuedAt:commandID:) -> ShieldRecord?`.
- Produces: `lock(selection:childID:store:) async -> Bool` and
  `unlock(store:) async -> Bool`, both injectable with `ActiveLockStore`.

- [ ] **Step 1: Write failing routing and architecture tests**

Pin that an empty selection returns nil; a constructed record has `.savedList`,
the stable key, `.manual` only, and `webOpen == false`; unlock removes only the
stable Home record while a fixture automatic record remains. Also read
`HomeSettingsSheet.swift` from `#filePath` and assert it contains neither
`screenTimeManager.shieldApps()` nor `screenTimeManager.clearAllShields()`.

- [ ] **Step 2: Run the new suite and verify RED**

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -parallel-testing-enabled NO \
  -only-testing:'Evlin iOSTests/HomeSettingsLockRoutingTests'
```

Expected: compile/test failure because the router does not exist and the old
button calls are still present.

- [ ] **Step 3: Implement the stable manual record router**

`makeRecord` copies the selected app/category/web token sets, rejects a fully
empty selection, sets `appliesToAll=false`, `sources=[.manual]`,
`targetChildID=childID`, and uses the exact stable target key
`home-settings-selected`. `lock` uses `store.addShield(record, force: true)`;
`unlock` uses only `store.removeShield(recordKey: recordKey)`.

- [ ] **Step 4: Replace the two button actions**

The Lock button parses the existing `childDeviceID`, then calls the router in a
`Task`. The Unlock button calls only the router's `unlock`. Include web-domain
tokens in the visible selection count. Rename the second label to
`Unlock Selected Apps` so it does not promise removal of automatic locks or
blocks. Post the existing lock-state notification only after the awaited record
mutation completes.

- [ ] **Step 5: Run focused and overlap tests**

Run the Step 2 command plus `ActiveLockStoreTests` and
`CommandProvenanceTests`. Expected: all pass; the overlap test proves an earned,
task, reflection, or limit record survives Home unlock.

- [ ] **Step 6: Commit exact files**

```bash
git add -- 'Evlin iOS/Services/HomeSettingsLockRouting.swift' \
  'Evlin iOS/Views/Home/HomeSettingsSheet.swift' \
  'Evlin iOSTests/HomeSettingsLockRoutingTests.swift'
git diff --cached --check
git diff --cached --name-only
git commit -m 'fix: route home lock controls through records'
```

---

### Task 3: Remove Dead Direct-Write APIs and Close C-3

**Files:**
- Modify: `Evlin iOS/Services/ScreenTimeManager.swift`
- Modify: `Evlin iOSTests/HomeSettingsLockRoutingTests.swift`
- Create: `docs/superpowers/reports/2026-07-15-lock-single-writer-c3-completion.md`

**Interfaces:**
- Removes: `ScreenTimeManager.shieldAllApps()`.
- Removes: `ScreenTimeManager.unshieldApps(forMinutes:)`.
- Preserves: selection/authorization APIs and any debug-only reset behavior not
  named by C-3.

- [ ] **Step 1: Add the failing dead-API architecture assertion**

Extend the source guard to assert `ScreenTimeManager.swift` contains neither
`func shieldAllApps(` nor `func unshieldApps(`. Run it and verify RED on the two
current definitions.

- [ ] **Step 2: Reconfirm zero callers**

```bash
rg -n '\.shieldAllApps\(|\.unshieldApps\(|shieldAllApps\(|unshieldApps\(' \
  --glob '*.swift' .
```

Expected before deletion: exactly the two definitions in
`ScreenTimeManager.swift`, with no executable caller.

- [ ] **Step 3: Delete the two methods**

Remove only `shieldAllApps()` and `unshieldApps(forMinutes:)`. Do not delete
`shieldApps`, `clearAllShields`, selection persistence, deletion protection, or
authorization code in this task.

- [ ] **Step 4: Run final functional and architecture gates**

Run Task 1 and Task 2 focused suites, then:

```bash
rg -n 'ManagedSettingsStore\(\)|allowPlaybackInEmbeddedWebView' \
  'Evlin iOS/Views/Child/BigKid/Reflection/BigKidVideoView.swift'
rg -n 'screenTimeManager\.(shieldApps|clearAllShields)\(' \
  'Evlin iOS/Views/Home/HomeSettingsSheet.swift'
rg -n '\.shieldAllApps\(|\.unshieldApps\(|shieldAllApps\(|unshieldApps\(' \
  --glob '*.swift' .
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -configuration Release -destination 'generic/platform=iOS Simulator'
```

Expected: all tests and Release build pass; all three `rg` commands exit 1 with
no matches.

- [ ] **Step 5: Record the R-2 closure evidence**

The completion report lists the three removed bypasses, tests proving record
overlap preservation, the Release build result, and a repository-wide
ManagedSettings writer inventory. Any remaining intentional writer outside
`ActiveLockStore` must be identified by target/process ownership; an unexplained
main-app writer fails C-3.

- [ ] **Step 6: Commit and review**

```bash
git add -- 'Evlin iOS/Services/ScreenTimeManager.swift' \
  'Evlin iOSTests/HomeSettingsLockRoutingTests.swift' \
  'docs/superpowers/reports/2026-07-15-lock-single-writer-c3-completion.md'
git diff --cached --check
git diff --cached --name-only
git commit -m 'refactor: remove dead screen time shield writers'
```

Request independent spec and quality reviews. Do not deploy.

## Self-Review

- **Spec coverage:** reflection direct writer, both Home buttons, and both dead
  methods map one-to-one to Tasks 1-3; overlap and backward compatibility are
  explicit gates.
- **Placeholder scan:** all edits, interfaces, commands, expected failures, and
  acceptance results are specified; no implementation placeholder remains.
- **Type consistency:** `webOpen`, `ActiveShieldProjection`, the stable Home
  record key, and router method names are defined once and consumed consistently.
