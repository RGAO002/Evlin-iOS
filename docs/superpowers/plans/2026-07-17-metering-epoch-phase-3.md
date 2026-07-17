# Metering Epoch Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task by task in the existing iOS main workspace. Do not create a worktree, delegate work, or push.

**Goal:** Replace the device's legacy earned-metering lifecycle with one owner-fenced, versioned Device Epoch Store; exact Phase 2 registration/sample transport; strict callback trust; continuous pause accounting; canonical rollover; and compare-and-swap self-lock provenance, then remove the Phase 3 R-16 guards in six independently reversible commits.

**Architecture:** `MeteringEpochContract.swift` remains the pure contract. A single App Group transaction owns generation identity, daily epoch identity, exact selection bytes, monitor stop targets, registration/sample work, pause runtime, and earned self-lock receipts. The app and Device Activity Monitor (DAM) extension share the clock and store, while only the app/DAM production path may own monitors. Every callback is pure-validated and owner-rechecked before any business effect. Protocol 1 remains the wire until the matching protocol-2 epoch registration succeeds.

**Technology:** Swift 6, Swift Testing/XCTest, FamilyControls, DeviceActivity, ManagedSettings, CryptoKit, App Group file persistence plus `flock`, URLSession, iOS/iPadOS 17.6 deployment builds, and the existing FastAPI Phase 2 contract as an external dependency.

---

## Execution Rules

Run every command from the named repository and stop immediately on a failed assertion.

- iOS repository: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS`
- backend repository: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend`
- rulebook: `/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md`
- canonical design: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/specs/2026-07-15-metering-epoch-design.md`
- capability result: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/research/2026-07-15-metering-monitor-capability-results.md`

Before Task 1, record the baseline without changing it:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git status --short --branch
git diff -- 'Evlin iOS/ContentView.swift' 'Evlin iOS/Services/APIClient.swift' 'Evlin iOS/Views/Onboarding/OnboardingCoordinator.swift'
git ls-files --others --exclude-standard
```

The current unrelated `ContentView.swift`, `APIClient.swift`, onboarding, Xcode user-state, debugger, `.DS_Store`, and untracked Phase 2 plan changes belong to the user. Preserve every unrelated byte. Where this plan must add metering fields to `APIClient.swift`, stage only the exact metering hunks with `git add -p` and verify the cached diff does not contain the user's pre-existing changes.

For every task:

1. Add the named test first and run the RED command.
2. Implement only the code needed by that test.
3. Run the focused and task-full commands.
4. Stage only the files listed by the task.
5. Run `git diff --cached --check`, inspect `git diff --cached --stat`, inspect the full `git diff --cached`, and confirm `git diff --cached --name-only` is a subset of the task's file list.
6. Commit with the exact task message. Never amend another task's commit.

No task may alter Profile manual-button behavior, Render, TestFlight, production databases, or unrelated onboarding/beta-agreement work. No guard is deleted until its authoritative replacement and RED/GREEN tests are committed. Do not introduce a freshness flag, headroom rule, raw-threshold ceiling, debounce, lifecycle flag, quarantine, transition latch, or veto outside the registered epoch state.

## Pinned Backend Contract

The implementation must encode these live Phase 2 interfaces exactly; the device must not infer a different contract:

```text
GET  /api/v1/child/state
POST /api/v1/child/earned-time/epochs
POST /api/v1/child/earned-time/sample
Header on both POSTs: X-Evlin-Child-Device-ID: <canonical UUID>
```

`GET /child/state` advertises `metering_protocol_version` (absent decodes as 1) and `earned_time_runtime` with `usage_date`, `timezone`, `policy_revision`, `daily_pool_minutes`, `device_cap_minutes`, `remaining_minutes`, and `estimated_minutes`.

Registration request fields are exactly `protocol_version`, `epoch_id`, `device_id`, `usage_date`, `timezone`, `policy_revision`, `measurement_selection_digest`, `enforcement_set_id`, `started_at`, `base_accepted_minutes`, and `reason`. A 200 response is `registered` or `already_registered`, protocol 2, and a `snapshot`. The only structured conflict is HTTP 409 with `code == "authoritative_base_mismatch"` and `authoritative_snapshot`; all other non-2xx responses use FastAPI's `detail` envelope. A successful registration is the backend's only per-device v2 ratchet.

Registration errors are exact: 403 child-device-context mismatch; 404 child device not found; 503 `metering_v2_not_advertised`; 422 `device_missing_child_profile_id`; and 409 `started_at_invalid`, `timezone_mismatch`, `usage_date_mismatch`, `started_at_usage_date_mismatch`, `started_at_in_future`, `policy_revision_mismatch`, `enforcement_set_mismatch`, `replacement_reason_mismatch`, `gate_resume_requires_paused_predecessor`, `gate_resume_requires_open_gate`, `epoch_scope_conflict`, `epoch_immutable_mismatch`, or `epoch_retired`.

Sample request fields are exactly `device_id`, `usage_date`, `timezone`, `activity_name`, `event_name`, `threshold_minutes`, `estimated_minutes`, `observed_at`, `client_sample_id`, plus either the v2 pair `protocol_version`/`epoch_id` or the v1 pair `generation_armed_at`/`generation_offset_minutes`. A sample response is the `DeviceDaySnapshot` fields `child_device_id`, `usage_date`, `estimated_minutes`, `cap_minutes`, `child_day_state`, `used_minutes`, `remaining_minutes`, `counted`, and `warning`.

Sample HTTP errors are exact: 403 `child device context mismatch`, 404 `child device not found`, 422 `device_missing_child_profile_id`, and 409 `device_identity_changed`. Protocol/gate validation failures return HTTP 200 with `counted == false` and one of the terminal warning strings classified in Task 2.

Protocol 2 uses activity prefix `evlin.earned.budget.` and event `evlin.earned.t<threshold>`. Protocol 1 must continue sending the adjusted estimate as both `threshold_minutes` and `estimated_minutes`. Protocol 2 sends raw threshold as `threshold_minutes` and pause-adjusted estimate as `estimated_minutes`.

## Target And Build Matrix

New shared source membership is explicit because filesystem-synchronized groups do not add files to extension exception lists automatically.

| File | App | DAM | Push NSE | Shield Config | Report |
|---|---:|---:|---:|---:|---:|
| `MeteringRuntimeInfrastructure.swift` | yes | yes | yes | no | no |
| `DeviceEpochStore.swift` | yes | yes | yes | no | no |
| `MeteringEpochWire.swift` | yes | yes | yes | no | no |
| `EarnedMeteringCallback.swift` | yes | yes | no | no | no |
| `EarnedSelfLock.swift` | yes | yes | no | no | no |

`MeteringDeviceActivityCenter` remains app/DAM-only in `EarnedBudgetScheduler.swift`. The Push NSE receives the shared clock/store solely to read canonical state; its Release build has no earned `startMonitoring` call or monitor-owner capability. `DEBUG` clock controls are enclosed by compile-time `#if DEBUG` and must have no symbol or preference key in Release products.

## Authoritative State Model

The exact persisted envelope introduced in Task 4 is:

```swift
nonisolated struct EpochRegistrationWork: Codable, Equatable, Sendable {
    let request: EpochRegistrationRequestDTO
    var attemptCount: Int
    var nextAttemptAt: Date
}

nonisolated struct EpochSampleWork: Codable, Equatable, Sendable {
    let request: EpochSampleRequestDTO
    let epochID: UUID?
    var attemptCount: Int
    var nextAttemptAt: Date
}

nonisolated struct DeviceEpochStoreState: Codable, Equatable, Sendable {
    static let currentVersion = 3
    var version: Int
    var ownerDeviceID: UUID?
    var generation: DeviceMeteringGeneration?
    var dailyEpoch: DeviceDailyEpoch?
    var registrationQueue: [EpochRegistrationWork]
    var sampleQueue: [EpochSampleWork]
    var monitorStopWork: [MeteringMonitorStopWork]
    var earnedSelfLock: EarnedSelfLockReceipt?
}

nonisolated struct MeteringMonitorStopWork: Codable, Equatable, Sendable {
    let ownerDeviceID: UUID
    var activityNames: [String]
}

nonisolated struct DeviceMeteringGeneration: Codable, Equatable, Sendable {
    let key: MeteringGenerationKey
    let activityName: String
    let measurementSelectionBytes: Data
    let installedAt: Date
}

nonisolated struct DeviceDailyEpoch: Codable, Equatable, Sendable {
    let epochID: UUID
    let key: MeteringEpochKey
    let startedAt: Date
    let baseAcceptedMinutes: Int
    let replacementReason: MeteringEpochReplacementReason
    var registeredAt: Date?
    var registration: MeteringRegistrationState
    var lastRawThresholdMinutes: Int
    var excludedRawMinutes: Int
    var isPaused: Bool
    var resumeBoundaryPending: Bool
}

nonisolated enum MeteringRegistrationState: Codable, Equatable, Sendable {
    case legacyV1
    case pendingV2(baseCorrectionUsed: Bool)
    case registeredV2
}

nonisolated struct EarnedSelfLockReceipt: Codable, Equatable, Sendable {
    let epochID: UUID
    let generationActivityName: String
    let recordKey: String
    let postMutationRecord: ShieldRecord
}
```

Only these six generation-key fields are stable identity: `protocolVersion`, `childDeviceID`, `canonicalTimezone`, `policyRevision`, `measurementSelectionDigest`, and `enforcementSetID`. `usageDate`, offsets, estimates, counters, timestamps, gate state, and retry state are forbidden from the generation key. The daily epoch key adds `usageDate`. The SHA-256 digest is computed over the exact bytes already persisted at `earned.measurementSelection`; normal reads must never decode and re-encode those bytes.

