# Profile Phase 0 Snapshot Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic iPhone/iPad visual regression gate for the six approved Phase 0 Profile states without adding any Release fixture or production runtime mechanism.

**Architecture:** `ProfileView` receives one instance-scoped, DEBUG-only fixture initializer that seeds its existing state and injects a closure that prevents its existing `onAppear` runtime effects. One new XCTest source owns native rendering, fixed-environment assertions, the A-F fixtures, normalized RGBA comparison, readable diff artifacts, and explicit baseline recording. Baselines are committed PNG assets; no dependency, target, scheme, project-file, or production settings change is allowed.

**Tech Stack:** Swift 5, SwiftUI, UIKit, XCTest, Xcode 26.3, iOS Simulator 26.3.1.

## Global Constraints

- Canonical design: `docs/superpowers/specs/2026-07-15-profile-snapshot-harness-design.md`.
- Work only in `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS`; do not create a worktree and do not revert or rewrite existing user changes.
- Source edits are limited to `Evlin iOS/Views/Profile/ProfileView.swift` and the new `Evlin iOSTests/ProfileSnapshotTests.swift`; generated baselines are limited to `Evlin iOSTests/__Snapshots__/ProfileSnapshotTests/**/*.png`.
- Every fixture type, initializer, stored dependency, and fixture branch in `ProfileView.swift` must be enclosed by `#if DEBUG`. `ProfileSnapshotFixture_v1` must be absent from the Release binary.
- Polling/runtime suppression is instance dependency injection. Do not add a global/static switch, UserDefaults/App Group key, launch argument, process-environment read, setting, singleton mode, or production feature flag.
- The normal `ProfileView(child:)` initializer and its Release behavior remain source-compatible.
- Pinned phone: iPhone 17 Pro, `iPhone18,1`, 402 x 874 pt, iOS 26.3.1 build `23D8133`.
- Pinned tablet: iPad (A16), `iPad15,7`, 820 x 1180 pt, iOS 26.3.1 build `23D8133`.
- Pinned presentation: English, locale `en_US`, light appearance, Dynamic Type AX2, animations disabled.
- Recording requires `EVLIN_RECORD_PROFILE_SNAPSHOTS=1` and is rejected outside the pinned environment. Compare mode never updates a baseline.
- A diff failure writes and attaches actual, red heat-map, and expected/actual/diff composite images, and prints their absolute paths.
- Do not touch or stage agreement/onboarding edits, Xcode user data, `ContentView.swift`, unrelated `APIClient.swift` hunks, `.DS_Store`, or debugger files.
- Do not push Render or TestFlight.

---

### Task 1: Add the DEBUG-Only Profile Fixture Seam

**Files:**
- Modify: `Evlin iOS/Views/Profile/ProfileView.swift:53-165,552-644`
- Create: `Evlin iOSTests/ProfileSnapshotTests.swift`

**Interfaces:**
- Consumes: existing `ProfileView` state, `ChildProfile`, `TaskItem`, `DeviceItem`, `RuleItem`, `ManualLockAggregateState`, `APIClient.EarnedSummaryDTO`, `ProfileSubTab`.
- Produces: DEBUG-only `ProfileView.ProfileSnapshotFixture_v1` and `ProfileView.init(snapshotFixture:)`. Release retains only `ProfileView(child:...)`.

- [ ] **Step 1: Record the starting boundary and write the failing compile test**

Run `git status --short` and record the output in the task report. Create `Evlin iOSTests/ProfileSnapshotTests.swift` with a `@MainActor final class ProfileSnapshotTests: XCTestCase` and this initial test:

```swift
import XCTest
import SwiftUI
@testable import Evlin_iOS

@MainActor
final class ProfileSnapshotTests: XCTestCase {
    func test_debugFixtureCanSeedProfileWithoutLiveRuntimeEffects() {
        let fixture = ProfileView.ProfileSnapshotFixture_v1(
            child: .previewLiam,
            tasks: [],
            devices: [],
            rules: ProfileMockData.rules(for: "liam", dailyLimitMinutes: 120),
            dailyLimitMinutes: 120,
            localStatus: .unlocked,
            manualLockState: .unlocked,
            automaticCoveringSources: [],
            earnedSummary: nil,
            profileTab: .overview
        )

        _ = ProfileView(snapshotFixture: fixture)
    }
}
```

- [ ] **Step 2: Prove the test fails for the missing fixture entry**

