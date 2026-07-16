# Profile Phase 0 Snapshot Harness Design

**Date:** 2026-07-15

**Status:** Approved by Fred on 2026-07-15. This document records the approved harness boundary; it does not reopen Phase 0 product behavior.

## Goal

Turn the six Phase 0 Profile acceptance states into a deterministic visual gate on the pinned iPhone and iPad simulators, without adding a production fixture, polling switch, networking mode, or runtime mechanism.

## Scope

The implementation may change only:

- `Evlin iOS/Views/Profile/ProfileView.swift`, for one DEBUG-only fixture initializer and its injected runtime-effects dependency;
- `Evlin iOSTests/ProfileSnapshotTests.swift`, for all fixture construction, rendering, environment checks, image comparison, artifacts, and tests;
- committed PNG baselines below `Evlin iOSTests/__Snapshots__/ProfileSnapshotTests/`.

It must not modify the project file, agreement/onboarding files, API clients, stores, schedulers, schemes, or production settings. The synchronized Xcode test group discovers the new Swift test and PNG baselines without a project-file edit.

## Release Boundary

Every fixture declaration, fixture initializer, injected dependency, and `onAppear` fixture branch in `ProfileView.swift` is enclosed by `#if DEBUG`.

The normal Release initializer and `onAppear` body remain unchanged. A Release build must not contain the unique `ProfileSnapshotFixture_v1` sentinel in symbols or strings. `internal` visibility and `@testable import` are not accepted as isolation.

## Runtime-Effects Injection

The harness disables runtime effects per `ProfileView` instance. Under `#if DEBUG`, the view receives an injected closure with this contract:

```swift
private var runtimeEffectsAllowed: () -> Bool = { true }
```

The normal initializer retains the default live closure. The DEBUG fixture initializer injects `{ false }`, seeds the view's existing `@State` wrappers, and the existing `onAppear` returns before network refresh, lock reconciliation, polling, deep-link actions, or state replacement.

This is dependency injection, not a global flag. Production code reads no UserDefaults, App Group key, process environment variable, singleton, launch argument, or new setting to select fixture behavior. It therefore complies with R-16: no new production mechanism or guard is introduced.

## Fixture Contract

`ProfileView.SnapshotFixture` carries only values already owned by `ProfileView`:

- child presentation;
- tasks, enrolled devices, and rules;
- daily pool value;
- local lock status;
- manual aggregate state;
- complete automatic covering sources;
- earned summary;
- profile sub-tab.

The initializer seeds these existing states and disables runtime effects. Reflection remains sourced from the existing `ParentReflectionFixtureStore`. Exact-app rows remain sourced from the existing `DeviceAppsSheet(fixtureApps:)` seam. No duplicate presentation logic is added.

## Pinned Environment

The gate runs twice with these exact destinations:

| Form factor | Simulator | Model identifier | Logical size | Runtime |
|---|---|---|---|---|
| iPhone | iPhone 17 Pro | `iPhone18,1` | 402 x 874 pt | iOS 26.3.1 (`23D8133`) |
| iPad | iPad (A16) | `iPad15,7` | 820 x 1180 pt | iOS 26.3.1 (`23D8133`) |

Both runs use:

- locale `en_US` and language English;
- light appearance;
- Dynamic Type `accessibility2` (AX2);
- scale implied by the pinned simulator model;
- animations disabled while rendering.

The test fails before comparison when the device name, model identifier, OS version, locale, appearance, or expected logical size differs. It never silently skips or records a baseline under a mismatched environment.

## Snapshot Matrix

Each form factor records the following deterministic states:

1. **A - independent device bars:** device A has `remaining_to_cap=120/cap=120`, device B has `60/60`, and shared remaining is 35. Both device bars are full; labels may use the effective shared 35-minute text.
2. **B - task pause:** complete automatic source state contains only `task_pause`; manual state is unlocked. The CTA remains green `Lock`, while the inline reason directs the parent to tasks below.
3. **C - earned exhaustion:** summary is exhausted for canonical `usage_date=2026-07-15`; manual state is unlocked. `Override today` is separate from the green manual CTA.
4. **D - mixed manual devices:** manual aggregate is mixed across two devices. The existing disabled `Updating ... devices` reconciliation presentation remains intact.
5. **E - active reflection:** the existing reflection store supplies an assigned reflection. `ParentReflectionStatusCard` replaces the summary/manual CTA.
6. **F - exact-app limit:** the Profile snapshot keeps the child-wide CTA green and a separate `DeviceAppsSheet` snapshot displays a concrete enabled exact-app limit. Per-app state does not recolor or repurpose the child-wide CTA.

This produces seven baseline images per form factor: A through E, F Profile, and F App Limits.

## Rendering And Comparison

The new test file owns a native UIKit/SwiftUI renderer. It hosts each view in a window at the pinned logical size, applies the pinned environment, waits for one deterministic layout pass, and renders a PNG with `UIGraphicsImageRenderer`. No third-party snapshot package or new target is added.

Expected and actual PNGs are decoded to normalized 8-bit RGBA buffers. Comparison allows only a small documented antialiasing tolerance and reports both changed-pixel count and ratio. A layout, color, copy, truncation, overlap, or control-state change must exceed the gate.

On failure the test writes, attaches, and prints absolute paths for:

- actual image;
- red heat-map diff;
- side-by-side expected / actual / diff composite.

Artifacts live under `/tmp/evlin-profile-snapshot-diffs/<environment>/<test-name>/`, so a reviewer can identify the changed region immediately.

Baseline recording is explicit: `EVLIN_RECORD_PROFILE_SNAPSHOTS=1`. Recording is rejected unless every pinned environment assertion passes. Normal test runs never update baselines.

## Verification Gates

The harness is accepted only when all of these pass:

1. default compare mode passes all seven images on iPhone and all seven on iPad;
2. recording followed by compare produces no diff;
3. a deliberate one-pixel test-side mutation proves the diff artifact path and heat map work, then is removed;
4. Debug tests prove fixture state is not replaced after `onAppear` and no polling task is started;
5. a Release build succeeds and `nm`/`strings` find no `ProfileSnapshotFixture_v1` sentinel;
6. `git diff --cached --name-only` contains only the allowed view, test, and baseline paths;
7. a reviewer visually inspects the committed iPhone and iPad baselines before approval.

## Non-Goals

- No product behavior changes.
- No polling or networking abstraction outside the DEBUG fixture instance.
- No new production feature flag, setting, App Group key, launch argument, or environment read.
- No replacement of `ProfileView` with a test-only clone.
- No Render or TestFlight deployment.
