# Profile Multi-Device Lock Design

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
- If no device is locked, tapping the CTA sends `lock-selected` to every device.
- If any device is locked, tapping the CTA sends `unlock-selected` to every
  device. This makes mixed state converge to fully unlocked without changing the
  existing button copy.
- Poll each targeted device independently for its requested acknowledged state.
- Treat a device as queued when its endpoint accepted the command but its ACK did
  not arrive before the existing polling deadline.
- A request failure for one device must not prevent attempts for the remaining
  devices.

## UI State And Errors

The existing CTA remains disabled while the batch is running. Its aggregate
state is:

- pending when no device state has been fetched successfully;
- shielded when at least one device is shielded;
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
- Do not share one device's `list_id` carry into another device. Locked-set IDs
  are device-scoped; the existing local carry is applied only where its owning
  device is unambiguous.

## Testing

- Unit-test aggregate CTA intent for all-clear, all-locked, and mixed states.
- Unit-test target resolution excludes invalid UUIDs and includes both old and
  newly paired devices.
- Unit-test batch-result messaging for all-ACKed, queued, and partial failure.
- Run the focused iOS test target and build the app to catch Swift concurrency
  and view compilation regressions.