---

## Task 1: Inject The Shared Clock And DeviceActivityCenter

**Interfaces**

- Consumes: existing `MeteringClock`, App Group `group.com.evlin.ios`, `DeviceActivityCenter.startMonitoring`/`stopMonitoring`, and scheduler APIs.
- Produces: `AppGroupMeteringClock`, DEBUG-only `DebugMeteringClockOverride`, `MeteringDeviceActivityCenter`, and scheduler initializers that contain no concrete time/center construction.

**Files**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringRuntimeInfrastructure.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetScheduler.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringRuntimeInfrastructureTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED**

Add tests that inject a fixed clock and a recording center, then prove scheduler date construction and start/stop calls use only the injected values. Parse `project.pbxproj` to assert the new clock file belongs to app, DAM, and Push NSE; the center protocol belongs to app/DAM only. Add source assertions that `DebugMeteringClockOverride` is inside `#if DEBUG` and no Push NSE production source calls `startMonitoring` outside its existing DEBUG capability probe.

Use this exact seam:

```swift
@MainActor
protocol MeteringDeviceActivityCenter: AnyObject {
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws
    func stopMonitoring(_ activities: [DeviceActivityName])
}

extension DeviceActivityCenter: MeteringDeviceActivityCenter {}

nonisolated struct AppGroupMeteringClock: MeteringClock {
    var now: Date {
        #if DEBUG
        if let value = UserDefaults(suiteName: EarnedTimeStore.appGroupSuiteName)?
            .object(forKey: DebugMeteringClockOverride.key) as? Double {
            return Date(timeIntervalSince1970: value)
        }
        #endif
        return Date()
    }
}

#if DEBUG
nonisolated enum DebugMeteringClockOverride {
    static let key = "evlin.metering.debugClockNow"
    static func set(_ date: Date?, defaults: UserDefaults?) {
        defaults?.set(date?.timeIntervalSince1970, forKey: key)
    }
}
#endif
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringRuntimeInfrastructureTests' -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests' test
```

Expected RED: compile errors for missing `AppGroupMeteringClock`, `DebugMeteringClockOverride`, `MeteringDeviceActivityCenter`, and injectable scheduler initializers.

**Minimal implementation**

Give every scheduler/coordinator initializer explicit defaults, but store the dependencies and never reconstruct them:

```swift
@MainActor
final class EarnedBudgetScheduler {
    private let center: any MeteringDeviceActivityCenter
    private let clock: any MeteringClock

    init(
        center: any MeteringDeviceActivityCenter = DeviceActivityCenter(),
        clock: any MeteringClock = AppGroupMeteringClock()
    ) {
        self.center = center
        self.clock = clock
    }
}
```

Replace scheduler-local `Date()` and `DeviceActivityCenter()` construction with `clock.now` and `center`. Do not change arming policy in this task.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringRuntimeInfrastructureTests' -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'Evlin iOS' -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 build
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 build
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 build
find ~/Library/Developer/Xcode/DerivedData \( -path '*Release-iphoneos/Evlin iOS.app/Evlin iOS' -o -path '*Release-iphoneos/EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor' -o -path '*Release-iphoneos/EvlinPushApplier.appex/EvlinPushApplier' \) -type f -print0 | xargs -0 strings | rg -n 'DebugMeteringClockOverride|evlin\.metering\.debugClockNow' && exit 1 || true
```

Expected GREEN: tests/builds pass; the final symbol scan prints nothing.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/MeteringRuntimeInfrastructure.swift' 'Evlin iOS/Services/EarnedBudgetScheduler.swift' 'Evlin iOSTests/MeteringRuntimeInfrastructureTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: inject metering runtime dependencies'
```

## Task 2: Pin The Phase 2 Wire And Advertised-Version Input

**Interfaces**

- Consumes: live backend schemas in `app/schemas/earned_time.py`, routes in `app/api/routes/earned_time.py`, router prefix in `app/main.py`, and current `ChildStateResponse`/`PollEarnedTimeConfigDTO` decoding.
- Produces: exact Codable wire DTOs, terminal/retry registration and sample classifications, `effectiveMeteringProtocolVersion`, and `policyRevision` input. It does not persist a v2 ratchet.

**Files**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochWire.swift`
- Modify metering hunks only: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/APIClient.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/BigKid/BigKidModels.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochWireTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED**

Use literal JSON fixtures copied from the live schema to test every snake-case key, absent-advertisement fallback to 1, `policy_revision` decoding, registration 200, the structured base-mismatch 409, generic `detail`, and sample terminal warnings. Assert v1 and v2 paired metadata cannot be mixed by construction.

The Swift interface is exact:

```swift
nonisolated struct EpochRegistrationRequestDTO: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let epochID: UUID
    let deviceID: UUID
    let usageDate: String
    let timezone: String
    let policyRevision: String
    let measurementSelectionDigest: String
    let enforcementSetID: UUID
    let startedAt: Date
    let baseAcceptedMinutes: Int
    let reason: MeteringEpochReplacementReason
}

nonisolated struct EpochRegistrationResponseDTO: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case registered, alreadyRegistered = "already_registered" }
    let status: Status
    let epochID: UUID
    let meteringProtocolVersion: Int
    let snapshot: DeviceDaySnapshotDTO
}

nonisolated struct EpochRegistrationConflictDTO: Codable, Equatable, Sendable {
    let code: String
    let authoritativeSnapshot: DeviceDaySnapshotDTO
}

nonisolated enum EpochSampleProtocolDTO: Codable, Equatable, Sendable {
    case v1(generationArmedAt: Date, generationOffsetMinutes: Int)
    case v2(epochID: UUID)
}

nonisolated struct EpochSampleRequestDTO: Codable, Equatable, Sendable {
    let deviceID: UUID
    let usageDate: String
    let timezone: String
    let activityName: String
    let eventName: String
    let thresholdMinutes: Int
    let estimatedMinutes: Int
    let observedAt: Date
    let clientSampleID: String
    let protocolMetadata: EpochSampleProtocolDTO
}

nonisolated struct DeviceDaySnapshotDTO: Codable, Equatable, Sendable {
    let childDeviceID: UUID
    let usageDate: String
    let estimatedMinutes: Int
    let capMinutes: Int?
    let childDayState: String
    let usedMinutes: Int
    let remainingMinutes: Int
    let counted: Bool
    let warning: String?
}

nonisolated enum EpochRegistrationHTTPDisposition: Equatable, Sendable {
    case registered(EpochRegistrationResponseDTO)
    case authoritativeBaseMismatch(DeviceDaySnapshotDTO)
    case terminal(status: Int, detail: String)
    case retry(status: Int, detail: String?)
}

nonisolated enum EpochSampleHTTPDisposition: Equatable, Sendable {
    case accepted(DeviceDaySnapshotDTO)
    case terminal(DeviceDaySnapshotDTO)
    case terminalHTTP(status: Int, detail: String)
    case retry(status: Int, detail: String?)
}
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochWireTests' test
```

Expected RED: missing DTOs and missing `metering_protocol_version`/`policy_revision` decoding.

**Minimal implementation**

Use explicit `CodingKeys`. `EpochSampleRequestDTO.encode(to:)` must emit exactly one protocol pair. Add optional backend fields without breaking old child-state fixtures:

```swift
let meteringProtocolVersion: Int?
var effectiveMeteringProtocolVersion: Int { meteringProtocolVersion ?? 1 }

// EarnedTimeRuntime
let policyRevision: String?

// PollEarnedTimeConfigDTO uses literal snake-case stored properties.
let policy_revision: String?
```

Add `meteringProtocolVersion: Int? = nil` to `ChildStateResponse.init` and `policyRevision: String? = nil` to every explicit `EarnedTimeRuntime` initializer so existing v1 fixtures remain source- and wire-compatible.

Classify sample warnings `invalid_protocol_metadata`, `legacy_after_v2`, `stale_epoch`, `owner_mismatch`, `usage_date_mismatch`, `policy_revision_mismatch`, `event_namespace_mismatch`, `implausible_threshold`, `gate_resume_rebase_required`, and `accounting_paused` as terminal. Classify registration 4xx other than `authoritative_base_mismatch` as terminal and 408/429/5xx/network failures as retry. Do not write any local protocol version in this task.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochWireTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' -only-testing:'Evlin iOSTests/EarnedConfigCommandTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
./.venv/bin/python -m pytest -q tests/test_metering_epoch_registration.py tests/test_metering_epoch_sample_adapter.py tests/test_earned_time_protocol_ratchet.py tests/test_metering_epoch_phase2_integration.py
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -sdk iphonesimulator IPHONEOS_DEPLOYMENT_TARGET=17.6 build
```