```bash
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -testLanguage en -testRegion US \
  -only-testing:'Evlin iOSTests/ProfileSnapshotTests/test_debugFixtureCanSeedProfileWithoutLiveRuntimeEffects'
```

Expected: compile failure naming missing `ProfileSnapshotFixture_v1` or `init(snapshotFixture:)`. A failure caused by an unrelated dirty file must be resolved without changing that file.

- [ ] **Step 3: Add the injected DEBUG runtime-effects dependency**

Inside `ProfileView`, add this stored dependency next to the polling state, including the compiler guard:

```swift
#if DEBUG
    /// Instance-only dependency for deterministic visual fixtures. Release does
    /// not compile this path; production never reads a mode flag.
    private var runtimeEffectsAllowed: () -> Bool = { true }
#endif
```

At the first line of the existing `.onAppear` body add:

```swift
#if DEBUG
            guard runtimeEffectsAllowed() else { return }
#endif
```

Do not move, duplicate, or edit the existing live `onAppear` operations below the guard.

- [ ] **Step 4: Add the fixture value and initializer under one DEBUG guard**

In the same file, after `ProfileView` and before helper views, add:

```swift
#if DEBUG
extension ProfileView {
    struct ProfileSnapshotFixture_v1 {
        let child: ChildProfile
        let tasks: [TaskItem]
        let devices: [DeviceItem]
        let rules: [RuleItem]
        let dailyLimitMinutes: Int
        let localStatus: ChildProfile.Status
        let manualLockState: ManualLockAggregateState
        let automaticCoveringSources: [String]
        let earnedSummary: APIClient.EarnedSummaryDTO?
        let profileTab: ProfileSubTab
    }

    init(snapshotFixture fixture: ProfileSnapshotFixture_v1) {
        self.init(child: fixture.child)
        runtimeEffectsAllowed = { false }
        _tasks = State(initialValue: fixture.tasks)
        _devices = State(initialValue: fixture.devices)
        _rules = State(initialValue: fixture.rules)
        _dailyLimitMinutes = State(initialValue: fixture.dailyLimitMinutes)
        _localStatus = State(initialValue: fixture.localStatus)
        _manualLockState = State(initialValue: fixture.manualLockState)
        _automaticCoveringSources = State(initialValue: fixture.automaticCoveringSources)
        _earnedSummary = State(initialValue: fixture.earnedSummary)
        _profileTab = State(initialValue: fixture.profileTab)
    }
}
#endif
```

The initializer deliberately does not seed poll tasks, lock operations, errors, freshness dates, or callbacks. They retain existing inert defaults. If Swift requires the extension to precede a private helper declaration, move only the extension location; do not broaden access control.

- [ ] **Step 5: Run the focused test and both build configurations**

Run the Step 2 test command again. Expected: PASS.

Then run:

```bash
xcodebuild build \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator'

xcodebuild build \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/evlin-profile-snapshot-release
```

Expected: both builds succeed; normal `ProfileView(child:)` call sites remain unchanged.

- [ ] **Step 6: Audit and commit only the seam**

```bash
git diff --check -- \
  'Evlin iOS/Views/Profile/ProfileView.swift' \
  'Evlin iOSTests/ProfileSnapshotTests.swift'
git add -- \
  'Evlin iOS/Views/Profile/ProfileView.swift' \
  'Evlin iOSTests/ProfileSnapshotTests.swift'
git diff --cached --name-only
git diff --cached --check
git commit -m 'test: add debug profile fixture seam'
```

Expected staged names: exactly the two listed files.

---

### Task 2: Add the Pinned Renderer, A-F Matrix, Diffs, and Baselines

**Files:**
- Modify: `Evlin iOSTests/ProfileSnapshotTests.swift`
- Create: `Evlin iOSTests/__Snapshots__/ProfileSnapshotTests/iPhone17Pro-iOS26.3.1-23D8133-en_US-light-AX2/*.png`
- Create: `Evlin iOSTests/__Snapshots__/ProfileSnapshotTests/iPadA16-iOS26.3.1-23D8133-en_US-light-AX2/*.png`

**Interfaces:**
- Consumes: Task 1's DEBUG-only initializer, existing `ParentReflectionFixtureStore`, existing `DeviceAppsSheet(fixtureApps:)`.
- Produces: seven committed visual contracts per form factor and a self-contained XCTest comparator.

- [ ] **Step 1: Replace the smoke test with the pinned environment gate**

Add `UIKit` and `CoreGraphics` imports. Define a test-only environment value with exact accepted destinations:

