# Metering Epoch Phase 0 Completion Report

Date: 2026-07-15

Status: **COMPLETE LOCALLY, NOT DEPLOYED**

Phase 0 is complete on the local `calendar-in-chat` branch. The production
behavior, deterministic Profile fixture, pinned iPhone/iPad snapshots, Release
isolation, focused backend gate, and focused iOS gate have all passed. No
Render deployment or TestFlight upload was performed.

## Production Scope

The Phase 0 production range remains the reviewed range recorded by Task 6:

- iOS: `9df2b6c..bd3ba9d`
- backend: `183457c..62d6ecb`

It provides own-cap device bars, manual-only Profile lock/unlock behavior,
separate automatic-lock explanations/actions, canonical-date earned override,
multi-device earned-source release, and app/NSE ordering that persists the
override marker before removing the earned shield.

## Snapshot Harness

The visual-evidence blocker was closed in a separate, tightly scoped range:

- `f108b02` — DEBUG-only Profile fixture seam
- `72ecd9b` — mounted runtime-effect guard test
- `31d694b` — preserve the production memberwise initializer
- `2e4adae` — pinned renderer, A-F matrix, and 14 baselines
- `0d089cf` — expose complete device bars in the snapshot viewport
- `f2b3f6d` — harden scroll assertions, window teardown, and CGContext lifetime

The fixture initializer and polling injection exist only inside `#if DEBUG`.
The Release executable was checked with both `strings` and `nm`; neither
contained `ProfileSnapshotFixture_v1`.

Pinned visual environment:

- iPhone 17 Pro (`iPhone18,1`), iOS 26.3.1 build 23D8133, 402x874 points
- iPad (A16) (`iPad15,7`), iOS 26.3.1 build 23D8133, 820x1180 points
- `en_US`, light appearance, Dynamic Type AX2

Evidence is committed as 14 PNGs under
`Evlin iOSTests/__Snapshots__/ProfileSnapshotTests/`. The A-F states cover
independent device bars, task pause, earned exhaustion and separate override,
mixed/manual pending state, reflection, and exact-app Profile/sheet rendering.
The test harness writes readable actual/diff/comparison artifacts on failure.

Independent review verdict: approved with no Critical, Important, or Minor
findings after the lifecycle and diff-path hardening commit.

## Fresh Final Gates

- Backend manual-only and earned-override suites: **11 passed, 0 failed**.
- iOS Phase 0 selected suites: **148 passed, 0 failed, 0 skipped** on pinned
  iPhone 17 Pro / iOS 26.3.1.
- Profile iPhone gate: **2 test methods passed, 0 failed**; the methods perform
  seven snapshot comparisons plus the runtime guard.
- Profile iPad gate: **2 test methods passed, 0 failed**; the methods perform
  seven snapshot comparisons plus the runtime guard.
- Release simulator build: `** BUILD SUCCEEDED **`; DEBUG fixture sentinel
  absent from the executable.
- Snapshot range `c2e3b69..f2b3f6d`: `git diff --check` passed; changed paths
  are exactly `ProfileView.swift`, `ProfileSnapshotTests.swift`, and 14 PNGs.
- Agreement/onboarding, `ContentView`, dirty `APIClient`, Xcode user data, and
  debugger files remained outside the staged/committed snapshot range.

Existing Swift 6 actor-isolation warnings remain warnings and did not fail any
gate. The Release build's existing Sentry upload script ran as part of the local
build; this was not an application deployment.

## Task 4 App Group Isolation Classification

Final classification: **historical test-isolation defect/debt, not a product
defect and not a Phase 0 Task 4 regression**.

`ActiveLockStore` intentionally persists through the production App Group so
the app and extensions share one durable lock record set. Older XCTest suites
constructed multiple stores against that same suite and did not always remove
every durable record between suites. Combined test runs could therefore observe
records left by another test. The production architecture requires that shared
suite; the defect is the tests' missing isolation/cleanup seam. It should be
fixed as test infrastructure without changing the product's App Group identity.

## Deployment Gate

Although the Phase 0 spec classifies this phase as independently releasable,
**Render and TestFlight still require Fred's explicit approval**. Neither is
being pushed or uploaded as part of this completion. Phase 1 may proceed
locally on the current branch.