Expected GREEN: exact wire fixtures round-trip and the unchanged backend Phase 2 suites pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/MeteringEpochWire.swift' 'Evlin iOS/Models/BigKid/BigKidModels.swift' 'Evlin iOSTests/MeteringEpochWireTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git add -p 'Evlin iOS/Services/APIClient.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: pin metering epoch phase 2 wire'
```

## Task 3: Add The Phase 3 Adapter Vectors

**Interfaces**

- Consumes: the 23 canonical Phase 0/1 vectors and Phase 2 wire dispositions.
- Produces: immutable device adapter vectors `P3V01` (self-lock compare-and-swap) and `P3V02` (paused terminal response), with a manifest that ties all Phase 3 R-16 removals to executable evidence.

**Files**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/Fixtures/metering_epoch_phase3_vectors.json`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochPhase3VectorTests.swift`

**TDD RED**

Create this complete fixture:

```json
{
  "schemaVersion": 1,
  "vectors": [
    {
      "id": "P3V01",
      "kind": "self_lock_compare_and_swap",
      "receiptEpochId": "10000000-0000-0000-0000-000000000001",
      "receiptGenerationActivityName": "evlin.earned.budget.20000000-0000-0000-0000-000000000001",
      "recordKey": "com.evlin.active-locks.child",
      "postMutationSources": ["manual", "earnedTime"],
      "currentSources": ["manual", "task", "earnedTime"],
      "expectedReleased": false,
      "expectedSources": ["manual", "task", "earnedTime"]
    },
    {
      "id": "P3V02",
      "kind": "paused_terminal_response",
      "response": {
        "child_device_id": "30000000-0000-0000-0000-000000000001",
        "usage_date": "2026-07-17",
        "estimated_minutes": 20,
        "cap_minutes": 60,
        "child_day_state": "open",
        "used_minutes": 20,
        "remaining_minutes": 40,
        "counted": false,
        "warning": "accounting_paused"
      },
      "expectedDisposition": "terminal",
      "expectedQueueDepth": 0,
      "expectedLocalEstimateMutation": 0,
      "expectedShieldMutation": 0
    }
  ]
}
```

The test must also compare the bytes and SHA-256 of:

- `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/Fixtures/metering_epoch_vectors.json`
- `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json`

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' test
```

Expected RED: the fixture decoder and adapter evaluator do not exist; the canonical byte-identity assertion already passes.

**Minimal implementation**

In the test target, decode the fixture into concrete structs. Evaluate P3V01 with a test-only value projection and strict equality; evaluate P3V02 through the production `EpochSampleHTTPDisposition` classifier. The test-only P3V01 oracle is exact and complete:

```swift
private struct ShieldRecordProjection: Equatable {
    let recordKey: String
    let sources: Set<String>
}

private func mayRelease(
    receipt: ShieldRecordProjection,
    current: ShieldRecordProjection?
) -> Bool {
    current == receipt
}
```

Task 10 replaces only the P3V01 test adapter with the real persisted `ShieldRecord` CAS; expected vector output remains byte-for-byte unchanged. Add `EpochSampleHTTPDisposition.removesQueuedSample` to `MeteringEpochWire.swift` with terminal/accepted true and retry false.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
./.venv/bin/python -m pytest -q tests/test_metering_epoch_vector_contract.py
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
shasum -a 256 'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json'
cmp -s 'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json'
```

Expected GREEN: P3V01 and P3V02 pass; both canonical fixture hashes are identical.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOSTests/Fixtures/metering_epoch_phase3_vectors.json' 'Evlin iOSTests/MeteringEpochPhase3VectorTests.swift' 'Evlin iOS/Services/MeteringEpochWire.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'test: add metering epoch phase 3 vectors'
```

## Task 4: Introduce The Versioned Device Epoch Store Transaction

**Interfaces**

- Consumes: the physical `earned-runtime.lock`, mirrored `evlin.childId`, exact persisted `earned.measurementSelection` bytes, canonical contract types, and Phase 3 queue DTOs.
- Produces: one atomic App Group JSON envelope, owner checks before and after every transaction, crash-safe pending stop names, and read-only legacy import. This becomes the only new epoch-state authority.

**Files**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/DeviceEpochStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED**

Test all of these independently: one-file persistence; schema version rejection; exact selection-byte digest; generation and daily epoch committed together; rollback on owner change before final check; rollback after simulated write/readback mismatch; persisted stop targets survive reopening; and two store instances serialize through the same file lock.

Use this exact transaction surface:

```swift
nonisolated enum DeviceEpochStoreError: Error, Equatable {
    case appGroupUnavailable
    case lockUnavailable
    case ownerMismatch
    case unsupportedVersion(Int)
    case invalidState
    case persistenceVerificationFailed
}

nonisolated struct DeviceEpochTransactionResult<Value: Sendable>: Sendable {
    let value: Value
    let committedState: DeviceEpochStoreState
}

nonisolated final class DeviceEpochStore: @unchecked Sendable {
    static let fileName = "device-epoch-store-v3.json"

    func load(expectedOwner: UUID) throws -> DeviceEpochStoreState

    func transaction<Value: Sendable>(
        expectedOwner: UUID,
        _ body: (inout DeviceEpochStoreState) throws -> Value
    ) throws -> DeviceEpochTransactionResult<Value>
}

nonisolated extension EarnedTimeStore {
    func measurementSelectionBytes() -> Data? // returns exact persisted Data
}
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' test
```

Expected RED: missing store/state symbols and no raw selection-byte accessor.

**Minimal implementation**

Rename the private lock implementation to internal `EarnedRuntimeInterprocessLock` and reuse it from both stores with the same `earned-runtime.lock` path. Under that lock: synchronize owner defaults, require canonical owner equality, decode state or create version 3, mutate a copy, validate invariants, write a temporary file, `fsync` the file, atomically rename over `device-epoch-store-v3.json`, `fsync` the parent directory, re-read and compare, then recheck the owner. If the final owner check fails, restore the prior bytes atomically before releasing the lock and throw `.ownerMismatch`.

State validation must enforce:

```swift
guard state.version == DeviceEpochStoreState.currentVersion,
      state.generation.map({ $0.key.childDeviceID == state.ownerDeviceID }) ?? true,
      state.dailyEpoch.map({ $0.key.childDeviceID == state.ownerDeviceID }) ?? true,
      state.dailyEpoch == nil || state.generation != nil,
      state.generation.map({
    MeteringEpochContract.selectionDigest(persistedSelectionBytes: $0.measurementSelectionBytes)
        == $0.key.measurementSelectionDigest
      } ?? true),
      state.monitorStopWork.allSatisfy {
        Set($0.activityNames).count == $0.activityNames.count
            && $0.activityNames.allSatisfy(EarnedActivityGeneration.isEarnedActivityName)
      }
else { throw DeviceEpochStoreError.invalidState }
```

Do not decode/re-encode `FamilyActivitySelection` to calculate the digest. Do not delete legacy lifecycle keys in this task.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -sdk iphonesimulator IPHONEOS_DEPLOYMENT_TARGET=17.6 build
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Debug -sdk iphonesimulator IPHONEOS_DEPLOYMENT_TARGET=17.6 build
```

Expected GREEN: transactional, owner-race, persistence, lock-contention, and target-membership tests pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOSTests/DeviceEpochStoreTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: add transactional device epoch store'
```

## Task 5: Reconcile Stable Generation And Daily Epoch Identity

**Interfaces**

- Consumes: Device Epoch Store, exact raw selection bytes/digest, backend runtime context, stable generation/daily keys, injected center/clock, and all seven replacement reasons.
- Produces: deterministic keep/install/replace decisions, repeating canonical monitor installation, and crash-safe stop completion. Mutable poll data cannot churn generation identity.

**Files**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochCoordinator.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetScheduler.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/DeviceEpochCoordinatorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetSchedulerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED**

Test the Cartesian identity boundary: changing usage date, offset, estimate, remaining, counters, timestamps, gate, retry count, or poll time keeps generation; changing one of the six generation fields replaces it. Test day-only rollover creates a new daily epoch with the same generation. Test every legal replacement reason and reject `poll_refresh`. Test a crash after persisting old activity names: reopening stops every name before clearing the list. Assert all production earned schedules use `repeats: true` with canonical timezone start/end components.

The coordinator interface is:

```swift
nonisolated struct MeteringReconciliationInput: Sendable {
    let ownerDeviceID: UUID
    let advertisedProtocolVersion: Int
    let usageDate: String
    let canonicalTimezone: String
    let policyRevision: String
    let measurementSelectionBytes: Data
    let enforcementSetID: UUID
    let baseAcceptedMinutes: Int
    let gateIsOpen: Bool
    let now: Date
    let explicitRecovery: MeteringExplicitRecovery?
}

@MainActor
protocol DeviceEpochCoordinating: AnyObject {
    func reconcile(_ input: MeteringReconciliationInput) async throws
    func stopPersistedTargets(ownerDeviceID: UUID) throws
}
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/DeviceEpochCoordinatorTests' -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' test
```

Expected RED: no production coordinator exists and the existing arm signature churns on date/offset/pool/cap while resume arming is non-repeating.

**Minimal implementation**

Build `MeteringGenerationKey` directly from its six fields and `MeteringEpochKey` by adding only `usageDate`. Choose protocol 2 only when advertised version is at least 2; otherwise generation protocol remains 1. On install:

1. In one store transaction, append old active/pending names to owner-scoped `monitorStopWork`, write the new generation and daily epoch, and set registration `.pendingV2` or `.legacyV1`.
2. Stop every persisted old name through the injected center.
3. Install the new generated activity using the existing canonical `dailySchedule(timezoneIdentifier:)`, never `armFromNow`.
4. In a second owner-fenced transaction, clear only names confirmed stopped.

Use this exact daily epoch construction:

