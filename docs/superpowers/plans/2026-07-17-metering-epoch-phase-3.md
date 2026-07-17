# Metering Epoch Phase 3 Implementation Plan

> **For implementation agents:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task by task in the existing iOS main workspace. Do not create a worktree, delegate work, amend task commits, push, deploy, or touch production data.

**Goal:** Replace the legacy earned-time lifecycle with independently attributable dated callback routes, one crash-safe owner-fenced Device Epoch Store, exact Phase 2 delivery, conservative pause accounting, durable rollover/identity/shield effects, and an eight-date no-churn installation horizon; then demolish the superseded R-16 mechanisms in separately testable commits.

**Architecture:** The Apple callback boundary carries only activity name, event name, and observed time. An opaque UUID in both names resolves an immutable durable route containing owner/day/epoch/policy provenance. One versioned App Group root owns generation, epoch, route/tombstone, registration, sample, install, coverage, ratchet, shield-reference, identity-cleanup, and rollover state under `ActiveLockPersistenceLock`. The app and DAM are the only monitor owners. A full horizon is canonical today plus seven dates. Uncovered callbacks have zero metering or earned-shield effects.

**Technology:** Swift language mode 5.0, XCTest, FamilyControls, DeviceActivity, ManagedSettings, CryptoKit, App Group persistence plus `flock`, URLSession, Xcode 26.3 / iPhoneOS 26.2 SDK, iOS 26.3 simulator runtime, and deployment target iOS/iPadOS 17.6.

---

## Execution Contract

Use only these healthy repositories and canonical rulebook:

```text
/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md
```

Before Task 1, preserve the immutable bases and the pre-existing dirty state:

```bash
set -euo pipefail
IOS_REPO=/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
BACKEND_REPO=/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
EVIDENCE="$IOS_REPO/.superpowers/evidence/metering-phase3"
mkdir -p "$EVIDENCE/logs"
git -C "$IOS_REPO" status --short --branch | tee "$EVIDENCE/ios-status-before.txt"
git -C "$BACKEND_REPO" status --short --branch | tee "$EVIDENCE/backend-status-before.txt"
git -C "$IOS_REPO" rev-parse HEAD | tee "$EVIDENCE/ios-base-sha.txt"
git -C "$BACKEND_REPO" rev-parse HEAD | tee "$EVIDENCE/backend-base-sha.txt"
shasum -a 256 /Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md \
  | tee "$EVIDENCE/r16-base-sha256.txt"
```

The existing iOS changes in `ContentView.swift`, `APIClient.swift`, onboarding,
Xcode user data, debugger data, `.DS_Store`, and the untracked Phase 2 plan are
user work. The backend changes in `.superpowers/sdd/task-8-report.md` and
`tests/test_bigkid_endpoints.py` are also user work. Preserve every unrelated
byte. Task 3 must stage only its metering hunks from `APIClient.swift` with
`git add -p`.

Use these exact simulator destinations:

```bash
IOS_PHONE='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3'
IOS_PAD='platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3'
```

The simulator proves runtime behavior on iOS 26.3. Every build sets
`IPHONEOS_DEPLOYMENT_TARGET=17.6` and `TARGETED_DEVICE_FAMILY='1,2'`; that is
deployment compatibility evidence, not a physical 17.6 runtime result.

Every task follows this order:

1. Add the named test first and run the exact RED command.
2. Confirm the stated failure, not an unrelated compiler or environment error.
3. Add the minimum implementation described in the task.
4. Run focused and task-full GREEN commands.
5. Stage only the task's declared files. For a pre-dirty file, use `git add -p`.
6. Run `git diff --cached --check`, inspect `git diff --cached --stat`, inspect
   the complete `git diff --cached`, and compare `git diff --cached --name-only`
   to the declared file list.
7. Commit once with the exact subject. Never amend or combine task commits.

No task changes Profile manual-button semantics, onboarding/beta agreement,
Render, TestFlight, a production database, or Phase 2 backend production code.
No old guard is removed until its replacement, recovery behavior, and vectors
are green in an earlier commit.

## Pinned Phase 2 Wire

The API prefix is supplied by the existing base URL. The live paths and headers
are exactly:

```text
GET  /api/v1/child/state
     X-Child-Id: <canonical UUID>
POST /api/v1/child/earned-time/epochs
     X-Evlin-Child-Device-ID: <canonical UUID>
POST /api/v1/child/earned-time/sample
     X-Evlin-Child-Device-ID: <canonical UUID>
```

`GET /child/state` decodes `metering_protocol_version` (absent means 1) and
`earned_time_runtime`: `usage_date`, `timezone`, `policy_revision` (String),
`daily_pool_minutes`, `device_cap_minutes`, `remaining_minutes`, and
`estimated_minutes`.

Registration request keys are exactly `protocol_version`, `epoch_id`,
`device_id`, `usage_date`, `timezone`, `policy_revision`,
`measurement_selection_digest`, `enforcement_set_id`, `started_at`,
`base_accepted_minutes`, and `reason`. HTTP 200 is `registered` or
`already_registered`, with `epoch_id`, `metering_protocol_version`, and
`snapshot`. The only top-level structured 409 is
`authoritative_base_mismatch` plus `authoritative_snapshot`; every other error
uses FastAPI `detail`.

Sample common keys are exactly `device_id`, `usage_date`, `timezone`,
`activity_name`, `event_name`, `threshold_minutes`, `estimated_minutes`,
`observed_at`, and `client_sample_id`. V2 adds the pair
`protocol_version`/`epoch_id`. V1 adds the pair
`generation_armed_at`/`generation_offset_minutes`. There is no
`device_to_backend_offset_seconds` field. The response keys are
`child_device_id`, `usage_date`, `estimated_minutes`, `cap_minutes`,
`child_day_state`, `used_minutes`, `remaining_minutes`, `counted`, and
`warning`.

V1 sends the pause-adjusted cumulative estimate as both `threshold_minutes` and
`estimated_minutes`. V2 sends the verified route's raw threshold as
`threshold_minutes` and the pause-adjusted cumulative estimate as
`estimated_minutes`. New dated-route work uses the opaque idempotency value
`earned:<v1|v2>:<lowercase-route-uuid>:t<threshold>`; a retried work item keeps
the originally encoded value byte-for-byte.

Registration detail values are `metering_v2_not_advertised`,
`device_missing_child_profile_id`, `started_at_invalid`, `timezone_mismatch`,
`usage_date_mismatch`, `started_at_usage_date_mismatch`,
`started_at_in_future`, `policy_revision_mismatch`,
`enforcement_set_mismatch`, `replacement_reason_mismatch`,
`gate_resume_requires_paused_predecessor`,
`gate_resume_requires_open_gate`, `epoch_scope_conflict`,
`epoch_immutable_mismatch`, and `epoch_retired`. Sample terminal warnings are
`invalid_protocol_metadata`, `legacy_after_v2`, `usage_date_mismatch`,
`stale_epoch`, `owner_mismatch`, `policy_revision_mismatch`,
`event_namespace_mismatch`, `invalid_generation_metadata`, `implausible_threshold`,
`gate_resume_rebase_required`, and `accounting_paused`.

The live Phase 2 v2 namespace validator accepts sample aliases
`evlin.earned.budget.<route-uuid>` and `evlin.earned.t<threshold>`. Phase 3's
Apple activity/event names remain `evlin.earned.v2.<route-uuid>` and
`evlin.earned.v2.<route-uuid>.t<threshold>` so the callback carries the opaque
route in both names. `MeteringEpochWire` derives the Phase 2 aliases only after
the immutable route is authorized; it never feeds aliases back into local
callback trust.

## Target Membership

| Source | App | DAM | Push NSE | Shield Config | Report |
|---|---:|---:|---:|---:|---:|
| `MeteringRuntimeInfrastructure.swift` | yes | yes | yes | no | no |
| `MeteringDeviceActivityCenter.swift` | yes | yes | no | no | no |
| `MeteringEpochWire.swift` | yes | yes | yes | no | no |
| `DeviceEpochStore.swift` | yes | yes | yes | no | no |
| `MeteringEpochDelivery.swift` | yes | yes | yes | no | no |
| `MeteringCallbackRoute.swift` | yes | yes | no | no | no |
| `EarnedMeteringCallback.swift` | yes | yes | no | no | no |
| `EarnedShieldEffectStore.swift` | yes | yes | yes | no | no |
| `EarnedMeteringRecoveryDriver.swift` | yes | yes | no | no | no |

The DAM membership closure for `EarnedShieldEffectStore.swift` also contains
`Models/ShieldRecord.swift`, `Models/ShieldTier.swift`,
`Services/ShieldSourceLogic.swift`, and
`Services/ActiveLockPersistenceLock.swift`. It does not add
`ActiveLockStore.swift` or `ActiveLockStoreTypes.swift` to DAM. Push may compile
the store/wire/effect sources for state and CAS recovery but never the center
adapter, route installer, or monitor recovery driver.

## Exact Shared Interfaces

Task implementations use these declarations without renaming fields or adding
parallel flags.

```swift
import DeviceActivity
import Foundation

nonisolated struct MeteringAppleCallback: Codable, Equatable, Sendable {
    let activityName: String
    let eventName: String
    let observedAt: Date
}

@MainActor
protocol MeteringDeviceActivityCenter {
    var activities: [DeviceActivityName] { get }
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule?
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent]
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws
    func stopMonitoring(_ activities: [DeviceActivityName])
}

@MainActor
struct SystemMeteringDeviceActivityCenter: MeteringDeviceActivityCenter {
    private let center: DeviceActivityCenter

    init(center: DeviceActivityCenter = DeviceActivityCenter()) {
        self.center = center
    }

    var activities: [DeviceActivityName] { center.activities }

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? {
        center.schedule(for: activity)
    }

    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        center.events(for: activity)
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        try center.startMonitoring(activity, during: schedule, events: events)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        center.stopMonitoring(activities)
    }
}
```

The versioned root uses these exact state types:

