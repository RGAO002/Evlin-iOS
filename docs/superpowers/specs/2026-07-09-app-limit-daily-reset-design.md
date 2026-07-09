# Per-App Limit Daily Reset Design

**Date:** 2026-07-09

## Problem

Apple's `DeviceActivity` event counters restart for a new daily interval, but
Evlin's local per-app usage offset and reported high-water mark are currently
stored only by app-limit rule ID. Those local values survive midnight. The
monitor extension then adds yesterday's offset to today's fresh thresholds,
inflating usage and potentially applying an immediate limit shield.

Production evidence for Esen's single-device account showed this exact pattern:
Instagram carried 20 minutes into the next day and LinkedIn carried 45 minutes.

## Decision

Scope per-app usage state by both rule ID and usage date. The actual App Group
keys retain their existing prefixes:

```
evlin.appLimitUsageOffset.<rule-id>.<yyyy-mm-dd>
evlin.appLimitReported.<rule-id>.<yyyy-mm-dd>
```

Every read and write must use the same explicit `usageDate` that is sent with
the usage sample. This preserves usage through same-day monitor re-arms while a
different day naturally reads as zero. Correctness must not depend on an
`intervalDidStart` callback running exactly at midnight.

`EarnedTimeStore.swift`, which is compiled into both the main app and the
DeviceActivity monitor extension, will own the single shared date formatter.
It must use a Gregorian calendar, `en_US_POSIX`, and `TimeZone.current`. The
extension sample writer and the main-app state poller must both use this helper;
they may not maintain separate date implementations.

Legacy unscoped keys will not be migrated. They carry no date, so assigning them
to the current day could repeat the false-lock incident. Existing identity-reset
cleanup will continue removing both legacy and date-scoped keys by prefix.

Whenever either offset or reported usage is written for `(ruleID, usageDate)`,
the store inspects both date-scoped roots for that rule. If it observes a newer
stored date, it suppresses the incoming stale write without removing or setting
any key. Otherwise it removes only that rule's legacy unscoped keys and keys
strictly older than the incoming date; it never removes a newer date key.

The app and extension do not use a cross-process lock. Under a narrow
interleaving, an older writer can miss a concurrently-created newer key and add
an extra older key after the current writer's cleanup. The next current-date
write prunes that older key. Current-date reads remain correct because values
are date-scoped, and cleanup never deletes newer state.

## Data Flow

1. The shared store helper determines the sample's `usageDate` identically in
   the monitor extension and main app.
2. It reads the offset for `(ruleID, usageDate)`.
3. It adds that offset to non-budget measurement thresholds.
4. It records the reported high-water mark for `(ruleID, usageDate)`.
5. The state poller's same-day re-arm reads and updates the same date-scoped
   values.
6. On the next date, no matching keys exist for that date, so the effective
   offset and reported value are both zero. A rare extra older physical key is
   ignored by current-date reads and removed by the next current-date write.

## Compatibility And Safety

- Same-day task pauses and monitor re-arms keep already-counted usage.
- A new day cannot inherit yesterday's offset or reported high-water mark.
- Existing legacy values are ignored rather than guessed into a date.
- Newer-date state wins: an observed stale write is suppressed.
- Cleanup removes only that rule's legacy and strictly older date-scoped keys;
  it never removes newer state.
- A concurrent interleaving may leave an extra older key temporarily, but the
  next current-date write removes it without affecting current reads.
- Account/family identity teardown still sweeps all per-app usage keys.
- This patch does not change DeviceActivity enforcement thresholds, backend
  aggregation, or lock precedence.

## Tests

Tests against the real App Group `UserDefaults` will prove:

- an offset persists within the same date;
- an offset does not leak into a different date;
- a reported high-water mark persists within the same date;
- a reported high-water mark does not leak into a different date;
- a legacy unscoped key is ignored;
- one rule's values do not affect another rule;
- the app and extension use the same Gregorian/POSIX usage-date helper;
- writing a new date removes the same rule's older date and legacy keys without
  removing another rule's keys.
- writing D+1 offset and reported values, then attempting D offset and reported
  writes, preserves D+1 and leaves D reads at zero.

The iOS app and DeviceActivity monitor extension must both compile after the
change.

## Out Of Scope

- Correcting the existing New York/Los Angeles canonical-timezone mismatch;
- deleting already-corrupted production samples;
- automatically removing an already-applied limit shield;
- changing the backend's same-app, same-day usage inheritance policy.

Those require separate backend/data-repair work after this client-side source
of future corruption is closed.