```swift
let epoch = DeviceDailyEpoch(
    epochID: UUID(),
    key: MeteringEpochKey(
        protocolVersion: generation.key.protocolVersion,
        childDeviceID: input.ownerDeviceID,
        usageDate: input.usageDate,
        canonicalTimezone: input.canonicalTimezone,
        policyRevision: input.policyRevision,
        measurementSelectionDigest: generation.key.measurementSelectionDigest,
        enforcementSetID: input.enforcementSetID
    ),
    startedAt: input.now,
    baseAcceptedMinutes: input.baseAcceptedMinutes,
    replacementReason: reason,
    registeredAt: nil,
    registration: input.advertisedProtocolVersion >= 2
        ? .pendingV2(baseCorrectionUsed: false)
        : .legacyV1,
    lastRawThresholdMinutes: 0,
    excludedRawMinutes: 0,
    isPaused: !input.gateIsOpen,
    resumeBoundaryPending: false
)
```

Do not delete the old arm-signature/fingerprint code yet. Switch production reconciliation to the new coordinator while retaining the old code as unreferenced compatibility code until Task 12.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/DeviceEpochCoordinatorTests' -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochContractTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' test
```

Expected GREEN: all mutable-input no-churn, legal-replacement, repeating-schedule, and crash-stop tests pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/DeviceEpochCoordinator.swift' 'Evlin iOS/Services/EarnedBudgetScheduler.swift' 'Evlin iOS/Services/EarnedBudgetArming.swift' 'Evlin iOSTests/DeviceEpochCoordinatorTests.swift' 'Evlin iOSTests/EarnedBudgetSchedulerTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: reconcile stable device metering epochs'
```

## Task 6: Persist Registration-Before-Sample Delivery And The V1 Lane

**Interfaces**

- Consumes: exact Task 2 DTOs, daily epoch registration state, backend-advertised protocol, API base URL already ending in `/api/v1`, and the existing App Group fallback wake mechanism.
- Produces: durable FIFO registration/sample work, exact POST headers and paths, one authoritative-base correction, terminal dequeue, retry backoff, and a per-epoch v2 transition only after registration 200.

**Files**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochWire.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochDeliveryTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`

**TDD RED**

Use a scripted transport and reopened stores to prove: registration is durably present before its first sample; samples cannot dispatch while registration is pending; a network failure survives process death; `registered` and `already_registered` enable v2; 409 base mismatch corrects pending base once and re-registers; a second mismatch is terminal; terminal warnings dequeue without local accounting/shield effects; retries preserve order; owner/epoch mismatch purges work; v1 remains v1 when advertisement is absent/1; and v1 cannot be emitted after that device epoch is registered v2.

Use the Task 4 persisted work structs and these exact transport interfaces:

```swift
protocol MeteringEpochTransport: Sendable {
    func register(
        _ request: EpochRegistrationRequestDTO,
        childDeviceID: UUID
    ) async -> EpochRegistrationHTTPDisposition
    func submit(
        _ request: EpochSampleRequestDTO,
        childDeviceID: UUID
    ) async -> EpochSampleHTTPDisposition
}

actor MeteringEpochDelivery {
    func enqueueRegistrationAndInitialSamples(
        ownerDeviceID: UUID,
        epochID: UUID,
        samples: [EpochSampleRequestDTO]
    ) throws
    func drain(ownerDeviceID: UUID) async
}
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' test
```

Expected RED: the existing reporter can send a sample directly, treats every 409 as success, has no registration queue, and cannot preserve protocol ordering across restart.

**Minimal implementation**

Move registration state onto `DeviceDailyEpoch`. In the same store transaction that creates a pending-v2 epoch, append its registration work before any sample work. The drain loop always inspects the matching epoch and registration head under owner lock:

```swift
switch epoch.registration {
case .legacyV1:
    try await drainV1Samples(for: epoch)
case .pendingV2:
    guard let registration = state.registrationQueue.first(where: {
        $0.request.epochID == epoch.epochID
    }) else { return }
    await deliverRegistration(registration, for: epoch)
case .registeredV2:
    try await drainV2Samples(for: epoch)
}
```

For registration 200, owner/epoch recheck in one transaction, remove registration work, set `.registeredV2`, and set `registeredAt = clock.now`. This transaction is the device's only v2 transition. For `authoritative_base_mismatch` while `.pendingV2(baseCorrectionUsed: false)`, update the not-yet-registered epoch's `baseAcceptedMinutes` from `authoritativeSnapshot.estimatedMinutes`, mark correction used, rebuild the registration request, and drop queued samples whose adjusted estimate was computed from the old base. A second mismatch becomes terminal and leaves the epoch pending for explicit identity recovery; it must not loop.

URL construction and headers are exact:

```swift
let registrationURL = apiBaseURL.appendingPathComponent("child/earned-time/epochs")
let sampleURL = apiBaseURL.appendingPathComponent("child/earned-time/sample")
request.setValue(owner.uuidString.lowercased(), forHTTPHeaderField: "X-Evlin-Child-Device-ID")
```

The v1 branch uses `generation_armed_at` plus `generation_offset_minutes` and sends the adjusted estimate for both threshold/estimate. The v2 branch uses `protocol_version = 2` plus `epoch_id`, raw threshold, and adjusted estimate. Keep the existing App Group fallback only as a wake signal; the Device Epoch Store queue is the payload authority.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' -only-testing:'Evlin iOSTests/MeteringEpochWireTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
./.venv/bin/python -m pytest -q tests/test_metering_epoch_registration.py tests/test_metering_epoch_sample_adapter.py tests/test_earned_time_protocol_ratchet.py tests/test_metering_epoch_phase2_integration.py tests/test_earned_time_sample.py
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -sdk iphonesimulator IPHONEOS_DEPLOYMENT_TARGET=17.6 build
```

Expected GREEN: all ordering/restart/version tests and unchanged backend contract tests pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/MeteringEpochWire.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Services/EarnedSampleReporter.swift' 'Evlin iOSTests/MeteringEpochDeliveryTests.swift' 'Evlin iOSTests/EarnedSampleReporterTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: order epoch registration before samples'
```

## Task 7: Put Strict Epoch Trust In The Production Callback Path

**Interfaces**

- Consumes: DAM callback activity/event names, active daily epoch, injected clock, exact namespace, default 30-second/max 60-second jitter, and durable delivery queue.
- Produces: one pure verdict before every business effect, owner/epoch recheck around the transaction, accepted sample intent, and zero effects for every rejected callback. Delayed callbacks have no lower-bound rejection.

**Files**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochContract.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedMeteringCallbackTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED**

For each reject verdict (owner, epoch, usage date, policy, namespace, negative delta, too early), assert byte-identical Device Epoch Store, no local estimate mutation, no queue append, no dispatch, no notification, no shield mutation, and no monitor start/stop/replacement. Add acceptance at exactly the 60-second jitter ceiling, rejection one second beyond it, and acceptance of a callback delayed by hours when the upper bound remains physically possible. Inject an owner change between transaction mutation and commit and assert rollback.

Use this production adapter:

```swift
nonisolated struct EarnedMeteringCallbackInput: Equatable, Sendable {
    let activityName: String
    let eventName: String
    let rawThresholdMinutes: Int
    let callbackAt: Date
    let presentedOwnerDeviceID: UUID
}

nonisolated struct EarnedMeteringAcceptedSample: Equatable, Sendable {
    let epochID: UUID
    let rawThresholdMinutes: Int
    let adjustedEstimateMinutes: Int
    let request: EpochSampleRequestDTO
}

nonisolated enum EarnedMeteringCallbackResult: Equatable, Sendable {
    case rejected(MeteringCallbackVerdict)
    case pauseUpdated
    case resumeBoundaryDiscarded
    case accepted(EarnedMeteringAcceptedSample)
}

nonisolated final class EarnedMeteringCallbackAdapter: @unchecked Sendable {
    init(
        store: DeviceEpochStore,
        clock: any MeteringClock,
        configuredJitterSeconds: Int = 30
    )
    func handle(
        _ input: EarnedMeteringCallbackInput,
        expectedOwner: UUID
    ) throws -> EarnedMeteringCallbackResult
}
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' test
```

Expected RED: the extension's legacy stale ladder permits business mutations before one authoritative verdict and still relies on raw-ceiling/freshness/headroom checks.

**Minimal implementation**

Parse activity UUID and exact event threshold without mutating state. Load a snapshot and calculate:

```swift
guard generation.activityName == input.activityName else {
    return .rejected(.rejectEpoch)
}
let adjusted = epoch.baseAcceptedMinutes
    + input.rawThresholdMinutes
    - epoch.excludedRawMinutes
let verdict = MeteringEpochContract.callbackVerdict(
    MeteringCallbackInput(
        activeEpochID: epoch.epochID,
        callbackEpochID: epoch.epochID,
        activeOwnerDeviceID: epoch.key.childDeviceID,
        callbackOwnerDeviceID: input.presentedOwnerDeviceID,
        activeUsageDate: epoch.key.usageDate,
        callbackUsageDate: canonicalUsageDate,
        activePolicyRevision: epoch.key.policyRevision,
        callbackPolicyRevision: generation.key.policyRevision,
        expectedEventNamespace: "evlin.earned.v2",
        callbackEventNamespace: parsedNamespace,
        adjustedEstimateMinutes: adjusted,
        baseAcceptedMinutes: epoch.baseAcceptedMinutes,
        startedAt: epoch.startedAt,
        callbackAt: input.callbackAt,
        jitterSeconds: min(max(configuredJitterSeconds, 0), 60)
    )
)
guard verdict == .accept else { return .rejected(verdict) }
```

`callbackVerdict` must enforce `delta >= 0` and `delta * 60 <= elapsedSeconds + jitterSeconds` only. It must not reject because a callback is old. After the pure accept, enter one owner-fenced transaction, re-match activity, epoch, owner, date, policy, and namespace, update high-water state, and append the sample. Dispatch, local estimate, notification, and shield work occur only from the committed accepted result. A rejected result may emit an OS log after return, but no persisted diagnostic or retry entry.

Leave the old raw ceiling, freshness, and five-minute veto implementations unreferenced until Tasks 13-15.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/MeteringEpochContractTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' -only-testing:'Evlin iOSTests/DeviceIdentityTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -sdk iphonesimulator IPHONEOS_DEPLOYMENT_TARGET=17.6 build
```