```swift
nonisolated enum MeteringGenerationRetireReason: String, Codable, Sendable {
    case policyChange = "policy_change"
    case selectionChange = "selection_change"
    case enforcementSetChange = "enforcement_set_change"
    case timezoneChange = "timezone_change"
    case identityChange = "identity_change"
}

nonisolated struct MeteringPolicyGeneration: Codable, Equatable, Sendable {
    let generationID: UUID
    let protocolVersion: Int
    let ownerChildDeviceID: UUID
    let timezoneIdentifier: String
    let policyRevision: String
    let selectionDigest: String
    let enforcementSetID: UUID
    let persistedSelectionBytes: Data
    let createdAt: Date
    var retiredAt: Date?
    var retireReason: MeteringGenerationRetireReason?

    var key: MeteringGenerationKey {
        MeteringGenerationKey(
            protocolVersion: protocolVersion,
            childDeviceID: ownerChildDeviceID,
            canonicalTimezone: timezoneIdentifier,
            policyRevision: policyRevision,
            measurementSelectionDigest: selectionDigest,
            enforcementSetID: enforcementSetID
        )
    }
}

nonisolated enum DeviceDailyEpochStatus: String, Codable, Sendable {
    case active
    case paused
    case exhausted
    case retired
}

nonisolated enum MeteringAcceptedBaseSource: String, Codable, Sendable {
    case childState200 = "child_state_200"
    case registration200 = "registration_200"
    case registrationConflict409 = "registration_conflict_409"
}

nonisolated struct DeviceDailyEpoch: Codable, Equatable, Sendable {
    let epochID: UUID
    let protocolVersion: Int
    let ownerChildDeviceID: UUID
    let usageDate: String
    let timezoneIdentifier: String
    let policyRevision: String
    let selectionDigest: String
    let enforcementSetID: UUID
    let startedAt: Date
    var registeredAt: Date?
    var baseAcceptedMinutes: Int
    var baseSource: MeteringAcceptedBaseSource
    var lastRawThresholdMinutes: Int
    var excludedWhilePausedMinutes: Int
    var status: DeviceDailyEpochStatus
    var resumeBoundaryPending: Bool
    var retiredAt: Date?
    var retireReason: MeteringEpochReplacementReason?
    var exhaustedAt: Date?
}

nonisolated enum MeteringRouteLifecycle: String, Codable, Sendable {
    case prepared
    case installed
    case active
    case retired
    case stopped
}

nonisolated struct MeteringRouteEventPlan: Codable, Equatable, Sendable {
    let eventName: String
    let thresholdMinutes: Int
}

nonisolated struct MeteringPersistedSchedule: Codable, Equatable, Sendable {
    let usageDate: String
    let timezoneIdentifier: String
    let intervalStart: DateComponents
    let intervalEnd: DateComponents
    let repeats: Bool
}

nonisolated struct MeteringCallbackRoute: Codable, Equatable, Sendable {
    let routeID: UUID
    let activityName: String
    let eventNamespace: String
    let generationID: UUID
    let generationKey: MeteringGenerationKey
    let ownerChildDeviceID: UUID
    let usageDate: String
    let epochID: UUID
    let plannedAt: Date
    let schedule: MeteringPersistedSchedule
    let eventPlan: [MeteringRouteEventPlan]
    var lifecycle: MeteringRouteLifecycle
}

nonisolated struct MeteringRouteTombstone: Codable, Equatable, Sendable {
    let routeID: UUID
    let activityName: String
    let eventNamespace: String
    let ownerChildDeviceID: UUID
    let usageDate: String
    let epochID: UUID
    let retiredAt: Date
    var stopAcknowledgedAt: Date?
    var referencedWorkTerminalAt: Date?
    let retainUntil: Date
}

nonisolated enum ActivityInstallAuthorization: String, Codable, Sendable {
    case registered
    case futurePlanned
    case offlinePending
}

nonisolated enum ActivityInstallPhase: String, Codable, Sendable {
    case pendingStart
    case installed
    case pendingStop
    case stopped
}

nonisolated struct ActivityInstallWork: Codable, Equatable, Sendable {
    let workID: UUID
    let routeID: UUID
    var authorization: ActivityInstallAuthorization
    var phase: ActivityInstallPhase
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastErrorCode: String?
    var daemonVerifiedAt: Date?
    var acknowledgedAt: Date?
}

nonisolated enum MonitorCoverageStatus: String, Codable, Sendable {
    case ready
    case installLimited
    case coverageExhausted
}

nonisolated struct MonitorCoverageState: Codable, Equatable, Sendable {
    let generationID: UUID
    let requiredStartUsageDate: String
    let requiredEndUsageDate: String
    var readyThroughUsageDate: String?
    var status: MonitorCoverageStatus
    var refreshedAt: Date
    var lastErrorCode: String?
}

nonisolated enum BaseCorrectionState: String, Codable, Sendable {
    case available
    case used
}

nonisolated struct EpochRegistrationWork: Codable, Equatable, Sendable {
    let workID: UUID
    var request: EpochRegistrationRequestDTO
    var baseCorrection: BaseCorrectionState
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastHTTPStatus: Int?
}

nonisolated struct EpochSampleWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let lane: MeteringSampleLane
    let request: EpochSampleRequestDTO
    var deliveryAuthorization: EpochSampleDeliveryAuthorization
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastHTTPStatus: Int?
}

nonisolated struct MeteringOwnerRatchet: Codable, Equatable, Sendable {
    let ownerChildDeviceID: UUID
    var advertisedVersion: Int
    var selectedVersion: Int
    var registeredV2At: Date?
}

nonisolated struct ShieldEffectReference: Codable, Equatable, Sendable {
    let operationID: UUID
    let ownerChildDeviceID: UUID
    let epochID: UUID
    let routeID: UUID
}

nonisolated enum WorkAcknowledgement: String, Codable, Sendable {
    case pending
    case acknowledged
}

nonisolated enum IdentityCleanupPhase: String, Codable, Sendable {
    case prepared
    case retiring
    case cleaning
    case complete
}

nonisolated struct IdentityCleanupWork: Codable, Equatable, Sendable {
    let operationID: UUID
    let oldOwnerChildDeviceID: UUID
    let newOwnerChildDeviceID: UUID?
    let routeIDs: [UUID]
    let activityNames: [String]
    let epochIDs: [UUID]
    let registrationWorkIDs: [UUID]
    let sampleWorkIDs: [UUID]
    let fallbackLogicalKeys: [String]
    let shieldOperationIDs: [UUID]
    var phase: IdentityCleanupPhase
    var registrationPurgeAcknowledgements: [UUID: WorkAcknowledgement]
    var samplePurgeAcknowledgements: [UUID: WorkAcknowledgement]
    var fallbackPurgeAcknowledgements: [String: WorkAcknowledgement]
    var shieldReleaseAcknowledgements: [UUID: WorkAcknowledgement]
    var monitorStopAcknowledgements: [String: WorkAcknowledgement]
}

nonisolated struct RolloverEffectsWork: Codable, Equatable, Sendable {
    let operationID: UUID
    let ownerChildDeviceID: UUID
    let fromUsageDate: String
    let toUsageDate: String
    let retiredEpochID: UUID?
    let newEpochID: UUID
    var earnedSourceReset: WorkAcknowledgement
    var perAppSourceReset: WorkAcknowledgement
    var taskGateReconcile: WorkAcknowledgement
    var bypassExpiryReconcile: WorkAcknowledgement
    var registrationReady: WorkAcknowledgement
    var installReady: WorkAcknowledgement
}

nonisolated struct DeviceEpochStoreState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4
    var schemaVersion: Int
    var ownerChildDeviceID: UUID?
    var generations: [UUID: MeteringPolicyGeneration]
    var activeGenerationID: UUID?
    var epochs: [UUID: DeviceDailyEpoch]
    var activeEpochID: UUID?
    var routes: [UUID: MeteringCallbackRoute]
    var routeTombstones: [UUID: MeteringRouteTombstone]
    var registrationWork: [UUID: EpochRegistrationWork]
    var sampleWork: [UUID: EpochSampleWork]
    var installWork: [UUID: ActivityInstallWork]
    var coverage: MonitorCoverageState?
    var shieldEffectReferences: [UUID: ShieldEffectReference]
    var identityCleanup: IdentityCleanupWork?
    var rolloverEffects: RolloverEffectsWork?
    var ratchets: [UUID: MeteringOwnerRatchet]
}
```

The only accepted policy input is backend-shaped:

```swift
nonisolated struct AuthoritativeMeteringInput: Equatable, Sendable {
    let ownerChildDeviceID: UUID
    let advertisedProtocolVersion: Int
    let usageDate: String
    let timezoneIdentifier: String
    let policyRevision: String
    let dailyPoolMinutes: Int
    let deviceCapMinutes: Int
    let remainingMinutes: Int
    let estimatedMinutes: Int
    let enforcementSetID: UUID
    let persistedSelectionBytes: Data
    let accountingGateOpen: Bool
    let observedAt: Date
}
```

`estimatedMinutes` alone supplies a current epoch's accepted base. A
registration 409 may replace it once with
`authoritative_snapshot.estimated_minutes`. Offset, remaining, cap, local
estimate, and a future-date guess never supply the base.

---
## Task 1: Register Every Phase 3 Safety State Under R-16

**Interfaces:** Consumes rulebook §11/R-16 and canonical vectors V01-V32.
Produces a canonical registry row for each new state before any state is
implemented, plus a test/hash mirror in the iOS repository. The rulebook is not
inside a Git repository, so its content hash is evidence; the task commit
contains only the iOS mirror and test.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-phase3-r16-registration.md`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase3R16RegistrationTests.swift`

**TDD RED:** Add the test first. It reads the rulebook and requires these exact
state names: `MeteringCallbackRoute/route tombstone`,
`pendingStart/installed/pendingStop`, `futurePlanned/offlinePending`,
`MonitorCoverageState.readyThrough/coverageExhausted`,
`registration queue/per-owner protocol ratchet`, `baseCorrection available/used`,
`process-role monitor owner`, `resumeBoundaryPending/paused high-water`,
`EarnedShieldEffectEnvelope`, `IdentityCleanupWork`, `RolloverEffectsWork`, and
`EpochSampleWork`.

```swift
func testPhase3SafetyStatesAreRegisteredUnderR16() throws {
    let rulebook = try String(
        contentsOfFile: "/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md",
        encoding: .utf8
    )
    let required = [
        "MeteringCallbackRoute/route tombstone",
        "pendingStart/installed/pendingStop",
        "futurePlanned/offlinePending",
        "MonitorCoverageState.readyThrough/coverageExhausted",
        "registration queue/per-owner protocol ratchet",
        "baseCorrection available/used",
        "process-role monitor owner",
        "resumeBoundaryPending/paused high-water",
        "EarnedShieldEffectEnvelope",
        "IdentityCleanupWork",
        "RolloverEffectsWork",
        "EpochSampleWork",
    ]
    for state in required {
        XCTAssertTrue(rulebook.contains(state), "missing R-16 registration: \(state)")
    }
}
```

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringPhase3R16RegistrationTests' test
```

Expected RED: the assertion names the first unregistered Phase 3 state.

**Minimal GREEN:** Append one R-16 table immediately after the existing T1-T10
table. Every row records the exact replacement/justification, terminal deletion
criterion, and evidence below:

| State | Replacement or justification | Deletion criterion | Evidence |
|---|---|---|---|
| `MeteringCallbackRoute/route tombstone` | T2/T8 callback provenance | stop ack + referenced work terminal + retention elapsed | V04, V05, V08, V27 |
| `pendingStart/installed/pendingStop` | T8 lifecycle choreography | start verified or stopped absence verified | V01, V07, V13, V28 |
| `futurePlanned/offlinePending` | explicit future/offline authorization | registration success, route retirement, or stop | V24, V27, V28 |
| `MonitorCoverageState.readyThrough/coverageExhausted` | bounded dated coverage truth | horizon refilled or generation/owner retired | V24, V25, V26 |
| `registration queue/per-owner protocol ratchet` | direct v1-only path | queue terminal; ratchet ends only at identity retirement | V19, V20, V30 |
| `baseCorrection available/used` | bounded authoritative 409 correction | registration succeeds or epoch retires | V32 |
| `process-role monitor owner` | capability safety | physical start/callback/replacement/stop/day proof for new role | target tests + Release scan + physical gate |
| `resumeBoundaryPending/paused high-water` | T7 | first post-resume callback or epoch retirement | V10, V11, V12 |
| `EarnedShieldEffectEnvelope` | T4 veto | exact release/retirement/cleanup ack | V15, V16, P3V01 |
| `IdentityCleanupWork` | T8 detached teardown | every captured ack durable | V13, V29 |
| `RolloverEffectsWork` | durable canonical rollover | every reset/reconcile/install/register ack durable | V09, V21, V22, V29 |
| `EpochSampleWork` | legacy retry/fallback after ratchet | accepted or terminal disposition | V19, V20, V30 |

The iOS mirror reproduces the table and records the post-edit SHA-256 from:

```bash
shasum -a 256 /Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md
```

**Focused and full GREEN:** Re-run the RED command, then run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' \
  -only-testing:'Evlin iOSTests/MeteringPhase3R16RegistrationTests' test
```

Expected GREEN: all 12 rows are present and existing T1-T10 ownership remains
unchanged; T5 still owns the device `+5` heuristic.

**Staged review and commit:**

```bash
git add 'docs/superpowers/reports/2026-07-17-metering-phase3-r16-registration.md' \
  'Evlin iOSTests/MeteringPhase3R16RegistrationTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
test "$(git diff --cached --name-only | wc -l | tr -d ' ')" -eq 2
git commit -m 'test: register phase 3 metering safety states'
```

## Task 2: Land Shared Clock And Value-Type Center Injection

**Interfaces:** Consumes existing `MeteringClock` and Apple's value-type
`DeviceActivityCenter`. Produces a DEBUG-gated App Group clock for app/DAM/Push
and the exact non-`AnyObject` center protocol/adapter for app/DAM only. Clock
selection cannot grant monitor ownership.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringRuntimeInfrastructure.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringDeviceActivityCenter.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringRuntimeInfrastructureTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Add tests that instantiate a struct fake as
`MeteringDeviceActivityCenter`, inject fixed time into app and DAM entry
factories, assert Push has no center source membership, and inspect source text
for `#if DEBUG` around both `DebugAppGroupMeteringClock` and its preference key.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringRuntimeInfrastructureTests' \
  -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests' test
```

Expected RED: compile errors name `SystemMeteringClock`,
`DebugAppGroupMeteringClock`, and `MeteringDeviceActivityCenter`.

**Minimal GREEN:** Add the center declarations from Exact Shared Interfaces and
this complete clock implementation:

```swift
import Foundation

nonisolated struct SystemMeteringClock: MeteringClock {
    var now: Date { Date() }
}

#if DEBUG
nonisolated struct DebugAppGroupMeteringClock: MeteringClock {
    static let preferenceKey = "evlin.metering.debugClockNow"
    let defaults: UserDefaults?
    let fallback: any MeteringClock

    var now: Date {
        guard let raw = defaults?.string(forKey: Self.preferenceKey),
              let value = ISO8601DateFormatter().date(from: raw)
        else { return fallback.now }
        return value
    }
}
#endif

nonisolated enum MeteringRuntimeClock {
    static func live(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios")
    ) -> any MeteringClock {
#if DEBUG
        return DebugAppGroupMeteringClock(defaults: defaults, fallback: SystemMeteringClock())
#else
        return SystemMeteringClock()
#endif
    }
}
```

Add exact membership exceptions from the target matrix. Keep
`MeteringDeviceActivityCenter.swift` absent from Push.

**Focused and full GREEN:** Re-run RED, then build app, DAM, and Push in Debug:

```bash
for target in 'Evlin iOS' EvlinDeviceActivityMonitor EvlinPushApplier; do
  xcodebuild -project 'Evlin iOS.xcodeproj' -target "$target" \
    -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO \
    IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
done
```

Expected GREEN: the struct fake conforms, fixed time is shared, and all three
targets compile at deployment 17.6. Release binary exclusion is proved only
after Task 25 builds known products.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/MeteringRuntimeInfrastructure.swift' \
  'Evlin iOS/Services/MeteringDeviceActivityCenter.swift' \
  'Evlin iOSTests/MeteringRuntimeInfrastructureTests.swift' \
  'Evlin iOSTests/MeteringTargetMembershipTests.swift' \
  'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: inject shared metering runtime dependencies'
```

## Task 3: Pin Apple Callback And Exact Phase 2 Wire DTOs

**Interfaces:** Consumes the pinned backend contract and existing
`ChildStateResponse`/`EarnedTimeRuntime` in `BigKidModels.swift`. Produces
`MeteringAppleCallback`, Codable registration/sample DTOs, exact response DTOs,
the exact child-state fetch DTO/request, and the advertised runtime projection.
The sample DTO enforces either the v1 pair or the v2 pair, never both or neither.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochWire.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/BigKid/BigKidModels.swift`
- Modify selected hunks only: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/APIClient.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochWireTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Encode one v1 and one v2 request and compare their JSON key sets
and values exactly; decode registration 200, base-mismatch 409, terminal sample
200, and child state with/without advertisement. Assert child state uses
`X-Child-Id` and not `X-Evlin-Child-Device-ID`; both POSTs use
`X-Evlin-Child-Device-ID` and not `X-Child-Id`; the Apple DTO has only three
encoded keys.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringEpochWireTests' test
```

Expected RED: compile errors name `EpochRegistrationRequestDTO`,
`EpochSampleRequestDTO`, and `MeteringAppleCallback`.

**Minimal GREEN:** Implement the Apple DTO from Exact Shared Interfaces and
these wire declarations with explicit coding keys:

