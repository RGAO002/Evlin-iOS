# Task 6A: Parent Unlock Override Policy

## Scope

Implemented only the pure effective-projection policy and its focused unit
tests. No persistence, command handling, metering, DeviceActivity monitor,
NSE application path, ActiveLockStore integration, routes, or UI behavior was
changed.

## Files

- `Evlin iOS/Services/ParentUnlockOverridePolicy.swift`
- `Evlin iOSTests/ParentUnlockOverrideEnforcementTests.swift`
- `Evlin iOS.xcodeproj/project.pbxproj`

The project membership entry makes the policy available to the Device Activity
Monitor and Push Applier targets for the later integration work. The main app
and unit-test target use synchronized-folder membership.

## Policy Contract

`ParentUnlockOverridePolicy.project(shields:blocks:snapshot:reflectionActive:)`
returns a new effective projection and leaves its inputs untouched.

- Only a non-cancelled `.active` snapshot suppresses enforcement.
- Scope-to-source mapping is explicit: `manual` removes `.manual`,
  `earned_time` removes `.earnedTime`, `task_pause` removes `.taskPause`, and
  both `device_limit` and `per_app_limit` remove `.limit`.
- A record remains in the projection whenever it has any non-covered source,
  including an unknown future source.
- Manual `BlockRecord` effects are absent only while the active override
  includes the manual scope.
- An active Reflection record (`all:reflection:`) remains unmodified when
  `reflectionActive` is true, so its all-app shield remains effective even
  though reflection records carry the historical manual source.
- Cancelled and expired snapshots produce the unmodified shield and block
  projection. Expiry is represented by the durable snapshot status; policy
  evaluation itself has no clock, I/O, SwiftUI dependency, or side effect.

## RED Evidence

Created `ParentUnlockOverrideEnforcementTests.swift` before the policy existed.
The focused simulator run failed with `Cannot find
'ParentUnlockOverridePolicy' in scope` at each projection boundary (exit 65).
The remaining type-inference diagnostics were consequential to that missing
symbol. This confirmed the test fixture compiled against the existing Task 5
types and the only missing boundary was the policy.

## GREEN Evidence

Focused verification command:

```text
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,id=F2A09216-2200-49E5-A10E-A36556A44C16' \
  -only-testing:'Evlin iOSTests/ParentUnlockOverrideEnforcementTests'
```

Result: `TEST SUCCEEDED`, 4 tests, 0 failures.

- `testReflectionRecordAndEffectiveShieldSurviveOverride`
- `testOverrideRemovesManualEarnedTaskAndLimitEffects`
- `testOverrideOnlyFiltersSourcesNamedByItsScopes`
- `testCancelledAndExpiredSnapshotsLeaveProjectionUnchanged`

The test log is `/tmp/evlin-task-6a-focused.log` and the result bundle is
`/Users/fred/Library/Developer/Xcode/DerivedData/Evlin_iOS-geyjpkkjrxcksfdldydaocnxzuys/Logs/Test/Test-Evlin iOS-2026.08.26_09-29-44--0400.xcresult`.

## Deferred Work

Task 6 integration must invoke this policy before ManagedSettings projection
from the main app, NSE, and Device Activity Monitor paths. That work is
intentionally excluded from this subtask.

## Review Fix: Coverage Additions

Added test-only coverage for the Task 6A review findings. Production policy,
Task 6B integration, and metering were not changed.

- `testNoSnapshotLeavesProjectionUnchanged` proves `snapshot: nil` returns the
  original shields and blocks.
- `testOverrideFiltersEachScopeIndependently` covers `manual`, `earned_time`,
  `task_pause`, `device_limit`, and `per_app_limit` independently. The latter
  two each verify suppression of the shared `.limit` source.
- `testEarnedTimeSuppressionDoesNotRequireManualSource` proves a covered
  earned-time source is removed when the record has no manual source and a
  task-pause source remains.

Focused verification command:

```text
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,id=F2A09216-2200-49E5-A10E-A36556A44C16' \
  -only-testing:'Evlin iOSTests/ParentUnlockOverrideEnforcementTests'
```

Output:

```text
** TEST SUCCEEDED **

Test suite 'ParentUnlockOverrideEnforcementTests' started
Test case 'testCancelledAndExpiredSnapshotsLeaveProjectionUnchanged' passed
Test case 'testEarnedTimeSuppressionDoesNotRequireManualSource' passed
Test case 'testNoSnapshotLeavesProjectionUnchanged' passed
Test case 'testOverrideFiltersEachScopeIndependently' passed
Test case 'testOverrideRemovesManualEarnedTaskAndLimitEffects' passed
Test case 'testReflectionRecordAndEffectiveShieldSurviveOverride' passed
```

Result: 6 tests, 0 failures. Full command output is
`/tmp/evlin-task-6a-review-fix.log`; result bundle is
`/Users/fred/Library/Developer/Xcode/DerivedData/Evlin_iOS-geyjpkkjrxcksfdldydaocnxzuys/Logs/Test/Test-Evlin iOS-2026.08.26_09-38-20--0400.xcresult`.