Expected GREEN: strict trust and zero-effect matrix pass, including owner-race rollback and delayed acceptance.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedMeteringCallback.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOS/Services/MeteringEpochContract.swift' 'Evlin iOSTests/EarnedMeteringCallbackTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: enforce strict production callback trust'
```

## Task 8: Account For Continuous Monitor Pause And Resume

**Interfaces**

- Consumes: gate state derived from task/reflection policy, daily epoch raw high-water/exclusion fields, repeating monitor, active-app exact counter capability, and conservative extension behavior.
- Produces: continuous pause exclusion, one conservative resume-boundary discard, optional app-only exact rebase, and no earned monitor stop when the gate closes.

**Files**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochCoordinator.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/CommandPoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPauseAccountingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedConfigCommandTests.swift`

**TDD RED**

Cover gate close before first threshold, multiple paused thresholds, resume with Evlin absent, exact app resume, the first conservative boundary after resume, subsequent accepted progress, task bypass today, reflection still closed despite task bypass, and bypass expiry tomorrow. Assert gate close never calls `stopMonitoring` for the earned activity and never discards the generation. Existing legacy/per-app monitor policy is outside this assertion.

Add this transition API:

```swift
nonisolated enum MeteringResumeEvidence: Equatable, Sendable {
    case exactRawThreshold(Int)
    case unavailable
}

nonisolated enum MeteringProcessRole: Equatable, Sendable {
    case mainApp
    case deviceActivityMonitor
    case pushNSE
}

nonisolated enum MeteringGateTransitionResult: Equatable, Sendable {
    case unchanged
    case paused
    case resumedConservatively
    case requiresExactRebase(baseAcceptedMinutes: Int)
}

func transitionGate(
    ownerDeviceID: UUID,
    gateIsOpen: Bool,
    resumeEvidence: MeteringResumeEvidence,
    caller: MeteringProcessRole
) throws -> MeteringGateTransitionResult
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringPauseAccountingTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' -only-testing:'Evlin iOSTests/EarnedConfigCommandTests' test
```

Expected RED: poll/config paths stop the earned monitor on gate close and the extension uses `pendingUncounted`/`counterRecoveryRequired` flags instead of epoch-owned pause state.

**Minimal implementation**

Under one owner-fenced store transaction, implement the exact arithmetic:

```swift
if epoch.isPaused {
    epoch.excludedRawMinutes += max(0, raw - epoch.lastRawThresholdMinutes)
    epoch.lastRawThresholdMinutes = raw
    return .pauseUpdated
}
if epoch.resumeBoundaryPending {
    epoch.excludedRawMinutes += max(0, raw - epoch.lastRawThresholdMinutes)
    epoch.lastRawThresholdMinutes = raw
    epoch.resumeBoundaryPending = false
    return .resumeBoundaryDiscarded
}
let adjusted = epoch.baseAcceptedMinutes + raw - epoch.excludedRawMinutes
epoch.lastRawThresholdMinutes = raw
```

On close, set `isPaused = true` and keep the monitor. On conservative resume, set `isPaused = false` and `resumeBoundaryPending = true`. On an active main-app call with exact raw evidence, create a `gate_resume_exact_rebase` epoch with authoritative accepted base and raw zero. DAM and Push NSE must map exact evidence to `.unavailable`; the capability report did not prove extension-primary exact ownership. Do not stop an earned monitor solely because task/reflection gate closes. Do not restart it on open if generation identity is unchanged.

Retain the legacy pause flags as dead compatibility state until Task 16.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringPauseAccountingTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' -only-testing:'Evlin iOSTests/EarnedConfigCommandTests' -only-testing:'Evlin iOSTests/EarnedGateTautologyTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/CommandPollerTests' -only-testing:'Evlin iOSTests/CommandPollerEffectiveStateTests' test
```

Expected GREEN: continuous-monitor, conservative-discard, exact-app-rebase, bypass, and reflection precedence tests pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedMeteringCallback.swift' 'Evlin iOS/Services/DeviceEpochCoordinator.swift' 'Evlin iOS/Services/BigKidStatePoller.swift' 'Evlin iOS/Services/CommandPoller.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/MeteringPauseAccountingTests.swift' 'Evlin iOSTests/BigKidStatePollerTests.swift' 'Evlin iOSTests/EarnedConfigCommandTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: account for earned metering pauses'
```

## Task 9: Reconcile Canonical Timezone Rollover Conservatively

**Interfaces**

- Consumes: injected clock, canonical timezone/date, interval-start callbacks, callback date observations, child-state runtime delivery, task-lock reconciler, automatic shield sources, and repeating schedules.
- Produces: exactly-once day rollover, old-day callback rejection before mutation, new-day epoch/base, source-specific automatic reset, and no unproven NSE-primary ownership.

**Files**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochCoordinator.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringCanonicalRolloverTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`

**TDD RED**

Use virtual time to prove local Tokyo midnight does not roll a New York canonical day; New York midnight rolls once; timezone change replaces generation/epoch once; interval start, stale callback observation, and backend delivery converge idempotently; yesterday's earned/per-app automatic sources clear while manual/block sources remain; task lock reconciles for today; and the first trustworthy new-day bucket is measurable with the app absent. Assert stale callback handling itself reports all-zero `MeteringEffects`.

Use this exact entry point:

```swift
nonisolated enum MeteringRolloverTrigger: String, Sendable {
    case intervalStart
    case callbackClockObservation
    case backendRuntime
}

@MainActor
func reconcileCanonicalDay(
    ownerDeviceID: UUID,
    canonicalTimezone: String,
    authoritativeBaseMinutes: Int,
    trigger: MeteringRolloverTrigger
) async throws -> Bool
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringCanonicalRolloverTests' test
```

Expected RED: old day state is lifecycle-driven, interval start only performs partial source reset, and callback/backend paths do not converge through one canonical transaction.

**Minimal implementation**

First call the callback adapter. If it rejects because the store date differs from `clock.now` in the canonical timezone, return that rejection with zero callback effects. Then invoke `reconcileCanonicalDay(..., trigger: .callbackClockObservation)` as a separate clock-driven reconciliation that consumes no callback threshold/event data. This preserves strict callback zero-effect semantics while making a callback clock observation a rollover wake.

The rollover transaction must retire the old daily epoch, purge its queued registration/sample work, preserve the stable generation when timezone/policy/selection/set are unchanged, create one `day_rollover` epoch with backend authoritative base when delivered or zero when offline, and persist required stop/install targets. After commit, clear only prior-day `earnedTime` and per-app `limit` automatic state, preserve `manual`, `taskPause`, reflection/manual, and block records, then invoke existing task-lock reconciliation for the new canonical date.

Backend runtime delivery reaches this entry point through `BigKidStatePoller`. Push NSE remains a read-only consumer of shared clock/store state and Release code must not start or become primary owner of earned monitoring. Keep the repeating app/DAM monitor and conservative boundary behavior until the physical overnight gate proves otherwise.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringCanonicalRolloverTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/DeviceIdentityTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/ActiveLockStoreTests' -only-testing:'Evlin iOSTests/ShieldSourceSetTests' -only-testing:'Evlin iOSTests/ReflectionLockReconcilerTests' -only-testing:'Evlin iOSTests/TaskPauseShieldMappingTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 build
```

Expected GREEN: canonical vectors 9, 11, 12, 21, and 22 pass with source-preservation regressions.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/DeviceEpochCoordinator.swift' 'Evlin iOS/Services/EarnedMeteringCallback.swift' 'Evlin iOS/Services/BigKidStatePoller.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/MeteringCanonicalRolloverTests.swift' 'Evlin iOSTests/BigKidStatePollerTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: reconcile canonical metering rollover'
```

## Task 10: Persist Earned Self-Lock Provenance And CAS Release

**Interfaces**

- Consumes: active epoch/generation, `ActiveLockStore.addShieldWithReceipt`, exact durable `ShieldRecord`, `ActiveLockPersistenceLock`, backend remaining snapshot, and source-set semantics.
- Produces: local earned self-lock receipt and compare-and-swap earned-only release that never removes newer/manual/task/reflection/block/per-app state.

**Files**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSelfLock.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/ActiveLockStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSelfLockTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochPhase3VectorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/ActiveLockStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED**

Test receipt fields, process restart, duplicate exhaustion, backend headroom after self-lock, same-key newer manual/task mutation, removed/recreated record, stale epoch, identity switch, and mixed sources. P3V01 must prove CAS failure leaves `manual + taskPause + earnedTime` unchanged. A successful exact match removes only `earnedTime`; records retain `manual`, `taskPause`, `limit`, and any reflection-owned manual source. Block records are byte-identical.

Use the exact `EarnedSelfLockReceipt` persisted by Task 4:

```swift
actor EarnedSelfLockCoordinator {
    func apply(ownerDeviceID: UUID, epochID: UUID) async throws
    func releaseIfBackendHasHeadroom(
        ownerDeviceID: UUID,
        epochID: UUID,
        remainingMinutes: Int
    ) async throws -> Bool
}

