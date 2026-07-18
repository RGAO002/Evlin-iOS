# Phase 3 Task 10 Implementation Report

## Scope

Implemented dated route installation arbitration and verification. The user-approved integration-blocker expansion also changes `MeteringEpochDelivery.swift` and `MeteringEpochDeliveryTests.swift`: registration 200 now accepts planned routes, persists registration, terminalizes registration work, preserves the v1 selection, and promotes matching pending install authorization to `registered` without activating the route.

## TDD Evidence

- RED: `MeteringEpochDeliveryTests/testRegistration200PromotesPlannedRouteInstallWithoutActivatingRoute` executed 1 test with 3 expected assertion failures: registration work remained pending, `registeredAt` was nil, and install authorization remained `registrationRequired`. Log: `/tmp/evlin-task10-registration-red.log`.
- GREEN: the planned-registration test and authentic delivery-to-installer integration test executed 2 tests with 0 failures. Log: `/tmp/evlin-task10-registration-green.log`.
- RED: `DatedRouteInstallerTests/testInstallCASRefusesExpiredClaim` executed 1 test with 4 expected assertion failures. Log: `/tmp/evlin-task10-expired-cas-red.log`.
- GREEN: the expired-CAS regression executed 1 test with 0 failures. Log: `/tmp/evlin-task10-expired-cas-green.log`.

## Verification

- `SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild ... -scheme 'Evlin iOS' ... build-for-testing` succeeded after final changes. Log: `/tmp/evlin-task10-build-for-testing-final2.log`.
- Unsigned `EvlinDeviceActivityMonitor` Debug iphoneos build succeeded with `CODE_SIGNING_ALLOWED=NO` and `SENTRY_SKIP_DSYM_UPLOAD=1`.
- Unsigned `EvlinPushApplier` Debug iphoneos build succeeded with the same settings. `DatedRouteInstaller.swift` is in the App/DAM synchronized-target exception set only; it is absent from Push.

## Residual Limitation

The pinned iPhone 17 Pro iOS 26.3.1 XCTest runner reproducibly aborts with `malloc: pointer being freed was not allocated` while starting the isolated dated crash-boundary test. Exact command:

```sh
SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO -only-testing:'Evlin iOSTests/DatedRouteInstallerTests/testCrashAfterClaimResumesWithOneStart' test
```

The failure is recorded in `/tmp/evlin-task10-crash-after-claim-reboot.log`; rebooting the simulator did not change it. Per task direction, no broad historical suite or further unbounded retries were run. The crash-envelope tests remain in place and compile in the successful build-for-testing run.

## Review Fix

### Scope

- `Evlin iOS/Services/DatedRouteInstaller.swift`
- `Evlin iOS/Services/DeviceEpochStore.swift`
- `Evlin iOS/Services/MeteringEpochDelivery.swift`
- `Evlin iOSTests/DatedRouteInstallerTests.swift`
- `Evlin iOSTests/MeteringEpochDeliveryTests.swift`

### RED

- `SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO -only-testing:'Evlin iOSTests/DatedRouteInstallerTests/testDeferredInstallCASRefusesExpiredClaimAndInstallerReportsClaimLost' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests/testWarningTimeMismatchReplacesCandidateWithoutStoppingPriorMonitor' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests/testExcessiveActivitiesCoverageUsesEligibleCanonicalDatesAndStopsAfterFirstFailure' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests/testConfigurationFailureDefersInstallAndClearsOwnedClaim' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests/testPlannedRegistrationConflictRetryAndTerminalResponsesClearClaims' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests/testRegistration200DoesNotPromoteInstallForRetiredOrTombstonedRoute' test` recorded the expired-defer regression as expected: the stale claimant deferred `excessiveActivities` and reset to `pendingStart` instead of reporting `claimLost`. Log: `/tmp/evlin-task10-review-red.log`.

### GREEN / Build Evidence

- The matching bounded runner invocation was attempted once after the fixes. It compiled but the pinned simulator reproducibly aborted with `malloc: pointer being freed was not allocated` after beginning the dated installer tests; it did not provide a complete runtime GREEN. Log: `/tmp/evlin-task10-review-green.log`.
- `SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO build-for-testing` completed with `** TEST BUILD SUCCEEDED **`. Log: `/tmp/evlin-task10-review-build-for-testing-final.log`.
- Unsigned iOS 17.6 DAM build completed with `** BUILD SUCCEEDED **`: `/tmp/evlin-task10-review-dam-build.log`.
- Unsigned iOS 17.6 Push build completed with `** BUILD SUCCEEDED **`: `/tmp/evlin-task10-review-push-build.log`.

