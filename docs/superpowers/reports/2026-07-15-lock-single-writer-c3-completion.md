# Lock Single-Writer C-3 Completion Report

**Date:** 2026-07-19
**Branch:** `claude/c3-single-writer`
**Plan:** `docs/superpowers/plans/2026-07-15-lock-single-writer-c3.md`
**Rule-book scope:** C-3 / R-2 / D-2 only. No metering, epoch, override, task,
reflection-lifecycle, or backend behavior changed. No new persistent
guard/flag introduced (R-16: nothing to register — `webOpen` is a per-record
attribute, not a global guard).

## 1. The three removed bypasses

| # | Bypass | Before | After |
|---|--------|--------|-------|
| 1 | `ReflectionVideoWebAccess.allowPlaybackInEmbeddedWebView()` (`Evlin iOS/Views/Child/BigKid/Reflection/BigKidVideoView.swift`) nil-ed `shield.webDomainCategories`/`shield.webDomains` from the view (`.onAppear` + `VideoEmbedView.load`) | Direct main-app write racing ActiveLockStore | Deleted. Reflection records carry `ShieldRecord.webOpen == true` (set in `ReflectionLockRecordFactory.make`); `ActiveShieldProjection` opens the WEB projection only — apps stay fully shielded. Missing `webOpen` decodes `false` (legacy payloads unchanged). |
| 2 | Home settings buttons: `screenTimeManager.shieldApps()` ("Lock Selected Apps"), `screenTimeManager.clearAllShields()` ("Unlock All Apps", "Reset Everything") in `Evlin iOS/Views/Home/HomeSettingsSheet.swift` | Direct shield-field writes + record-store wipe | D-2: buttons KEPT. Lock upserts the single stable manual record `savedList:home-settings-selected` via `HomeSettingsLockRouting.lock` (`force: true`). Unlock (renamed "Unlock Selected Apps") removes ONLY that record — no `unshieldAll`, no block/override/accounting changes. "Reset Everything" clears records via `ActiveLockStore.unshieldAll()/unblockAll()` (its recompute writes the nils). Web-domain tokens now count toward the visible selection. |
| 3 | Dead APIs `ScreenTimeManager.shieldAllApps()` and `ScreenTimeManager.unshieldApps(forMinutes:)` (plus the private relock timer `scheduleRelock(afterMinutes:)` and its unused `DeviceActivityCenter`) | Zero-caller direct writers | Deleted. Caller scan before deletion matched only the two definitions (`rg` over all `*.swift`). |

## 2. Tests proving record-overlap preservation

All RED-first (verified failing before implementation), then GREEN twice.

- `HomeSettingsLockRoutingTests.test_unlock_removes_only_home_record_and_automatic_record_survives`
  — an `.earnedTime` automatic record survives Home unlock; only
  `savedList:home-settings-selected` is removed.
- `ActiveLockStoreTests.test_webOpen_broad_record_wins_only_for_web_projection`
  — parent `all` + reflection `webOpen` project to `applications == .all`,
  `webDomains == .open` (webOpen wins for web ONLY).
- `ActiveLockStoreTests.test_projection_without_webOpen_keeps_parent_full_web_shield`
  — without `webOpen`, the parent full lock still closes web (`.all`).
- `ActiveLockStoreTests.test_reflection_web_open_coexisting_with_parent_all_keeps_web_available`
  — store-level: recompute diag lands in `branch=all_apps_only`.
- `ReflectionLockApplierTests.test_release_preserves_existing_blocks` (existing)
  — reflection release keeps unrelated blocks.
- `ShieldRecordNormalizationTests.test_missing_webOpen_decodes_false` /
  `test_webOpen_true_roundtrips_through_codable` /
  `test_legacy_reflection_normalization_preserves_webOpen`
  — persisted-record backward compatibility; no legacy record is discarded.
- Architecture guards (source-level, `#filePath`-resolved):
  `ReflectionVideoWebAccessTests.test_video_source_has_no_direct_managed_settings_write`,
  `HomeSettingsLockRoutingTests.test_settings_sheet_has_no_direct_screen_time_shield_calls`,
  `HomeSettingsLockRoutingTests.test_screen_time_manager_has_no_dead_direct_writers`.

Final focused run (all six suites, `-parallel-testing-enabled NO`,
iPhone 17 Pro / iOS 26.3.1 simulator): **69 test cases passed, 0 failed**
(`ShieldRecordNormalizationTests`, `ReflectionLockApplierTests`,
`ReflectionVideoWebAccessTests`, `ActiveLockStoreTests`,
`HomeSettingsLockRoutingTests`, `CommandProvenanceTests`).

## 3. Build results