```swift
private struct SnapshotEnvironment {
    let folder: String
    let deviceName: String
    let modelIdentifier: String
    let logicalSize: CGSize

    static func current(file: StaticString = #filePath, line: UInt = #line) throws -> Self {
        let env = ProcessInfo.processInfo.environment
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(version.majorVersion, 26, file: file, line: line)
        XCTAssertEqual(version.minorVersion, 3, file: file, line: line)
        XCTAssertEqual(version.patchVersion, 1, file: file, line: line)
        XCTAssertTrue(
            ProcessInfo.processInfo.operatingSystemVersionString.contains("23D8133"),
            "Expected iOS build 23D8133",
            file: file,
            line: line
        )
        XCTAssertTrue(Locale.current.identifier.hasPrefix("en_US"), file: file, line: line)

        switch (env["SIMULATOR_DEVICE_NAME"], env["SIMULATOR_MODEL_IDENTIFIER"]) {
        case ("iPhone 17 Pro", "iPhone18,1"):
            return .init(
                folder: "iPhone17Pro-iOS26.3.1-23D8133-en_US-light-AX2",
                deviceName: "iPhone 17 Pro",
                modelIdentifier: "iPhone18,1",
                logicalSize: CGSize(width: 402, height: 874)
            )
        case ("iPad (A16)", "iPad15,7"):
            return .init(
                folder: "iPadA16-iOS26.3.1-23D8133-en_US-light-AX2",
                deviceName: "iPad (A16)",
                modelIdentifier: "iPad15,7",
                logicalSize: CGSize(width: 820, height: 1180)
            )
        default:
            XCTFail("Unpinned snapshot destination: \(env["SIMULATOR_DEVICE_NAME"] ?? "nil") / \(env["SIMULATOR_MODEL_IDENTIFIER"] ?? "nil")", file: file, line: line)
            throw SnapshotFailure.unpinnedEnvironment
        }
    }
}
```

Also assert `UIScreen.main.bounds.size == logicalSize` before rendering. A mismatch is a failure, never `XCTSkip`.

- [ ] **Step 2: Add native fixed-view rendering**

Implement a `@MainActor render<V: View>(_:size:) throws -> UIImage` helper that:

1. wraps the input in `NavigationStack` when the case factory does not already do so;
2. applies `.environment(\.locale, Locale(identifier: "en_US"))`, `.environment(\.dynamicTypeSize, .accessibility2)`, and `.preferredColorScheme(.light)`;
3. injects `APIClient(baseURL: "https://snapshot.invalid")`, `FamilyStore(api:)`, and a supplied `ParentReflectionFixtureStore`;
4. hosts the view in `UIHostingController` and a `UIWindow` at the exact logical size;
5. sets `window.overrideUserInterfaceStyle = .light`, verifies the resulting trait, disables UIKit animations for the render, and restores the prior animation setting with `defer`;
6. performs layout and one main-runloop turn, then renders with `UIGraphicsImageRenderer` at `UIScreen.main.scale` using `window.layer.render(in:)`;
7. hides/releases the window after capture.

Do not launch the Evlin app, read live stores, wait for polling, or use a screenshot package.

- [ ] **Step 3: Add normalized comparison and readable failure artifacts**

Implement these test-only contracts in the same file:

```swift
private struct RGBAImage {
    let width: Int
    let height: Int
    var bytes: [UInt8]
}

private struct SnapshotDiff {
    let changedPixels: Int
    let totalPixels: Int
    let heatMap: UIImage
    var ratio: Double { Double(changedPixels) / Double(totalPixels) }
}
```

Decode expected and actual `CGImage` values into premultiplied-last, byte-order-32-big RGBA buffers. Mark a pixel changed when any channel differs by more than 2. Permit at most `0.0005` changed-pixel ratio; dimensions must match exactly.

`assertSnapshot(named:image:environment:)` must:

- derive the source baseline directory from `#filePath`;
- reject recording unless `SnapshotEnvironment.current()` succeeded;
- when `EVLIN_RECORD_PROFILE_SNAPSHOTS == "1"`, atomically write PNG and return;
- otherwise fail clearly if the baseline is missing;
- on mismatch write `actual.png`, `diff.png`, and `comparison.png` below `/tmp/evlin-profile-snapshot-diffs/<environment>/<name>/`;
- create `XCTAttachment` values for all three artifacts with `.keepAlways` lifetime;
- include changed pixels, ratio, threshold, and absolute artifact paths in `XCTFail`.

