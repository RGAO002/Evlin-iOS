# Profile Multi-Device Lock Design

> **SUPERSEDED (2026-07-15):** This document is historical and must not be used
> to define the Profile CTA. Its "any source means Unlock" and "Unlock removes
> automatic sources" behavior conflicts with the approved
> [Metering Epoch Reliability Design](2026-07-15-metering-epoch-design.md),
> especially Section 3.6 and Phase 0. The CTA now adds/removes `manual` only;
> automatic reasons use separate policy-specific actions.

## Problem

The Profile CTA says `Lock/Unlock <child>'s devices`, but it resolves one
`child_device_id`. Pairing an additional device overwrites the locally preferred
device ID, so the CTA starts targeting only the newly paired device. Older
devices receive neither a command nor an APNs wake.

## Scope

Change only the child Profile lock/unlock CTA. Keep the existing backend
single-device endpoints and the current user-facing button copy. Per-device app
catalogs, locked sets, commands, delivery, and acknowledgements remain isolated
by device ID.

## Behavior

- Resolve every valid device UUID in the selected child's live `FamilyStore`
  record. Do not use `evlin.childDeviceID` to narrow this child-level action.
- Fetch each device's acknowledged lock state and aggregate it for the CTA.
- Determine whether a device is shielded from the `covering_sources` returned by
  that device's identity-safe Locked Set lock-state response. Every non-empty
  source list counts (`manual`, `earnedTime`, and `taskPause`/wire equivalents):
  the backend `unlock-selected` endpoint removes all of these sources for that
  selected set. Do not filter the aggregate to manual locks only.
- If no device is locked, tapping the CTA sends `lock-selected` to every device.
- If any device is locked, tapping the CTA sends `unlock-selected` to every
  device. This makes mixed state converge to fully unlocked without changing the
  existing button copy.
- On an exhausted day, unlocking first calls the profile-scoped
  `unlock-override` once to suppress renewed earned-time auto-locking, then still
  sends `unlock-selected` to every child device. `unlock-override` changes the
  child-day state but creates no device command, so it must not return early or
  replace the per-device fan-out. The local App Group override write remains an
  immediate local safeguard, not evidence that any child device acknowledged.
- Aggregate exhaustion as child/profile state: if any fetched device reports
  exhausted, the unlock path performs the one profile override before fan-out.
- Poll each targeted device independently for its requested acknowledged state.
- Treat a device as queued when its endpoint accepted the command but its ACK did
  not arrive before the existing polling deadline.
- A request failure for one device must not prevent attempts for the remaining
  devices.

## UI State And Errors

The existing CTA remains disabled while the batch is running. Its aggregate
state is:

- pending when no device state has been fetched successfully;
- shielded when at least one device's Locked Set has non-empty
  `covering_sources`, regardless of which selected-set source is present;
- clear when all successfully fetched devices are clear.

After a batch:

- all devices acknowledged: clear the note and show the aggregate real state;
- accepted but not all acknowledged: show a queued note with the number of
  devices still waiting;
- one or more request failures: show a concise partial-failure message with the
  failed device count; successful devices retain their result.

If the child has no valid device UUIDs, keep the CTA disabled.

## Implementation Boundaries

- Add a pure aggregate-state helper so mixed/all-clear/all-locked behavior is
  unit-testable without rendering `ProfileView`.
- Update `ProfileView` to derive target IDs from the child's complete device
  collection, fan out API calls, and aggregate per-device ACK polling.
- Do not add a backend batch endpoint and do not change pairing persistence in
  this fix; other single-device workflows may still use the preferred ID.
- Do not call the existing global `applyListIDIfNeeded` carry from a multi-device
  refresh, command response, or ACK poll. Locked-set IDs are device-scoped and
  the current carry has no device-keyed storage, so applying several responses
  would be last-writer-wins corruption. A future device-keyed carry can restore
  this optimization; it is outside this fix.

## Testing

- Unit-test aggregate CTA intent for all-clear, all-locked, and mixed states.
- Unit-test that earned-time/task-pause Locked Set sources count as shielded and
  route through full-device unlock rather than being ignored.
- Unit-test exhausted unlock sequencing: one profile override followed by one
  `unlock-selected` attempt per valid child device, with no early return.
- Unit-test target resolution excludes invalid UUIDs and includes both old and
  newly paired devices.
- Unit-test batch-result messaging for all-ACKed, queued, and partial failure.
- Run the focused iOS test target and build the app to catch Swift concurrency
  and view compilation regressions.