extension ActiveLockStore {
    func removeSourceIfUnchanged(
        _ source: ShieldSource,
        recordKey: String,
        expectedRecord: ShieldRecord
    ) -> Bool
}
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/EarnedSelfLockTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' test
```

Expected RED: earned shields have no epoch/generation/post-mutation receipt and backend headroom can remove `earnedTime` without comparing durable state.

**Minimal implementation**

After a terminal accepted sample says remaining is zero, call `addShieldWithReceipt` and commit `receipt.after` with active epoch/generation into Device Epoch Store only after owner/epoch recheck. For release, require remaining greater than zero and matching owner/epoch/receipt, then call `removeSourceIfUnchanged`. That method must execute under `ActiveLockPersistenceLock.shared.withLock`, reload durable state, compare `shieldRecords[recordKey] == expectedRecord`, strip only the requested source with `ShieldSourceLogic.removingSource`, persist/verify, and recompute. CAS failure is a no-op and does not clear the receipt; identity retirement clears it atomically in Task 11.

Replace the test-only `ShieldRecordSnapshot` P3V01 adapter with the actual `ShieldRecord` projection. Leave the old backend veto function dead until Task 15.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/EarnedSelfLockTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' -only-testing:'Evlin iOSTests/ActiveLockStoreTests' -only-testing:'Evlin iOSTests/ShieldSourceSetTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/ReflectionLockApplierTests' -only-testing:'Evlin iOSTests/ReflectionLockReconcilerTests' -only-testing:'Evlin iOSTests/TaskPauseShieldMappingTests' -only-testing:'Evlin iOSTests/ActiveLockStoreLimitReconcileTests' test
```

Expected GREEN: P3V01 and all source-preserving CAS cases pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedSelfLock.swift' 'Evlin iOS/Services/ActiveLockStore.swift' 'Evlin iOS/Services/EarnedSampleReporter.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOSTests/EarnedSelfLockTests.swift' 'Evlin iOSTests/MeteringEpochPhase3VectorTests.swift' 'Evlin iOSTests/ActiveLockStoreTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: add earned self-lock cas provenance'
```

## Task 11: Atomically Retire Epoch State On Identity Switch

**Interfaces**

- Consumes: all identity switch/sign-out/family reset call sites, Device Epoch Store owner fence, active/pending/retiring/legacy earned activity names, registration/sample work, reporter fallback wake/payload, old-day state, and self-lock receipt.
- Produces: one logical retirement transaction, complete daemon stop list, queue/fallback purge, delayed-work firewall, and clean new-owner initialization.

**Files**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochCoordinator.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/Auth/AuthService.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/FamilyGoneDetector.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringIdentityRetirementTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/DeviceIdentityTests.swift`

**TDD RED**

Seed active, pending, retiring, legacy, and generated activity names; registration/sample retries; reporter fallback payload/wake; prior-day estimate/accepted/override/pause state; and self-lock provenance. Switch A to B at injected race points before write, after write, before daemon stop, during async response, and before queue drain. Assert every A name is stopped, every A work item is purged, A's automatic earned source is released only through its receipt/CAS, B remains byte-identical during delayed A callbacks/responses, and reopening finishes persisted stop targets.

Use this exact result:

```swift
nonisolated struct MeteringIdentityRetirement: Equatable, Sendable {
    let retiredOwnerDeviceID: UUID
    let activityNamesToStop: [String]
    let earnedSelfLockReceipt: EarnedSelfLockReceipt?
}

func retireIdentity(
    expectedOwnerDeviceID: UUID
) throws -> MeteringIdentityRetirement
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringIdentityRetirementTests' -only-testing:'Evlin iOSTests/DeviceIdentityTests' test
```

Expected RED: existing identity teardown does not purge all reporter queue/fallback/lifecycle state and delayed old-owner work can reach non-epoch storage.

**Minimal implementation**

While the old owner mirror still matches and under the existing interprocess lock, collect a sorted deduplicated union of legacy, active, pending, retiring, and persisted stop-target names. Atomically clear old-owner generation/day/registration/sample/old-day state, append an old-owner `MeteringMonitorStopWork` containing that union, and detach the old self-lock receipt into the return value. Then update identity, stop every union name, CAS-release the detached earned receipt, and remove only the completed stop-work entry and old-owner reporter fallback payload/wake. On crash, reopening processes the retained owner-scoped stop work; on delayed callback/response, owner mismatch rejects before mutation.

Wire this operation through `EarnedBudgetArming.mirrorChildIdentity`, `reconcileIdentityTransition`, `teardownFamilyIdentity`, `AuthService.persistTerminalFailClosed`/`clearFamilyScopedLocalState`, and `FamilyGoneDetector.failOpen` so child reassignment, account switch, sign-out, terminal fail-close, and family reset all share it. Do not alter Profile Lock/Unlock endpoints or manual source behavior. Keep old lifecycle storage readable until Task 17, but it is no longer writable or authoritative.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringIdentityRetirementTests' -only-testing:'Evlin iOSTests/DeviceIdentityTests' -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' test
```

**Task-full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/ActiveLockStoreTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' -only-testing:'Evlin iOSTests/CommandPollerTests' test
```

Expected GREEN: all identity race and delayed mutation assertions pass, including canonical vector 13.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Services/DeviceEpochCoordinator.swift' 'Evlin iOS/Services/EarnedSampleReporter.swift' 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOS/Services/EarnedBudgetArming.swift' 'Evlin iOS/Services/Auth/AuthService.swift' 'Evlin iOS/Services/FamilyGoneDetector.swift' 'Evlin iOS/Services/BigKidStatePoller.swift' 'Evlin iOSTests/MeteringIdentityRetirementTests.swift' 'Evlin iOSTests/DeviceIdentityTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: retire metering state on identity switch'
```

## Task 12: Demolish R-16 T1 Arm Signature And Re-Encoded Fingerprint

**Interfaces**

- Consumes: committed stable six-field generation key, exact persisted selection bytes/digest, Device Epoch Store, and canonical vectors 1-3 and 7.
- Produces: no production `armSignature` state or normal-path `FamilyActivitySelection` re-encoding; old serialized unknown fields remain safely ignored.

**Files**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetArmingTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringR16DemolitionTests.swift`

**TDD RED**

Add `testT1LegacyArmSignatureIsAbsent`. It reads the production files and fails on `armSignature`, `makeArmSignature`, `currentArmSignature`, or `selectionFingerprint`. Add a migration case that decodes old JSON containing `armSignature` and imports only stable identity/raw bytes.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests/testT1LegacyArmSignatureIsAbsent' test
```

Expected RED: the scalar key, builders, and selection re-encoding are found.

**Minimal implementation**

Delete the T1 scalar key, builders, comparisons, persisted legacy field, and mutable-signature tests. The only identity input is:

```swift
guard let bytes = store.measurementSelectionBytes(),
      let rawSetID = store.lockedSetID,
      let enforcementSetID = UUID(uuidString: rawSetID) else { return }
let digest = MeteringEpochContract.selectionDigest(persistedSelectionBytes: bytes)
```

Do not add another fingerprint. Task 5 tests must be green before deletion.

**Focused/full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests' -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' -only-testing:'Evlin iOSTests/DeviceEpochCoordinatorTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' test
```

Expected GREEN: T1 absence, migration, and vectors 1-3/7 pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedBudgetArming.swift' 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOSTests/EarnedBudgetArmingTests.swift' 'Evlin iOSTests/MeteringR16DemolitionTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'refactor: remove legacy earned arm signature'
```

## Task 13: Demolish R-16 T2 Raw Threshold Ceiling

**Interfaces**

- Consumes: strict epoch physical-time validation, pause-adjusted estimate, 30-second default/60-second maximum jitter, and vectors 4-6.
- Produces: no raw-threshold ceiling or offset-derived plausibility mechanism outside `MeteringEpochContract.callbackVerdict`.

**Files**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringR16DemolitionTests.swift`

**TDD RED**

Add `testT2RawThresholdCeilingIsAbsent` scanning for `EarnedThresholdPlausibility` and raw-ceiling inputs. Add a high-raw/large-exclusion accepted case and a low-raw/too-early rejected case.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests/testT2RawThresholdCeilingIsAbsent' test
```

Expected RED: `EarnedThresholdPlausibility` and extension call sites remain.

**Minimal implementation**

Delete the type, persisted ceiling, calls, and old tests. Retain exactly:

```swift
let delta = adjustedEstimateMinutes - baseAcceptedMinutes
guard delta >= 0 else { return .rejectNegativeDelta }
let elapsed = max(0, callbackAt.timeIntervalSince(startedAt))
guard Double(delta * 60) <= elapsed + Double(jitterSeconds) else {
    return .rejectTooEarly
}
```

Do not add another threshold cap.

**Focused/full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/MeteringPauseAccountingTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochContractTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' test
```

Expected GREEN: T2 absence and vectors 4-6 pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedTimeStore.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/EarnedTimeStoreTests.swift' 'Evlin iOSTests/MeteringR16DemolitionTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'refactor: remove raw threshold ceiling'
```

## Task 14: Demolish R-16 T3 Fresh-At-Fire Gate

**Interfaces**

- Consumes: owner/epoch/date/policy/namespace/physical trust and vectors 4, 5, and 8.
- Produces: no wall-clock freshness veto or lower-bound callback-age rejection.

**Files**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringR16DemolitionTests.swift`

**TDD RED**