The heat map uses opaque red for changed pixels and dim grayscale for unchanged pixels. The composite places expected, actual, and diff left-to-right with visible labels.

- [ ] **Step 4: Build the exact A-F fixture matrix**

Use fixed UUIDs for one child and two devices, nil avatar URLs, static copy, no freshness timestamp, and `ProfileMockData.rules(..., 120)`. Construct device rows through `DeviceItem(dto: EnrolledDeviceDTO(...))` so both rows carry stable UUIDs.

Decode summaries from fixed JSON through `JSONDecoder` so optional wire behavior matches production. Add these cases:

```text
A-independent-bars:
  shared remaining=35, pool=120;
  device A remaining_to_cap=120 cap=120 used=0;
  device B remaining_to_cap=60 cap=60 used=0;
  manual=.unlocked, automatic=[], localStatus=.unlocked.

B-task-pause:
  shared remaining=120, task_pause covers all devices;
  one pending task is visible below;
  manual=.unlocked, localStatus=.locked.

C-earned-exhausted:
  state=exhausted, remaining=0, pool=120, usage_date=2026-07-15,
  automatic=[earned_time], manual=.unlocked, localStatus=.locked.

D-mixed-manual:
  shared remaining=35, manual=.mixed, localStatus=.locked.

E-reflection:
  child id/name match ChildProfile.previewLiam;
  call reflectionStore.simulateAssignment(childId: "liam");
  profileTab=.overview. The reflection card replaces the summary and CTA.

F-exact-app-profile:
  shared remaining=35, manual=.unlocked, no child-wide automatic source.

F-exact-app-sheet:
  one enabled Instagram DeviceAppItem with usedMin=12, limitMin=30,
  stable bundleID and ruleID, supplied through DeviceAppsSheet(fixtureApps:).
```

Snapshot names are exactly:

```text
A-independent-bars.png
B-task-pause.png
C-earned-exhausted.png
D-mixed-manual.png
E-reflection.png
F-exact-app-profile.png
F-exact-app-sheet.png
```

For each Profile case, inject `ProfileView(snapshotFixture:)`. For E, inject the prepared reflection store. For F sheet, use the existing fixture initializer and the same fixed device/child identity. Do not duplicate Profile or DeviceAppsSheet UI in the test.

- [ ] **Step 5: Prove missing baselines fail, then record both pinned sets**

First run compare mode on iPhone. Expected: FAIL with a missing-baseline message and no implicit write.

The XCTest process runs inside the simulator, so a shell-prefixed environment
variable does not reach it. Resolve and boot the two exact simulator UDIDs,
then set the recording variable in each simulator's launchd environment:

```bash
xcrun simctl list devices available 'iOS 26.3.1'
PHONE_UDID='<iPhone 17 Pro UUID from the command above>'
IPAD_UDID='<iPad (A16) UUID from the command above>'

xcrun simctl boot "$PHONE_UDID" || true
xcrun simctl spawn "$PHONE_UDID" launchctl setenv EVLIN_RECORD_PROFILE_SNAPSHOTS 1
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination "platform=iOS Simulator,id=$PHONE_UDID" \
  -parallel-testing-enabled NO \
  -testLanguage en -testRegion US \
  -only-testing:'Evlin iOSTests/ProfileSnapshotTests'
xcrun simctl spawn "$PHONE_UDID" launchctl unsetenv EVLIN_RECORD_PROFILE_SNAPSHOTS

xcrun simctl boot "$IPAD_UDID" || true
xcrun simctl spawn "$IPAD_UDID" launchctl setenv EVLIN_RECORD_PROFILE_SNAPSHOTS 1
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination "platform=iOS Simulator,id=$IPAD_UDID" \
  -parallel-testing-enabled NO \
  -testLanguage en -testRegion US \
  -only-testing:'Evlin iOSTests/ProfileSnapshotTests'
xcrun simctl spawn "$IPAD_UDID" launchctl unsetenv EVLIN_RECORD_PROFILE_SNAPSHOTS
```

Expected: seven PNGs in each exact environment folder. The `unsetenv` commands
are mandatory cleanup. `-parallel-testing-enabled NO` prevents Xcode clone
destinations from changing the exact device name seen by the fixture guard.

- [ ] **Step 6: Prove the diff path, then restore the clean test**

Temporarily mutate one rendered pixel in test memory before comparison for `A-independent-bars`. Run compare mode once. Expected: a failure message naming absolute `actual.png`, `diff.png`, and `comparison.png` paths, with all three attached to the xcresult. Open the composite and confirm the altered pixel is red. Remove the mutation and rerun; do not commit the mutation or `/tmp` artifacts.