```swift
nonisolated enum EpochRegistrationReasonDTO: String, Codable, Sendable {
    case initial
    case dayRollover = "day_rollover"
    case policyChange = "policy_change"
    case selectionChange = "selection_change"
    case enforcementSetChange = "enforcement_set_change"
    case identityRecovery = "identity_recovery"
    case gateResumeExactRebase = "gate_resume_exact_rebase"
}

nonisolated enum MeteringSampleLane: String, Codable, Sendable {
    case v1
    case v2
}

nonisolated enum EpochSampleDeliveryAuthorization: String, Codable, Sendable {
    case waitingForRegistration
    case deliverable
}

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
    let reason: EpochRegistrationReasonDTO

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case epochID = "epoch_id"
        case deviceID = "device_id"
        case usageDate = "usage_date"
        case timezone
        case policyRevision = "policy_revision"
        case measurementSelectionDigest = "measurement_selection_digest"
        case enforcementSetID = "enforcement_set_id"
        case startedAt = "started_at"
        case baseAcceptedMinutes = "base_accepted_minutes"
        case reason
    }
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
    let protocolVersion: Int?
    let epochID: UUID?
    let generationArmedAt: Date?
    let generationOffsetMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case usageDate = "usage_date"
        case timezone
        case activityName = "activity_name"
        case eventName = "event_name"
        case thresholdMinutes = "threshold_minutes"
        case estimatedMinutes = "estimated_minutes"
        case observedAt = "observed_at"
        case clientSampleID = "client_sample_id"
        case protocolVersion = "protocol_version"
        case epochID = "epoch_id"
        case generationArmedAt = "generation_armed_at"
        case generationOffsetMinutes = "generation_offset_minutes"
    }

    var lane: MeteringSampleLane? {
        let hasV2 = protocolVersion == 2 && epochID != nil
            && generationArmedAt == nil && generationOffsetMinutes == nil
        let hasV1 = protocolVersion == nil && epochID == nil
            && generationArmedAt != nil && generationOffsetMinutes != nil
        if hasV2 { return .v2 }
        if hasV1 { return .v1 }
        return nil
    }
}

nonisolated enum MeteringPhase2SampleNames {
    static func activityName(routeID: UUID) -> String {
        "evlin.earned.budget.\(routeID.uuidString.lowercased())"
    }

    static func eventName(thresholdMinutes: Int) -> String {
        "evlin.earned.t\(thresholdMinutes)"
    }
}

nonisolated enum MeteringClientSampleID {
    static func make(
        lane: MeteringSampleLane,
        routeID: UUID,
        thresholdMinutes: Int
    ) -> String {
        "earned:\(lane.rawValue):\(routeID.uuidString.lowercased()):t\(thresholdMinutes)"
    }
}

nonisolated enum MeteringEpochRequests {
    static func registration(
        baseURL: URL,
        ownerChildDeviceID: UUID,
        body: EpochRegistrationRequestDTO
    ) throws -> URLRequest {
        try request(
            url: baseURL.appendingPathComponent("child/earned-time/epochs"),
            ownerChildDeviceID: ownerChildDeviceID,
            body: body
        )
    }

    static func sample(
        baseURL: URL,
        ownerChildDeviceID: UUID,
        body: EpochSampleRequestDTO
    ) throws -> URLRequest {
        try request(
            url: baseURL.appendingPathComponent("child/earned-time/sample"),
            ownerChildDeviceID: ownerChildDeviceID,
            body: body
        )
    }

    private static func request<Body: Encodable>(
        url: URL,
        ownerChildDeviceID: UUID,
        body: Body
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            ownerChildDeviceID.uuidString.lowercased(),
            forHTTPHeaderField: "X-Evlin-Child-Device-ID"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        return request
    }
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

    enum CodingKeys: String, CodingKey {
        case childDeviceID = "child_device_id"
        case usageDate = "usage_date"
        case estimatedMinutes = "estimated_minutes"
        case capMinutes = "cap_minutes"
        case childDayState = "child_day_state"
        case usedMinutes = "used_minutes"
        case remainingMinutes = "remaining_minutes"
        case counted
        case warning
    }
}

nonisolated struct EpochRegistrationResponseDTO: Codable, Equatable, Sendable {
    let status: String
    let epochID: UUID
    let meteringProtocolVersion: Int
    let snapshot: DeviceDaySnapshotDTO

    enum CodingKeys: String, CodingKey {
        case status
        case epochID = "epoch_id"
        case meteringProtocolVersion = "metering_protocol_version"
        case snapshot
    }
}

nonisolated struct EpochRegistrationConflictDTO: Codable, Equatable, Sendable {
    let code: String
    let authoritativeSnapshot: DeviceDaySnapshotDTO

    enum CodingKeys: String, CodingKey {
        case code
        case authoritativeSnapshot = "authoritative_snapshot"
    }
}

nonisolated struct MeteringChildStateRuntimeDTO: Codable, Equatable, Sendable {
    let usageDate: String
    let timezone: String
    let policyRevision: String
    let dailyPoolMinutes: Int
    let deviceCapMinutes: Int
    let remainingMinutes: Int
    let estimatedMinutes: Int

    enum CodingKeys: String, CodingKey {
        case usageDate = "usage_date"
        case timezone
        case policyRevision = "policy_revision"
        case dailyPoolMinutes = "daily_pool_minutes"
        case deviceCapMinutes = "device_cap_minutes"
        case remainingMinutes = "remaining_minutes"
        case estimatedMinutes = "estimated_minutes"
    }
}

nonisolated struct MeteringChildStateDTO: Codable, Equatable, Sendable {
    let meteringProtocolVersion: Int?
    let usageCountingAllowed: Bool?
    let earnedTimeRuntime: MeteringChildStateRuntimeDTO?

    enum CodingKeys: String, CodingKey {
        case meteringProtocolVersion = "metering_protocol_version"
        case usageCountingAllowed = "usage_counting_allowed"
        case earnedTimeRuntime = "earned_time_runtime"
    }

    var advertisedProtocolVersion: Int { meteringProtocolVersion ?? 1 }
    var accountingGateOpen: Bool { usageCountingAllowed ?? true }
}

nonisolated enum MeteringChildStateRequests {
    static func state(baseURL: URL, ownerChildDeviceID: UUID) -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("child/state")
        )
        request.httpMethod = "GET"
        request.setValue(
            ownerChildDeviceID.uuidString.lowercased(),
            forHTTPHeaderField: "X-Child-Id"
        )
        return request
    }
}
```

Add only the exact runtime fields to existing child-state DTOs. Do not change
unrelated API code. Add `MeteringEpochWire.swift` to app, DAM, and Push.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringEpochWireTests' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedConfigCommandTests' test
```

Expected GREEN: literal JSON and deterministic idempotency values match the live
schemas; absent advertisement selects 1; `policy_revision` is String;
`cap_minutes` decodes null; no invented wire key is present.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/MeteringEpochWire.swift' \
  'Evlin iOS/Models/BigKid/BigKidModels.swift' \
  'Evlin iOSTests/MeteringEpochWireTests.swift' \
  'Evlin iOSTests/MeteringTargetMembershipTests.swift' \
  'Evlin iOS.xcodeproj/project.pbxproj'
git add -p 'Evlin iOS/Services/APIClient.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: add exact metering epoch wire DTOs'
```

## Task 4: Add The Versioned Atomic Device Epoch Store

**Interfaces:** Consumes every state declaration above, exact
`MeteringEpochContract.selectionDigest(persistedBytes:)`, the mirrored
`evlin.childId`, and `ActiveLockPersistenceLock`. Produces one schema-v4 root,
atomic write/readback, owner rechecks, and migration from absent schema. This
task persists generation and current epoch in one transaction but does not
select v2 in production.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/DeviceEpochStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Tests cover absent-root bootstrap, exact schema round-trip, future
schema refusal, atomic generation+epoch commit, injected write/readback failure,
interprocess-lock failure, owner mismatch before mutation, owner change during
mutation, and preservation of exact selection bytes.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' test
```

Expected RED: compile failure for `DeviceEpochStore` and
`DeviceEpochStoreState.currentSchemaVersion`.

**Minimal GREEN:** Implement this concrete API and no second payload store:

```swift
nonisolated protocol DeviceEpochStoreLocking: Sendable {
    func withLock<T>(_ body: () -> T) -> T?
}

extension ActiveLockPersistenceLock: DeviceEpochStoreLocking {}

nonisolated protocol DeviceEpochFileIO: Sendable {
    func read(from url: URL) throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) throws
}

