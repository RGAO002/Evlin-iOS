# Per-App Limit Midnight Rollover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep recurring per-app limits counting and enforcing after canonical midnight without requiring the child main app to reopen.

**Architecture:** The existing Apple monitor remains stable. Its DAM
`intervalDidStart` callback advances a persisted per-app accounting interval,
while effect-journal keys add canonical date identity so equal thresholds on
different days do not collide.

**Tech Stack:** Swift, DeviceActivity, ManagedSettings, App Group durable JSON,
XCTest, Xcode 26.

## Global Constraints

- Change only per-app rollover state, per-app effect identity, DAM v2 interval
  routing, and focused tests.
- Never call `startMonitoring` from DAM or NSE for this repair.
- Never modify earned Total Pool or Device Limit behavior.
- Preserve all non-limit shield sources.
- Preserve the two existing unrelated `xcuserdata` worktree changes.
- No push, deployment, TestFlight upload, or production-data mutation.

---

### Task 1: Pin Daily Provenance And Effect Identity

**Files:**
- Modify: `Evlin iOS/Services/AppLimitEpochTypes.swift`
- Modify: `Evlin iOS/Services/AppLimitProvenance.swift`
- Modify: `Evlin iOS/Services/AppLimitEffectJournal.swift`
- Test: `Evlin iOSTests/AppLimitMidnightRolloverTests.swift`

**Interfaces:**
- Produces:
  `AppLimitProvenanceStore.rolloverRecurringInterval(activityName:now:)`
- Produces an enum result with `rolledOver`, `unchanged`, and fail-closed
  rejection cases.
- `AppLimitEffectKey` gains optional `usageDate`; new production callbacks
  always supply it, while legacy nil keys retain their previous storage text.

- [ ] **Step 1: Write RED tests**

Add tests that seed a recurring Facebook rule on day D and assert:

```swift
let result = try provenanceStore.rolloverRecurringInterval(
    activityName: provenance.activityName,
    now: dayDPlusOne
)
XCTAssertEqual(result, .rolledOver(from: "2026-07-25", to: "2026-07-26"))
```

Assert the stored provenance keeps `armID` and `activityName`, advances
`usageDate`, sets `startedAt` to the callback time, resets base/raw/ignored,
preserves `pausedAt`, and clears `authoritativeUsedTodayMinutes`.

Add a second test proving D:t5 and D+1:t5 produce unequal storage keys while a
decoded legacy nil-date key keeps the old storage format.

- [ ] **Step 2: Run RED**

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:'Evlin iOSTests/AppLimitMidnightRolloverTests'
```

Expected: compile failure because the rollover interface and dated effect key
do not exist.

- [ ] **Step 3: Implement the minimal transition**

Resolve by exact activity name inside `AppLimitEpochStore.transaction`, validate
the current set slot and canonical timezone, reject non-recurring/backward
movement, and replace only the day-scoped provenance fields. Do not invoke a
scheduler.

Include `callback.provenance.usageDate` when constructing
`AppLimitEffectKey`. Preserve the legacy storage format when the key date is
nil.

- [ ] **Step 4: Run GREEN and focused regressions**

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:'Evlin iOSTests/AppLimitMidnightRolloverTests' \
  -only-testing:'Evlin iOSTests/AppLimitCallbackValidatorTests' \
  -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' \
  -only-testing:'Evlin iOSTests/AppLimitPlannerTests' \
  -only-testing:'Evlin iOSTests/AppLimitPauseResumeTests'
```

Expected: all selected suites pass.

### Task 2: Route V2 Midnight Through DAM

**Files:**
- Modify: `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `Evlin iOSTests/AppLimitMidnightRolloverTests.swift`

**Interfaces:**
- Consumes:
  `AppLimitProvenanceStore.rolloverRecurringInterval(activityName:now:)`
- Reuses existing `resetLimitShields(activity:)`.

- [ ] **Step 1: Write RED entry-routing tests**

Assert a v2 activity start:

```swift
"evlin.limit.v2.<uuid>"
```

is classified as per-app recurring rollover, while earned-v2, heartbeat, and
legacy limit names retain their existing owners. Assert rollover runs before
limit-only reset and no scheduler operation is requested.

- [ ] **Step 2: Run RED**

Run the Task 1 command plus the extension routing test. Expected: v2 activity
has no `intervalDidStart` branch.

- [ ] **Step 3: Add the v2 branch**

Before the legacy `evlin.limit.window.` branch, recognize
`evlin.limit.v2.`. Call the rollover transition with `Date()`. On
`rolledOver` or `unchanged`, call `resetLimitShields(activity:)`; on rejection
or error, record diagnostics and fail closed without removing shields.

- [ ] **Step 4: Verify**

```bash
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:'Evlin iOSTests/AppLimitMidnightRolloverTests' \
  -only-testing:'Evlin iOSTests/AppLimitCallbackValidatorTests' \
  -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests' \
  -only-testing:'Evlin iOSTests/AppLimitPlannerTests' \
  -only-testing:'Evlin iOSTests/AppLimitPauseResumeTests' \
  -only-testing:'Evlin iOSTests/LimitResetPolicyTests'
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -configuration Debug -destination 'generic/platform=iOS'
```

Expected: all selected tests and the device build pass.

- [ ] **Step 5: Review the final diff**

```bash
git diff --check
git diff --name-only
git diff -- \
  'Evlin iOS/Services/AppLimitEpochTypes.swift' \
  'Evlin iOS/Services/AppLimitProvenance.swift' \
  'Evlin iOS/Services/AppLimitEffectJournal.swift' \
  'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' \
  'Evlin iOSTests/AppLimitMidnightRolloverTests.swift'
```

Confirm no earned implementation, backend file, beta-agreement file, or
`xcuserdata` file is included.
