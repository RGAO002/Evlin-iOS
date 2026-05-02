# Dual-Mode Enforcement Architecture

**Date**: 2026-04-28
**Status**: Design draft, pre-implementation
**Supersedes**: relevant portions of `persistence-research.md` Section 4
**Related**: `child-device-persistence.md`, `persistence-research.md`

## Goal

Define two product modes for Evlin's child-device enforcement, sharing one engine but exposing two distinct product semantics:

- **Std mode** — default-open, parent imposes restrictions. Fail-open.
- **Max mode** — default-closed over a managed surface, parent grants permission windows. Fail-closed.

Engine, persistence layer, and DeviceActivity primitives are shared. Polarity, defaults, UI vocabulary, and SLA differ.

---

## 1. Shared enforcement engine

All enforcement, regardless of mode, runs through the same primitives:

- `ManagedSettingsStore` — system-process state holding the current shield set
- `DeviceActivitySchedule` + `DeviceActivityMonitor` extension — OS-driven wake-ups
- App Group container — shared state between main app and extension

The engine has one responsibility: at every wake event, **reconcile the desired shield state from current rules and write it to ManagedSettings**. Reconciliation is idempotent and stateless — no incremental updates, always full computation.

```swift
func reconcileShield(at now: Date = Date()) {
    let mode = AppGroupConfig.currentMode
    let surface = AppGroupConfig.managedSurface       // allowlist of what Evlin is allowed to touch
    let rules = AppGroupConfig.activeRules(at: now)   // rules whose schedule covers `now`

    // Mode chooses ONLY the baseline. Both effects are applied in both modes.
    let baseline: ManagedTarget = {
        switch mode {
        case .std: return .empty                       // default-open
        case .max: return surface                      // default-closed over surface
        }
    }()

    // Apply restricts (additive), then allows (subtractive). Allows win — they
    // are explicit overrides authored by the parent. Final result is clamped
    // to the managed surface so Evlin never shields anything outside its scope.
    let restricts = rules.filter { $0.effect == .restrict }
                         .reduce(ManagedTarget.empty) { $0.union($1.target) }
    let allows = rules.filter { $0.effect == .allow }
                      .reduce(ManagedTarget.empty) { $0.union($1.target) }

    let shielded = baseline.union(restricts)
                           .subtracting(allows)
                           .intersection(surface)

    apply(shielded, to: ManagedSettingsStore())
}
```

**Why "allow wins over restrict"**: an `.allow` rule is the parent's explicit override — "I know there's normally a lock here, I'm granting access for this window." Treating it as the higher-priority effect is what makes Std mode able to express "Saturday 4-6 PM open even though weekday-bedtime restriction would normally cover it" and Max mode able to express "Sunday morning chores window open even though everything else is locked." Both modes need both effects. Mode polarity lives entirely in the baseline choice.

Reconciliation runs:
- On every `DeviceActivitySchedule` `intervalDidStart` / `intervalDidEnd`
- On every heartbeat schedule firing (every 15 minutes)
- On main app launch
- On APNs alert push delivery (via NSE if validated; else on next main-app launch)
- On explicit user actions in main app

**Critical**: extension reads `AppGroupConfig` fresh every time. Never caches mode or rules in extension memory — extension may be killed between firings.

---

## 2. Policy model

### Rule (the only authoring unit)

```swift
struct Rule: Codable, Identifiable {
    let id: UUID
    var title: String
    var window: Schedule          // when this rule is active
    var target: ManagedTarget     // what apps/categories/domains it covers
    var effect: Effect            // .restrict or .allow — explicit, never inferred
    var createdAt: Date
    var modeAtCreation: Mode      // metadata for migration UX
}

enum Effect: String, Codable {
    case restrict   // shield these targets when window is active
    case allow      // un-shield these targets when window is active (overrides baseline)
}

enum Mode: String, Codable {
    case std
    case max
}
```

The `effect` field is the load-bearing decision: it determines what the rule does, regardless of which mode is currently active. Mode controls **defaults and presentation**, not interpretation.

### ManagedTarget — what a rule operates on

```swift
struct ManagedTarget: Codable, Hashable {
    var categories: Set<ActivityCategoryToken>     // e.g. .games, .socialNetworking
    var applications: Set<ApplicationToken>        // specific bundle IDs
    var webDomains: Set<WebDomainToken>            // specific domains
    static let empty = ManagedTarget(...)
    func union(_ other: ManagedTarget) -> ManagedTarget
    func subtracting(_ other: ManagedTarget) -> ManagedTarget
    func intersection(_ other: ManagedTarget) -> ManagedTarget
}
```

