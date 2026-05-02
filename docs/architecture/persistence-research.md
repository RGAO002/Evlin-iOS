# Persistence research: surviving the adversarial child on a consumer iPhone

**Date**: 2026-04-27
**Scope**: What enforcement mechanisms actually survive force-quit, reboot, BFU, airplane mode, authorization revocation, and app deletion on a non-jailbroken, non-supervised consumer iPhone running iOS 17/18.
**Audience**: Evlin engineering, for architectural decisions on the child-mode app.

> **Honesty disclaimer**: Apple does not document many of these behaviors precisely, and several have shifted across iOS versions without changelog entries. Where the answer is "probably," this report says "probably" — empirical testing on real hardware is required to firm up the cells flagged in Section 5.

---

## Section 1: Scenario × mechanism matrix

Legend: ✓ works, ✗ fails, ⚠ partial / unreliable / undocumented.

| # | Scenario | A. Silent push | B. Alert push | C. BGTask | D. DeviceActivity ext | E. ManagedSettings persistence | F. PushKit (VoIP) | G. Critical Alert | H. Local notif via DA | I. MDM (supervised) | J. "Don't allow delete" | K. Auth revocation effect |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Foreground | ✓ delivered | ✓ delivered | n/a | ✓ fires | ✓ enforced | ✓ | ✓ | ✓ | ✓ | n/a | n/a |
| 2 | Backgrounded (suspended) | ⚠ throttled | ✓ shown; wakes app briefly | ⚠ OS-scheduled | ✓ fires | ✓ enforced | ⚠ deprecated for non-VoIP | ✓ | ✓ | ✓ | n/a | n/a |
| 3 | System-terminated (memory) | ⚠ may wake briefly | ✓ shown; can wake on tap | ⚠ may run | ✓ fires (own process) | ✓ enforced | ✗ in practice | ✓ | ✓ | ✓ | n/a | n/a |
| 4 | User force-quit (App Switcher) | ✗ blocked until manual relaunch | ✓ shown but tap won't run background code | ✗ blocked | ✓ extension is separate process, still fires | ✓ enforced | ✗ | ✓ shown | ✓ shown | ✓ | n/a | n/a |
| 5 | Post-reboot, AFU | ⚠ delivered, but app must register; first push may not wake | ✓ delivered & shown | ✗ until app launches once to re-register handlers | ✓ schedules persist; extension fires without app launch | ✓ persists across reboot | ✗ | ✓ | ✓ | ✓ | n/a | n/a |
| 6 | Post-reboot, BFU (no unlock yet) | ✗ queued, not delivered to app | ✗ shown on lockscreen but app not woken | ✗ | ⚠ schedules registered with system likely fire, but extension may be delayed; undocumented | ✓ shields enforced (system process) | ✗ | ⚠ shown lockscreen | ⚠ shown lockscreen | ✓ MDM commands queue | n/a | n/a |
| 7 | Low Power Mode | ⚠ heavily throttled / dropped | ✓ delivered | ✗ paused | ✓ unaffected (system schedule) | ✓ | ✗ | ✓ | ✓ | ✓ | n/a | n/a |
| 8 | Focus / DND blocking notifications | ✓ silent isn't a notification — unaffected | ⚠ banner suppressed but payload delivered to `didReceive` | n/a | ✓ | ✓ | ✓ | ✓ bypasses Focus | ⚠ suppressed banner, payload still wakes | ✓ | n/a | n/a |
| 9 | Airplane mode | ✗ no network | ✗ no network | ✗ no network for fetch | ✓ unaffected (local schedule) | ✓ | ✗ | ✗ | ✓ unaffected | ⚠ MDM commands queue | n/a | n/a |
| 10 | Screen Time / FamilyControls auth revoked | ✗ app loses entitlement context but APNs still works; control APIs no-op | n/a | n/a | ✗ extension cannot write ManagedSettings | ⚠ existing shields appear to clear when revoked (see K below) | n/a | n/a | n/a | ✓ (MDM bypasses Screen Time) | n/a | shields cleared on revoke |
| 11 | App deleted (deletion allowed) | ✗ device token invalidated | ✗ | ✗ | ✗ extension gone | ⚠ shields likely cleared when app uninstalled | ✗ | ✗ | ✗ | ✓ MDM can prevent | If "Don't allow" off — child can delete | n/a |
| 12 | "Don't allow deleting apps" set | ✓ unaffected | ✓ | ✓ | ✓ | ✓ | n/a | ✓ | ✓ | ✓ | **Effective**: removes Delete from long-press menu AND from Settings → General → iPhone Storage. **Bypassable** only by toggling the Screen Time restriction itself (which requires the Screen Time passcode). | n/a |

