# Phase 4 Physical Metering Gate

Status: PENDING

This report is intentionally incomplete. Building the DEBUG probe or passing
simulator tests does not constitute physical verification.

| Gate | Required evidence | Status |
|---|---|---|
| P4-DEVICE-1 | One unused selected app stays unshielded for 90 seconds, then produces one physically plausible callback and one limit shield after one minute of real foreground use. | PENDING |
| P4-DEVICE-2 | Gate pause, callback, app termination, relaunch, and conservative successor resume preserve raw audit data without charging paused use. | PENDING |
| P4-DEVICE-3 | A newer clear tombstone survives replay of an older set through another delivery channel. | PENDING |
| P4-DEVICE-4 | Two enrolled child devices retain independent rule, token, arm, receipt, and usage attribution. | PENDING |

## Required Capture

- Device model and OS
- Build commit SHA and local timezone
- Selected token digest, rule ID, ordering token, arm ID, activity/event names
- Timestamped arm provenance and `includesPastActivity` readback
- Timestamped callback decision/reason, shield source, and applied receipt
- Screenshots, exported logs, and durable store-byte digest

phase_complete: false
releasable: false