Add `testT3FreshAtFireGateIsAbsent` scanning for `shouldApplyEarnedShieldFresh` and callback-age windows. Add a physically possible 12-hour-delayed callback that queues once and a stale-day callback that rejects with zero effects.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests/testT3FreshAtFireGateIsAbsent' test
```

Expected RED: the freshness helper and extension branch remain.

**Minimal implementation**

Delete freshness timestamps, helper, tests, and call sites. A shield follows only a committed accepted callback plus a current-epoch terminal backend response. Preserve epoch/date trust; do not replace freshness with retry-age or debounce state.

**Focused/full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/MeteringCanonicalRolloverTests' -only-testing:'Evlin iOSTests/EarnedSelfLockTests' test
```

Expected GREEN: T3 absence, delayed acceptance, and stale-day zero-effect tests pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedSampleReporter.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/EarnedSampleReporterTests.swift' 'Evlin iOSTests/MeteringR16DemolitionTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'refactor: remove fresh at fire gate'
```

## Task 15: Demolish The Phase 3 Portion Of R-16 T4

**Interfaces**

- Consumes: strict epoch trust, terminal backend snapshot, earned self-lock receipt/CAS, vectors 4, 5, 16, P3V01, and P3V02.
- Produces: no device-side 600-second, five-minute, plus-five, or backend-headroom veto outside registered epoch/CAS state. Phase 5 still owns backend periodic reconciliation.

**Files**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringR16DemolitionTests.swift`

**TDD RED**

Add `testT4Phase3LegacyVetoesAreAbsent` scanning for `backendVetoesSelfLock`, legacy 600-second constants, `threshold + 5` trust, and five-minute vetoes.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests/testT4Phase3LegacyVetoesAreAbsent' test
```

Expected RED: the old self-lock veto and plus-five trust remain as dead code.

**Minimal implementation**

Delete those vetoes and tests. Lock only from a current epoch response with remaining zero; release only with remaining above zero and exact receipt-record CAS:

```swift
guard response.remainingMinutes > 0,
      receipt.epochID == activeEpoch.epochID,
      receipt.generationActivityName == activeGeneration.activityName
else { return false }
return await activeLockStore.removeSourceIfUnchanged(
    .earnedTime,
    recordKey: receipt.recordKey,
    expectedRecord: receipt.postMutationRecord
)
```

Do not add headroom/minimum-time checks.

**Focused/full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests' -only-testing:'Evlin iOSTests/EarnedSelfLockTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/ActiveLockStoreTests' -only-testing:'Evlin iOSTests/ShieldSourceSetTests' test
```

Expected GREEN: T4 absence, strict trust, P3V01/P3V02, and source preservation pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedSampleReporter.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/EarnedSampleReporterTests.swift' 'Evlin iOSTests/MeteringR16DemolitionTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'refactor: remove legacy earned self lock vetoes'
```

## Task 16: Demolish R-16 T7 Pause Recovery Flags

**Interfaces**

- Consumes: epoch-owned `isPaused`, raw high-water, excluded raw minutes, `resumeBoundaryPending`, vectors 10-12, and P3V02.
- Produces: no `pendingUncounted` or `counterRecoveryRequired` flags/branches.

**Files**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringR16DemolitionTests.swift`

**TDD RED**

Add `testT7PauseRecoveryFlagsAreAbsent` scanning both prefix names/accessors. Seed old defaults containing both keys and prove startup removes/ignores them while preserving Device Epoch Store pause state.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests/testT7PauseRecoveryFlagsAreAbsent' test
```

Expected RED: prefix constants, accessors, and branches remain.

**Minimal implementation**

Delete flags, rollback-key entries, accessors, branches, and obsolete tests. During v3 initialization remove old keys by prefix without migrating their Boolean values. The conservative epoch fields are authoritative; add no replacement flag.

**Focused/full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests' -only-testing:'Evlin iOSTests/MeteringPauseAccountingTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' -only-testing:'Evlin iOSTests/EarnedGateTautologyTests' -only-testing:'Evlin iOSTests/CommandPollerEffectiveStateTests' test
```

Expected GREEN: T7 absence, conservative resume, task/reflection precedence, and P3V02 pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOS/Services/BigKidStatePoller.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/EarnedTimeStoreTests.swift' 'Evlin iOSTests/BigKidStatePollerTests.swift' 'Evlin iOSTests/MeteringR16DemolitionTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'refactor: remove legacy pause recovery flags'
```

## Task 17: Demolish R-16 T8 Competing Lifecycle Authorities

**Interfaces**

- Consumes: Device Epoch Store transaction, persisted stop targets, durable registration/sample queues, identity retirement, and vectors 1, 7, 9, and 13.
- Produces: one epoch authority; no lifecycle blob, active-name scalar, breadcrumbs, reporter payload queue, or competing writer.

**Files**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetScheduler.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/Auth/AuthService.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringR16DemolitionTests.swift`

**TDD RED**

Add `testT8CompetingLifecycleAuthoritiesAreAbsent` scanning for `activityLifecycle`, `activityBreadcrumbs`, `activeActivityNameKey`, lifecycle persistence, and reporter payload queue keys. Seed each old form, migrate twice, and assert one v3 generation, deduplicated stop targets, no duplicate sample, and removed old keys.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests/testT8CompetingLifecycleAuthoritiesAreAbsent' test
```

Expected RED: old lifecycle/breadcrumb/active-name/reporter payload authorities remain.

**Minimal implementation**

Preserve only pure names:

```swift
nonisolated enum MeteringActivityNamespace {
    static let legacyActivityName = "evlin.earned.budget"
    static let generatedActivityPrefix = "evlin.earned.budget."
    static func generatedActivityName(id: UUID) -> String {
        generatedActivityPrefix + id.uuidString.lowercased()
    }
    static func isEarnedActivityName(_ value: String) -> Bool {
        value == legacyActivityName || value.hasPrefix(generatedActivityPrefix)
    }
}
```

Delete `Generation`/`Lifecycle`, serializers, breadcrumbs, active scalar, and payload queue after one owner-matching migration under `earned-runtime.lock`. Keep only the payload-free reporter wake. No dual write is permitted.

**Focused/full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' -only-testing:'Evlin iOSTests/MeteringIdentityRetirementTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -sdk iphonesimulator IPHONEOS_DEPLOYMENT_TARGET=17.6 build
```

Expected GREEN: T8 migration/crash/identity tests and vectors 1/7/9/13 pass.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOS/Services/EarnedBudgetArming.swift' 'Evlin iOS/Services/EarnedBudgetScheduler.swift' 'Evlin iOS/Services/EarnedSampleReporter.swift' 'Evlin iOS/Services/Auth/AuthService.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/EarnedTimeStoreTests.swift' 'Evlin iOSTests/EarnedSampleReporterTests.swift' 'Evlin iOSTests/MeteringR16DemolitionTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'refactor: remove competing earned lifecycle state'
```

## Task 18: Pass The Automated Phase 3 Completion Gate

**Interfaces**

- Consumes: Tasks 1-17, canonical vectors 1-23, P3V01/P3V02, current backend Phase 2, target membership, Release exclusion, and existing identity/source/app-limit/task/manual regressions.
- Produces: an automated completion manifest green on iPhone/iPad iOS 17.6 and every target. It does not claim physical-device reliability.

**Files**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochPhase3CompletionTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`

**TDD RED**

Add architecture tests asserting: all six old mechanisms are absent; generation key fields are exactly six; epoch key adds only usage date; Device Epoch Store is the only payload authority; shared files have exact membership; Push NSE has no Release monitor ownership; all targets use deployment 17.6/device family 1,2; and Release binaries contain no DEBUG clock symbol/key.

```swift
let forbiddenProductionSymbols = [
    "armSignature", "EarnedThresholdPlausibility",
    "shouldApplyEarnedShieldFresh", "backendVetoesSelfLock",
    "pendingUncountedReconciliation", "counterRecoveryRequired",
    "activityLifecycle", "activityBreadcrumbs",
]
```

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' -only-testing:'Evlin iOSTests/MeteringEpochPhase3CompletionTests' -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests' test
```

Expected RED: any missed symbol, membership, Release, deployment, or ownership defect is named. Fix only that Phase 3 defect.

**Minimal implementation**

Implement file/project/product inspection in the two tests. Do not suppress failures. Preserve a baseline-proven unrelated failure as an explicit external concern, but leave this task uncommitted until every Phase 3 assertion passes.

**Focused verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.6' \
  -only-testing:'Evlin iOSTests/MeteringRuntimeInfrastructureTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochWireTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochContractTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' \
  -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' \
  -only-testing:'Evlin iOSTests/DeviceEpochCoordinatorTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' \
  -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' \
  -only-testing:'Evlin iOSTests/MeteringPauseAccountingTests' \
  -only-testing:'Evlin iOSTests/MeteringCanonicalRolloverTests' \
  -only-testing:'Evlin iOSTests/EarnedSelfLockTests' \
  -only-testing:'Evlin iOSTests/MeteringIdentityRetirementTests' \
  -only-testing:'Evlin iOSTests/MeteringR16DemolitionTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochPhase3CompletionTests' test
```

**Task-full verification**

