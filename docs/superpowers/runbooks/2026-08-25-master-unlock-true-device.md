# Master Unlock cross-stack acceptance

Date: 2026-08-26

## Immutable inputs

- Backend branch: `feature/master-unlock-override`
- Backend tested SHA: `4fc3a6c`
- iOS branch: `visual-v2`
- iOS tested SHA: `2eeb770`
- Backend creation flag: off by default (`master_unlock_creation_enabled=false`)
- Signed archive: `/Users/fred/Downloads/Evlin-visual-v2-2eeb770.xcarchive`
- Development IPA: `/Users/fred/Downloads/Evlin-visual-v2-2eeb770/Evlin iOS.ipa`
- App version/build: `1.1 (2)`
- Signing team: `D9FM36P37F`

Both branches are pushed to origin. Neither branch has been merged into its
production main branch by this acceptance record.

## Automated gate

| Layer | Evidence | Result |
| --- | --- | --- |
| Backend focused | Override model, API, command ordering, expiry, reflection/task/app-limit integration | 118 passed |
| Backend adjacent | Selected set, earned time, task lock, app limit, command delivery, pairing, account deletion, reflection | 349 passed; 18 baseline failures reproduced at `dd61ac7` |
| Backend migration | Feature migration upgrade/downgrade/upgrade against PostgreSQL | 1 passed |
| Alembic topology | `2026_08_25_child_unlock_override` | one head |
| iOS feature/UI | Master projection/operation, override store/wire/enforcement/expiry/identity teardown, app-limit slot accounting, command poller, phone snapshots | 185 passed |
| iOS metering isolation | Authoritative correction, conservative resume, rollover, cold reopen, production integration, app-limit pause/recovery, task/reflection locks | 190 passed |
| iPad visual gate | All Profile snapshots on iPad A16 | passed |
| Release build | Generic iOS Release, main app and embedded extensions | passed |
| Signed archive/export | Development-signed archive and IPA from tested SHA | passed |

One old correction race test required a contract correction after the CAS
store migration: either concurrent writer may win, but the result must be
serializable. The old "callback must hold the root lock first" assertion failed
on clean `origin/main` as well. The replacement test passed in the 190-test
metering gate and preserves both legal outcomes without permitting lost work.

The parent-unlock DeviceActivity expiry callback was also hardened before this
record: it now performs only a synchronous, revision-scoped local expiry and
shield recomputation. It does not wait on the scheduler, XPC, or network. A
late callback from an older revision cannot expire a newer override.

## Deployment gate

Do not enable the UI against production until the backend feature commit is
deployed and its migration is at head. The creation flag remains off during
migration verification. Enable only for the designated internal family after
the API smoke test below succeeds.

## Pre-device smoke test

- [ ] Deploy backend SHA `4fc3a6c` to a non-production service.
- [ ] Confirm the database reports one Alembic head.
- [ ] Create a 15-minute override, read it back, cancel it, then create a
      one-minute override and observe expiry commands/receipts.
- [ ] Confirm a stale lower revision cannot replace a newer desired state.
- [ ] Confirm Reflection remains authoritative while an override is active.

## Device set

| Role | Device | CoreDevice ID | Install |
| --- | --- | --- | --- |
| Parent | Fred's iPhone XS Max | `BEBBD1B3-F848-5102-B6B8-26EEACB3BA1B` | pending; device offline at archive time |
| Kid 1 | Liam's iPhone 11 | `F5946523-B50E-55D4-9305-4690E89929E0` | pending backend staging gate |
| Kid 2 | Ruoping's iPad 10th gen | `767F867E-8CA2-59C4-B487-41D55B671095` | pending backend staging gate |

Install the same IPA on all three with `devicectl`, without Xcode Run or a
debugger. Capture each device's current DAM trace sequence before installation.

## True-device scenarios

### 1. Duration and force-quit expiry

- [ ] Unlock for 15 minutes across both K devices.
- [ ] Force-quit both K apps immediately.
- [ ] Both devices unlock, show the same persisted expiry, and re-lock at expiry.
- [ ] P side progresses pending -> confirmed without claiming success early.

### 2. Accounting continuity

- [ ] Record epoch and route IDs before override.
- [ ] Use a pool-selected app and an app with an existing per-app limit.
- [ ] Pool and per-app usage continue to increase during override.
- [ ] Epoch and route IDs remain unchanged; no gate pause or fresh re-arm occurs.

### 3. Unfinished task

- [ ] With an unfinished task, Master Unlock offers a duration and states that
      the task is not being approved.
- [ ] At expiry, the task lock returns if the task remains incomplete.
- [ ] Completing the task prevents that source from returning.

### 4. Reflection priority

- [ ] Start Reflection during an active override.
- [ ] Reflection shields immediately and hides the Master Button.
- [ ] Completing Reflection returns to the still-valid override, or to current
      rules if the override expired meanwhile.
- [ ] The Reflection record is never removed by a Master Unlock command.

### 5. Asymmetric offline devices

- [ ] Apply while one K device is offline; P side names the waiting device.
- [ ] Bring it online and confirm convergence to the same revision.
- [ ] Repeat with one device offline through expiry; foreground/poll/NSE/DAM
      recovery must converge without a false green parent state.

### 6. Two-parent conflict

- [ ] Parent A unlocks while Parent B locks or cancels from a stale screen.
- [ ] Highest server revision wins on backend, P side, both K mirrors, shields,
      and expiry schedules.
- [ ] Superseded commands do not produce a visible lock/unlock flap.

## Memory and daemon acceptance

- [ ] DAM slot diagnostics include the override expiry activity and stay within
      the existing slot budget.
- [ ] Compare trace `beforeState -> afterState` footprint distribution with the
      pre-install window; p95 and peak must not regress.
- [ ] No parent-unlock callback remains at `waitTimedOut` or lacks `exit`.
- [ ] No new extension `per-process-limit`, app watchdog, or `0xdead10cc` event
      appears during the test window.

## Merge decision

Merge/deploy is allowed only when all six scenarios and memory/daemon checks
are recorded as passed. Until then, rollback is simply: keep backend creation
disabled and do not distribute the `visual-v2` IPA outside the designated
devices.
