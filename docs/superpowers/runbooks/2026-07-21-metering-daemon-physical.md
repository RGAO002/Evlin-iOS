# Metering Daemon Physical Investigation

This runbook gathers evidence. It does not prove the metering feature is fixed.
Use one K device only until the v2 activation and topology results are recorded.

## Hard Rules

- Use a DEBUG build connected to the local backend. Do not enable protocol v2 on Render.
- Do not run `unshield_all`, `unblock_all`, or any debug reset while collecting baseline evidence.
- Do not change tasks, reflection state, limits, selection, timezone, or identity during a timed run.
- Record PASS, FAIL, or UNKNOWN. Do not infer a cause from a moving or frozen bar.
- Abort immediately if the diagnostics page records a global stop, owner mismatch, or daemon mismatch.

## 1. Start The Local Backend

In the backend repository, keep its existing `.env` values and override only the advertised protocol:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
METERING_EPOCH_ADVERTISED_VERSION=2 \
  .venv/bin/uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Confirm the K device's `baseURL` points to this Mac, not Render. The setting name is
`METERING_EPOCH_ADVERTISED_VERSION`; its production default remains `1`.

## 2. Establish One Clean Identity

1. Install the DEBUG K build on one device.
2. Pair it to the intended local account and child device. Do not reuse a different child's pairing.
3. On K, open **Parent Controls > Developer Tools > Metering Daemon**.
4. Tap **Refresh** once.
5. Record or export the page before running any timing test.

Required identity evidence:

| Row | Required value |
|---|---|
| app mode | `child` |
| identity ready | `yes` |
| owner mirror | same UUID as epoch owner |
| epoch owner | same UUID as owner mirror |
| GLOBAL STOPS | `0` since the journal was cleared |

If identity is not ready, stop. Re-pairing or identity repair is a separate operation and invalidates
the current timing run.

## 3. Prove Which Protocol Is Running

The **V2 activation evidence** section is the only protocol verdict. A bar moving is not evidence of v2.

Expected progression after the K app polls the local backend:

| Stage | Meaning | Allowed next action |
|---|---|---|
| `v1` | v2 was not selected | wait for a state poll; inspect backend advertisement |
| `dual_active_incomplete` | candidate exists but daemon/install evidence is incomplete | Refresh; inspect missing route/install/readback row |
| `dual_active_awaiting_activation` | exact daemon config exists but activation is not acknowledged | keep app open; inspect activation delivery |
| `v2_ready` with `V2 READY = YES` | ratchet, active route, active install, acknowledgement, and exact readback all agree | continue to v2 tests |
| `inconsistent` | local claims v2 but one or more physical facts disagree | abort and export journal |

`V2 READY = YES` requires all of these exact values:

- local selection `v2`;
- epoch and route UUIDs present;
- route lifecycle `active`;
- install phase `active`;
- activation ack `yes`;
- exact daemon readback `match` for every active dated route.

Do not proceed to reset, pause/resume, or earned-time conclusions while this row is `NO`.

## 4. Per-App Topology A/B

This test isolates Apple daemon behavior from backend policy. Both arms use the same app token,
timezone, one-minute threshold, and `includesPastActivity=true`; only the topology name changes.

1. Pick one app that has not been opened since local midnight.
2. On K, open **Parent Controls > Developer Tools > Command Delivery** and find
   **Per-App Legacy / V2 A-B**.
3. Select that one app.
4. Select **Legacy**, tap **Arm legacy 1-minute probe**, then use only that app for 90 seconds.
5. Return to Evlin. Record topology callbacks and the Metering Daemon readback. Tap **Stop topology probe**.
6. Without changing the selected app, select **V2**, arm it, then use only that app for 90 seconds.
7. Return and record the same rows. Stop the probe.

Result classification:

| Legacy readback/callback | V2 readback/callback | Result |
|---|---|---|
| match / callback | match / callback | PASS: both daemon topologies fire |
| match / callback | match / none | FAIL: v2 callback topology is isolated |
| match / none | match / none | UNKNOWN: Apple usage eligibility or selection is not controlled |
| missing or mismatch | any | FAIL: arm/readback layer failed; callback timing is not interpretable |
| any | missing or mismatch | FAIL: arm/readback layer failed; callback timing is not interpretable |

Do not use the production per-app rule during this A/B run.

## 5. V2 State Transitions

Run these only after `V2 READY = YES`. Export the journal before and after each row; change one
variable at a time.

| Run | Action | Required evidence |
|---|---|---|
| pause | create one incomplete task or start reflection | gate becomes paused; active monitor is not globally stopped |
| resume | complete the task or end reflection | one successor/recovery transition; exact readback returns to match |
| manual lock | tap the green manual lock button | manual shield changes; no DeviceActivity stop/start caused by the button |
| manual unlock | tap the red manual unlock button | only manual shield is removed; no global stop and metering stays armed |
| controlled reset | invoke the approved DEBUG/admin reset generation | new generation/epoch identity; old same-day high water is not presented as the new baseline |

For each timed check, use a five-minute earned threshold. Record daemon callback entries and backend
accepted samples separately from the P-side bar. The bar is a projection, not the physical source.

## 6. Abort Conditions

Stop the run and export the journal when any condition is true:

- owner mirror differs from epoch owner;
- app mode is not `child`;
- measurement selection is missing or changed during the run;
- any `stop_all` / **GLOBAL STOPS** entry appears;
- expected daemon configuration is missing or mismatched;
- v2 local selection is present but the activation stage is `inconsistent`;
- a daemon readback is initiated synchronously on the main thread;
- the app or extension is rebuilt, reinstalled, re-paired, or its Screen Time permission changes.

The inspector implementation is off-main, single-flight, and rate-limited. If Instruments or a hang
trace contradicts that fact on-device, classify the run FAIL and keep the trace.

## 7. Evidence Sheet

Fill every row without causal language:

| Check | Status | Device time | Owner UUID | Route/arm UUID | Latest exact readback | Callback/sample evidence | Journal export |
|---|---|---|---|---|---|---|---|
| identity | UNKNOWN | | | | | | |
| v2 activation | UNKNOWN | | | | | | |
| legacy per-app topology | UNKNOWN | | | | | | |
| v2 per-app topology | UNKNOWN | | | | | | |
| task/reflection pause | UNKNOWN | | | | | | |
| resume | UNKNOWN | | | | | | |
| manual lock | UNKNOWN | | | | | | |
| manual unlock | UNKNOWN | | | | | | |
| controlled reset | UNKNOWN | | | | | | |

Only after this table identifies a reproducible failing boundary should a production RED test and fix
be written. Do not combine failures from different owner identities or from runs separated by a global stop.