Cells marked ⚠ in scenarios 5/6 with the DeviceActivity extension and authorization revocation in scenario 10 are the ones most worth empirical testing — see Section 5.

---

## Section 2: Per-mechanism deep dive

### A. APNs silent push (`content-available: 1`, `apns-push-type: background`, priority 5)

**What it is.** A push payload with no user-visible alert, intended to wake an app for ~30 seconds of background work. `apns-push-type: background` and `apns-priority: 5` are mandatory since iOS 13. Apple's reference: ["Pushing background updates to your app"](https://developer.apple.com/documentation/usernotifications/pushing_background_updates_to_your_app).

**Apple's stated guarantees.** None. The docs say silent pushes "may be throttled" and that the system "decides when to wake your app." Apple explicitly calls priority-5 background pushes "best-effort," and the [APNs metrics console](https://developer.apple.com/documentation/usernotifications/viewing-the-status-of-push-notifications-using-metrics-and-apns) shows "discarded" as a normal outcome.

**Real-world reliability.** Engineering write-ups from Pushwoosh and OneSignal converge on: under typical conditions a few silent pushes per hour land within 1–5 minutes; bursts beyond ~2–3/hour per device get dropped; Low Power Mode reduces this dramatically; "device-wide budget" exhaustion (battery, cellular data) suspends background delivery entirely until reset. [Pushwoosh's overview](https://help.pushwoosh.com/hc/en-us/articles/26713265335581-Understanding-Silent-Push-Notification-Behavior-and-Limits-on-iOS) and [Mohsin Khan's "Opportunities, Not Guarantees"](https://mohsinkhan845.medium.com/silent-push-notifications-in-ios-opportunities-not-guarantees-2f18f645b5d5) both describe identical patterns.

**Gotchas.** (1) Force-quit (App Switcher swipe) sets a "do-not-launch" flag that Apple has confirmed in [forum threads](https://developer.apple.com/forums/thread/666149) blocks silent pushes until the user taps the icon — this is the single biggest defeat for our use case. (2) BFU (post-reboot, no unlock) queues but does not deliver. (3) Apple's [forum guidance](https://developer.apple.com/forums/thread/126540) is that silent pushes "will not be delivered to your app if it has been swiped away or killed." (4) Sending an alert push in addition to the silent payload is a documented workaround Apple itself suggests for reliability.

**Verdict for Evlin.** Primary remote-command channel, but never the *only* one. Always pair with a visible alert push (parent device sends alert to child if silent path fails) and a defense-in-depth scheduled fallback.

---

### B. APNs alert push (visible)

**What it is.** Standard `alert` payload, `apns-push-type: alert`, priority 10. Always shown to the user; calls `userNotificationCenter(_:didReceive:withCompletionHandler:)` when the user interacts; can wake the app to background via the `mutable-content: 1` flag and a Notification Service Extension to mutate the payload before display.

**Stated guarantees.** Best-effort, but priority-10 alerts are the most reliably delivered class of push Apple offers. They are explicitly *not* throttled the way background pushes are.

**Real-world.** Per OneSignal/Mixpanel postmortems, alert delivery rate to APNs-acknowledged tokens exceeds 99% within minutes when device is reachable. Alert pushes are delivered in BFU state (shown on lockscreen) and in Low Power Mode.

**Gotchas.** A force-quit app cannot run code from a silent payload, but a Notification Service Extension *can* run on alert delivery — and the extension is a separate process. However, the NSE has no FamilyControls/ManagedSettings entitlement context the same way a DeviceActivity extension does; you can manipulate ManagedSettings from any process belonging to the app group as long as authorization was granted, but this hasn't been authoritatively confirmed for NSE specifically.

**Verdict.** Use alert push as the always-visible fallback for any urgent command. The downside is UX noise (every command shows a banner), but it's the most reliable channel that survives most adversarial states short of airplane mode.

---

### C. BGTaskScheduler (`BGAppRefreshTask`, `BGProcessingTask`)

**What it is.** Replaces the older `application(_:performFetchWithCompletionHandler:)`. App registers task identifiers at launch, submits requests for "earliest begin date," iOS schedules at its discretion. Apple ref: [BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler).

**Stated guarantees.** None on timing. AppRefresh is meant for short bursts (<30s); ProcessingTask for longer work needing power/network. Apple confirms in the docs: tasks must be re-registered on every launch, and tasks do not survive a reboot until the app launches once.

**Real-world.** Latency between submission and execution is typically several hours, sometimes a full day. Heavily user-pattern-driven. Force-quit blocks AppRefresh entirely; ProcessingTask is reported in [forum threads](https://developer.apple.com/forums/thread/685525) to sometimes still run after force-quit but with tighter limits — this is undocumented and unreliable.

**Gotchas.** First-launch requirement is fatal for our threat model: a child who reboots and never opens Evlin gets no BGTask execution, ever. The app must run at least once per process lifecycle to register handlers.

**Verdict.** Useless as a primary mechanism. Acceptable as a low-priority sync/heartbeat layer once the app has been launched at least once post-boot.

---

### D. DeviceActivityMonitor extension + DeviceActivitySchedule

**What it is.** A separate process, launched by the OS on a calendar schedule registered via `DeviceActivityCenter.startMonitoring(_:during:events:)`. Methods: `intervalDidStart`, `intervalWillEndWarning`, `eventDidReachThreshold`. Apple refs: [WWDC21 "Meet the Screen Time API"](https://developer.apple.com/videos/play/wwdc2021/10123/), [WWDC22 "What's new in Screen Time API"](https://developer.apple.com/videos/play/wwdc2022/110336/), [DeviceActivity docs](https://developer.apple.com/documentation/deviceactivity).

**Stated guarantees.** The extension runs *without launching the main app*. The schedule is owned by the OS and survives reboot, force-quit, and main-app deletion-as-long-as-the-extension-bundle-is-still-installed (which is bundled with the host app, so deletion does kill it). Memory budget is documented as ~6 MB.

**Real-world.** This is the most powerful mechanism we have, and also the buggiest. Reports across [Apple Forums](https://developer.apple.com/forums/tags/device-activity), [Frederik Riedel's "State of the Screen Time API 2024"](https://riedel.wtf/state-of-the-screen-time-api-2024/), and [letvar's three-part Medium series](https://letvar.medium.com/time-after-screen-time-part-3-the-device-activity-monitor-extension-284da931391b) all describe `intervalDidStart` and `eventDidReachThreshold` failing to fire intermittently, especially on iOS 16.0–16.2 and after device reboots. iOS 17 improved this materially but reports of skipped intervals still appear. Memory limit Jetsam crashes are common if you do anything heavyweight in the extension — keep code paths to "read App Group queue → write ManagedSettings → return."

**Gotchas.** (1) The extension CAN write to `ManagedSettingsStore` without the main app running — confirmed by Apple in WWDC21 and reproducible in practice. (2) Schedule registration requires the main app to have run at least once with FamilyControls authorization. (3) Schedules with `repeats: true` are documented to persist across reboot; non-repeating schedules' post-reboot behavior is less clear. (4) Token re-issuance bug (Riedel problem #1) means stored `ApplicationToken` values can become stale across major iOS updates.

**Verdict.** This is the load-bearing mechanism. Pre-stage every policy you can as a DeviceActivitySchedule; treat the main app as ancillary. Use a high-frequency heartbeat schedule (every 15 min, the documented minimum) as the bottom-floor defense for ad-hoc remote commands when push fails.

---

### E. ManagedSettingsStore persistence

**What it is.** A keyed store of restrictions (shields, app categories, web domains) maintained by an iOS system daemon. [ManagedSettings docs](https://developer.apple.com/documentation/managedsettings).

**Stated guarantees.** "Settings are automatically synchronised with the system and persist until you clear them" (Apple docs). No mention of reboot/termination clearing them — implication: they persist.

**Real-world.** Confirmed across multiple developer reports: shields survive app force-quit, system termination, and reboot. The store is process-independent.

**Gotchas.** (1) `revokeAuthorization()` does clear shields owned by the revoked app — see K. (2) Deleting the app appears to clear the app's shields (the store is keyed by bundle), though this isn't explicitly documented. (3) Token migration bugs (Riedel problem #2) can leave shields visually mismatched but logically applied — apps appear blocked but UI is wrong. (4) An iOS major update that re-issues tokens (Riedel problem #1) can effectively orphan shields — they're still in the store keyed to dead tokens.

**Verdict.** Reliable substrate. Always write a *baseline* shield ASAP after first authorization (default-deny posture); the store will hold it through everything except explicit revocation.

---

### F. PushKit (VoIP push)

**What it is.** A separate push channel originally designed for VoIP apps. Pre-iOS 13 it was the gold standard for waking terminated apps reliably.

**Stated guarantees.** Since iOS 13 ([Apple forum thread](https://developer.apple.com/forums/thread/117939)), apps receiving a PushKit push *must* report an incoming call to CallKit within a short window or the OS terminates the app. Non-VoIP use is explicitly disallowed and App Review flags it.

**Verdict.** Do not use. App Review will reject; even if it shipped, the OS would terminate the app for not reporting a call. This door closed in 2019.

---

### G. Critical Alerts entitlement

**What it is.** A special entitlement (`com.apple.developer.usernotifications.critical-alerts`) granting an app the ability to send notifications that bypass Focus, Do Not Disturb, and the ringer mute switch. [Apple ref](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts). Requires manual approval via [this request form](https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/).

**Stated guarantees.** Once granted, alerts play sound through silenced devices.

**Real-world.** Apple's published criteria are health, safety, and security. Approved categories include medical alerts, home security, and severe-weather. Parental control is not on the canonical list but is plausibly arguable on a "child safety" rationale. [Hacker News thread on the policy](https://news.ycombinator.com/item?id=43922698) shows non-medical apps being denied frequently. Approval times range from days to months.

**Verdict.** Worth applying for, low expectations. If granted, use sparingly — it's a parent-side notification ("child went offline for 3 hours") rather than a child-side mechanism. Does not solve any of the child-side scenarios in the matrix.

---

### H. Local notifications fired from DeviceActivity events

**What it is.** A DeviceActivity extension can post a `UNNotificationRequest` from `intervalDidStart`/`eventDidReachThreshold`. This appears as a normal local notification.

**Real-world.** Posting from the extension works but is reported as flaky — see Forum threads on `eventDidReachThreshold`. The notification can wake the main app *only if the user taps it*; tapping a local notification does invoke the app's `didReceive` handler in the background and gives ~30s of execution.

**Verdict.** Unreliable as a wake mechanism. The DA extension itself is your wake mechanism — the local notification is mainly user-facing UX ("Time's up").

---

### I. MDM / Apple Configurator 2 / supervised mode

**What it is.** Supervision is a device flag set during initial setup that unlocks dozens of [MDM payload restrictions](https://support.apple.com/guide/deployment/mdm-restrictions-payload-mdm38df53c2a/web) unavailable to consumer devices. Relevant payloads:
- `restrictAppRemoval` — true prevents app deletion (more robust than Screen Time's "Don't Allow Deleting Apps")
- `forceSingleAppMode` / Autonomous Single App Mode — locks device to one app
- `allowAppInstallation: false` — prevents installs (and thus reinstalls of bypass tools)
- `allowEraseContentAndSettings: false` — blocks the "wipe and start over" attack
- `allowScreenTime` / `forceScreenTimeNonRemovableApps` — prevents disabling Screen Time

**The supervision setup pain.** Confirmed: standard path requires Apple Configurator 2 on a Mac, USB cable, and a full device wipe. Once supervised, an MDM enrollment profile from any MDM provider (Mosyle, Jamf Now, SimpleMDM, Hexnode, Scalefusion, Miradore, Kandji) installs and accepts commands. [SimpleMDM's primer](https://simplemdm.com/blog/what-is-ios-supervised-mode-how-do-i-activate-supervision/) and [Apple's guide](https://support.apple.com/guide/apple-configurator-mac/supervise-devices-apd9e4f64088/mac) both confirm this.

**Consumer-friendly alternatives?** Largely none. [Mosyle Manager](https://school.mosyle.com/) offers a B2B parent product but supervision still requires AC2 + cable + wipe. Apple does not allow over-the-air supervision for non-DEP-enrolled devices outside Apple Business Manager. There is no signed-config-profile-from-USB path that consumers can do without a Mac. Some third-party iOS apps claim to "supervise" via configuration profiles but they do not — they install profiles that grant certificate trust or VPN, which is much less powerful.

**Cost & friction.** MDM seats run $1–4/device/month (Mosyle has a free tier up to N devices; Jamf Now starts at $2/device). The harder cost is the *one-time wipe-and-reset* the parent must do on the child's existing phone, plus walking through Setup Assistant with the supervision certificate. This is a brick wall for most consumer customers.

**Verdict.** Supervision is the only path that lets you survive every scenario in the matrix, including a hostile, technically savvy child. But it is functionally inaccessible to typical consumer parents. Worth offering as an "advanced mode" with onboarding documentation; do not depend on it for the mainstream product.

---

### J. "Don't Allow Deleting Apps" (Screen Time content restriction)

**What it is.** Settings → Screen Time → Content & Privacy Restrictions → iTunes & App Store Purchases → Deleting Apps → Don't Allow.

**Real-world.** Genuinely effective. With this set:
- Long-press → Remove App offers only "Remove from Home Screen," not "Delete App."
- Settings → General → iPhone Storage → [App] removes the "Delete App" button (offers "Offload App," which preserves data and reinstalls on next launch — the app *icon* and shield bundle remain).
- The App Store's open-app shortcut shows no delete affordance.

**Bypasses.** The only bypass on a non-jailbroken device is to disable the restriction itself, which requires the Screen Time passcode. If the parent owns the Screen Time passcode and the child does not, this restriction is robust.

**Gotchas.** (1) Some users on iOS 18.x reported the toggle silently failing to enforce after major updates ([Apple Community](https://discussions.apple.com/thread/255785091)) — set, verify, and re-verify after every iOS update. (2) "Offload App" still works and removes the executable; the shield extensions persist but the main app's bundle is gone until the user taps the icon, at which point the App Store reinstalls. So this is not airtight. (3) Some users have reported third-party screen time apps (e.g., Opal) that turn the restriction on and forget to turn it off, blocking deletion of unrelated apps — UX gotcha.

**Verdict.** A meaningful speedbump but not airtight. Combine with Screen Time passcode owned by the parent. Cannot replace MDM `restrictAppRemoval`.

---

### K. FamilyControls authorization revocation

**What it is.** The user can revoke our FamilyControls authorization from Settings → Screen Time → [our app]. There is also a programmatic [`revokeAuthorization(completionHandler:)`](https://developer.apple.com/documentation/familycontrols/authorizationcenter/revokeauthorization(completionhandler:)) we'd never call.

**Real-world.** [Riedel's analysis](https://riedel.wtf/state-of-the-screen-time-api-2024/) and forum reports confirm: when authorization is revoked, the system clears all ManagedSettings shields owned by that app effectively immediately. The DeviceActivity schedules are also dropped. The app then runs without authorization until re-prompted.

**Detection.** `AuthorizationCenter.shared.authorizationStatus` reports `.denied`. Apps don't get a callback when revocation happens; you discover it on next foreground or when an API call fails. There is no "revocation event" push.

**Gotchas.** (1) On iOS 17 the auth status is reportedly cached in some scenarios — the API can return `.approved` until app restart even after revocation. (2) For child-mode apps, this is the single biggest non-MDM threat vector: a child who knows the device's regular passcode can revoke our authorization in seconds.

**Verdict.** Without supervision, this is the floor of what we can protect against. Mitigation is to put the FamilyControls toggle behind the *Screen Time* passcode (parent-owned), not the device passcode. This is a Settings-level configuration the parent must make at onboarding.

---

## Section 3: The hard limits

These cannot be solved on a consumer-mode iPhone in 2026. Citations below.

1. **A force-quit app cannot run code in response to silent push or BGTask until the user manually relaunches it.** Confirmed by Apple staff in [Forum thread 666149](https://developer.apple.com/forums/thread/666149) and [thread 685525](https://developer.apple.com/forums/thread/685525). The DeviceActivity *extension* is a separate process and is unaffected; this is why it must be the load-bearing layer.

2. **A child who knows the device passcode can revoke FamilyControls authorization in Settings, and the system will immediately clear our shields.** [Riedel 2024](https://riedel.wtf/state-of-the-screen-time-api-2024/) Problem #3. There is no API to require Screen Time passcode for our authorization toggle; the parent must set the Screen Time passcode at onboarding for this to be gated at all.

3. **A child can delete the app unless "Don't Allow Deleting Apps" is set under Screen Time, and even then "Offload App" works.** [Apple Community thread on iOS 18 deletion bug](https://discussions.apple.com/thread/255785091) shows the restriction can fail silently after updates.

4. **BFU (post-reboot, never-unlocked) state delivers no silent pushes to apps and gives no main-app code execution.** This is by design for security ([Apple's data protection model](https://support.apple.com/guide/security/data-protection-overview-secf6276da8a/web)). Mitigation: pre-staged ManagedSettings + DeviceActivity schedules continue working in BFU because they live in system processes.

5. **Airplane mode + force-quit + reboot is the worst-case adversarial trifecta.** Only pre-staged DeviceActivity schedules and existing ManagedSettings shields enforce; we cannot reach the device with any command. Any policy that requires *new* parent input during this state will not land.

6. **Non-jailbroken consumer iPhones cannot be put into supervised mode without a Mac, a USB cable, and a full device wipe.** Apple has not relaxed this in any iOS 17/18 release and there is no public roadmap suggesting they will. ([Apple Configurator setup guide](https://support.apple.com/guide/apple-configurator-mac/supervise-devices-apd9e4f64088/mac).)

7. **PushKit-as-a-wakeup-trick is dead.** Since iOS 13 it must report a call to CallKit or the OS terminates the app ([Apple forum 117939](https://developer.apple.com/forums/thread/117939)). App Review enforces this. Don't try.

---

## Section 4: Recommended architecture for Evlin

Layered defense, ordered from most-OS-native to most-fragile.

### Layer 1 — Pre-staged enforcement (load-bearing)

- **Default-deny baseline shield**: at first FamilyControls authorization, immediately write a baseline `ManagedSettingsStore` shield covering high-risk app categories (games, social, etc.). Never fully clear it; only *open* gaps.
- **All recurring policies as DeviceActivitySchedules**: school hours, bedtime, weekend windows. The DA extension writes ManagedSettings on `intervalDidStart`. This works through reboot, force-quit, airplane mode, and BFU.
- **Heartbeat DA schedule**: a 15-minute repeating DeviceActivityEvent whose extension reads an App Group pending-command queue and applies it. This is the bottom-floor catch for ad-hoc commands when push fails.

### Layer 2 — Real-time remote commands

- **APNs alert push as the primary channel**, not silent push. Yes, the user sees it. That's a feature, not a bug — the parent sending a "lock now" is a moment that warrants a banner. Use a Notification Service Extension to apply ManagedSettings before display.
- **Silent push as a parallel quieter channel** that the backend sends *alongside* the alert. If the silent path delivers (suspended or backgrounded scenarios), the alert is harmless redundancy.
- **No PushKit. No reliance on BGTaskScheduler for command delivery.**

### Layer 3 — Failure detection and parent escalation

- **Backend last-seen heartbeat**: the DA extension pings the backend every 15 minutes via the App Group queue mechanism. If silent for >N hours, parent gets a "Liam's device is offline / has been force-quit" notification on their device.
- **Critical Alerts entitlement application** for parent-side alerts only (not child-side enforcement). Sets up the "child has tampered" alarm channel that bypasses Focus.

### Layer 4 — Onboarding instrumentation

- **Mandatory parent-owned Screen Time passcode** at first run. Without this, scenario 10 (auth revocation) is trivially defeated.
- **"Don't Allow Deleting Apps" walkthrough** with a deep link to Settings (`App-prefs:` URL). Explicit warning that Offload remains possible.
- **Optional supervised-mode track** for technically capable parents — documentation on AC2 setup, Mosyle/Jamf Now sign-up flow, and the trade-offs (one-time wipe required). Position as "Advanced Protection."

### Residual unsolvable cases (be honest with the customer)

- Child knows Screen Time passcode → all bets off.
- Child force-quits + airplane mode + reboots in BFU → only pre-staged policy enforces; no new commands land.
- iOS major update may re-issue tokens or break the DA extension intermittently — plan for a "shield rebuilder" that re-applies all policy on app foreground.

---

## Section 5: Open questions (recommended for empirical testing)

These could not be answered authoritatively from documentation or engineering blogs. Test on real iPhones running iOS 17.5+ and 18.x.

1. **Does a `DeviceActivityMonitor` extension fire `intervalDidStart` while the device is in BFU?** The schedule is in a system process, but the extension may be marked Data Protection class B/C and refuse to launch pre-unlock. Critical for the bedtime-through-overnight-reboot scenario. (Hypothesis: fires after first unlock; *may* fire at scheduled time even in BFU but with delay.)

2. **Does `revokeAuthorization()` propagate immediately to a running DA extension, or does the extension continue to write ManagedSettings until next launch?** Determines how fast the "revoke and play games" attack lands.

3. **Does deleting the app with "Don't Allow Deleting Apps" set leave shields in place if the user uses "Offload App"?** The shields are keyed to the bundle; offload preserves it. Expect ✓ but verify.

4. **Can a Notification Service Extension write `ManagedSettingsStore` on alert push delivery, and does the write persist if the app is force-quit?** This would make alert push a real enforcement channel, not just a UI notification.

5. **What is the actual silent-push delivery rate when sending one push every 30 minutes to a force-quit child app?** Apple's flag is documented as sticky-until-relaunch, but [Forum 685525](https://developer.apple.com/forums/thread/685525) notes "in some circumstances iOS will not honour this flag." Quantify.

6. **iOS 18.x specifically: does "Don't Allow Deleting Apps" + Screen Time passcode actually prevent deletion 100% of the time, or are the bug reports in [Apple Community 255785091](https://discussions.apple.com/thread/255785091) representative of a broader regression?**

7. **Is there a documented or undocumented mechanism for an MDM-less app to enroll into supervised mode?** Sources reviewed all say no, but third-party MDM vendors (Mosyle, Jamf, Hexnode) keep marketing "consumer parent" SKUs — confirm whether any of them have an over-the-air supervision path Apple has quietly enabled, or whether they're all packaging the same AC2-on-Mac dance with prettier UX.

---

## Sources

- Apple — [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing_background_updates_to_your_app)
- Apple — [BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler)
- Apple — [DeviceActivity](https://developer.apple.com/documentation/deviceactivity), [DeviceActivitySchedule](https://developer.apple.com/documentation/deviceactivity/deviceactivityschedule)
- Apple — [ManagedSettings](https://developer.apple.com/documentation/managedsettings)
- Apple — [FamilyControls revokeAuthorization](https://developer.apple.com/documentation/familycontrols/authorizationcenter/revokeauthorization(completionhandler:))
- Apple — [Critical Alerts entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts)
- Apple — [Configuring Family Controls](https://developer.apple.com/documentation/xcode/configuring-family-controls)
- Apple — [Supervise devices with Apple Configurator](https://support.apple.com/guide/apple-configurator-mac/supervise-devices-apd9e4f64088/mac)
- WWDC21 — [Meet the Screen Time API (session 10123)](https://developer.apple.com/videos/play/wwdc2021/10123/)
- WWDC22 — [What's new in Screen Time API (session 110336)](https://developer.apple.com/videos/play/wwdc2022/110336/)
- Apple Forum — [Background fetch after app is force-quit (666149)](https://developer.apple.com/forums/thread/666149)
- Apple Forum — [iOS Background Execution Limits (685525)](https://developer.apple.com/forums/thread/685525)
- Apple Forum — [iOS 13 PushKit VoIP restrictions (117939)](https://developer.apple.com/forums/thread/117939)
- Apple Forum — [eventDidReachThreshold not firing (737741)](https://developer.apple.com/forums/thread/737741)
- Frederik Riedel — ["State of the Screen Time API 2024"](https://riedel.wtf/state-of-the-screen-time-api-2024/)
- Pushwoosh — [Understanding Silent Push Behavior on iOS](https://help.pushwoosh.com/hc/en-us/articles/26713265335581-Understanding-Silent-Push-Notification-Behavior-and-Limits-on-iOS)
- Mohsin Khan — ["Silent Push Notifications: Opportunities, Not Guarantees"](https://mohsinkhan845.medium.com/silent-push-notifications-in-ios-opportunities-not-guarantees-2f18f645b5d5)
- letvar — ["Time After Screen Time, part 3: DeviceActivity Monitor Extension"](https://letvar.medium.com/time-after-screen-time-part-3-the-device-activity-monitor-extension-284da931391b)
- Julius Brussee — [Developer's Guide to Apple's Screen Time APIs](https://medium.com/@juliusbrussee/a-developers-guide-to-apple-s-screen-time-apis-familycontrols-managedsettings-deviceactivity-e660147367d7)
- SimpleMDM — [What is iOS Supervised Mode](https://simplemdm.com/blog/what-is-ios-supervised-mode-how-do-i-activate-supervision/)
- Mosyle — [Parent product overview](https://school.mosyle.com/parents/)
- Apple Community — [iOS 18 cannot delete apps (255785091)](https://discussions.apple.com/thread/255785091)
- Hacker News — [Apple's Critical Alert policy (2023) discussion](https://news.ycombinator.com/item?id=43922698)