An absent 17.6 runtime is a blocker; do not substitute a newer runtime:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
IPHONE_UDID="$(xcrun simctl list devices available -j | jq -r '.devices["com.apple.CoreSimulator.SimRuntime.iOS-17-6"] // [] | .[] | select(.name | startswith("iPhone")) | .udid' | head -1)"
IPAD_UDID="$(xcrun simctl list devices available -j | jq -r '.devices["com.apple.CoreSimulator.SimRuntime.iOS-17-6"] // [] | .[] | select(.name | startswith("iPad")) | .udid' | head -1)"
test -n "$IPHONE_UDID"
test -n "$IPAD_UDID"
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination "platform=iOS Simulator,id=$IPHONE_UDID" test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination "platform=iOS Simulator,id=$IPAD_UDID" test
for target in 'Evlin iOS' 'Evlin iOSTests' 'EvlinDeviceActivityMonitor' 'EvlinPushApplier' 'EvlinShieldConfig' 'EvlinDeviceActivityReport'; do
  xcodebuild -project 'Evlin iOS.xcodeproj' -target "$target" -configuration Debug -sdk iphonesimulator IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build || exit 1
done
for target in 'Evlin iOS' 'EvlinDeviceActivityMonitor' 'EvlinPushApplier' 'EvlinShieldConfig' 'EvlinDeviceActivityReport'; do
  xcodebuild -project 'Evlin iOS.xcodeproj' -target "$target" -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build || exit 1
done
```

The full test target includes all existing regressions; also run the critical ownership suites explicitly:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination "platform=iOS Simulator,id=$IPHONE_UDID" \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' -only-testing:'Evlin iOSTests/EarnedConfigCommandTests' \
  -only-testing:'Evlin iOSTests/EarnedGateTautologyTests' -only-testing:'Evlin iOSTests/DeviceIdentityTests' \
  -only-testing:'Evlin iOSTests/ActiveLockStoreTests' -only-testing:'Evlin iOSTests/ActiveLockStoreLimitReconcileTests' \
  -only-testing:'Evlin iOSTests/ShieldSourceSetTests' -only-testing:'Evlin iOSTests/AppLimitMeasurementTests' \
  -only-testing:'Evlin iOSTests/AppLimitToggleGateTests' -only-testing:'Evlin iOSTests/TaskPauseShieldMappingTests' \
  -only-testing:'Evlin iOSTests/ReflectionLockApplierTests' -only-testing:'Evlin iOSTests/ReflectionLockReconcilerTests' \
  -only-testing:'Evlin iOSTests/CommandPollerTests' -only-testing:'Evlin iOSTests/CommandPollerEffectiveStateTests' test
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
./.venv/bin/python -m pytest -q tests/test_metering_epoch_vector_contract.py tests/test_metering_epoch_readiness.py tests/test_metering_epoch_registration.py tests/test_metering_epoch_sample_adapter.py tests/test_metering_epoch_phase2_integration.py tests/test_metering_epoch_lifespan.py tests/test_metering_day_reconciler.py tests/test_metering_gate.py tests/test_earned_time_protocol_ratchet.py tests/test_earned_time_sample.py tests/test_earned_time_auto_lock.py tests/test_earned_time_lock_receipts.py tests/test_earned_time_remaining_recompute.py tests/api/test_limits_regression_pack.py
git status --short
```

Expected GREEN: both 17.6 full runs, six Debug targets, five Release products, explicit regressions, and backend dependency suites pass; backend status is baseline-identical.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOSTests/MeteringEpochPhase3CompletionTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'test: gate metering epoch phase 3 completion'
```

## Task 19: Record The Automated Completion Report

**Interfaces**

- Consumes: resolved Task 12-18 SHAs, green Task 18 logs, vectors, capability report, and four physical gates.
- Produces: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md` with automated-complete/physical-pending status and the exact demolition table.

**Files**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md`

**TDD RED**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
test -f docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
```

Expected RED: exit 1 because no report exists.

**Minimal implementation**

Resolve the exact commits and create the complete report with expanding `apply_patch` input:

```bash
T1_SHA="$(git log -1 --format=%H --grep='^refactor: remove legacy earned arm signature$')"
T2_SHA="$(git log -1 --format=%H --grep='^refactor: remove raw threshold ceiling$')"
T3_SHA="$(git log -1 --format=%H --grep='^refactor: remove fresh at fire gate$')"
T4_SHA="$(git log -1 --format=%H --grep='^refactor: remove legacy earned self lock vetoes$')"
T7_SHA="$(git log -1 --format=%H --grep='^refactor: remove legacy pause recovery flags$')"
T8_SHA="$(git log -1 --format=%H --grep='^refactor: remove competing earned lifecycle state$')"
GATE_SHA="$(git log -1 --format=%H --grep='^test: gate metering epoch phase 3 completion$')"
for SHA in "$T1_SHA" "$T2_SHA" "$T3_SHA" "$T4_SHA" "$T7_SHA" "$T8_SHA" "$GATE_SHA"; do
  printf '%s\n' "$SHA" | rg -q '^[0-9a-f]{40}$' || exit 1
done
apply_patch <<PATCH
*** Begin Patch
*** Add File: docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
+# Metering Epoch Phase 3 Completion
+
+**Status:** AUTOMATED COMPLETE; PHYSICAL DEVICE GATES PENDING
+
+## 本阶段拆除清单 + 向量证据
+
+| R-16 row | Authoritative replacement | Removed or narrowed mechanism | Removal commit | Green vector evidence |
+|---|---|---|---|---|
+| T1 | Six-field generation key plus exact persisted-byte SHA-256 | Arm signature and re-encoded selection fingerprint | \u0060$T1_SHA\u0060 | Canonical 1, 2, 3, 7 |
+| T2 | Epoch physical-time trust over adjusted delta | Raw threshold ceiling | \u0060$T2_SHA\u0060 | Canonical 4, 5, 6 |
+| T3 | Owner/epoch/date/policy/namespace trust with no lower age bound | Fresh-at-fire gate | \u0060$T3_SHA\u0060 | Canonical 4, 5, 8 |
+| T4 (Phase 3) | Strict callback trust plus self-lock receipt/CAS | Device 600-second/five-minute/plus-five/headroom vetoes | \u0060$T4_SHA\u0060 | Canonical 4, 5, 16; P3V01, P3V02 |
+| T7 | Epoch raw high-water/exclusion/pause/resume state | Pending-uncounted and counter-recovery flags | \u0060$T7_SHA\u0060 | Canonical 10, 11, 12; P3V02 |
+| T8 | Versioned owner-fenced Device Epoch Store | Lifecycle, active scalar, breadcrumbs, reporter payload queue | \u0060$T8_SHA\u0060 | Canonical 1, 7, 9, 13 |
+
+No Phase 3 R-16 row is deferred. The backend periodic-reconciliation portion of T4 remains owned by Phase 5.
+
+## Automated Evidence
+
+- Completion gate commit: \u0060$GATE_SHA\u0060
+- Canonical vectors 1-23 and P3V01/P3V02: PASS
+- iPhone and iPad iOS/iPadOS 17.6 full suites: PASS
+- Six Debug targets and five production Release targets at deployment 17.6: PASS
+- Backend Phase 2 dependency matrix: PASS; backend status unchanged from baseline
+- Release DEBUG-clock exclusion and Push NSE no-production-owner assertions: PASS
+
+## Physical Device Gates
+
+| Gate | Status |
+|---|---|
+| Production earned threshold, foreground and force-killed | PENDING |
+| DEBUG per-app threshold | PENDING |
+| Two-device attribution smoke | PENDING |
+| TestFlight overnight canonical-midnight soak | PENDING |
+
+The capability spike did not prove replacement callbacks, exact extension rebase, or NSE-primary ownership. The conservative branch remains enabled until physical evidence exists.
*** End Patch
PATCH
```

**Focused/full verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
rg -n '^\*\*Status:\*\* AUTOMATED COMPLETE; PHYSICAL DEVICE GATES PENDING$|^## 本阶段拆除清单 \+ 向量证据$|^\| T1 |^\| T2 |^\| T3 |^\| T4 \(Phase 3\) |^\| T7 |^\| T8 |' docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
test "$(rg -c '^\| T[12378] |^\| T4 \(Phase 3\) ' docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md)" -eq 6
test "$(rg -c '^\| .* \| PENDING \|' docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md)" -eq 4
! rg -n 'T[B]D|T[O]DO|similar[[:space:]]+to|PHYSICAL COMPLETE' docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
git diff --check -- docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
```

Expected GREEN: six demolition rows, four pending physical rows, resolved commit IDs, and no false completion.

**Stage, review, commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'docs: report metering epoch phase 3'
```

---

## Automated Completion Gate

Phase 3 is **AUTOMATED COMPLETE** only when all 19 commits exist, Task 18 is green on iPhone/iPad 17.6, every target builds, backend Phase 2 remains green, Release excludes the DEBUG clock override, Push NSE has no production monitor ownership, all six R-16 mechanisms are absent, and Task 19 records resolved evidence.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git status --short
git diff --check
rg -n '本阶段拆除清单 \+ 向量证据|AUTOMATED COMPLETE; PHYSICAL DEVICE GATES PENDING' docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
! rg -n 'armSignature|EarnedThresholdPlausibility|shouldApplyEarnedShieldFresh|backendVetoesSelfLock|pendingUncountedReconciliation|counterRecoveryRequired|activityLifecycle|activityBreadcrumbs' 'Evlin iOS' EvlinDeviceActivityMonitor EvlinPushApplier
git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend status --short
```

Only baseline unrelated changes may remain.

## Physical-Device Pending Gate

Keep all four §14 gates pending: production earned threshold (foreground and force-killed), DEBUG per-app threshold, two-device attribution in both directions, and TestFlight overnight canonical-midnight soak with both apps force-killed. The DAM/NSE spike did not prove replacement callbacks, exact extension rebase, or NSE-primary ownership. Do not claim all metering products fixed until physical evidence is attached.