### Covered Fixes

- Planned registration now treats planned/active routes consistently across registration success, authoritative-base conflict, terminal, and retry responses; retired, tombstoned, missing, and mismatched route provenance is superseded with its claim cleared.
- `installLimited` coverage is recalculated from the current eligible canonical horizon and accepts any verified, dual-active, or active install for each date; the test includes a stale coverage record, tombstoned route, and retired duplicate generation.
- Configuration construction failures defer through the install retry policy and clear the owned claim. Exact daemon comparison includes `warningTime`. Deferred install mutations reject expired claims and the installer reports `claimLost`.

## Review Fix Round 2 Evidence

### Scope

Registration and install work now share a current-provenance predicate: route/epoch/owner coherence, planned-or-active lifecycle, an unretired generation, and either the active generation or the exact durable V2 handoff candidate. The predicate permits Task 11's `.preparing`, `.dualV2`, and `.cutoverReady` candidate while the prior route remains active.

Installer arbitration now supersedes stale install work before Apple start, keeps an observed `excessiveActivities` stop-filling signal even when the defer CAS loses at lease expiry, limits coverage calculation to the failed generation's eligible canonical horizon, and validates persisted event plans before event construction. Registration 409 conflicts with mismatched authoritative owner/date snapshots terminalize as `snapshot_mismatch` with their claim cleared.

### TDD Evidence

- RED dated-installer regression bundle: `testRetiredOrNonCandidateInstallWorkIsSupersededWithoutStartingApple` was added and compiled by the command below, but the iPhone 17 Pro 26.3.1 runner ended before XCTest output, consistent with the documented malloc/restart boundary. No repeat was made. Log: `/tmp/evlin-task10-r2-dated-red.log`.
- RED delivery regression command was started for `testDelayedRegistration200SupersedesRetiredOrNoLongerCandidateGeneration` and terminated on explicit operator instruction when two overlapping owned `xcodebuild` processes were found. It produced no assertion result. Log: `/tmp/evlin-task10-r2-delivery-red.log`.
- GREEN: the final build-for-testing succeeded, then `testDelayedRegistration200SupersedesRetiredOrNoLongerCandidateGeneration`, `testRegistration200AcceptsExactPreparingHandoffCandidateWhilePriorRouteIsActive`, and `testAuthoritativeBaseMismatchWithMismatchedSnapshotTerminalizesImmediately` executed separately with `test-without-building`; all 3 passed on iPhone 17 Pro 26.3.1. XCTest result: `/Users/fred/Library/Developer/Xcode/DerivedData/Evlin_iOS-fudwpoudhduvkfducxcstdyqummi/Logs/Test/Test-Evlin iOS-2026.07.18_04-25-23--0400.xcresult`. Log: `/tmp/evlin-task10-r2-delivery-green.log`.
- One bounded dated GREEN attempt covered stale install, pre-cutover candidate, lease-expiry stop-filling, stale R1/R2 coverage, and malformed persisted event-plan regressions. The runner ended before XCTest output or a result bundle; it was not repeated. Log: `/tmp/evlin-task10-r2-dated-green.log`.

### Build Evidence

- `SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,id=F2A09216-2200-49E5-A10E-A36556A44C16' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build-for-testing` succeeded. Log: `/tmp/evlin-task10-r2-build-for-testing.log`.
- The final post-provenance-hardening `build-for-testing` succeeded with the same pinned destination. Log: `/tmp/evlin-task10-r2-build-for-testing-final.log`.
- Unsigned `EvlinDeviceActivityMonitor` Debug iphoneos build with `CODE_SIGNING_ALLOWED=NO` succeeded. Log: `/tmp/evlin-task10-r2-dam-unsigned.log`.
- Unsigned `EvlinPushApplier` Debug iphoneos build with `CODE_SIGNING_ALLOWED=NO` succeeded. Log: `/tmp/evlin-task10-r2-push-unsigned.log`.