### Managed surface — Evlin's scope

```swift
struct ManagedSurface: Codable {
    var categories: Set<ActivityCategoryToken>
    var applications: Set<ApplicationToken>
    var webDomains: Set<WebDomainToken>
    // Implicit: everything NOT in this set is OUT OF SCOPE — Evlin never touches it
}
```

The managed surface is set during onboarding (via `FamilyActivitySelection`) and editable later. It is the **product boundary**:

- Apps the parent does not explicitly add are not in the managed surface
- Both modes operate **only** over the managed surface; everything outside is untouched

**Consumer v1 policy** (current product tier): Apple's `FamilyActivitySelection` does not surface most system apps (Phone, Messages, Settings, etc.) for selection at all in non-supervised mode, so they are effectively never managed. We codify this as a deliberate v1 product choice: Evlin in consumer mode does not manage system communication, navigation, or Apple-provided utility apps even where technically possible. This is a v1 promise, not a permanent architectural truth — a future supervised/MDM tier (see Section 9) may extend the manageable surface to include Safari, App Store, or specific system surfaces, and the rules in this document are written so that change is purely a question of expanding `ManagedSurface`, not rewriting the engine.

Crucially, this means **Max mode's "default closed" applies only to the managed surface, not to the entire phone**. Phone calls, messages, parent-comm apps, school apps, payments — if not in the managed surface — work normally regardless of mode.

---

## 3. Std mode semantics

### Defaults
- Managed surface: typically large (Games + Social + Entertainment categories + a few specific apps)
- Active rules at any time: typically zero
- Effect default in UI: `.restrict`

### Onboarding flow
1. "Which categories of apps do you want Evlin to manage?" → adds to managed surface
2. "Optional: any specific apps to add?" → bundle IDs into managed surface
3. "Want to set up an initial schedule? (e.g. bedtime)" → creates `.restrict` rules
4. Done; default state for managed apps is OPEN

### Authoring metaphor
"Add a restriction": pick window + targets within managed surface; effect is `.restrict`. UI calls this a "lock" or "limit".

### Chat verbs
- `lock` — create or extend a `.restrict` rule
- `unlock` — cancel an active `.restrict` rule
- `bedtime` — preset `.restrict` rule template
- `block_category` — `.restrict` rule with category target

### Calendar visualization
- Empty calendar = no restrictions = managed apps fully open
- Filled blocks = restriction windows; tapping shows what's locked when

### Failure semantics — fail-open
- Evlin failing/uninstalling/force-quit → no restrictions get applied → managed apps revert to fully open
- Already-applied shields persist across reboot via `ManagedSettings`, but no NEW restrictions land if Evlin is dead
- Parent gets a heartbeat-stale alert after threshold; otherwise quiet failure

### SLA
- "Imposed restrictions take effect within 15 minutes via DeviceActivity heartbeat, near-instantly via APNs alert push when device is reachable"
- "Existing restrictions remain enforced through reboot and app force-quit"
- "If your child uninstalls Evlin or revokes Screen Time access, restrictions are removed; you will be notified"

### Audience
Cooperative families, younger users, families new to parental control, "I just want to limit screen time at bedtime" mainstream use case.

---

## 4. Max mode semantics

### Defaults
- Managed surface: typically narrower than Std (parent picks deliberately because everything in it starts locked)
- Active rules at any time: zero or more `.allow` windows
- Effect default in UI: `.allow`

### Onboarding flow
1. "Pick the apps and categories you want Evlin to **manage tightly**. Anything you pick will be **locked by default** unless you grant a window." → managed surface
2. Strong warning: "Apps you do not pick here are never affected by Evlin. Phone, Messages, Maps, etc. continue to work normally."
3. "Set up your child's permission windows." → creates `.allow` rules
4. Done; default state for managed apps is CLOSED

### Authoring metaphor
"Add a permission window": pick window + targets within managed surface; effect is `.allow`. UI calls this an "access window" or "open window".

### Chat verbs
- `open_window` — create an `.allow` rule
- `close_window` — cancel an active `.allow` rule
- `extend_window` — extend the end time of an active `.allow` rule
- `end_today` — emergency: cancel all future `.allow` rules for the rest of the day