nonisolated struct SystemDeviceEpochFileIO: DeviceEpochFileIO {
    func read(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

nonisolated enum DeviceEpochStoreError: Error, Equatable {
    case lockUnavailable
    case ownerMismatch
    case unsupportedSchema(Int)
    case encodeFailed
    case writeFailed
    case readbackFailed
}

nonisolated final class DeviceEpochStore: @unchecked Sendable {
    static let shared = DeviceEpochStore()

    static let fileName = "metering-device-epoch-store-v4.json"

    init(
        fileURL: URL? = nil,
        lock: any DeviceEpochStoreLocking = ActiveLockPersistenceLock.shared,
        fileIO: any DeviceEpochFileIO = SystemDeviceEpochFileIO(),
        ownerProvider: @escaping @Sendable () -> UUID? = {
            UserDefaults(suiteName: "group.com.evlin.ios")?
                .string(forKey: "evlin.childId")
                .flatMap(UUID.init(uuidString:))
        }
    )

    func read() throws -> DeviceEpochStoreState

    @discardableResult
    func transaction<Value>(
        expectedOwner: UUID?,
        _ mutate: (inout DeviceEpochStoreState) throws -> Value
    ) throws -> Value
}
```

`transaction` acquires `ActiveLockPersistenceLock` through
`DeviceEpochStoreLocking`, checks the owner provider,
decodes one root, applies the closure to a copy, checks owner again, writes with
`.atomic`, decodes readback, compares it to the intended root, checks owner a
third time, and only then returns. Tests inject lock refusal and file-operation
faults through the declared initializer; production always uses the shared lock,
`SystemDeviceEpochFileIO`, and App Group container. No individual queue or
lifecycle key is written to `UserDefaults`.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochContractTests' test
for target in 'Evlin iOS' EvlinDeviceActivityMonitor EvlinPushApplier; do
  xcodebuild -project 'Evlin iOS.xcodeproj' -target "$target" \
    -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO \
    IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
done
```

Expected GREEN: all fault cases leave the prior root byte-identical and all
three consumers compile.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOSTests/DeviceEpochStoreTests.swift' \
  'Evlin iOSTests/MeteringTargetMembershipTests.swift' \
  'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: add atomic device epoch store'
```

## Task 5: Activate Durable V1 Queue And Recovery Before V2

**Interfaces:** Consumes `EpochSampleRequestDTO`, `DeviceEpochStore`, and the
current `EarnedSampleReporter` v1 fields. Produces durable registration/sample
queues, terminal/retry response classification, legacy queue import, and a
recovery driver that is already active while local selected protocol remains 1.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochDelivery.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochDeliveryTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Persist a v1 callback, terminate the producer, instantiate a new
delivery driver, and assert the same request bytes are posted once and removed
only after terminal/accepted disposition. Cover malformed protocol pairs,
network/5xx retry, sample 409 identity terminal, `accounting_paused`,
`legacy_after_v2`, duplicate work ID, legacy UserDefaults import, and owner
switch during response handling. Also cover child-state 200 decoding, non-200
failure, absent runtime, and exact `X-Child-Id` request bytes.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' test
```

Expected RED: the cold driver sees no `EpochSampleWork` because production
still owns payloads in the legacy retry key.

**Minimal GREEN:** Add these production boundaries:

```swift
nonisolated protocol MeteringHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: MeteringHTTPTransport {}

nonisolated enum EpochSampleHTTPDisposition: Equatable, Sendable {
    case accepted(DeviceDaySnapshotDTO)
    case terminal(DeviceDaySnapshotDTO?)
    case retry

    var removesQueuedSample: Bool {
        switch self {
        case .accepted, .terminal: return true
        case .retry: return false
        }
    }
}

nonisolated enum EpochRegistrationHTTPDisposition: Equatable, Sendable {
    case registered(EpochRegistrationResponseDTO)
    case authoritativeBaseMismatch(DeviceDaySnapshotDTO)
    case terminal
    case retry
}

nonisolated final class MeteringEpochDelivery: @unchecked Sendable {
    init(
        baseURL: URL,
        store: DeviceEpochStore = .shared,
        transport: any MeteringHTTPTransport,
        clock: any MeteringClock = MeteringRuntimeClock.live()
    )

    func enqueueV1(_ request: EpochSampleRequestDTO, owner: UUID) throws
    func enqueueRegistration(_ request: EpochRegistrationRequestDTO, owner: UUID) throws
    func fetchChildState(owner: UUID) async throws -> MeteringChildStateDTO
    func drain(owner: UUID) async
}
```

The old retry queue is imported once under the root transaction and removed
only after root readback. Existing production callback reporting calls
`enqueueV1` then `drain`; no v2 request can yet be constructed or selected.
`fetchChildState(owner:)` uses `MeteringChildStateRequests.state`, requires HTTP
200, and decodes `MeteringChildStateDTO`; it never substitutes cached/local
minutes for a missing runtime. Registration 200 is the only future transition
that may set selected version 2.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' \
  -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' test
```

Expected GREEN: v1 remains selected, queue/reopen behavior is durable, and
accepted/terminal work drains without a fallback payload authority. The driver
dispatches only `EpochSampleDeliveryAuthorization.deliverable`; registration-
blocked work remains durable and untouched.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/MeteringEpochDelivery.swift' \
  'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOS/Services/EarnedSampleReporter.swift' \
  'Evlin iOSTests/MeteringEpochDeliveryTests.swift' \
  'Evlin iOSTests/EarnedSampleReporterTests.swift' \
  'Evlin iOSTests/MeteringTargetMembershipTests.swift' \
  'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: activate durable metering delivery queue'
```

## Task 6: Extend Backend Vector Evidence Without Production Changes

**Interfaces:** Consumes the existing Phase 2 endpoints, database fixtures, and
canonical V01-V23 fixture. Produces shared V24-V32 fixture cases and endpoint
integration evidence for registration/sample rows, device/child ledgers, bank
ledger, lock ledger, and `legacy_after_v2`. It changes backend tests only.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_vector_contract.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_phase3_vectors.py`

**TDD RED:** First add a coverage test requiring exactly V01-V32 and the exact
new meanings below. Add endpoint tests that post a pre-ratchet v1 request,
register, post a route-shaped v2 request, then post stale v1 and query row counts
inside the same PostgreSQL transaction.

| ID | Required outcome |
|---|---|
| V24 | today + 7 dates; refill appends one tail date; no unchanged replacement |
| V25 | expired coverage; unknown callback has zero metering/earned effects |
| V26 | `excessiveActivities`; verified routes preserved; ready-through bounded |
| V27 | malformed/mismatched/prepared/tombstoned/unauthorized-unregistered routes have zero effects; current offline work is registration-blocked |
| V28 | install fault boundaries adopt the same route/work IDs |
| V29 | shield/identity/rollover fault boundaries converge by ack/CAS |
| V30 | real v1 -> registration -> v2 -> stale v1 `legacy_after_v2` |
| V31 | production `ShieldRecord.taskPause` CAS preservation contract |
| V32 | one authoritative 409 base correction; second conflict terminal |

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
pytest -q tests/test_metering_epoch_phase3_vectors.py
```

Expected RED: fixture coverage reports V24-V32 absent.

**Minimal GREEN:** Add a typed `phase3_cases` group and complete JSON cases with zero-valued effect keys for
rejected routes and concrete IDs/dates from `2026-07-17` through `2026-07-24`.
The V30 endpoint test must call the real routes and assert one epoch row, one v2
sample row, the expected earned-time device/child ledger values, unchanged bank
and lock ledgers for stale v1, and terminal warning `legacy_after_v2`. Its v2
request uses the live Phase 2 aliases `evlin.earned.budget.<route-uuid>` and
`evlin.earned.t5`; Swift separately proves the raw Apple event contains that
same route UUID. V31 is a
cross-language data contract only; Swift owns the real `ShieldRecord` execution.
Do not change `app/`, migrations, or the user's dirty
`tests/test_bigkid_endpoints.py`.

Update the existing vector contract test to require V01-V32 and dispatch
V24-V32 through the new Phase 3 test adapter. Its cross-repository byte test may
skip only when `EVLIN_BACKEND_ONLY_CI=1`; Task 7 removes the temporary workspace
drift by committing the identical iOS fixture and reruns the non-skipped check.

**Focused and full GREEN:** Re-run RED, then:

```bash
EVLIN_BACKEND_ONLY_CI=1 pytest -q \
  tests/test_metering_epoch_phase3_vectors.py \
  tests/test_metering_epoch_phase2_integration.py \
  tests/test_metering_epoch_registration.py \
  tests/test_metering_epoch_vector_contract.py \
  tests/test_metering_epoch_models.py
```

Expected GREEN: V30 reaches real rows/ledgers and stale v1 creates no new row or
ledger mutation.

**Staged review and commit:**

```bash
git add tests/fixtures/metering_epoch_vectors.json \
  tests/test_metering_epoch_vector_contract.py \
  tests/test_metering_epoch_phase3_vectors.py
git diff --cached --check
git diff --cached --stat
git diff --cached
test "$(git diff --cached --name-only | wc -l | tr -d ' ')" -eq 3
git commit -m 'test: extend phase 3 metering vector evidence'
```

## Task 7: Land Swift V24-V32 And Real P3V01 CAS Adapter

**Interfaces:** Consumes the byte-identical backend fixture, actual
`ShieldRecord`/`ShieldSource.taskPause`, and the pure epoch contract. Produces
Swift vector decoding, expanded observable effects, and a production CAS
function used later by the durable effect store. P3V01 never uses a test-only
record projection.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/Fixtures/metering_epoch_vectors.json`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/Fixtures/metering_epoch_phase3_vectors.json`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochContract.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedShieldEffectStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochGoldenVectorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochVectorCoverageTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochPhase3VectorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Copy the backend fixture byte-for-byte, require V01-V32, and add
P3V01 with a Codable production `ShieldRecord` containing
`[manual, taskPause, earnedTime]`. Its expected CAS failure uses a newer current
record and preserves all three sources. A second case proves an exact match
removes only `earnedTime`.

```json
{
  "schema_version": 1,
  "cases": [
    {
      "id": "P3V01",
      "operation_id": "70000000-0000-0000-0000-000000000001",
      "expected_applied": {
        "recordKey": "savedList:60000000-0000-0000-0000-000000000001",
        "tier": "savedList",
        "targetKey": "60000000-0000-0000-0000-000000000001",
        "displayName": "Locked Set",
        "lastCommandID": "70000000-0000-0000-0000-000000000001",
        "appTokens": [],
        "categoryTokens": [],
        "webDomainTokens": [],
        "appliesToAll": false,
        "issuedAt": "2026-07-17T12:00:00Z",
        "expiresAt": null,
        "originalRequest": "earned terminal route",
        "targetChildID": "80000000-0000-0000-0000-000000000001",
        "sources": ["manual", "taskPause", "earnedTime"]
      },
      "current": {
        "recordKey": "savedList:60000000-0000-0000-0000-000000000001",
        "tier": "savedList",
        "targetKey": "60000000-0000-0000-0000-000000000001",
        "displayName": "Locked Set",
        "lastCommandID": "70000000-0000-0000-0000-000000000099",
        "appTokens": [],
        "categoryTokens": [],
        "webDomainTokens": [],
        "appliesToAll": false,
        "issuedAt": "2026-07-17T12:00:00Z",
        "expiresAt": null,
        "originalRequest": "newer task mutation",
        "targetChildID": "80000000-0000-0000-0000-000000000001",
        "sources": ["manual", "taskPause", "earnedTime"]
      },
      "release_succeeds": false,
      "remaining_sources": ["manual", "taskPause", "earnedTime"]
    },
    {
      "id": "P3V02",
      "operation_id": "70000000-0000-0000-0000-000000000002",
      "expected_applied": {
        "recordKey": "savedList:60000000-0000-0000-0000-000000000002",
        "tier": "savedList",
        "targetKey": "60000000-0000-0000-0000-000000000002",
        "displayName": "Locked Set",
        "lastCommandID": "70000000-0000-0000-0000-000000000002",
        "appTokens": [],
        "categoryTokens": [],
        "webDomainTokens": [],
        "appliesToAll": false,
        "issuedAt": "2026-07-17T12:00:00Z",
        "expiresAt": null,
        "originalRequest": "earned terminal route",
        "targetChildID": "80000000-0000-0000-0000-000000000002",
        "sources": ["manual", "taskPause", "earnedTime"]
      },
      "current": {
        "recordKey": "savedList:60000000-0000-0000-0000-000000000002",
        "tier": "savedList",
        "targetKey": "60000000-0000-0000-0000-000000000002",
        "displayName": "Locked Set",
        "lastCommandID": "70000000-0000-0000-0000-000000000002",
        "appTokens": [],
        "categoryTokens": [],
        "webDomainTokens": [],
        "appliesToAll": false,
        "issuedAt": "2026-07-17T12:00:00Z",
        "expiresAt": null,
        "originalRequest": "earned terminal route",
        "targetChildID": "80000000-0000-0000-0000-000000000002",
        "sources": ["manual", "taskPause", "earnedTime"]
      },
      "release_succeeds": true,
      "remaining_sources": ["manual", "taskPause"]
    }
  ]
}
```

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' test
```

Expected RED: V24-V32 are not decoded and the production CAS API is missing.

**Minimal GREEN:** Extend `MeteringEffects` with route/install/tombstone,
coverage, queue, envelope, and rollover counters. Add typed Phase 3 input and
observation cases to `MeteringEpochContract.swift`. Add this production
function to `EarnedShieldEffectStore.swift`:

```swift
nonisolated enum EarnedShieldCAS {
    static func releasingEarnedSource(
        current: ShieldRecord?,
        expectedApplied: ShieldRecord
    ) -> ShieldRecord? {
        guard current == expectedApplied else { return current }
        var released = expectedApplied
        released.sources.remove(.earnedTime)
        return released.sources.isEmpty ? nil : released
    }
}
```

The vector test constructs the full real `ShieldRecord` memberwise, calls this
function, and compares the complete resulting record. Add effect-store target
membership and its DAM dependency closure now.

**Focused and full GREEN:** Re-run RED, verify fixture hashes, then run:

```bash
cmp 'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringEpochContractTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' test
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
pytest -q tests/test_metering_epoch_vector_contract.py \
  tests/test_metering_epoch_phase3_vectors.py
```

Expected GREEN: V01-V32 execute, fixtures are byte-identical, and P3V01 reaches
the production CAS with real `.taskPause`.

**Staged review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' \
  'Evlin iOSTests/Fixtures/metering_epoch_phase3_vectors.json' \
  'Evlin iOS/Services/MeteringEpochContract.swift' \
  'Evlin iOS/Services/EarnedShieldEffectStore.swift' \
  'Evlin iOSTests/MeteringEpochGoldenVectorTests.swift' \
  'Evlin iOSTests/MeteringEpochVectorCoverageTests.swift' \
  'Evlin iOSTests/MeteringEpochPhase3VectorTests.swift' \
  'Evlin iOSTests/MeteringTargetMembershipTests.swift' \
  'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
BACKEND_VECTOR_SHA="$(git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend \
  log --format='%H%x09%s' \
  "$(cat .superpowers/evidence/metering-phase3/backend-base-sha.txt)..HEAD" \
  | awk -F '\t' '$2 == "test: extend phase 3 metering vector evidence" { print $1 }')"
test "$(printf '%s\n' "$BACKEND_VECTOR_SHA" | rg -c '^[0-9a-f]{40}$')" -eq 1
git commit -m 'test: add phase 3 route and effect vectors' \
  -m "Phase3-Depends-On: $BACKEND_VECTOR_SHA"
```

## Task 8: Add Dated Route Names, Schedules, And Eight-Date Planning

**Interfaces:** Consumes the six-field `MeteringGenerationKey`, exact persisted
selection bytes, `MeteringEpochContract.selectionDigest(persistedBytes:)`, and
the injected clock. Produces strict route naming/parsing, non-repeating
`datedSchedule(usageDate:timeZone:calendar:)`, and deterministic today + 7
planning. A future route reserves an epoch UUID but does not create or register
a current `DeviceDailyEpoch` before its date.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringCallbackRoute.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetScheduler.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringCallbackRouteTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetSchedulerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Test exact names for a fixed route UUID; reject malformed UUIDs,
route mismatch, wrong threshold suffix, zero/negative threshold, and extra
segments. Test New York spring/fall DST dates, Tokyo/New York split, invalid
calendar dates, and `repeats == false`. Advance 121 ten-second polls and assert
one generation, exactly eight fixed route/epoch IDs, no replacement start/stop,
and date excluded from generation identity.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringCallbackRouteTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' test
```

Expected RED: `datedSchedule` and `MeteringRouteNamespace` are missing.

**Minimal GREEN:** Add this exact schedule implementation; keep
`dailySchedule(timeZone:calendar:)` only for the legacy lane until Task 24:

```swift
nonisolated enum MeteringDatedScheduleError: Error, Equatable {
    case invalidUsageDate(String)
    case calendarArithmeticFailed(String)
}

extension EarnedBudgetScheduler {
    nonisolated static func datedSchedule(
        usageDate: String,
        timeZone: TimeZone,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> DeviceActivitySchedule {
        let pieces = usageDate.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2])
        else { throw MeteringDatedScheduleError.invalidUsageDate(usageDate) }

        var policyCalendar = calendar
        policyCalendar.locale = Locale(identifier: "en_US_POSIX")
        policyCalendar.timeZone = timeZone
        var start = DateComponents()
        start.calendar = policyCalendar
        start.timeZone = timeZone
        start.year = year
        start.month = month
        start.day = day
        start.hour = 0
        start.minute = 0
        start.second = 0
        guard let startDate = policyCalendar.date(from: start),
              policyCalendar.dateComponents([.year, .month, .day], from: startDate).year == year,
              policyCalendar.dateComponents([.year, .month, .day], from: startDate).month == month,
              policyCalendar.dateComponents([.year, .month, .day], from: startDate).day == day
        else { throw MeteringDatedScheduleError.invalidUsageDate(usageDate) }
        guard let endDate = policyCalendar.date(byAdding: .day, value: 1, to: startDate)
        else { throw MeteringDatedScheduleError.calendarArithmeticFailed(usageDate) }
        let fields: Set<Calendar.Component> = [
            .calendar, .timeZone, .year, .month, .day, .hour, .minute, .second,
        ]
        let intervalStart = policyCalendar.dateComponents(fields, from: startDate)
        let intervalEnd = policyCalendar.dateComponents(fields, from: endDate)
        return DeviceActivitySchedule(
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            repeats: false
        )
    }
}
```

Add namespace and planner APIs:

```swift
nonisolated struct ParsedMeteringRouteName: Equatable, Sendable {
    let routeID: UUID
    let thresholdMinutes: Int
}

nonisolated enum MeteringRouteNamespace {
    static let prefix = "evlin.earned.v2."

    static func activityName(routeID: UUID) -> String
    static func eventName(routeID: UUID, thresholdMinutes: Int) -> String
    static func parse(activityName: String, eventName: String) -> ParsedMeteringRouteName?
}

nonisolated enum MeteringHorizonPlanner {
    static let dateCount = 8

    static func requiredUsageDates(
        today: String,
        timeZone: TimeZone,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> [String]
}
```

For each missing date, create one immutable route with stable UUIDs, a
`futurePlanned` `pendingStart`, exact schedule/event plan, and no registration
work. For current date, co-persist generation, full epoch, route, registration,
and install work from `AuthoritativeMeteringInput`. Reconciliation reuses every
existing route ID for the same `(generationID, usageDate)`.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringCallbackRouteTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' \
  -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' test
```

Expected GREEN: V24 and the 121-poll assertion retain one generation and the
same eight route IDs; DST schedules span the correct canonical dates.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/MeteringCallbackRoute.swift' \
  'Evlin iOS/Services/EarnedBudgetScheduler.swift' \
  'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOSTests/MeteringCallbackRouteTests.swift' \
  'Evlin iOSTests/EarnedBudgetSchedulerTests.swift' \
  'Evlin iOSTests/MeteringTargetMembershipTests.swift' \
  'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: plan stable dated metering routes'
```

## Task 9: Implement Crash-Safe Register, Start, Verify, Activate, Stop

**Interfaces:** Consumes route/install/registration work, exact center
inspection methods, and the delivery queue. Produces the only dated monitor
installer and recovery state machine. Today's route requires registration
before start except explicit `offlinePending`; future dates use
`futurePlanned`. New is verified before activation; old is retired/stopped only
after new is active.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochDelivery.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringCallbackRoute.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringActivityInstallRecoveryTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Inject stops after: root `pendingStart`, registration 200 before
local ack, daemon start before verify, verify before activation, activation
before old retirement, retirement before `pendingStop`, Apple stop before
absence ack, and ack before tombstone retention. Reopen each root and assert the
same work/route IDs converge. Test failed new start leaves old active. Test
`excessiveActivities` preserves verified routes and never stops one for room.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringActivityInstallRecoveryTests' test
```

Expected RED: a reopened `pendingStart` remains pending and no center call is
made.

**Minimal GREEN:** Implement the exact driver boundary:

```swift
@MainActor
final class EarnedMeteringRecoveryDriver {
    init(
        store: DeviceEpochStore = .shared,
        delivery: MeteringEpochDelivery,
        center: any MeteringDeviceActivityCenter,
        clock: any MeteringClock = MeteringRuntimeClock.live()
    )

    func recover(ownerChildDeviceID: UUID) async throws
}
```

`recover` drains registration first, adopts any daemon-started route by exact
schedule/events equality, persists `.installed`, atomically marks new `.active`
and old `.retired`, appends old `.pendingStop`, calls stop, and acknowledges
only after `activities` no longer contains the old name. A 200 registration
sets install authorization `.registered`; future date and offline states remain
explicit. A base mismatch consumes `BaseCorrectionState.available`, creates one
corrected epoch/request from `authoritativeSnapshot.estimatedMinutes`, and sets
`.used`; a second mismatch is terminal and retires the epoch rather than loops.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringActivityInstallRecoveryTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' \
  -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' test
```

Expected GREEN: V26/V28/V32 pass, every reopen reuses IDs, and no old route is
stopped before verified new activation.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' \
  'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOS/Services/MeteringEpochDelivery.swift' \
  'Evlin iOS/Services/MeteringCallbackRoute.swift' \
  'Evlin iOSTests/MeteringActivityInstallRecoveryTests.swift' \
  'Evlin iOSTests/MeteringTargetMembershipTests.swift' \
  'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: recover dated monitor installation transactions'
```

## Task 10: Put Immutable Route Trust Before Every Callback Effect

**Interfaces:** Consumes `MeteringAppleCallback`, strict route parser,
tombstones, active epoch/generation, 30-second production jitter, and durable
queues. Produces one callback coordinator used by app tests and DAM integration.
It has no lower-bound age rejection and caps injected jitter at 60 seconds.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringCallbackRoute.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochDelivery.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedMeteringCallbackTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Drive unknown, malformed, route-ID mismatch, prepared, retired,
stopped, tombstoned, future, unregistered, wrong owner/day/epoch/policy,
namespace mismatch, paused, coverage-exhausted, negative delta, 31-seconds-too-
early, 61-second configured jitter, delayed one-day callback, current-day
`offlinePending`, and a valid registered callback. For every rejection assert
root bytes, queue depth, transport calls, notifications, shield records, and
center calls are unchanged. The cross-date case must resolve an actual old-route
tombstone. The trusted `offlinePending` case appends one
`.waitingForRegistration` sample but has zero estimate/network/backend/
notification/shield effects.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' test
```

Expected RED: there is no production coordinator accepting the Apple-shaped DTO.

**Minimal GREEN:** Add this boundary:

```swift
nonisolated enum EarnedMeteringCallbackOutcome: Equatable, Sendable {
    case queued(sampleWorkID: UUID)
    case heldForRegistration(sampleWorkID: UUID)
    case discarded(reason: String)
}

nonisolated final class EarnedMeteringCallback: @unchecked Sendable {
    static let defaultJitterSeconds = 30
    static let maximumJitterSeconds = 60

    init(
        store: DeviceEpochStore = .shared,
        delivery: MeteringEpochDelivery,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        jitterSeconds: Int = defaultJitterSeconds
    )

    func handle(
        _ callback: MeteringAppleCallback,
        expectedOwnerChildDeviceID: UUID
    ) throws -> EarnedMeteringCallbackOutcome
}
```

The initializer preconditions `0...60`. `handle` parses both names, resolves
route or tombstone, validates route lifecycle and full independent provenance,
runs `MeteringEpochContract.callbackVerdict`, computes adjusted cumulative
estimate, then atomically advances epoch high-water and enqueues one v1/v2 work.
For `.offlinePending`, it enqueues with `.waitingForRegistration` without
advancing accepted local estimate. Registration 200 atomically promotes matching
work to `.deliverable` before the delivery driver can dispatch it.
The transport is not called inside the transaction. Before delivery or later
shield mutation, those components repeat owner/route/epoch authorization.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' test
```

Expected GREEN: V04/V05/V08/V13/V27 pass; delayed input is accepted; every
rejected callback has a zero effect envelope.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedMeteringCallback.swift' \
  'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOS/Services/MeteringCallbackRoute.swift' \
  'Evlin iOS/Services/MeteringEpochDelivery.swift' \
  'Evlin iOSTests/EarnedMeteringCallbackTests.swift' \
  'Evlin iOSTests/MeteringTargetMembershipTests.swift' \
  'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: authorize callbacks through durable routes'
```

## Task 11: Persist Shield Mutation And CAS Recovery Under The Shared Lock

**Interfaces:** Consumes real `ShieldRecord`, `ShieldSourceLogic`, P3V01,
`ActiveLockPersistenceLock`, and route authorization. Produces an independently
recoverable `EarnedShieldEffectEnvelope`; the epoch root stores only its
reference. `ActiveLockStore` and DAM delegate earned mutation/release to the
shared utility while preserving all other source behavior.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedShieldEffectStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/ActiveLockStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedShieldEffectStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/ActiveLockStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochPhase3VectorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Inject crashes before/after prepared write, shield write, applied
write, ManagedSettings recompute, release-pending write, CAS release, and
released write. Include a same-key newer manual/taskPause mutation, deleted and
recreated record, unrelated block, mixed limit/manual/taskPause sources, owner
switch, and duplicate terminal callback.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' test
```

Expected RED: a crash after shield persistence leaves no durable effect phase
from which exact release can recover.

**Minimal GREEN:** Add these exact types and operations:

```swift
nonisolated enum EarnedShieldEffectPhase: String, Codable, Sendable {
    case prepared
    case applied
    case releasePending
    case released
}

nonisolated struct EarnedShieldEffectEnvelope: Codable, Equatable, Sendable {
    let operationID: UUID
    let ownerChildDeviceID: UUID
    let epochID: UUID
    let generationID: UUID
    let routeID: UUID
    let recordKey: String
    let before: ShieldRecord?
    let intendedAfter: ShieldRecord
    var phase: EarnedShieldEffectPhase
}

nonisolated final class EarnedShieldEffectStore: @unchecked Sendable {
    init(
        suiteName: String = "group.com.evlin.ios",
        lock: ActiveLockPersistenceLock = .shared
    )

    func prepareAndApply(
        envelope: EarnedShieldEffectEnvelope,
        authorize: () -> Bool,
        recompute: ([String: ShieldRecord]) -> Void
    ) throws

    func requestRelease(
        operationID: UUID,
        authorize: () -> Bool,
        recompute: ([String: ShieldRecord]) -> Void
    ) throws

    func recover(
        authorize: (EarnedShieldEffectEnvelope) -> Bool,
        recompute: ([String: ShieldRecord]) -> Void
    ) throws
}
```

Under `ActiveLockPersistenceLock`, persist `.prepared` before shield mutation,
read back, write exact `intendedAfter`, persist `.applied`, then recompute.
Release persists `.releasePending`, calls `EarnedShieldCAS`, persists only an
exact-match change, records `.released`, and recomputes. A CAS conflict leaves
the complete current record untouched. Add/remove only `.earnedTime`; never
alter `manual`, `.taskPause`, `.limit`, reflection-owned manual records, or
blocks.

Add `shieldEffectStore: EarnedShieldEffectStore` to the recovery driver's
initializer and the exact wrapper
`func recoverShieldEffects(ownerChildDeviceID: UUID) throws`; it calls
`EarnedShieldEffectStore.recover` with route/owner authorization and the shared
recompute closure.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' \
  -only-testing:'Evlin iOSTests/ActiveLockStoreTests' \
  -only-testing:'Evlin iOSTests/ShieldSourceSetTests' \
  -only-testing:'Evlin iOSTests/TaskPauseShieldMappingTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -target EvlinDeviceActivityMonitor \
  -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO \
  IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
```

Expected GREEN: P3V01 executes the durable production path and DAM compiles with
the narrow dependency closure.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedShieldEffectStore.swift' \
  'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' \
  'Evlin iOS/Services/ActiveLockStore.swift' \
  'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' \
  'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOSTests/EarnedShieldEffectStoreTests.swift' \
  'Evlin iOSTests/ActiveLockStoreTests.swift' \
  'Evlin iOSTests/MeteringEpochPhase3VectorTests.swift' \
  'Evlin iOSTests/MeteringTargetMembershipTests.swift' \
  'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: persist earned shield effect envelopes'
```

## Task 12: Make Identity Cleanup Owner-Independent And Recoverable

**Interfaces:** Consumes root routes/tombstones/queues/fallback keys, shield
envelopes, and all legacy stop targets while they still exist. Produces one
owner-independent cleanup envelope persisted before owner replacement. Every
process rejects the old owner as soon as `.prepared` exists.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedShieldEffectStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringIdentityCleanupTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetArmingTests.swift`

**TDD RED:** Crash before/after cleanup preparation, old retirement, owner swap,
each registration/sample deletion, each fallback deletion, shield CAS, Apple
stop, each acknowledgement, and final envelope removal. Race a delayed callback
and async response at every boundary. Assert only captured old-owner logical
IDs are removed; new-owner work survives.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' test
```

Expected RED: owner replacement can erase the old owner marker before monitor
stop and queue cleanup are recoverable.

**Minimal GREEN:** Add:

```swift
extension DeviceEpochStore {
    func prepareIdentityTransition(
        from oldOwner: UUID,
        to newOwner: UUID?,
        legacyActivityNames: [String],
        legacyFallbackLogicalKeys: [String]
    ) throws -> UUID
}
```

In one lock transaction, snapshot and sort all old logical IDs, persist
`.prepared`, retire old epochs/routes, add route tombstones, and replace the
owner. `read` and callback authorization reject the old owner whenever this
envelope is nonterminal. Recovery acknowledges exact queue/fallback deletion,
shield CAS, and old activity absence individually. Main app owns monitor work;
DAM can recover shield state; Push only persists/wakes cleanup and never starts
or stops monitoring.

Add the exact recovery entry
`func recoverIdentityCleanup() async throws` to
`EarnedMeteringRecoveryDriver`.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' test
```

Expected GREEN: V13/V29 pass and delayed old work is zero-effect immediately
after preparation, including after owner swap and process restart.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' \
  'Evlin iOS/Services/EarnedBudgetArming.swift' \
  'Evlin iOS/Services/EarnedShieldEffectStore.swift' \
  'Evlin iOSTests/MeteringIdentityCleanupTests.swift' \
  'Evlin iOSTests/EarnedBudgetArmingTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: recover owner independent metering cleanup'
```

## Task 13: Persist Canonical Rollover Effects At Every Boundary

**Interfaces:** Consumes preinstalled dated routes, authoritative canonical
timezone/date, source-specific resets, task gate, bypass marker, registration,
and install state. Produces one `RolloverEffectsWork` created in the same root
transaction as old-epoch retirement/new-epoch creation. No new-day usage or
self-lock effect commits before all required acknowledgements.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/ActiveLockStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringRolloverEffectsTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochGoldenVectorTests.swift`

**TDD RED:** Race callback vs interval start, callback vs app poll, backend
delivery vs midnight, two simultaneous triggers, and old callback after new
commit. Crash before/after the root transaction and each earned/per-app reset,
task reconcile, bypass expiry, registration ack, install ack, and final delete.
Use Tokyo device time with New York canonical time. Assert old callback resolves
its tombstone and cannot erase/set current-day state.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringRolloverEffectsTests' test
```

Expected RED: a crash after new epoch persistence can leave old earned sources
without durable reset work.

**Minimal GREEN:** Add the one shared transition API exercised by every trigger
role in this task's race harness; Task 17 wires each production entry point to
this same API:

```swift
extension DeviceEpochStore {
    func prepareRollover(
        ownerChildDeviceID: UUID,
        fromUsageDate: String,
        to input: AuthoritativeMeteringInput,
        routeID: UUID,
        epochID: UUID
    ) throws -> UUID
}
```

The transaction deterministically reuses an existing `(owner,toUsageDate)`
operation, retires the old epoch, creates the full new epoch and registration
work from backend `estimatedMinutes`, activates the reserved dated route only
after registration/install acknowledgement, and persists all six pending effect
acks. Reset/reconcile operations read back before acknowledging. While work is
pending, a new-day callback may be durably represented but has zero local usage
or shield effects.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringRolloverEffectsTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' \
  -only-testing:'Evlin iOSTests/ActiveLockStoreTests' \
  -only-testing:'Evlin iOSTests/TaskPauseShieldMappingTests' test
```

Expected GREEN: V08/V09/V21/V22/V29 pass, with old route tombstone evidence and
source-specific readback acknowledgements.

The recovery driver exposes the exact entry
`func recoverRollover(ownerChildDeviceID: UUID) async throws`.
Before preparing a current-day epoch, that method calls
`MeteringEpochDelivery.fetchChildState(owner:)`, combines the returned runtime
with the active generation's exact persisted selection bytes and enforcement
set ID, and constructs `AuthoritativeMeteringInput`. A non-200, missing runtime,
owner mismatch, or date mismatch leaves the preinstalled route non-authorizing
and the callback zero-effect; no local value supplies `baseAcceptedMinutes`.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' \
  'Evlin iOS/Services/EarnedMeteringCallback.swift' \
  'Evlin iOS/Services/ActiveLockStore.swift' \
  'Evlin iOSTests/MeteringRolloverEffectsTests.swift' \
  'Evlin iOSTests/MeteringEpochGoldenVectorTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: persist canonical rollover effects'
```

## Task 14: Make Pause And Resume Always Conservative

**Interfaces:** Consumes full epoch status/high-water/excluded state and
task/reflection gate input. Produces continuous dated-monitor accounting with
one discarded post-resume boundary. It never stops a route for gate close,
never emits `gate_resume_exact_rebase`, and exposes no exact-raw branch.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPauseAccountingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`

**TDD RED:** Cover pause before first callback, multiple paused thresholds,
resume without callback, first callback after resume, subsequent callback,
duplicate threshold, force-quit DAM-only sequence, task bypass, reflection
precedence, and monitor call counts. First post-resume callback must update
excluded/high-water, clear the boundary, and create no queue/shield effect.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringPauseAccountingTests' test
```

Expected RED: production still routes pause through legacy recovery/rearm flags.

**Minimal GREEN:** Use only this transition math inside the root transaction:

```swift
nonisolated enum MeteringPauseAccounting {
    static func observe(rawThreshold: Int, epoch: inout DeviceDailyEpoch) -> Int? {
        let increment = max(0, rawThreshold - epoch.lastRawThresholdMinutes)
        if epoch.status == .paused || epoch.resumeBoundaryPending {
            epoch.excludedWhilePausedMinutes += increment
            epoch.lastRawThresholdMinutes = max(epoch.lastRawThresholdMinutes, rawThreshold)
            epoch.resumeBoundaryPending = false
            return nil
        }
        epoch.lastRawThresholdMinutes = max(epoch.lastRawThresholdMinutes, rawThreshold)
        return epoch.baseAcceptedMinutes
            + epoch.lastRawThresholdMinutes
            - epoch.excludedWhilePausedMinutes
    }
}
```

Gate close sets `.paused`; gate open sets `.active` and
`resumeBoundaryPending = true`. Neither transition calls center start/stop.
DAM and app use the same transaction. Push may persist or wake already explicit
work, but cannot infer a gate transition from an incomplete payload and cannot
own monitor operations.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringPauseAccountingTests' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' \
  -only-testing:'Evlin iOSTests/TaskPauseShieldMappingTests' test
```

Expected GREEN: V10/V11/V12 pass; one boundary bucket is conservatively
discarded; monitor start/stop counts remain zero for gate-only transitions.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOS/Services/EarnedMeteringCallback.swift' \
  'Evlin iOS/Services/BigKidStatePoller.swift' \
  'Evlin iOSTests/MeteringPauseAccountingTests.swift' \
  'Evlin iOSTests/BigKidStatePollerTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: account conservatively across metering pauses'
```

## Task 15: Switch The Real Production Chain From V1 To Registered V2

**Interfaces:** Consumes the already-active durable v1 queue, exact DTOs,
installer, callback coordinator, and registration 200. Produces the real
production chain: Apple callback -> DTO -> route -> registration -> local
ratchet -> v2 sample; stale queued v1 after ratchet remains deliverable and
terminates `legacy_after_v2`. Advertisement alone never selects v2.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochDelivery.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochWire.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringProductionRatchetTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`

**TDD RED:** Through the real DAM adapter, fire the currently active production
v1 callback (`evlin.earned.budget.<generation-uuid>` / `evlin.earned.t5`) while
the local ratchet selects 1 and capture exact v1 bytes. Advertise 2 and assert it
stays v1. Feed registration 200, start and verify the dated replacement, and
assert selected version becomes 2 durably. Fire that dated route callback and
capture exact v2 bytes with the Phase 2 alias projection.
Then deliver the retained v1 work and feed a real backend-shaped 200
`legacy_after_v2`; assert queue removal and no local estimate/shield change.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringProductionRatchetTests' test
```

Expected RED: production DAM calls the dictionary body builder directly and no
registration response changes a local ratchet.

**Minimal GREEN:** DAM constructs only:

```swift
let callback = MeteringAppleCallback(
    activityName: activity.rawValue,
    eventName: event.rawValue,
    observedAt: MeteringRuntimeClock.live().now
)
```

The legacy lane passes its DTO through the already durable v1 queue and retains
its exact existing generation metadata. The v2 lane passes the DTO to
`EarnedMeteringCallback`; only after route authorization, the sample builder maps route UUID/threshold through
`MeteringPhase2SampleNames`; raw Apple names remain in the durable route and
callback audit. Delivery persists selected
version 2 only in the same transaction that records registration 200 and
`registeredAt`; the dated replacement is not activated before that transaction
and start verification. V1 bodies retain `generation_armed_at` and
`generation_offset_minutes` and put the adjusted estimate in both minute
fields; v2 bodies use the Phase 2 aliases, `protocol_version = 2`, epoch ID,
raw threshold, and pause-adjusted estimate.
A stale v1 work item is not rewritten as v2. Terminal warning removes it.

**Focused and full GREEN:** Re-run RED, then run both real sides:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringProductionRatchetTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' \
  -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' \
  -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' test
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
pytest -q tests/test_metering_epoch_phase3_vectors.py \
  tests/test_metering_epoch_phase2_integration.py \
  tests/test_metering_epoch_registration.py
```

Expected GREEN: V19/V20/V30 reach request bytes, queues, epoch/sample rows,
ledgers, and terminal stale-v1 behavior. Backend production remains unchanged.

**Staged review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' \
  'Evlin iOS/Services/EarnedSampleReporter.swift' \
  'Evlin iOS/Services/MeteringEpochDelivery.swift' \
  'Evlin iOS/Services/MeteringEpochWire.swift' \
  'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOS/Services/EarnedMeteringCallback.swift' \
  'Evlin iOSTests/MeteringProductionRatchetTests.swift' \
  'Evlin iOSTests/EarnedSampleReporterTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: ratchet production metering from v1 to v2'
```

## Task 16: Integrate Horizon Refresh And Coverage-Exhausted Product State

**Interfaces:** Consumes the eight-date planner, install recovery,
`excessiveActivities`, authoritative poll input, and existing earned readiness
surface. Produces app-run horizon refill without replacement churn and explicit
`ready`/`installLimited`/`coverageExhausted` behavior. Coverage failure neither
adds nor preserves an earned lock and leaves other sources byte-identical.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetScheduler.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringCoverageIntegrationTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetArmingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`

**TDD RED:** Run 121 unchanged production polls, advance one canonical date and
poll once, simulate force-quit through ready-through + 1, inject
`excessiveActivities` after dates 0-3, and reopen. Assert fixed eight IDs across
unchanged polls, only one tail route on advance, verified dates preserved,
actual ready-through recorded, uncovered callbacks zero-effect, earned source
removed only by exact existing provenance, and manual/taskPause/reflection/
admin/block/limit/per-app records unchanged.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringCoverageIntegrationTests' test
```

Expected RED: production polling still invokes the legacy replacement arm and
has no coverage-exhausted state.

**Minimal GREEN:** Project child state into `AuthoritativeMeteringInput`, call
route planning/recovery on app poll/activation, and make readiness derive only
from `MonitorCoverageState`. On `excessiveActivities`, persist
`lastErrorCode = "excessiveActivities"`, calculate ready-through from verified
center state, and stop filling without stopping a verified route. When today is
uncovered, set `.coverageExhausted`; callback coordinator returns zero effects,
and exact earned self-lock release may run through the envelope CAS. No blanket
unshield or source mutation is permitted.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringCoverageIntegrationTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' \
  -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' \
  -only-testing:'Evlin iOSTests/ActiveLockStoreTests' test
```

Expected GREEN: V01/V24/V25/V26 pass through production polling with one
generation and exactly eight fixed installs across 121 polls.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedBudgetArming.swift' \
  'Evlin iOS/Services/EarnedBudgetScheduler.swift' \
  'Evlin iOS/Services/BigKidStatePoller.swift' \
  'Evlin iOS/Services/EarnedTimeStore.swift' \
  'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' \
  'Evlin iOSTests/MeteringCoverageIntegrationTests.swift' \
  'Evlin iOSTests/EarnedBudgetArmingTests.swift' \
  'Evlin iOSTests/BigKidStatePollerTests.swift' \
  'Evlin iOSTests/EarnedTimeStoreTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: expose bounded metering coverage state'
```

## Task 17: Wire Real Cold-Reopen Recovery And Migrate Every Consumer

**Interfaces:** Consumes all replacement services from Tasks 2-16. Produces one
app/DAM reopen entry point that recovers pending install, prepared shield,
cleaning identity, and pending rollover work before new reconciliation. It
migrates every `EarnedActivityGeneration` consumer to the root/route APIs while
leaving the old definition physically present for Task 24.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetScheduler.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/Auth/AuthService.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/FamilyGoneDetector.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Views/Child/BigKid/BigKidRootView.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringColdReopenRecoveryTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AuthServiceTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetArmingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetSchedulerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`

**TDD RED:** Seed four separate cold roots: install `.pendingStart`, shield
`.prepared`, identity `.cleaning`, and rollover with one pending ack. Invoke the
real app launch/activation entry and DAM interval/callback entry. Assert each
recovers before new poll work. Clear the mirrored owner before reopening the
identity case and prove owner-independent cleanup still advances. Also test
sign-out/family-gone stop all route and captured legacy names. This is a genuine
behavioral RED, not a static source assertion.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringColdReopenRecoveryTests' test
```

Expected RED: persisted work remains nonterminal because app/DAM lifecycle
entry points do not call the recovery driver.

**Minimal GREEN:** Add one idempotent entry:

```swift
@MainActor
extension EarnedMeteringRecoveryDriver {
    func recoverOwnerIndependentCleanup() async throws {
        try await recoverIdentityCleanup()
    }

    func recoverBeforeReconciliation(ownerChildDeviceID: UUID) async throws {
        try recoverShieldEffects(ownerChildDeviceID: ownerChildDeviceID)
        try await recoverOwnerIndependentCleanup()
        try await recoverRollover(ownerChildDeviceID: ownerChildDeviceID)
        try await recover(ownerChildDeviceID: ownerChildDeviceID)
    }
}
```

App/DAM process reopen and sign-out recovery call
`recoverOwnerIndependentCleanup()` before resolving a current owner. App
activation, authenticated child-state poll, DAM interval start, and DAM
threshold callback then call `recoverBeforeReconciliation(ownerChildDeviceID:)`
before creating work. Sign-out/family-gone first prepares identity cleanup and
only then clears credentials. Replace all direct
legacy lifecycle reads/writes in the listed production consumers with
root/route APIs. Before commit, this command must print only the legacy enum
definition and tests intentionally retained for Task 24:

```bash
rg -n 'EarnedActivityGeneration' \
  'Evlin iOS' 'EvlinDeviceActivityMonitor' 'Evlin iOSTests' --glob '*.swift'
```

No new production consumer may remain.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringColdReopenRecoveryTests' \
  -only-testing:'Evlin iOSTests/MeteringActivityInstallRecoveryTests' \
  -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' \
  -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' \
  -only-testing:'Evlin iOSTests/MeteringRolloverEffectsTests' \
  -only-testing:'Evlin iOSTests/AuthServiceTests' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' test
for target in 'Evlin iOS' EvlinDeviceActivityMonitor EvlinPushApplier; do
  xcodebuild -project 'Evlin iOS.xcodeproj' -target "$target" \
    -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO \
    IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
done
```

Expected GREEN: all four real cold roots recover, sign-out remains fail-closed,
and app/DAM/Push compile before any legacy lifecycle deletion.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' \
  'Evlin iOS/Services/EarnedBudgetArming.swift' \
  'Evlin iOS/Services/EarnedBudgetScheduler.swift' \
  'Evlin iOS/Services/EarnedSampleReporter.swift' \
  'Evlin iOS/Services/EarnedTimeStore.swift' \
  'Evlin iOS/Services/BigKidStatePoller.swift' \
  'Evlin iOS/Services/Auth/AuthService.swift' \
  'Evlin iOS/Services/FamilyGoneDetector.swift' \
  'Evlin iOS/Views/Child/BigKid/BigKidRootView.swift' \
  'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' \
  'Evlin iOSTests/MeteringColdReopenRecoveryTests.swift' \
  'Evlin iOSTests/AuthServiceTests.swift' \
  'Evlin iOSTests/EarnedBudgetArmingTests.swift' \
  'Evlin iOSTests/EarnedBudgetSchedulerTests.swift' \
  'Evlin iOSTests/EarnedSampleReporterTests.swift' \
  'Evlin iOSTests/EarnedTimeStoreTests.swift' \
  'Evlin iOSTests/BigKidStatePollerTests.swift'
git diff --cached --check
git diff --cached --stat
git diff --cached
git diff --cached --name-only
git commit -m 'feat: recover metering work before reconciliation'
```

## Task 18: Demolish R-16 T1 Arm Signature Churn

**Interfaces:** Consumes committed six-field generation identity, exact raw-byte
digest, dated no-churn planner, and V01/V02/V03/V06/V07/V24. Produces complete
absence of scalar arm signatures and decode/re-encode fingerprinting.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetArmingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT1DemolitionTests.swift`

**TDD RED:** Add a source-architecture test requiring absence of
`armSignatureKey`, `makeArmSignature`, `shouldStartMonitoring`,
`previousArmSignature`, `selectionFingerprint`, `currentArmSignature`, and the
persisted `armSignature` field. Pair it with the 121-poll production test.

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT1DemolitionTests' test
```

Expected RED: the test names `armSignatureKey` in `EarnedBudgetArming.swift`.

**Minimal GREEN:** Delete exactly those symbols, scalar writes/migration, and
their direct tests. All generation decisions call
`selectionDigest(persistedBytes:)` and compare `MeteringGenerationKey`. Do not
add a debounce, last-arm digest, rearm-needed state, or offset veto.

**Focused and full GREEN:** Re-run RED, then:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT1DemolitionTests' \
  -only-testing:'Evlin iOSTests/MeteringCoverageIntegrationTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' \
  -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' test
```

Expected GREEN: one generation/eight routes survive 121 polls and mutable
offset/date/estimate changes.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedBudgetArming.swift' \
  'Evlin iOS/Services/EarnedTimeStore.swift' \
  'Evlin iOSTests/EarnedBudgetArmingTests.swift' \
  'Evlin iOSTests/EarnedTimeStoreTests.swift' \
  'Evlin iOSTests/MeteringT1DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat
git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove metering arm signature churn'
```

## Task 19: Demolish R-16 T2 Raw Threshold Ceiling

**Interfaces:** Consumes immutable route provenance, tombstones, owner/epoch
trust, and physical upper bound. Produces absence of the inline
`n > min(pool, cap)` stale-ladder defense without weakening rejected-callback
zero effects.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedMeteringCallbackTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT2DemolitionTests.swift`

**TDD RED:** Require `stale_ladder_drop` and the pool/cap raw ceiling to be
absent. Prove a delayed event planned by its immutable route remains valid even
after current policy cap changes, while an old route tombstone is zero-effect.

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT2DemolitionTests' test
```

Expected RED: the old DAM branch and diagnostic remain.

**Minimal GREEN:** Delete only that branch/diagnostic. Keep strict route,
owner/date/epoch/policy/namespace and elapsed-time checks before effects. Add no
secondary raw ceiling or quarantine.

**Focused and full GREEN:** Re-run RED, then run V04/V05/V08/V13/V27 through:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT2DemolitionTests' \
  -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' \
  -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' \
  -only-testing:'Evlin iOSTests/MeteringRolloverEffectsTests' test
```

Expected GREEN: valid delayed callback remains accepted and every stale route
case remains zero-effect.

**Staged review and commit:**

```bash
git add 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' \
  'Evlin iOSTests/EarnedMeteringCallbackTests.swift' \
  'Evlin iOSTests/MeteringT2DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat
git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove raw threshold stale ladder ceiling'
```

## Task 20: Demolish R-16 T3 Fresh-At-Fire Gate

**Interfaces:** Consumes strict callback trust, epoch gate status, terminal
event plan, override semantics, and shield envelope. Produces absence of
`shouldApplyEarnedShieldFresh` and any renamed freshness window.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedGateTautologyTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedShieldEffectStoreTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT3DemolitionTests.swift`

**TDD RED:** Require the helper and its DAM call to be absent. Drive an early
terminal event to strict rejection, a delayed trustworthy terminal event to the
real shield envelope, paused/reflection events to zero effects, and override to
source-specific suppression.

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT3DemolitionTests' test
```

Expected RED: `shouldApplyEarnedShieldFresh` remains in production.

**Minimal GREEN:** Delete the helper, branch, and obsolete direct tests. A
trusted terminal route plus open epoch gate calls the shield effect store; no
fresh-backend or first-threshold flag replaces it.

**Focused and full GREEN:** Re-run RED and V04/V05/V10/V12/V15/V16:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT3DemolitionTests' \
  -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' \
  -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' \
  -only-testing:'Evlin iOSTests/MeteringPauseAccountingTests' test
```

Expected GREEN: early/paused events remain zero-effect and delayed trusted
exhaustion persists one prepared/applied envelope.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedSampleReporter.swift' \
  'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' \
  'Evlin iOSTests/EarnedGateTautologyTests.swift' \
  'Evlin iOSTests/EarnedShieldEffectStoreTests.swift' \
  'Evlin iOSTests/MeteringT3DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat
git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove earned fresh at fire gate'
```

## Task 21: Demolish The Phase 3 Portion Of R-16 T4

**Interfaces:** Consumes trusted local lock, `EarnedShieldEffectEnvelope`, exact
CAS release, and P3V01. Produces absence of the 600-second/five-minute backend
headroom veto; backend correction can release only the recorded exact lock.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedGateTautologyTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedShieldEffectStoreTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT4DemolitionTests.swift`

**TDD RED:** Require `backendVetoesSelfLock`, `freshnessSeconds`, and
`marginMinutes` to be absent from the self-lock path. Feed fresh backend
headroom before a trustworthy terminal callback and assert local lock applies;
then feed correction and assert exact CAS release. A newer manual/taskPause
mutation must make release no-op.

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT4DemolitionTests' test
```

Expected RED: the old veto suppresses the trusted lock.

**Minimal GREEN:** Delete the helper/branch/old assertions. Route authoritative
correction to `requestRelease(operationID:authorize:recompute:)`; retain no waiting or headroom
guard.

**Focused and full GREEN:** Re-run RED and P3V01/V15/V16:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT4DemolitionTests' \
  -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' \
  -only-testing:'Evlin iOSTests/ActiveLockStoreTests' test
```

Expected GREEN: trusted lock is immediate, exact correction releases only
earned provenance, and conflicting records remain byte-identical.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedSampleReporter.swift' \
  'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' \
  'Evlin iOSTests/EarnedGateTautologyTests.swift' \
  'Evlin iOSTests/EarnedShieldEffectStoreTests.swift' \
  'Evlin iOSTests/MeteringT4DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat
git diff --cached && git diff --cached --name-only
git commit -m 'refactor: replace backend headroom veto with shield cas'
```

## Task 22: Demolish R-16 T5 Device Plus-Five Heuristic

**Interfaces:** Consumes the shared strict elapsed-time check with 30-second
default/60-second maximum jitter. Produces absence of
`EarnedThresholdPlausibility.toleranceMinutes = 5`. This task is T5, not T4.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT5DemolitionTests.swift`

**TDD RED:** Require the enum/tolerance and `elapsed + 5` arithmetic to be
absent. Exercise immediate t5 rejection, t5 at elapsed 269/270/271 seconds with
30-second jitter, configured jitter 60 accepted at its boundary, jitter 61
refused, and a one-day delayed callback accepted.

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT5DemolitionTests' test
```

Expected RED: `EarnedThresholdPlausibility` remains and immediate t5 is allowed.

**Minimal GREEN:** Delete the enum, call sites, and obsolete tests. Both legacy
and v2 callback lanes use `MeteringEpochContract.callbackVerdict`; add no whole-
bucket allowance.

**Focused and full GREEN:** Re-run RED and strict trust regressions:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT5DemolitionTests' \
  -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' \
  -only-testing:'Evlin iOSTests/MeteringProductionRatchetTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' test
```

Expected GREEN: V04/V05/V19/V30 pass with strict upper bounds and no lower age
bound.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedTimeStore.swift' \
  'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' \
  'Evlin iOSTests/EarnedTimeStoreTests.swift' \
  'Evlin iOSTests/MeteringT5DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat
git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove device plus five trust heuristic'
```

## Task 23: Demolish R-16 T7 Counter Recovery Flags

**Interfaces:** Consumes committed epoch pause status, high-water,
`excludedWhilePausedMinutes`, and one `resumeBoundaryPending`. Produces absence
of legacy pending-uncounted/counter-recovery state and same-day decrease latch.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT7DemolitionTests.swift`

**TDD RED:** Require absence of `counterRecoveryRequired`,
`pendingUncountedReconciliation`, `requiresCounterRecovery`, their persisted
prefixes, and rearm/decrease exceptions. Feed paused `counted=false`, restart,
resume, and two thresholds; assert terminal queue cleanup and exactly one
boundary discard.

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT7DemolitionTests' test
```

Expected RED: persisted prefixes and poller flag remain.

**Minimal GREEN:** Delete only the listed flags, producers, consumers, prefixes,
and direct tests. Keep `resumeBoundaryPending` only inside `DeviceDailyEpoch`.
Do not add another recovery latch.

**Focused and full GREEN:** Re-run RED and V06/V10/V11/V12:

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT7DemolitionTests' \
  -only-testing:'Evlin iOSTests/MeteringPauseAccountingTests' \
  -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' \
  -only-testing:'Evlin iOSTests/BigKidStatePollerTests' test
```

Expected GREEN: pause/restart converges with one epoch-scoped boundary and no
legacy recovery state.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedTimeStore.swift' \
  'Evlin iOS/Services/EarnedSampleReporter.swift' \
  'Evlin iOS/Services/BigKidStatePoller.swift' \
  'Evlin iOSTests/EarnedTimeStoreTests.swift' \
  'Evlin iOSTests/EarnedSampleReporterTests.swift' \
  'Evlin iOSTests/BigKidStatePollerTests.swift' \
  'Evlin iOSTests/MeteringT7DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat
git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove legacy counter recovery flags'
```

## Task 24: Demolish R-16 T8 Dual Activity Lifecycle

**Interfaces:** Consumes Task 17's compile-clean consumer migration, root route/
tombstone/install stop authority, identity cleanup, and one-shot legacy import.
Produces complete deletion of `EarnedActivityGeneration`, lifecycle/breadcrumb
keys, scalar active-name authority, and duplicate recovery logic.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetArmingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetSchedulerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AuthServiceTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT8DemolitionTests.swift`

**TDD RED:** First build app/DAM/tests against replacement APIs, then require
absence of `EarnedActivityGeneration`, `evlin.earned.activityLifecycle`,
`evlin.earned.activityBreadcrumbs`, and
`evlin.earned.activeActivityName` as live authorities. Seed a pre-Phase3
lifecycle blob and assert one root migration captures pending, retiring, active,
legacy `evlin.earned.budget`, scalar, and breadcrumb names in de-duplicated stop
work before deleting old keys.

Build forbidden source tokens in `MeteringT8DemolitionTests.swift` from string
segments so the final repository-wide `rg` does not match the architecture test
itself.

```bash
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT8DemolitionTests' test
```

Expected RED: the enum and dual lifecycle keys remain in `EarnedTimeStore.swift`.

**Minimal GREEN:** Delete the old enum, generation/lifecycle structs, persistence,
authorization, install/recover/stop functions, and direct tests. Keep one private
schema-specific decoder in `DeviceEpochStore` that imports old names only when
the schema-v4 root is absent, commits canonical pending-stop work, verifies
readback, then deletes old keys. It cannot authorize callbacks or overwrite an
existing root.

**Focused and full GREEN:** Re-run RED, require zero symbol references, then
build all consumers:

```bash
test -z "$(rg -l 'EarnedActivityGeneration' \
  'Evlin iOS' 'EvlinDeviceActivityMonitor' 'Evlin iOSTests' --glob '*.swift' || true)"
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" \
  -only-testing:'Evlin iOSTests/MeteringT8DemolitionTests' \
  -only-testing:'Evlin iOSTests/MeteringColdReopenRecoveryTests' \
  -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' \
  -only-testing:'Evlin iOSTests/AuthServiceTests' test
for target in 'Evlin iOS' EvlinDeviceActivityMonitor EvlinPushApplier; do
  xcodebuild -project 'Evlin iOS.xcodeproj' -target "$target" \
    -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO \
    IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
done
```

Expected GREEN: V01/V08/V09/V13/V21/V22/V28/V29 pass and all old names remain
crash-safe stop targets without a second authority.

**Staged review and commit:**

```bash
git add 'Evlin iOS/Services/EarnedTimeStore.swift' \
  'Evlin iOS/Services/DeviceEpochStore.swift' \
  'Evlin iOSTests/EarnedTimeStoreTests.swift' \
  'Evlin iOSTests/EarnedBudgetArmingTests.swift' \
  'Evlin iOSTests/EarnedBudgetSchedulerTests.swift' \
  'Evlin iOSTests/EarnedSampleReporterTests.swift' \
  'Evlin iOSTests/AuthServiceTests.swift' \
  'Evlin iOSTests/MeteringT8DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat
git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove dual earned activity lifecycle'
```

## Task 25: Build The Automated Completion Verifier And Run Every Gate

**Interfaces:** Consumes immutable iOS/backend bases, exact task subjects and
declared files, all V01-V32/P3V01 tests, all regression suites, six targets,
known Release products, and raw evidence logs. Produces a machine-readable
manifest that rejects missing/duplicate/unordered commits, vacuous builds or
scans, unhashed logs, and mismatched task files.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase3_completion.sh`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/tests/verify_metering_phase3_completion_test.sh`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-phase3-task-manifest.json`

**TDD RED:** In temporary synthetic repositories, test zero and duplicate
subject matches, duplicate SHA, commit before base, reversed iOS commit order,
wrong changed path, missing log, wrong log hash, zero Release products, missing
expected product, and missing Task 7 dependency trailer. The script does not
exist, so the first test fails at invocation.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
mkdir -p scripts/tests
bash scripts/tests/verify_metering_phase3_completion_test.sh
```

Expected RED: `scripts/verify_metering_phase3_completion.sh: No such file or directory`.

**Minimal GREEN:** The JSON manifest lists task number, repository (`ios` or
`backend`), exact subject, and exact allowed path set for all 26 tasks. The
verifier must:

1. Read both immutable base SHAs and reject a dirty/missing evidence baseline.
2. Resolve each included exact subject exactly once in its declared
   `BASE..HEAD` range.
3. Require all resolved SHAs unique and each SHA a descendant of its repository
   base.
4. Require every consecutive iOS task SHA to be an ancestor of the next iOS
   task SHA; Task 6 is the only backend commit, and Task 7's commit body must
   contain `Phase3-Depends-On: <Task-6-SHA>` to establish the cross-repository
   dependency edge.
5. Require each commit's changed paths to be nonempty and a subset of its
   declared file set.
6. Verify every raw log record contains command, Xcode/SDK or Python/PostgreSQL
   toolchain, destination/runtime, exit status, product paths where applicable,
   and SHA-256 of the raw log.
7. Require exactly six known Debug and six known Release target build results.
8. Require six known Release executable paths before any `strings` scan.
9. In post-report mode, include and verify Task 26's report commit rather than
   allowing the report to attest its own future SHA.
10. In `--render-report` mode, resolve every manifest SHA/log/product hash and
    write the complete Task 26 report with plain SHA cells and five physical
    `PENDING` rows.

**Focused and full GREEN:** Run the complete gate with raw logs and `pipefail`:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
set -euo pipefail
EVIDENCE="$PWD/.superpowers/evidence/metering-phase3"
PRODUCT_ROOT="$EVIDENCE/products"
mkdir -p "$EVIDENCE/logs" "$PRODUCT_ROOT"

xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PHONE" IPHONEOS_DEPLOYMENT_TARGET=17.6 \
  TARGETED_DEVICE_FAMILY='1,2' test \
  2>&1 | tee "$EVIDENCE/logs/ios-phone-full.log"
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination "$IOS_PAD" IPHONEOS_DEPLOYMENT_TARGET=17.6 \
  TARGETED_DEVICE_FAMILY='1,2' test \
  2>&1 | tee "$EVIDENCE/logs/ios-pad-full.log"

for configuration in Debug Release; do
  for target in 'Evlin iOS' EvlinDeviceActivityMonitor EvlinPushApplier \
      EvlinShieldConfig EvlinDeviceActivityReport 'Evlin iOSTests'; do
    safe_target="$(printf '%s' "$target" | tr ' /' '__')"
    xcodebuild -project 'Evlin iOS.xcodeproj' -target "$target" \
      -configuration "$configuration" -sdk iphoneos CODE_SIGNING_ALLOWED=NO \
      IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' \
      SYMROOT="$PRODUCT_ROOT" build \
      2>&1 | tee "$EVIDENCE/logs/build-${configuration}-${safe_target}.log"
  done
done

cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python -m pytest -q \
  tests/test_metering_epoch_vector_contract.py \
  tests/test_metering_epoch_readiness.py \
  tests/test_metering_policy_identity.py \
  2>&1 | tee "$EVIDENCE/logs/backend-phase3-pure.log"

.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_phase3_vectors.py \
  tests/test_metering_epoch_phase2_integration.py \
  tests/test_metering_epoch_registration.py \
  tests/test_metering_epoch_models.py \
  tests/test_earned_time_models.py \
  tests/test_metering_epoch_sample_adapter.py \
  tests/test_metering_epoch_lifespan.py \
  tests/test_metering_day_reconciler.py \
  tests/test_metering_gate.py \
  tests/test_earned_time_sample.py \
  tests/test_earned_time_auto_lock.py \
  tests/test_earned_time_lock_receipts.py \
  tests/test_earned_time_config.py \
  tests/test_earned_time_policy_summary.py \
  tests/test_earned_time_protocol_ratchet.py \
  tests/test_earned_time_remaining_recompute.py \
  tests/test_earned_time_profile_lock_concurrency.py \
  tests/test_task_lock_service.py \
  tests/test_task_gated_lock_routes.py \
  tests/test_app_limit_delivery.py \
  tests/test_app_limit_wire_contract.py \
  tests/api/test_app_limits_endpoint.py \
  tests/test_effective_state_sources.py \
  2>&1 | tee "$EVIDENCE/logs/backend-phase3-db-regressions.log"
```

Collect and verify nonvacuous Release products before scanning:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
EVIDENCE="$PWD/.superpowers/evidence/metering-phase3"
PRODUCT_ROOT="$EVIDENCE/products"
release_products=(
  "$PRODUCT_ROOT/Release-iphoneos/Evlin iOS.app/Evlin iOS"
  "$PRODUCT_ROOT/Release-iphoneos/EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor"
  "$PRODUCT_ROOT/Release-iphoneos/EvlinPushApplier.appex/EvlinPushApplier"
  "$PRODUCT_ROOT/Release-iphoneos/EvlinShieldConfig.appex/EvlinShieldConfig"
  "$PRODUCT_ROOT/Release-iphoneos/EvlinDeviceActivityReport.appex/EvlinDeviceActivityReport"
  "$PRODUCT_ROOT/Release-iphoneos/Evlin iOSTests.xctest/Evlin iOSTests"
)
test "${#release_products[@]}" -eq 6
for product in "${release_products[@]}"; do test -s "$product"; done
printf '%s\n' "${release_products[@]}" > "$EVIDENCE/release-products.txt"

for product in "${release_products[0]}" "${release_products[1]}" "${release_products[2]}"; do
  if strings "$product" | rg -n \
      'DebugAppGroupMeteringClock|evlin\.metering\.debugClockNow'; then
    exit 1
  fi
done
if strings "${release_products[2]}" | rg -n \
    'EarnedMeteringRecoveryDriver|SystemMeteringDeviceActivityCenter|evlin\.earned\.v2\.'; then
  exit 1
fi
```

Write one SHA-256 manifest entry per command/log with the exact destination,
exit 0, toolchain output, product list, and `shasum -a 256` result. Then run the
verifier through Task 24 before committing Task 25:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
EVIDENCE="$PWD/.superpowers/evidence/metering-phase3"
bash scripts/verify_metering_phase3_completion.sh \
  --manifest docs/superpowers/reports/2026-07-17-metering-phase3-task-manifest.json \
  --evidence "$EVIDENCE" --through-task 24
```

Expected GREEN: all runtime, build, backend, Release exclusion, R-16 absence,
target membership, and evidence integrity gates pass. A zero product set or
missing log fails explicitly.

**Staged review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
EVIDENCE="$PWD/.superpowers/evidence/metering-phase3"
git add scripts/verify_metering_phase3_completion.sh \
  scripts/tests/verify_metering_phase3_completion_test.sh \
  docs/superpowers/reports/2026-07-17-metering-phase3-task-manifest.json
git diff --cached --check
git diff --cached --stat
git diff --cached
test "$(git diff --cached --name-only | wc -l | tr -d ' ')" -eq 3
git commit -m 'test: verify metering phase 3 completion evidence'
bash scripts/verify_metering_phase3_completion.sh \
  --manifest docs/superpowers/reports/2026-07-17-metering-phase3-task-manifest.json \
  --evidence "$EVIDENCE" --through-task 25
```

## Task 26: Record Automated Evidence And Physical Pending Status

**Interfaces:** Consumes the Task 25 machine manifest, immutable bases, real
task SHAs, hashed raw logs, R-16 rulebook hash, and five unperformed physical
gates. Produces an honest report that attests Tasks 1-25 only. Its own commit is
verified afterward by a separate post-report artifact.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md`

**TDD RED:** Run a report validator before creating the report:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
EVIDENCE="$PWD/.superpowers/evidence/metering-phase3"
bash scripts/verify_metering_phase3_completion.sh \
  --manifest docs/superpowers/reports/2026-07-17-metering-phase3-task-manifest.json \
  --evidence "$EVIDENCE" --validate-report \
  docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
```

Expected RED: the completion report is missing.

**Minimal GREEN:** Use verifier render mode so exact-subject resolution must
return one 40-character line before any report is written:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
EVIDENCE="$PWD/.superpowers/evidence/metering-phase3"
REPORT=docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
bash scripts/verify_metering_phase3_completion.sh \
  --manifest docs/superpowers/reports/2026-07-17-metering-phase3-task-manifest.json \
  --evidence "$EVIDENCE" --through-task 25 --render-report "$REPORT"
```

The renderer writes status
`AUTOMATED GATES PASS; PHYSICAL GATES PENDING; PHASE 3 NOT COMPLETE OR RELEASABLE`,
immutable bases, toolchain/runtime, all command/log hashes, exact target
products, backend commit, and rulebook hash. It writes this exact heading and
column order, with Task 18/19/20/21/22/23/24's resolved plain SHAs:

```text
### 本阶段拆除清单 + 向量证据
| 台账 | 本阶段拆除 | 权威替代 | 拆除提交 SHA | 向量证据 |
```

The seven rows are T1, T2, T3, T4 (Phase 3), T5, T7, and T8 with the replacement
and vector sets stated in Tasks 18-24. The renderer also writes a separate
five-row physical table with every status exactly `PENDING`; it fails rather
than emitting a row whose SHA or log is not manifest-backed.

**Focused and full GREEN:** Validate the report against Tasks 1-25 and raw log
hashes:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
EVIDENCE="$PWD/.superpowers/evidence/metering-phase3"
bash scripts/verify_metering_phase3_completion.sh \
  --manifest docs/superpowers/reports/2026-07-17-metering-phase3-task-manifest.json \
  --evidence "$EVIDENCE" --through-task 25 --validate-report \
  docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
```

Expected GREEN: every report SHA/log/product is manifest-backed; report status
remains physical pending and makes no completion/release claim.

**Staged review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
EVIDENCE="$PWD/.superpowers/evidence/metering-phase3"
git add docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
git diff --cached --check
git diff --cached --stat
git diff --cached
test "$(git diff --cached --name-only | wc -l | tr -d ' ')" -eq 1
git commit -m 'docs: record metering phase 3 automated evidence'
REPORT_SHA="$(git rev-parse HEAD)"
bash scripts/verify_metering_phase3_completion.sh \
  --manifest docs/superpowers/reports/2026-07-17-metering-phase3-task-manifest.json \
  --evidence "$EVIDENCE" --through-task 26 --include-report "$REPORT_SHA" \
  > "$EVIDENCE/post-report-attestation.json"
shasum -a 256 "$EVIDENCE/post-report-attestation.json" \
  > "$EVIDENCE/post-report-attestation.sha256"
```

Expected post-commit result: all 26 task commits are represented honestly. The
external artifact includes the report commit; the report does not claim its own
future SHA.

---

## Automated Completion Gate

Automated Phase 3 evidence is acceptable only after Task 26's post-report
attestation proves:

- V01-V32 and P3V01 execute through the required production adapters;
- cold recovery passes for install, shield, identity, and rollover work;
- real v1 -> registration -> v2 -> stale v1 reaches backend rows/ledgers;
- 121 polls retain one generation and the same eight dated installs;
- every rejected/uncovered callback has zero measured effects;
- all R-16 demolition symbols are absent after their replacement vectors;
- app, tests, DAM, Push, Shield Config, and Report build in Debug and Release
  with Swift 5.0, deployment 17.6, and device family `1,2`;
- six nonempty Release products exist before scans;
- DEBUG clock symbols/keys are absent from Release, and Push has no earned route
  installer/monitor-owner symbols;
- all raw logs/products/commands have verified SHA-256 manifest entries;
- all task subjects resolve exactly once, SHAs are unique, repository ancestry
  is ordered, and the backend-to-iOS dependency trailer is exact.

Passing this gate does not make Phase 3 complete or releasable.

## Physical-Device Pending Gate

Keep these rows separate and `PENDING` until observed on real devices:

| Gate | Required evidence | Status |
|---|---|---|
| Production earned threshold | 6-7 minutes foreground and again with Evlin force-killed; one t5, five minutes, no churn | PENDING |
| DEBUG per-app | one-minute limit; no immediate shield, one shield after real use | PENDING |
| Two-device attribution | A then B usage; shared pool and own-cap rows/ledgers attributed exactly | PENDING |
| TestFlight overnight | both child apps force-killed across canonical midnight; dated route rollover and first bucket | PENDING |
| iOS/iPadOS 17.6 floor | physical minimum-floor install/start/callback/stop/horizon behavior because no local 17.6 runtime exists | PENDING |

Record accepted dated-activity count and any
`DeviceActivityCenter.MonitoringError.excessiveActivities` result. The eight-date
horizon remains the product design unless this physical evidence supports a
separately reviewed reduction. No row may be inferred from simulator, logs from
another OS version, or source inspection.

## Requirement-To-Task Audit

| Spec/rule area | Tasks |
|---|---|
| §3 product/source semantics, manual source preservation | 7, 11, 13, 14, 16, 20, 21, 25 |
| §6 generation, epoch, route, root, trust, shield/sample architecture | 2-17, 18-24 |
| §7 exact wire, queues, registration, compatibility, ratchet | 3, 5-7, 9, 10, 15, 25 |
| §8 poll/no-churn, replacement, pause, rollover, identity, coverage, exhaustion | 8-17, 18-24 |
| §10 multi-device/source convergence regressions | 6, 7, 11, 13, 21, 25 |
| §11 legacy device-total path remains untouched | 17, 24, 25 |
| §13 vectors, virtual time, fault injection, builds | 2, 4-17, 25 |
| §14 physical gates | Physical-Device Pending Gate |
| §15 Phase 3 definition and R-16 completion report | 1-26 |
| §16 acceptance and no completion before physical | 25, 26, both final gates |
| R-16 T1/T2/T3/T4/T5/T7/T8 | 18/19/20/21/22/23/24 after Tasks 2-17 replacements |

## Final Self-Review Commands

Before Task 1 begins and again before Task 26 reports evidence, run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
rg -n 'TB[D]|TO[DO]|similar[[:space:]]+to' \
  docs/superpowers/plans/2026-07-17-metering-epoch-phase-3.md && exit 1 || true
rg -n 'protocol MeteringDeviceActivityCenter: AnyObjec[t]|case deviceToBackendOffsetSecond[s].*device_to_backend_offset_second[s]|case exactRawThreshol[d]' \
  docs/superpowers/plans/2026-07-17-metering-epoch-phase-3.md && exit 1 || true
rg -n 'selectionDigest\(persistedBytes:|datedSchedule\(usageDate:|generation_offset_minutes|MeteringEpochWire.swift' \
  docs/superpowers/plans/2026-07-17-metering-epoch-phase-3.md
rg -n 'SWIFT_VERSION = 5.0|IPHONEOS_DEPLOYMENT_TARGET = 17.6|TARGETED_DEVICE_FAMILY = "1,2"' \
  'Evlin iOS.xcodeproj/project.pbxproj'
git status --short --branch
git diff --check
```

Manually verify every type name and signature is identical across task snippets;
every demolition depends on committed replacement tests; every new shared file
has exact target membership; Release scans follow successful known-product
builds; and no Profile, onboarding/beta, Render, TestFlight, production DB, or
Phase 2 production file appears in an iOS task commit.
