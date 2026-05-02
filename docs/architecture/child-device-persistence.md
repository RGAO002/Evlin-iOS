# Child-device persistence: what works without Evlin running

**Date**: 2026-04-28
**Question**: If the child reboots their iPhone and never opens Evlin, does our control still work?

## TL;DR

The premise "Evlin must be in the foreground to lock" is **partially wrong**. Already-applied shields and pre-scheduled DeviceActivity rules survive reboot without Evlin running. The real problem is **ad-hoc remote commands** ("lock right now" sent from the parent's chat) — those currently rely on the child app polling the backend, which requires the app to be alive.

## The three lock sources, classified by reboot survival

### 1. Already-applied shields (persistent locks) — survive reboot ✅

`ManagedSettingsStore` state is held by an iOS system process, not by the Evlin process. Once `store.shield.applications = [...]` has been written, the OS restores it after reboot and enforces it system-wide. Evlin doesn't need to run for this to work. The shield stays until something explicitly clears the store, or the user revokes FamilyControls authorization.

**Implication**: a "bedtime lock" that's already active will keep working through a reboot.

### 2. Scheduled DeviceActivity rules — survive reboot ✅

`DeviceActivitySchedule` registered via `DeviceActivityCenter` is owned by the OS. When the schedule fires, iOS launches our `EvlinDeviceActivityMonitor` extension (a separate process, NOT the main app). The extension's `intervalDidStart` callback writes `ManagedSettingsStore` and the shield is applied.

**Implication**: time-based policies (school hours, bedtime, daily windows) work entirely without the Evlin main app.

### 3. Ad-hoc remote commands — broken if app isn't running ⚠️

When the parent says "lock now for 30 min" in chat, the command flows: parent app → backend → child device. Current implementation: the child polls the backend. Polling requires the app to be alive. After reboot, if the child never opens Evlin, polling never happens, and the command never lands.

**This is the real architectural gap.**

## Standard iOS solutions for the ad-hoc gap, ranked

### A. APNs silent push (`content-available: 1`) — primary

- Parent → backend → APNs → iOS wakes Evlin on the child's device for a few seconds, even from a `terminated` state
- During those seconds, Evlin calls `ScreenTimeManager.shieldAllApps()` and exits; the shield persists in ManagedSettings
- APNs subscription is held by iOS itself, not by Evlin — works after reboot without the app being opened first
- This is the textbook solution for our use case

### B. BGAppRefreshTask / BGProcessingTask — fallback

- iOS schedules background runs at its discretion (typically every few hours)
- Cannot guarantee timely response, but requires no push infrastructure
- Useful as a safety net if APNs delivery is delayed or suppressed

### C. High-frequency DeviceActivity "heartbeat" — clever

- Register a recurring DeviceActivity event (e.g., every 15–30 min) whose only job is to wake the extension
- Extension reads a pending-command queue from the App Group container and writes ManagedSettings accordingly
- Pros: OS-level guarantee, no main-app dependency, no push infrastructure
- Cons: 15–30 min worst-case latency; watch DeviceActivity quota limits

## The hard limit: user force-quit

If the child swipes Evlin away in the App Switcher, iOS interprets it as "the user does not want this app running" and **suspends APNs silent push delivery and all BGTask scheduling for that app** until the user manually relaunches it by tapping the icon. This is a deliberate Apple product decision — no API circumvents it.

Mitigations (all defensive, none perfect):

1. **Pre-stage policy as DeviceActivitySchedule** so the OS keeps shields running for us (paths 1+2 above) — least dependent on the main app surviving
2. **Default-deny baseline shield**: on first authorization, immediately shield certain categories (e.g. games). Evlin only ever *opens* gaps in the baseline; if Evlin never runs again, the device stays locked. Failure mode is biased toward the parent's intent (fail-closed)
3. **Heartbeat detection + parent alert**: backend tracks last-seen timestamp from child device; if stale beyond threshold, push the parent a "Liam's device hasn't checked in for 3 hours" notification

## Engineering checklist (priority order)

1. **Wire APNs silent push** — backend sends, child app handles `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`. Without this, the remote-command architecture is structurally broken
2. **Move bedtime / school-hours policies to DeviceActivitySchedule** — stop relying on runtime command dispatch for predictable recurring locks
3. **Default-deny baseline** — apply a base shield at first authorization, never fully clear
4. **15-minute DeviceActivity heartbeat** with an App Group pending-command queue, as a fallback when APNs is suppressed
5. **Backend last-seen heartbeat + parent disconnection alerts**

Items 1, 3, 4, 5 are not yet implemented. Item 2 is partially done (some scheduling exists from the three-tier-lock work).

## Why this matters more than the UI redesign

The UI redesign makes Evlin look like a real product. This persistence work makes Evlin actually be a real product — without it, a child can defeat the system by force-quitting the app once. This should land before any consumer launch.