### Calendar visualization
- Empty calendar = no permission windows = managed apps fully locked
- Filled blocks = permission windows; tapping shows what's allowed when

### Failure semantics — fail-closed

These properties depend on which open questions in Section 8 resolve favorably. Treat them as **target SLA**, not validated guarantees, until the experiments in `experiment-plan.md` (forthcoming) confirm them.

- Evlin failing → no `.allow` rules get applied → managed surface stays fully shielded ✅ (relies only on already-applied ManagedSettings persistence, which is a documented Apple guarantee)
- Force-quit preserves the existing lock state ✅ (same reason)
- Reboot preserves the existing lock state ✅ (same reason)
- **BFU preservation of scheduled allow-windows** ⚠ (depends on Q1: does DA extension fire pre-unlock?)
- **Failure never weakens device state** ✅ in steady state, ⚠ during a window: if a window is currently open and Evlin dies, the window will close at its scheduled `intervalDidEnd` only if extension is alive then — but reconciliation on the next heartbeat (15 min) closes any orphan windows regardless

### Target SLA (subject to experimental validation)

- **Validated**: "Managed apps locked at baseline remain locked through reboot, force-quit, and offline conditions"
- **Validated**: "If your child revokes Screen Time access, the lock is broken; you will be notified within 15 minutes via heartbeat-stale detection"
- **Conditional on Q1 (BFU)**: "Permission windows open at their scheduled times even after overnight reboot"
- **Conditional on Q4 (NSE+ManagedSettings)**: "Ad-hoc permission grants take effect within seconds via APNs alert push when reachable"
- **Always-true fallback**: "Ad-hoc permission grants take effect within 15 minutes via DeviceActivity heartbeat"
- **Architectural intent**: "If Evlin or its connection fails, the device fails closed: managed apps remain locked. This is by design."

If Q1 fails (DA extension does not fire in BFU), the SLA softens to "Permission windows open at their scheduled times after the device has been unlocked at least once post-boot." We document this honestly rather than hide the gap.

If Q4 fails (NSE cannot write ManagedSettings), the "near-instant" promise is dropped and only the 15-minute heartbeat path is offered. APNs alert push still surfaces a notification to the child, but actual policy change waits for the heartbeat.

### Audience
Adversarial situations, focus-period contracts (exam prep, addiction recovery), strict-mode households, premium tier.

---

## 5. Mode switch behavior

Mode is per-device, set at onboarding, switchable later via parent UI. **Switching mode does not reinterpret existing rules.** Each rule's `effect` is preserved verbatim.

### What happens on switch

When the parent toggles Std → Max (or reverse):

1. **Migration confirmation screen** shows the parent:
   - The new baseline ("All managed apps will become locked by default" for Max; "All managed apps will become open by default" for Std)
   - Existing rules listed with their effect explicit and a preview of what they'll do under the new mode:
     - `.restrict` rules in Max: still apply on top of the closed baseline — useful for "extra strict" sub-windows (e.g., "absolutely no games during bedtime even though no allow-window covers it anyway"); often redundant but never wrong
     - `.allow` rules in Std: still carve open windows over the open baseline — useful only when stacked with a `.restrict` (e.g., "games restricted weekday afternoons EXCEPT Saturday 4–6") since otherwise they grant access to something already accessible
   - For each rule: keep / edit / delete options. Rules are never silently dropped.
   - Managed surface review: "Is this still the right set of apps to manage? In Max mode, all of these will be locked by default."

2. **Parent makes per-rule decisions**: keep / edit / delete each rule whose effect doesn't match the new mode's primary metaphor. No automatic flipping.

3. **Parent confirms**: write new mode to App Group. Next reconciliation cycle (immediate on main app, ≤15 min on extension) reflects new mode.

4. **Child device gets a soft notification**: "Mode changed by parent. New default state is in effect."

### What does NOT happen
- No silent reinterpretation of rule semantics
- No data loss
- No re-authorization of FamilyControls

### Edge cases
- Switching while a rule's window is currently active: respects new mode at next reconciliation; could result in immediate state change. Confirmation screen warns about this.
- Switching with managed surface empty: the new mode's defaults are vacuous; warn parent that no managed surface = mode is meaningless.

---

## 6. Chat (Evlin agent) semantics