- [ ] **Step 7: Run both compare gates twice**

Run both Step 5 `xcodebuild` commands after the simulator environment variable
has been unset, twice each. Keep `-parallel-testing-enabled NO`.

Expected: all 14 comparisons PASS on both consecutive runs, proving the baseline is not timing-dependent and compare mode does not modify baseline mtimes.

- [ ] **Step 8: Inspect all baselines visually**

Create contact sheets for the seven iPhone PNGs and seven iPad PNGs, then inspect them with the local image viewer. Confirm:

- A has two full device bars even though effective labels can show 35 minutes;
- B has green Lock plus task reason, with no overlap at AX2;
- C has green Lock and separate Override today;
- D shows the existing Updating state;
- E replaces summary/CTA with reflection;
- F Profile remains manual-only and F sheet exposes the exact-app limit;
- no text truncation, overlap, blank render, stale loading spinner, or dark appearance.

Any visual defect is a failed gate; fix only within the allowed two source files.

- [ ] **Step 9: Commit the harness and baselines**

```bash
git diff --check -- 'Evlin iOSTests/ProfileSnapshotTests.swift'
git add -- \
  'Evlin iOSTests/ProfileSnapshotTests.swift' \
  'Evlin iOSTests/__Snapshots__/ProfileSnapshotTests'
git diff --cached --name-only
git diff --cached --check
git commit -m 'test: pin profile phase zero snapshots'
```

Expected staged names: the test source and 14 PNGs only.

---

### Task 3: Run the Release, Scope, and Phase 0 Visual Gates

**Files:**
- Verify only: Task 1 and Task 2 paths.

**Interfaces:**
- Consumes: committed DEBUG fixture and visual baselines.
- Produces: evidence for the Phase 0 completion report; no source change.

- [ ] **Step 1: Verify the Release binary has no fixture path**

```bash
rm -rf /tmp/evlin-profile-snapshot-release
xcodebuild build \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/evlin-profile-snapshot-release

APP='/tmp/evlin-profile-snapshot-release/Build/Products/Release-iphonesimulator/Evlin iOS.app/Evlin iOS'
test -x "$APP"
! strings "$APP" | rg 'ProfileSnapshotFixture_v1'
! nm -gj "$APP" 2>/dev/null | rg 'ProfileSnapshotFixture_v1'
```

Expected: Release build succeeds and both absence commands exit zero.

- [ ] **Step 2: Re-run the existing Phase 0 automated gate**

Run the exact backend 11-test gate and iOS 148-test gate recorded in Task 6 of `2026-07-15-metering-epoch-phase-0.md`, then run the two Profile snapshot destinations once more. Expected: backend 11 passed, iOS 148 passed, iPhone 7 snapshots passed, iPad 7 snapshots passed.

- [ ] **Step 3: Audit the exact commit range and dirty worktree**

Let `BASE` be the commit before Task 1 and `HEAD` the Task 2 commit:

```bash
git diff --check "$BASE..$HEAD"
git diff --name-only "$BASE..$HEAD"
git status --short
```

Expected range names:

```text
Evlin iOS/Views/Profile/ProfileView.swift
Evlin iOSTests/ProfileSnapshotTests.swift
Evlin iOSTests/__Snapshots__/ProfileSnapshotTests/<14 PNG files>
```

The pre-existing agreement/onboarding, Xcode user-data, ContentView/APIClient, `.DS_Store`, and debugger changes remain unmodified and unstaged.

- [ ] **Step 4: Record evidence without deploying**

Append the two task commit IDs, test counts, Release sentinel checks, contact-sheet paths, and reviewer verdict to `.superpowers/sdd/progress.md`. Do not push Render, upload TestFlight, alter a deployment setting, or claim Phase 0 deployed. The completion report must state that deployment requires Fred's explicit approval and is not being performed now.

---

## Self-Review

- **Spec coverage:** Release isolation, instance injection, exact destinations, locale/light/AX2, A-F states, 14 baselines, explicit recording, readable diffs, visual inspection, scope hygiene, and no deployment each map to a task step.
- **Placeholder scan:** every code-edit step contains a concrete interface, command, expected result, and acceptance condition.
- **Type consistency:** `ProfileSnapshotFixture_v1` and `init(snapshotFixture:)` are defined in Task 1 and consumed verbatim in Task 2; existing reflection and app-limit fixture seams are reused without new interfaces.
