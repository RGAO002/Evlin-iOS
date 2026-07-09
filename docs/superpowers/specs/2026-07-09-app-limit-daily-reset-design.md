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

Date-scoped keys must remain bounded. Whenever either offset or reported usage
is written for `(ruleID, usageDate)`, the store first removes that rule's offset
and reported keys for every other date, including the legacy unscoped keys.
This write-path pruning needs no timer and keeps at most the current date's two
usage keys per rule.

## Data Flow

1. The shared store helper determines the sample's `usageDate` identically in
   the monitor extension and main app.
2. It reads the offset for `(ruleID, usageDate)`.
3. It adds that offset to non-budget measurement thresholds.
4. It records the reported high-water mark for `(ruleID, usageDate)`.
5. The state poller's same-day re-arm reads and updates the same date-scoped
   values.
6. On the next date, no matching keys exist, so the effective offset and
   reported value are both zero.

## Compatibility And Safety

- Same-day task pauses and monitor re-arms keep already-counted usage.
- A new day cannot inherit yesterday's offset or reported high-water mark.
- Existing legacy values are ignored rather than guessed into a date.
- A write for a new date removes that rule's older date-scoped and legacy keys.
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

The iOS app and DeviceActivity monitor extension must both compile after the
change.

## Out Of Scope

- Correcting the existing New York/Los Angeles canonical-timezone mismatch;
- deleting already-corrupted production samples;
- automatically removing an already-applied limit shield;
- changing the backend's same-app, same-day usage inheritance policy.

Those require separate backend/data-repair work after this client-side source
of future corruption is closed.