The agent's tool set is **mode-aware**. The system prompt the backend ships to Gemini varies by current child-device mode.

### Tool schema (backend)

```python
TOOLS_STD = [
    "lock(target, duration | until | schedule)",
    "unlock(target)",
    "bedtime(start, end, days)",
    "block_category(category, schedule)",
]

TOOLS_MAX = [
    "open_window(target, duration | until | schedule)",
    "close_window(target)",
    "extend_window(target, by)",
    "end_today(target='all')",
]

TOOLS_BOTH = [
    "show_status",
    "show_schedule",
    "edit_managed_surface",
    "switch_mode",   # Std ↔ Max with confirmation
]
```

### Why the verbs differ
Std's mental model is "restrict from baseline freedom." Max's is "grant from baseline restriction." Same primitive (a `Rule` with a window + target + effect), but the parent reasons about the world differently. Forcing one verb set onto both creates "lock 30 min" meaning "restrict for 30 min" in Std and "stop the current allow window for 30 min" in Max — that ambiguity is unacceptable.

### Translation in the dispatcher
Backend's verb dispatcher (already exists; tested in `test_verb_dispatcher.py`) maps verbs → `Rule` objects with explicit `effect`:

- `lock(games, 30min)` → Rule(effect=.restrict, target=games, window=now+30min)
- `open_window(games, 30min)` → Rule(effect=.allow, target=games, window=now+30min)

Both produce a Rule that the engine reconciles correctly under either mode — but the verb a parent uses matches their mental model.

---

## 7. Failure semantics summary

| Scenario | Std (fail-open) | Max (fail-closed) |
|---|---|---|
| Child force-quits Evlin | Existing restrictions persist; new ones don't land | Managed surface stays locked; permission grants don't land |
| Child reboots, never opens app | Existing restrictions persist | Managed surface stays locked |
| Phone in BFU | Same; existing restrictions hold | Same; managed surface stays locked |
| Evlin backend down | Existing rules continue running on schedule; new commands queued | Existing windows continue on schedule; ad-hoc grants don't land |
| Child revokes Screen Time auth | All restrictions lifted; parent alerted | Managed surface unlocked entirely; parent alerted (this is the floor) |
| Child uninstalls app | Same as revoke | Same as revoke |
| Child puts device in Airplane Mode | Heartbeat goes stale; existing rules unchanged | Heartbeat goes stale; existing windows unchanged |
| Heartbeat stale > N min | Parent push: "device offline" | Parent push: "device offline" + optional auto-cancel future windows |

The defining property: **in any failure mode, Std drifts toward freedom, Max drifts toward lock**. Both fail safely *for their respective product promise* — but those promises are different.

---

## 8. Open implementation questions

These need to be resolved before Phase 13 implementation begins:

1. **NSE writing ManagedSettings on alert push delivery** — if this works, ad-hoc grants in Max have near-instant SLA even after force-quit. If not, fall back to 15-min heartbeat. → covered by Experiment 1 in test plan.

2. **DA extension behavior in BFU** — if extension does fire pre-unlock, Max's "windows open on schedule even after overnight reboot" promise is solid. → covered by Experiment 3.

3. **ManagedSettingsStore count limits per app** — relevant if we want separate stores for emergency-shield vs normal-shield. Default is 1; entitlement allows more. Verify count needed.

4. **Schedule-count budget** — DA has a soft limit around 20 schedules per app. Need to confirm whether using one heartbeat schedule + a small number of window schedules + recurring weekly patterns stays under budget for realistic family configurations.

5. **`FamilyActivitySelection` persistence across managed surface edits** — when parent removes an app from the surface, does its existing token become invalid for shielding? Need to handle gracefully.

6. **Mode switch atomicity** — write-mode-then-reconcile is two steps; what if extension fires between them? Reconciliation reads mode + rules atomically from App Group; ensure write-side uses a single atomic write (e.g., write to temp file then rename).