- `xcodebuild build -configuration Release -destination 'generic/platform=iOS Simulator'` — **BUILD SUCCEEDED**.
- `xcodebuild build -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` — **BUILD SUCCEEDED**.
- All three `rg` gates exit 1 (no matches):
  1. `ManagedSettingsStore\(\)|allowPlaybackInEmbeddedWebView` in `BigKidVideoView.swift`
  2. `screenTimeManager\.(shieldApps|clearAllShields)\(` in `HomeSettingsSheet.swift`
  3. `\.shieldAllApps\(|\.unshieldApps\(|shieldAllApps\(|unshieldApps\(` over all `*.swift`

## 4. Repository-wide ManagedSettings writer inventory

Scan: `\.shield\.(applications|applicationCategories|webDomains|webDomainCategories)\s*=`,
`blockedApplications\s*=`, `clearAllSettings\(\)` over all targets.

**The single main-app shield/block writer:**
- `Evlin iOS/Services/ActiveLockStore.swift` (`recomputeAndApply()` applying
  `ActiveShieldProjection`) — C-3 compliant by definition.

**Other-process writers (dual-authority by design, not main-app):**
- `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
  (:772-:795, :840) — the extension-process recompute mirror. Out of C-3
  scope (C-3 governs the main app; the extension is the second authority in
  the established dual-authority design). NOTE: the mirror does not yet read
  `webOpen` (file is change-frozen for this work item); see Concerns.

**Retained main-app writers, each with named ownership:**
- `Evlin iOS/Services/ScreenTimeManager.swift`
  - `shieldApps()` (:175/:178) and `clearAllShields()` → `clearLockRestrictions()`
    (:247-:250): retained per plan Task 3 ("do not delete in this task").
    After this change they have **zero production callers** — candidates for a
    follow-up removal item.
  - `applyDeletionProtectionToManagedSettings` (:237 `clearAllSettings()`):
    `denyAppRemoval` deletion-protection path (different field, explicitly out
    of C-3 scope); it immediately re-applies records via
    `ActiveLockStore.reapplyCurrentRestrictions()`.
- `Evlin iOS/Views/Home/HomeSettingsSheet.swift` `nuclearReset()` (:2535
  `clearAllSettings()`): debug-only nuclear reset explicitly preserved by the
  plan; wipes record dicts via `unshieldAll()/unblockAll()` and re-enables
  deletion protection.
- `Evlin iOS/Views/Child/BigKid/BigKidRootView.swift` (:313
  `clearAllSettings()`): kid sign-out full teardown; releases all records via
  `ActiveLockStore.unshieldAll()/unblockAll()` FIRST, then clears settings —
  a deliberate leave-the-family reset, not a shield-policy writer.
- Debug probe views (not named by C-3, explicitly preserved):
  `Evlin iOS/Components/Debug/CommandDeliveryDiagnosticsView.swift` (separate
  named store `evlin.nsespike` + spike store), `Evlin iOS/Views/Debug/ShieldHarvestProbeView.swift`,
  `Evlin iOS/Views/Debug/SpikeView.swift`, `Evlin iOS/Views/Debug/QrSpikeDebugView.swift`
  (separate named debug store).

No unexplained main-app writer remains → **C-3 closed** for the main app's
shield/block fields.

## 5. Plan deviations

1. `Evlin iOS/Services/ShieldSourceLogic.swift` was also modified (not in the
   plan's file list): `ScreenTimeRecordKeySweep.sweep` rebuilds records
   memberwise, so it needed the one-line `webOpen: record.webOpen`
   passthrough to avoid silently dropping the attribute on re-key.
2. `HomeSettingsLockRouting.makeRecordUnchecked(appTokens:categoryTokens:webDomainTokens:...)`
   exists alongside the plan's `makeRecord(selection:...)`: FamilyControls
   tokens cannot be fabricated in unit tests, so the emptiness guard and the
   record shape are pinned through the split constructor. `makeRecord`
   delegates to it.
3. In addition to the two named buttons, the "Reset Everything (Re-run
   Onboarding)" call site of `clearAllShields()` was rerouted (the plan's
   architecture guard forbids any `screenTimeManager.clearAllShields()` in
   the sheet). Behavior preserved: record wipe + deletion-protection re-sync +
   lock-state notification after the awaited mutation.
4. The dead private `scheduleRelock(afterMinutes:)` and its
   `DeviceActivityCenter` property were removed together with
   `unshieldApps(forMinutes:)` (its only caller). The unused
   `DeviceActivityName.evlinUnlock` constant was left in place.

## 6. Concerns / follow-ups (not blocking C-3)

- The DeviceActivityMonitor extension's recompute mirror does not read
  `webOpen`; if the extension recomputes while a reflection lock coexists
  with a parent full lock, it would close web where the main app opens it.
  Rare overlap; requires a follow-up item on the change-frozen extension file.
- `ScreenTimeManager.shieldApps()`/`clearAllShields()` are now caller-less
  production code — schedule removal in a later cleanup item.

Do not deploy: no Render deploy, no TestFlight upload (per plan).
