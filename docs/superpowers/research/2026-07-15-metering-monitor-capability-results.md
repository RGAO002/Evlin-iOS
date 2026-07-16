# Metering Monitor Capability Results

Date observed: 2026-07-16

Status: Partial physical matrix complete. The iPad result is sufficient to
select the conservative implementation branch. A K-mode iPhone result remains
pending because the connected iPhone is a P-mode device.

## Build Under Test

- iOS commit: `77c62897dd10f4ce3d63ba24fa94367da8bea387`
- Backend commit: `ceff324c43705c9ac5ca59b14661dded2c0bc0f7`
- Xcode: 26.3 (`17C529`)
- SDK: iPhoneOS 26.2
- Configuration: signed Debug build
- PushApplier deployment target: 17.6 in Debug and Release
- Probe canonical timezone: `Asia/Tokyo`
- Tokens, device identifiers, and extracted plist files are intentionally not
  recorded.

## Physical Devices

| Device | OS | Evlin role | Result status |
|---|---|---|---|
| iPad (10th generation) | iPadOS 26.4.2 | K mode | DAM and NSE runs complete |
| iPhone | Not recorded | P mode | Not run; not a valid K-side probe host |

No claim is made about physical iOS/iPadOS 17.6 behavior. The deployment target
was compile-audited in Task 5, but no 17.6 physical device was used.

## iPad Results

The same Debug build was installed on the iPad. The operator opened the K-side
Command Delivery diagnostics and tapped `Run DAM monitor probe`. Codex then
force-terminated the main Evlin process and extracted the App Group preference
file after the callback windows.

### DAM-Origin

Two heartbeat callbacks independently installed probe schedules:

| Sequence | Superseded active | Stopped | Replacement active | Observation deadline |
|---|---|---|---|---|
| 1 | 16:20:21Z | 16:20:36Z | 16:20:51Z | 16:23:59Z |
| 2 | 16:21:20Z | 16:21:35Z | 16:21:50Z | 16:23:59Z |

For both sequences:

- stopped activity start returned `ok`, followed by an immediate stop call;
- initial active start returned `ok`;
- same-name replacement returned `ok`;
- no stopped callback was observed;
- no superseded callback was observed;
- no replacement callback was observed;
- the shared callback key remained absent.

Decision: **not proven / conservative branch**. A successful
`startMonitoring` return from the DAM extension did not produce the required
daemon callback.

### NSE-Origin

With the main Evlin app still force-terminated, the local sender issued one
single-token sandbox APNs probe. APNs returned HTTP 200, and the operator
confirmed that the visible `Metering monitor probe` notification arrived.

| Superseded active | Stopped | Replacement active | Observation deadline |
|---|---|---|---|
| 16:26:13Z | 16:26:28Z | 16:26:43Z | 16:27:47Z |

Observed:

- NSE stopped activity start returned `ok`, followed by an immediate stop;
- NSE initial active start returned `ok`;
- NSE same-name replacement returned `ok`;
- the notification proved the NSE ran while the main app was terminated;
- no stopped callback was observed;
- no superseded callback was observed;
- no replacement callback was observed;
- the shared callback key remained absent.

Decision: **not proven / conservative branch**. APNs can wake the NSE after
force-quit, but an NSE `startMonitoring` success did not produce the required
DeviceActivity callback.

## Four-Cell Matrix

| Device | Origin | Start/replace/stop | Stopped and superseded absent | Replacement callback | Decision |
|---|---|---|---|---|---|
| K-mode iPad | DAM heartbeat | All calls returned success/called | Yes | No | Not proven |
| K-mode iPad | NSE push | APNs 200; notification visible; all calls returned success/called | Yes | No | Not proven |
| K-mode iPhone | DAM heartbeat | Not run | Not run | Not run | Pending |
| K-mode iPhone | NSE push | Not run | Not run | Not run | Pending |

## Branch Decision

The iPad failure selects the conservative branch regardless of a later iPhone
result:

1. NSE may persist the newest policy, rule, or tombstone and wake state.
2. DAM/main app remains the production monitor owner.
3. The UI must not claim enforcement until applied-version readback confirms it.
4. Phase 3 must retain the continuous-monitor fallback with stable generation
   CAS and acknowledgement.
5. This probe does not authorize exact canonical-midnight rebase or NSE-primary
   production ownership.

A later K-mode iPhone run should still fill the remaining two matrix cells for
device-specific evidence. Only a separately reviewed physical canonical-day
boundary test may change any context-specific midnight branch.