7. **Telemetry around fail-closed events** — Max specifically needs to log "moments of unintended lockout" (e.g., trip with poor connectivity = no window grant = kid can't access allowed apps) so we can tune escalation thresholds.

---

## 8b. Authoring affordances and the "Unlock Device" semantic (added 2026-04-29)

This section refines the parent-facing operations exposed by each mode. It's authored after Section 4 was written and supersedes any contradictions there.

### Core principle: parent natural language is shared; affordances differ

Both modes accept the same parent input vocabulary — "lock games at 9 PM", "let him play 30 min", "no social during homework". The chat agent translates intent to a `Rule` whose `effect` matches what the parent meant *given the current baseline*. Verbs are not gated by mode.

What differs is **which UI buttons are exposed**, **which actions are framed as primary**, and crucially **which actions can be one-tap permanent vs. require a mode-level decision**.

### The "Unlock Device" rule (load-bearing for Max's promise)

In Std, a profile-level "Unlock Device" button can mean "clear all active `.restrict` rules right now" — this is consistent with Std's fail-open posture and matches the parent's expectation.

**In Max, "Unlock Device" must NOT exist as a one-tap permanent action.** If a single button on a child profile clears the baseline shield permanently, Max is no longer fail-closed — it's just Std with different defaults, and the entire promise to parents collapses. A determined kid would steal the parent's phone, hit Unlock once, and the contract breaks.

In Max, the equivalent affordance becomes **temporary `.allow` window creation**:

- "Open Access" / "Start Access Window"
- "Open for 15 min" / "Open for 30 min" / "Open for 1 hour"
- "Emergency Open" (with a duration prompt)

These all create a `Rule(target: managedSurface, effect: .allow, window: now…now+N)` that auto-expires. The reconciler subtracts the allow target from the baseline shield for the window's duration; once `intervalDidEnd` fires, the rule expires and reconciliation re-applies the full baseline.

True permanent un-locking in Max requires a **mode-level action** with deliberate friction:

- `Switch to Standard mode` (with migration confirmation per Section 5)
- `Disable Max mode` (returns to baseline-empty, requires mode-switch confirmation)
- `Remove app from managed surface` (per-target scope, removes that app from baseline)

### Authoring affordances by mode

| Affordance | Std | Max |
|---|---|---|
| Default state of managed surface | open | locked |
| Failure direction | drifts toward freedom (fail-open) | drifts toward lock (fail-closed) |
| Empty calendar means | total freedom | total lock over managed surface |
| One-tap "Unlock Device" on profile | ✅ clears active `.restrict` rules | ❌ does not exist; replaced by temporary "Open Access Window" affordances |
| Permanent un-lock | natural default; no special action needed | only via mode-level action (Switch/Disable/Remove from surface) |
| Temporary opening | unlock active restriction, or no-op if none active | create `.allow` rule with explicit duration |
| Temporary locking | create `.restrict` rule | shorten or cancel an active `.allow` rule (or create a `.restrict` overlay if no active allow covers the target) |
| `lock all` | shield all of managed surface | already locked at baseline; no-op |
| `unlock all` | clear all active `.restrict` rules | does NOT clear baseline; at most clears overlay restricts or `end_today` for active windows |
| Single-app shield | available; requires app token from picker | available and natural (just one shield write on top of baseline) |
| Category lock | available, needs category token setup | available; usually subsumed by managed-surface baseline |
| Permanent block until parent unblocks | available via API; not exposed in Std UI by default | exposed as first-class — write `Rule(.restrict, window: indefinite)` or extend baseline |
| `unblock app` (escape hatch) | always allowed (avoids mode lock-in) | always allowed |
| `unblockAll` (high-risk escape hatch) | allowed | allowed but behind explicit confirmation |

### Max-only capabilities, with validation status

These are framed in product copy as "Max gives you these things Std can't easily do":

| Capability | Validation status |
|---|---|
| Default-locked managed surface (baseline shield) | ✅ Validated — direct application of `ManagedSettings.shield` documented behavior |
| Fail-closed on Evlin failure | ✅ Validated — relies on OS persistence of ManagedSettings, documented |
| Permission windows / schedule contract authoring | ✅ Validated — same `DeviceActivitySchedule` API used in Std |
| `denyAppRemoval` enabled by default | ✅ Validated — but has side-effect (see below) |
| Hard block (permanent until parent action) | ✅ Validated — implementation is shield + denyAppRemoval + UI hiding of unblock; product policy, not new API |
| Single-app shield via parent-side picker | ⚠ **Pending** — depends on `.child` authorization with parent-side `FamilyActivitySelection` working reliably; flagged as Q in Section 8 |
| Category token setup on parent device | ⚠ **Pending** — same dependency as above |
| MDM/supervised force-quit prevention | ⏸ **Future tier** — requires Apple Configurator setup; v3+, not v2 |

### Honest disclosure required: `denyAppRemoval` side-effect

`denyAppRemoval` is a `ManagedSettings` restriction that prevents app deletion **device-wide**, not per-app. Apple does not expose per-app deletion blocking through any public API.

This means turning it on:
- ✅ Prevents kid from deleting Evlin (product intent)
- ❌ Also prevents kid from deleting any third-party app the parent doesn't care about
- ❌ May block re-installs in some flows

Max's product positioning makes this an acceptable trade for the "device contract" promise, but **onboarding must explicitly disclose the side-effect** and let the parent opt out. Otherwise families discover the consequence by surprise and feel Evlin overreached.

Suggested onboarding copy:
> "Max mode uses Apple's app-deletion lock to prevent your child from removing Evlin to bypass restrictions. As a side-effect, your child won't be able to delete any other apps either, including ones outside Evlin's managed list. This is an Apple platform limitation — we cannot make this restriction Evlin-only. You can disable this in Settings, but doing so weakens Max mode's enforcement."

### `.child` authorization is a hard prerequisite for Max

Std mode can ship with `.individual` authorization (the kid grants Screen Time access on their own device). Std's failure model is consistent with the kid being able to revoke that access — restrictions go away, parent gets notified, fail-open.

Max **requires** `.child` authorization through iCloud Family Sharing. With `.individual`, the kid can revoke Screen Time access from Settings unilaterally, which clears the baseline shield and breaks fail-closed. Only `.child` ties revocation to the parent's Apple ID.

This means Max has a hard onboarding requirement that Std does not:
- The family must have iCloud Family Sharing configured
- The kid's Apple ID must be a child member of the parent's family
- Authorization must be requested with `.child` context

If the family doesn't meet this, Max enrollment cannot proceed; offer Std as a fallback.

### Mode-switch implications

When parent flips Std → Max:
- Migration screen reviews managed surface and existing rules per Section 5
- **Add to Max-specific migration**: prompt parent to confirm `denyAppRemoval` opt-in (with side-effect disclosure)
- **Add to Max-specific migration**: verify `.child` authorization is in place; if not, block switch with "Set up Family Sharing first" guidance

When parent flips Max → Std:
- Existing rules' `effect` values are preserved verbatim
- Baseline lock is removed (managed surface becomes default-open)
- `denyAppRemoval` should be left as-is (parent toggles separately) or prompted to disable
- Active `.allow` rules become no-ops (the things they were allowing are already allowed); display in migration screen as "previously needed; can be deleted"

---

## 9. Roll-out plan

### v1 (Phase 13) — Std mode only
- Build the shared engine
- Build Std semantics: onboarding, calendar, chat verbs, failure paths
- Ship to all users
- Validate engine behavior in real households for 6+ weeks
- Tune heartbeat thresholds, APNs delivery rates, parent alert thresholds

### v2 (Phase 14, after Std validated) — Add Max mode
- Add Max-specific onboarding flow
- Add Max chat verbs to backend
- Add mode switch UI + migration confirmation screen
- Add fail-closed telemetry
- Position as advanced/strict/focus mode (final naming TBD)

### v3 — MDM-supervised tier (Phase 15+)
- Apple Configurator setup guide
- MDM payload bundle for force-quit prevention via Single App Mode
- Enterprise/severe-case audience only

---

## 10. Naming considerations (deferred)

"Std" and "Max" are working names. Final consumer-facing labels TBD. Candidates:

- **Std**: "Standard", "Family", "Balanced"
- **Max**: "Focus", "Strict", "Lockdown" (too aggressive?), "Contract Mode"

Avoid: "Easy/Hard", "Light/Heavy", "Free/Paid" (mode is not a paywall — both should be available; pricing is orthogonal).

---

## 11. References

- `child-device-persistence.md` — what survives reboot/force-quit
- `persistence-research.md` — full mechanism research and Apple doc citations
- WWDC21 session 10123 — `DeviceActivity` and `ManagedSettings` introduction
- WWDC22 session 110336 — Screen Time API updates
- Apple — [Configuring Family Controls](https://developer.apple.com/documentation/xcode/configuring-family-controls)
- Apple — [DeviceActivitySchedule](https://developer.apple.com/documentation/deviceactivity/deviceactivityschedule)
