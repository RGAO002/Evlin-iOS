# Metering Epoch Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task in the existing main workspaces. Do not begin execution until two independent reviewers change this document from **NEEDS RE-REVIEW** to PASS.

**Status:** NEEDS RE-REVIEW after review round 2

**Goal:** Ship the additive backend protocol and iOS device epoch runtime that preserve functional v1 until verified v2 activation, use immutable dated routes, recover every cross-process/crash boundary, and replace the Phase 3 R-16 mechanisms without inventing raw usage.

**Architecture:** Apple callbacks contain only activity name, event name, and observation time. An opaque route UUID in both names resolves an immutable App Group route with independent owner/day/epoch/policy provenance. One versioned Device Epoch Store coordinates app and DAM under `ActiveLockPersistenceLock`; the backend supplies authoritative bases, conservative resume registration, and activation acknowledgement. Canonical today plus seven dates are installed without replacement churn.

**Tech Stack:** Swift language mode 5.0, XCTest, DeviceActivity, FamilyControls, ManagedSettings, CryptoKit, App Group atomic persistence and `flock`, URLSession, FastAPI, Pydantic, SQLAlchemy, Alembic, PostgreSQL, pytest, Xcode 26.3/iPhoneOS 26.2 SDK, iOS 26.3.1 simulator runtime, deployment target iOS/iPadOS 17.6.

## Global Constraints

- Work only in `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS`, `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend`, and `/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md`.
- Use the existing main workspaces. Do not create a worktree, push, deploy, use Render/TestFlight, or access a production database.
- Preserve all pre-existing dirty and untracked files. In particular, Phase 3 does not modify `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/APIClient.swift`; its current agreement WIP must remain byte-identical and unstaged.
- Do not change Profile manual-button semantics, onboarding/beta agreement work, Phase 2 plans/reports, or unrelated product behavior.
- Do not remove or repurpose canonical spec §11's separate `BigKidActivityScheduler`/`/child/time-consumption` legacy device-total path; Phase 3 only keeps it distinguished from earned epoch v1/v2 behavior.
- Each task produces exactly one independently testable commit in the repository named by that task. Never amend, squash, or combine task commits.
- Every backend DB integration command uses `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/run_limits_db_regression.py`. Pure backend tests may use `.venv/bin/python -m pytest`.
- Every simulator command names a literal installed destination: `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1` or `platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1`. Device Release builds use the literal `generic/platform=iOS` destination because the scanned products must be `Release-iphoneos`.
- Every build sets `IPHONEOS_DEPLOYMENT_TARGET=17.6`, `TARGETED_DEVICE_FAMILY='1,2'`, and leaves `SWIFT_VERSION=5.0` unchanged. Simulator 26.3.1 evidence proves deployment compatibility, not physical 17.6 runtime behavior.
- No old R-16 mechanism is deleted until the authoritative replacement and its production-path vectors are green in an earlier commit.
- No unregistered Boolean, guard, veto, or fallback may duplicate the registered epoch state.
- All physical-device gates remain `PENDING`; no task may call Phase 3 complete or releasable until they pass.

## Immutable Execution Baseline

Before Task 1, capture immutable bases and dirty state without staging anything:

```bash
set -euo pipefail
IOS=/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
BACKEND=/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
EVIDENCE="$IOS/.superpowers/evidence/metering-phase3"
mkdir -p "$EVIDENCE/logs"
git -C "$IOS" status --short --branch | tee "$EVIDENCE/ios-status-before.txt"
git -C "$BACKEND" status --short --branch | tee "$EVIDENCE/backend-status-before.txt"
git -C "$IOS" rev-parse HEAD | tee "$EVIDENCE/ios-base-sha.txt"
git -C "$BACKEND" rev-parse HEAD | tee "$EVIDENCE/backend-base-sha.txt"
git -C "$IOS" diff --binary | shasum -a 256 | tee "$EVIDENCE/ios-dirty-diff-before.sha256"
git -C "$BACKEND" diff --binary | shasum -a 256 | tee "$EVIDENCE/backend-dirty-diff-before.sha256"
write_untracked_manifest() {
  local root="$1"
  local output="$2"
  git -C "$root" ls-files --others --exclude-standard -z |
    ROOT="$root" python3 -c '
import hashlib, json, os, stat, sys
root = os.environ["ROOT"]
excluded = b".superpowers/evidence/metering-phase3/"
paths = sorted(
    raw for raw in sys.stdin.buffer.read().split(b"\0")
    if raw and not raw.startswith(excluded)
)
for raw in paths:
    path = os.path.join(root, os.fsdecode(raw))
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode):
        kind = "symlink"
        digest = hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest()
    elif stat.S_ISREG(info.st_mode):
        kind = "file"
        h = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                h.update(chunk)
        digest = h.hexdigest()
    else:
        kind = "other"
        digest = hashlib.sha256(b"").hexdigest()
    print(json.dumps({
        "path_bytes_hex": raw.hex(),
        "kind": kind,
        "mode": stat.S_IMODE(info.st_mode),
        "sha256": digest,
    }, sort_keys=True, separators=(",", ":")))
' > "$output"
  shasum -a 256 "$output" > "$output.sha256"
}
write_untracked_manifest "$IOS" "$EVIDENCE/ios-untracked-before.manifest"
write_untracked_manifest "$BACKEND" "$EVIDENCE/backend-untracked-before.manifest"
shasum -a 256 /Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md | tee "$EVIDENCE/r16-before.sha256"
```

For every task: write RED first, run the exact RED command and confirm its named failure, implement the minimum code shown, run focused and full GREEN, stage only declared files, inspect `git diff --cached --check`, `--stat`, full diff, and `--name-only`, then commit with the exact subject. For a pre-dirty declared file use `git add -p` and verify unrelated hunks remain unstaged.

## Verified Existing Contracts

The backend is registered under `settings.api_prefix` (`/api/v1` in production). Exact live routes and headers are:

```text
GET  /api/v1/child/state
     X-Child-Id: <device UUID>
POST /api/v1/child/earned-time/epochs
     X-Evlin-Child-Device-ID: <device UUID>
POST /api/v1/child/earned-time/epochs/{epoch_id}/activation   [Phase 3 additive]
     X-Evlin-Child-Device-ID: <device UUID>
POST /api/v1/child/earned-time/sample
     X-Evlin-Child-Device-ID: <device UUID>
```

Current registration request fields are `protocol_version`, `epoch_id`, `device_id`, `usage_date`, `timezone`, `policy_revision`, `measurement_selection_digest`, `enforcement_set_id`, `started_at`, `base_accepted_minutes`, and `reason`. Existing HTTP 200 fields are `status`, `epoch_id`, `metering_protocol_version`, and authoritative `snapshot`; Phase 3 adds `epoch_status`. Existing base 409 remains exactly `code=authoritative_base_mismatch` plus `authoritative_snapshot`.

Sample common fields are `device_id`, `usage_date`, `timezone`, `activity_name`, `event_name`, `threshold_minutes`, `estimated_minutes`, `observed_at`, and `client_sample_id`. V2 adds `protocol_version=2` and `epoch_id`. V1 may omit both generation fields or send both `generation_armed_at` and `generation_offset_minutes`; a partial pair is invalid. Existing v2 wire aliases remain `evlin.earned.budget.<route UUID>` and `evlin.earned.t<threshold>`. Apple callback names remain `evlin.earned.v2.<route UUID>` and `evlin.earned.v2.<route UUID>.t<threshold>`, so both names carry the opaque route ID.

The current backend immediately ratchets in `metering_epoch_registry.register_metering_epoch`, returns no epoch status, and emits `gate_resume_rebase_required`; Task 3 replaces those semantics additively. `gate_resume_exact_rebase` stays accepted for old rows/clients, while new iOS emits only `gate_resume_conservative`.

The local SDK proves `DeviceActivityCenter` is a struct with `activities`, `schedule(for:)`, `events(for:)`, `startMonitoring`, and `stopMonitoring`; `DeviceActivityMonitor` callbacks provide only names. No app/DAM synchronous exact raw-usage API exists.

## Target Membership

The Xcode project has six targets. Files inside `Evlin iOS` are app members by synchronized root; app-folder sources shared with DAM or Push require exact `membershipExceptions` entries.

| Source | App | DAM | Push | Shield Config | Report | Tests |
|---|---:|---:|---:|---:|---:|---:|
| `MeteringRuntimeInfrastructure.swift` | yes | yes | yes | no | no | via app |
| `MeteringDeviceActivityCenter.swift` | yes | yes | no | no | no | via app |
| `MeteringEpochWire.swift` | yes | yes | yes | no | no | via app |
| `DeviceEpochStore.swift` | yes | yes | yes | no | no | via app |
| `MeteringEpochDelivery.swift` | yes | yes | no | no | no | via app |
| `MeteringCallbackRoute.swift` | yes | yes | no | no | no | via app |
| `MeteringDatedSchedule.swift` | yes | yes | no | no | no | via app |
| `DatedRouteInstaller.swift` | yes | yes | no | no | no | via app |
| `EarnedMeteringCallback.swift` | yes | yes | no | no | no | via app |
| `EarnedShieldEffectStore.swift` | yes | yes | yes | no | no | via app |
| `EarnedMeteringRecoveryDriver.swift` | yes | yes | no | no | no | via app |
| `MeteringProductionComposition.swift` | yes | yes | no | no | no | via app |
| `MeteringProcessEntries.swift` | yes | yes | no | no | no | via app |
| `MeteringV30ScenarioEncoder.swift` | yes | no | no | no | no | via app |

The DAM closure already includes `ShieldRecord.swift`, `ShieldTier.swift`, `ShieldSourceLogic.swift`, and `ActiveLockPersistenceLock.swift`. Do not add `ActiveLockStore.swift` or `ActiveLockStoreTypes.swift` to DAM. Push may read/persist work and shield envelopes but must not compile the center adapter, installer, callback owner, recovery driver, or any `startMonitoring` call.

## Pinned Shared Interfaces

These names and signatures are normative across tasks:

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
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { center.schedule(for: activity) }
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] { center.events(for: activity) }
    func startMonitoring(_ activity: DeviceActivityName, during schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent]) throws {
        try center.startMonitoring(activity, during: schedule, events: events)
    }
    func stopMonitoring(_ activities: [DeviceActivityName]) { center.stopMonitoring(activities) }
}

nonisolated enum MeteringProcessRole: String, Codable, Sendable {
    case app
    case deviceActivityMonitor
}

nonisolated struct MeteringProcessIdentity: Codable, Equatable, Sendable {
    let role: MeteringProcessRole
    let instanceID: UUID
}
```

The protocol deliberately has no `AnyObject` constraint, so a value adapter and struct fakes conform. Clock selection is independent of process-role authorization and can never grant Push monitor ownership.

## Commit Subjects

Tasks use these exact subjects in order:

```text
01 test: register phase 3 metering safety states
02 feat: inject shared metering runtime dependencies
03 feat: add conservative epoch activation protocol
04 feat: add exact metering epoch wire DTOs
05 feat: add atomic device epoch store
06 feat: queue legacy and epoch samples durably
07 test: extend backend phase 3 vectors
08 test: mirror phase 3 vectors in Swift
09 feat: plan immutable dated metering routes
10 feat: arbitrate and verify dated route installs
11 feat: activate v2 without breaking legacy metering
12 feat: authorize earned callbacks by immutable route
13 fix: replace route on authoritative base correction
14 feat: persist earned shield effects across processes
15 feat: retire metering identity atomically
16 feat: recover canonical rollover effects
17 feat: resume metering with conservative replacement
18 feat: wire production metering and V30 encoder
19 test: verify V30 exact bytes across the stack
20 feat: surface bounded metering coverage
21 feat: recover every metering process entry point
22 refactor: remove earned arm signature churn
23 refactor: remove stale raw threshold ceiling
24 refactor: remove earned fresh-at-fire gate
25 refactor: remove earned backend headroom veto
26 refactor: remove earned plus-five heuristic
27 refactor: remove earned counter recovery flags
28 refactor: retire duplicate earned activity lifecycle
29 test: add metering phase 3 completion verifier
30 docs: record metering phase 3 evidence
```

---

## Task 1: Register Every Phase 3 Safety State Under R-16

**Repository:** iOS commit; the rulebook edit is external hash-tracked evidence.

**Interfaces:** Consumes rulebook §11/R-16 and T1-T11. Produces registered names, replacement/justification, deletion criterion, and vector evidence before any Phase 3 state exists. T5 remains the Phase 2 backend heuristic; T11 is the distinct iOS whole-bucket heuristic removed in Task 26.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-phase3-r16-registration.md`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase3_r16.py`

**TDD RED:** Add a host-side stdlib parser before the rulebook rows. It locates
the existing T1-T11 table and the new Phase 3 state table by heading, parses
every Markdown cell, and compares normalized rows to two exact in-code tuples.
The T1-T11 tuple pins every pre-existing cell so this task cannot silently edit
the dismantling ledger. The Phase 3 tuple pins state name, replacement,
deletion criterion, and exact vector set; a name in prose or a wrong vector
must fail.

```python
def parse_table_after_heading(text: str, heading: str) -> tuple[tuple[str, ...], ...]:
    """Return exact non-header Markdown rows; reject duplicate/malformed tables."""

def main() -> int:
    rulebook = Path("/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md").read_text()
    assert parse_table_after_heading(
        rulebook,
        "## 11. 机制拆除台账(反臃肿闸,2026-07-15 Fred 提出)",
    ) == EXPECTED_T1_T11
    assert parse_table_after_heading(
        rulebook,
        "### Phase 3 registered safety state",
    ) == EXPECTED_PHASE3
    return 0
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/verify_metering_phase3_r16.py
```

Expected RED: the exact `### Phase 3 registered safety state` heading/table is
absent; a prose-only name cannot pass. Heading matching is exact after trimming
outer whitespace, not a substring search.

**Minimal GREEN:** Append the exact heading
`### Phase 3 registered safety state` and one R-16 table immediately after the
existing T1-T11 table with these exact rows:

| State | Replaces or justifies | Delete only when | Vectors |
|---|---|---|---|
| `MeteringCallbackRoute/route tombstone` | T2/T8 callback provenance | stop acknowledged, all references terminal, retention elapsed | V04,V05,V08,V27,V35 |
| `LegacyCompatibilityMonitorState` | preserves T8 v1 behavior while replacing its storage authority | owner v2 activated and legacy stop acknowledged | V30,V38 |
| `pendingStart/starting/installed/verified/dualActive/active/pendingStop/stopped` | replaces T8 lifecycle choreography; `dualActive` closes the backend/local ratchet crash window | daemon presence/config or absence acknowledged | V28,V30,V33,V38 |
| `V2RouteHandoff.preparing/dualV2/cutoverReady/committed` | net-new crash-safe v2-to-v2 replacement without a zero-metering window or stale prior sample loss | prior queue/in-flight barrier closed, replacement active, prior stop acknowledged, overlap samples terminal | V09,V21,V22,V32,V37 |
| `ActivityInstallClaim 60-second lease` | net-new app/DAM single-start arbitration | one proven monitor-owner process exists | V33 |
| `futurePlanned/offlinePending` | net-new explicit bounded authorization | registered/activated, retired, or stopped | V24,V27 |
| `MonitorCoverageState.readyThrough/coverageExhausted` | replaces false repeating coverage | horizon refilled or owner/generation retired | V24,V25,V26 |
| `registration/activation queue and per-owner protocol ratchet` | replaces direct v1-only dispatch without breaking v1 | owner retired after terminal queues | V19,V20,V30,V38 |
| `BaseCorrectionState.available/used` | net-new bounded 409 correction | registration accepted or correction terminal | V32 |
| `process-role monitor owner` | net-new capability boundary | physical ownership proof authorizes another role | target/Release/physical evidence |
| `resumeBoundaryPending/paused high-water` | replaces T7 | first new-route callback discarded or epoch retired | V10,V11,V12,V37 |
| `0/5/15/60/300 retry schedule` | net-new deterministic recovery policy | all work terminal | V34 |
| `EarnedShieldEffectEnvelope` | replaces T4 veto | exact release/CAS terminal | V15,V16,P3V01,P3V02,V36 |
| `IdentityCleanupWork` | replaces T8 detached teardown | every captured acknowledgement durable | V13,V29 |
| `RolloverEffectsWork` | net-new durable canonical rollover | all exact old/new effects acknowledged | V09,V21,V22,V29 |
| `EpochSampleWork` | replaces legacy retry/fallback after activation | accepted or terminal disposition | V19,V20,V30,V32 |

The iOS report reproduces the rows and records the post-edit rulebook hash.

**GREEN:** Re-run RED and existing vector coverage:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
shasum -a 256 /Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/verify_metering_phase3_r16.py
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' test
```

Expected GREEN: every exact Phase 3 row and all four cells match, and the exact
pre-existing T1-T11 rows are unchanged.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'docs/superpowers/reports/2026-07-17-metering-phase3-r16-registration.md' 'scripts/verify_metering_phase3_r16.py'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
test "$(git diff --cached --name-only | wc -l | tr -d ' ')" -eq 2
git commit -m 'test: register phase 3 metering safety states'
```

## Task 2: Add Shared Clock And Value-Compatible Center Injection

**Repository:** iOS.

**Interfaces:** Produces `SystemMeteringClock`, DEBUG-only `DebugAppGroupMeteringClock`, `MeteringRuntimeClock.live(defaults:)`, `MeteringDeviceActivityCenter`, and `SystemMeteringDeviceActivityCenter`. App and DAM receive the center source; Push receives only the clock source.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringRuntimeInfrastructure.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringDeviceActivityCenter.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringRuntimeInfrastructureTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** A struct fake conforms to the center protocol, fixed clocks return one date, source membership includes app/DAM but excludes Push for the center, and source inspection requires the preference key inside `#if DEBUG`.

```swift
@MainActor
private struct FakeCenter: MeteringDeviceActivityCenter {
    var activities: [DeviceActivityName] = []
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { nil }
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] { [:] }
    func startMonitoring(_ activity: DeviceActivityName, during schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent]) throws {}
    func stopMonitoring(_ activities: [DeviceActivityName]) {}
}
```

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringRuntimeInfrastructureTests' -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests' test
```

Expected RED: compile errors name `MeteringDeviceActivityCenter`, `SystemMeteringClock`, and `MeteringRuntimeClock`.

**Minimal GREEN:** Implement the pinned center interface and this clock code exactly:

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
              let date = ISO8601DateFormatter().date(from: raw)
        else { return fallback.now }
        return date
    }
}
#endif

nonisolated enum MeteringRuntimeClock {
    static func live(defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios")) -> any MeteringClock {
#if DEBUG
        return DebugAppGroupMeteringClock(defaults: defaults, fallback: SystemMeteringClock())
#else
        return SystemMeteringClock()
#endif
    }
}

nonisolated enum MeteringOwnerMirror {
    static let suiteName = "group.com.evlin.ios"
    static let ownerKey = "evlin.childId"

    static func current() -> UUID? {
        UserDefaults(suiteName: suiteName)?
            .string(forKey: ownerKey)
            .flatMap(UUID.init(uuidString:))
    }
}
```

Add `Services/MeteringRuntimeInfrastructure.swift` to DAM and Push membership exceptions and `Services/MeteringDeviceActivityCenter.swift` only to DAM. The target test parses `project.pbxproj` and asserts exact positive/negative membership.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringRuntimeInfrastructureTests' -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -configuration Debug -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' CODE_SIGNING_ALLOWED=NO build
```

Expected GREEN: struct conformance passes, all app dependencies build, and Push has no center membership. Release binary exclusion is proved nonvacuously in Task 29 after Release products exist.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/MeteringRuntimeInfrastructure.swift' 'Evlin iOS/Services/MeteringDeviceActivityCenter.swift' 'Evlin iOSTests/MeteringRuntimeInfrastructureTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: inject shared metering runtime dependencies'
```

## Task 3: Add Conservative Backend Registration And Activation

**Repository:** Backend.

**Interfaces:** Consumes current `POST /child/earned-time/epochs`, `EpochRegistrationRequest`, `DeviceDaySnapshot`, `usage_counting_allowed`, `EarnedTimeMeteringEpoch`, and Phase 2's opaque server-clock-issued canonical context. Produces additive `gate_resume_conservative`, `epoch_status`, activation DTOs/route/service, `activation_route_id`, and `activated_at`. Registration no longer ratchets; activation does only after the iOS production path has durably entered `dualActive`. No service accepts a caller-selected time/date/timezone authority.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/schemas/earned_time.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_epoch_contract.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_epoch_registry.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/earned_time.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/db/models/earned_time.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/alembic/versions/2026_07_17_meter_epoch_cons.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_models.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_registration.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_sample_adapter.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_phase2_integration.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_lifespan.py`

**TDD RED:** Add DB tests for all of these observable failures:

1. Registration 200 currently omits `epoch_status` and ratchets `Device.metering_protocol_version` to 2.
2. `gate_resume_conservative` currently fails Pydantic validation.
3. A `usage_counting_allowed` sequence `true,false` currently cannot return a newly registered paused epoch.
4. Activation route currently returns 404.
5. Paused-then-open sample currently returns `gate_resume_rebase_required`.
6. A gate-close activation race must return paused and preserve the ratchet at 1.
7. Direct activation exposes no `now_utc`, canonical-date, or timezone override;
   tests pin the production `screen_time_clock.now_utc` seam and assert exactly
   one capture.
8. Before activation, one v1 and one v2 sample covering the same cumulative
   minutes converge by monotonic max rather than addition. After the activation
   commit, v2 remains countable and v1 is terminal `legacy_after_v2` even when
   the activation response is treated as lost.
9. Between the unlocked scope observation and device row lock, reassign the
   device to another family/profile (and separately change it out of child
   mode). Activation must return `409 device_identity_changed` (or the existing
   child-not-found contract for non-child mode), leave both protocol ratchets
   unchanged, and create no epoch, sample, ledger, command, receipt, or APNs
   effect.
10. Seed an already-stale epoch family/profile/device scope, then separately
    supersede the active config/cap or change the selected enforcement set after
    registration but before activation. Each activation returns a stable 409,
    preserves protocol 1, and has zero sample/ledger/command/receipt/APNs effect.
    A future/naive `verified_at` is also rejected without mutation.
11. Commit activation, treat the response as lost, then independently close the
    gate, exhaust the epoch through a valid v2 sample, change current policy, and
    change the selected enforcement set before retrying the identical route.
    Every retry returns `already_activated`, protocol 2, the current snapshot and
    current mutable epoch status, with no second mutation. A different route or
    a retired/replaced epoch still returns the stable conflict.
12. Register a conservative/base-correction epoch with
    `base_accepted_minutes = 17`. Post a route-valid sample whose raw event
    threshold would fail a base-zero elapsed check but whose adjusted cumulative
    estimate advances only five physically possible minutes. It must count.
    Backend physical trust is evaluated exactly once against
    `epoch.base_accepted_minutes`; route namespace/threshold-name validation is
    separate and cannot reintroduce a base-zero elapsed test.

```python
ROUTE_ID = UUID("70000000-0000-0000-0000-000000000030")

async def _post_activation(client, scope, epoch_id: UUID, route_id: UUID):
    return await client.post(
        f"/child/earned-time/epochs/{epoch_id}/activation",
        json={
            "protocol_version": 2,
            "device_id": str(scope.device.id),
            "route_id": str(route_id),
            "verified_at": NOW_UTC.isoformat().replace("+00:00", "Z"),
        },
        headers={"X-Evlin-Child-Device-ID": str(scope.device.id)},
    )

async def test_registration_does_not_ratchet_until_verified_route_activation(client, session, monkeypatch):
    scope = await _seed_scope(session, metering_protocol_version=1)
    _configure_registry(monkeypatch, advertised_version=2)
    registered = await _post_registration(client, scope, _request_body(scope))
    await session.refresh(scope.device)
    assert registered.status_code == 200
    assert registered.json()["epoch_status"] == "active"
    assert scope.device.metering_protocol_version == 1

    activated = await _post_activation(client, scope, EPOCH_ID, ROUTE_ID)
    await session.refresh(scope.device)
    assert activated.json()["status"] == "activated"
    assert activated.json()["epoch_status"] == "active"
    assert scope.device.metering_protocol_version == 2
```

Run every DB test through the disposable runner:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_epoch_models.py tests/test_metering_epoch_registration.py tests/test_metering_epoch_sample_adapter.py tests/test_metering_epoch_phase2_integration.py tests/test_metering_epoch_lifespan.py
```

Expected RED: schema rejects `gate_resume_conservative`, registration lacks `epoch_status`, and activation is 404.

**Minimal GREEN:** Add exact DTOs without removing existing fields or enum values:

```python
EpochStatus = Literal["active", "paused", "exhausted", "retired"]

class EpochRegistrationReason(str, Enum):
    initial = "initial"
    day_rollover = "day_rollover"
    policy_change = "policy_change"
    selection_change = "selection_change"
    enforcement_set_change = "enforcement_set_change"
    identity_recovery = "identity_recovery"
    gate_resume_exact_rebase = "gate_resume_exact_rebase"
    gate_resume_conservative = "gate_resume_conservative"

class EpochRegistrationResponse(BaseModel):
    status: Literal["registered", "already_registered"]
    epoch_id: UUID
    metering_protocol_version: Literal[2]
    snapshot: DeviceDaySnapshot
    epoch_status: EpochStatus | None = None

class EpochActivationRequest(BaseModel):
    protocol_version: Literal[2]
    device_id: UUID
    route_id: UUID
    verified_at: datetime

class EpochActivationResponse(BaseModel):
    status: Literal["activated", "already_activated", "paused"]
    epoch_id: UUID
    epoch_status: EpochStatus
    metering_protocol_version: Literal[1, 2]
    snapshot: DeviceDaySnapshot
```

Add `GATE_RESUME_CONSERVATIVE` to `EpochReplacementReason` and `ExplicitRecovery`, map it in `_explicit_recovery`, and keep `GATE_RESUME_EXACT_REBASE`. Migration revision is exactly `2026_07_17_meter_epoch_cons` (within the repository's 32-character `alembic_version.version_num` limit), down revision `2026_07_16_meter_epoch_v2`; it replaces the replacement-reason check constraint and adds nullable UUID `activation_route_id` plus nullable timezone-aware `activated_at`.

Implement registration and activation with these exact service signatures:

```python
@dataclass(frozen=True)
class EpochActivationResult:
    status: Literal["activated", "already_activated", "paused"]
    epoch: EarnedTimeMeteringEpoch
    snapshot: DeviceDaySnapshot
    metering_protocol_version: Literal[1, 2]

async def activate_metering_epoch(
    session: AsyncSession,
    store: BigKidStore,
    *,
    child_device: Device,
    epoch_id: UUID,
    request: EpochActivationRequest,
) -> EpochActivationResult:
    # Mirror registration's observe -> advisory-profile -> device row ->
    # revalidate protocol before loading locked canonical authority.
    observed_scope = (await session.execute(
        select(Device.family_id, Device.child_profile_id, Device.mode).where(
            Device.id == child_device.id
        )
    )).one_or_none()
    if observed_scope is None or observed_scope.mode != DeviceMode.child:
        raise HTTPException(status_code=404, detail="child device not found")
    if observed_scope.child_profile_id is None:
        raise HTTPException(status_code=422, detail="device_missing_child_profile_id")
    await acquire_earned_profile_lock(
        session,
        family_id=observed_scope.family_id,
        child_profile_id=observed_scope.child_profile_id,
    )
    device = (await session.execute(
        select(Device)
        .where(Device.id == child_device.id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if device is None or device.mode != DeviceMode.child:
        raise HTTPException(status_code=404, detail="child device not found")
    if device.child_profile_id is None:
        raise HTTPException(status_code=422, detail="device_missing_child_profile_id")
    if (
        device.family_id != observed_scope.family_id
        or device.child_profile_id != observed_scope.child_profile_id
    ):
        raise HTTPException(status_code=409, detail="device_identity_changed")
    canonical_context = await load_sample_canonical_context(
        session,
        family_id=device.family_id,
        child_profile_id=device.child_profile_id,
    )
    captured_now = canonical_context.now_utc
    epoch = (await session.execute(
        select(EarnedTimeMeteringEpoch)
        .where(EarnedTimeMeteringEpoch.id == epoch_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if (
        epoch is None
        or epoch.family_id != device.family_id
        or epoch.child_profile_id != device.child_profile_id
        or epoch.child_device_id != device.id
        or epoch.protocol_version != 2
        or epoch.retired_at is not None
    ):
        raise HTTPException(status_code=409, detail="activation_epoch_not_current")
    if epoch.activation_route_id is not None and epoch.activation_route_id != request.route_id:
        raise HTTPException(status_code=409, detail="activation_route_mismatch")
    if epoch.activation_route_id == request.route_id and epoch.activated_at is not None:
        # The activation transaction already ratcheted protocol 2. Mutable gate,
        # policy, enforcement, date, or exhausted status cannot make its lost
        # response replay fail; replacement retirement still can.
        snapshot = await _current_snapshot(
            session,
            device=device,
            usage_date=canonical_context.usage_date,
        )
        return EpochActivationResult("already_activated", epoch, snapshot, 2)
    if epoch.usage_date != canonical_context.usage_date:
        raise HTTPException(status_code=409, detail="activation_epoch_not_current")
    runtime = await current_metering_runtime_snapshot(
        session,
        family_id=device.family_id,
        child_profile_id=device.child_profile_id,
        child_device_id=device.id,
        canonical_context=canonical_context,
    )
    if (
        epoch.canonical_timezone != runtime.timezone
        or epoch.policy_revision != runtime.revision
    ):
        raise HTTPException(status_code=409, detail="activation_policy_not_current")
    selected_set = await load_selected_set(
        session,
        family_id=device.family_id,
        child_device_id=device.id,
    )
    enforcement_set = await session.get(ChildCatalogList, epoch.enforcement_set_id)
    if (
        selected_set is None
        or selected_set.list_id != epoch.enforcement_set_id
        or enforcement_set is None
        or enforcement_set.family_id != device.family_id
        or enforcement_set.child_device_id != device.id
        or enforcement_set.status.lower() != "active"
    ):
        raise HTTPException(status_code=409, detail="activation_enforcement_set_not_current")
    if request.verified_at.tzinfo is None or request.verified_at.utcoffset() is None:
        raise HTTPException(status_code=409, detail="activation_verified_at_invalid")
    verified_at = request.verified_at.astimezone(timezone.utc)
    if verified_at > captured_now:
        raise HTTPException(status_code=409, detail="activation_verified_at_invalid")
    gate_open = await usage_counting_allowed(session, store, device.id)
    snapshot = await _current_snapshot(session, device=device, usage_date=epoch.usage_date)
    if not gate_open:
        epoch.status = "paused"
        await session.flush()
        return EpochActivationResult("paused", epoch, snapshot, device.metering_protocol_version)
    if epoch.status != "active":
        raise HTTPException(status_code=409, detail="activation_epoch_not_current")
    epoch.activation_route_id = request.route_id
    epoch.activated_at = captured_now
    device.metering_protocol_version = 2
    await session.flush()
    return EpochActivationResult("activated", epoch, snapshot, 2)
```

Registration calls `usage_counting_allowed` immediately before final epoch status/return, sets `result.epoch.status` from that final value, always returns it as `epoch_status`, and removes the current registration-time ratchet assignment. `gate_resume_conservative` requires a paused predecessor but accepts a final closed gate as a paused HTTP 200. The sample route emits `gate_resume_conservative_required` for paused plus open. Activation mirrors production registration's unlocked scope observation, profile advisory lock, device row lock, and family/profile/mode revalidation before loading issuer-only canonical authority. It then verifies immutable epoch family/profile/device/protocol/not-retired scope and exact route ownership. A same-route row with non-null `activated_at` returns `already_activated` immediately with protocol 2 and current snapshot/status; mutable date, policy, enforcement, gate, or exhausted drift cannot invalidate a transaction whose response was lost. Only a first activation continues through current date/timezone, policy revision, selected active enforcement set, verification timestamp, gate, and active-status checks before ratcheting. Tests force reassignment between observation and row lock, already-stale epoch scope, post-registration policy/enforcement changes before first activation, future verification time, and all four mutable-drift cases after committed activation. A test-only future instant is supplied only by monkeypatching the production clock seam, never through a service argument.

For protocol-2 sample ingest, retain route/activity/event namespace consistency but remove the separate `physical_threshold_is_trustworthy(base_accepted_minutes=0, adjusted_estimate_minutes=body.threshold_minutes, ...)` call. The sole physical check is `physical_threshold_is_trustworthy(base_accepted_minutes=epoch.base_accepted_minutes, adjusted_estimate_minutes=body.estimated_minutes, ...)`. Raw route thresholds may legitimately begin above zero after conservative resume or authoritative-base correction; trusting them as cumulative usage from zero would reject valid work. A negative adjusted delta still fails, and event threshold/name mismatch remains independently terminal.

Add route `POST /child/earned-time/epochs/{epoch_id}/activation`, validate header/body/path ownership, call `activate_metering_epoch`, commit, and return the exact response.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python -m pytest -q tests/test_metering_epoch_vector_contract.py
.venv/bin/python scripts/run_limits_db_regression.py tests/test_target_gate_resume_helpers.py
.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_epoch_models.py tests/test_metering_epoch_registration.py tests/test_metering_epoch_sample_adapter.py tests/test_metering_epoch_phase2_integration.py tests/test_metering_epoch_lifespan.py
```

Expected GREEN: migration upgrade/downgrade checks pass; registration leaves v1; gate-close races return paused; only first active activation ratchets; same-route committed replay survives mutable drift; nonzero-base adjusted samples count without a base-zero raw-threshold veto; exact-rebase remains accepted; the new warning is emitted.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py
```

Expected full GREEN: the complete disposable-database regression set passes without skips.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
git add app/schemas/earned_time.py app/services/metering_epoch_contract.py app/services/metering_epoch_registry.py app/api/routes/earned_time.py app/db/models/earned_time.py alembic/versions/2026_07_17_meter_epoch_cons.py tests/test_metering_epoch_models.py tests/test_metering_epoch_registration.py tests/test_metering_epoch_sample_adapter.py tests/test_metering_epoch_phase2_integration.py tests/test_metering_epoch_lifespan.py
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
IOS_TASK2_SHA="$(git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS log --format='%H%x09%s' "$(cat /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/.superpowers/evidence/metering-phase3/ios-base-sha.txt)..HEAD" | awk -F '\t' '$2 == "feat: inject shared metering runtime dependencies" { print $1 }')"
test "$(printf '%s\n' "$IOS_TASK2_SHA" | rg -c '^[0-9a-f]{40}$')" -eq 1
git commit -m 'feat: add conservative epoch activation protocol' -m "Phase3-Depends-On: $IOS_TASK2_SHA"
```

## Task 4: Add Exact Swift Wire DTOs

**Repository:** iOS.

**Interfaces:** Consumes Task 3 response shapes and current `/child/state`. Produces Apple DTO, v1/v2 sample, registration, activation, conflict, snapshot, and child-state DTOs plus exact URLRequest builders. `APIClient.swift` is not consumed or modified.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochWire.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/BigKid/BigKidModels.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochWireTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Encode metadata-free v1, metadata-bearing v1, v2, registration, and activation requests; decode active/paused registration, base 409, activation, sample, and child state. Assert exact key sets, headers, paths, aliases, and that partial v1 metadata and mixed v1/v2 metadata have no lane.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochWireTests' test
```

Expected RED: compile errors name `EpochRegistrationRequestDTO`, `EpochActivationRequestDTO`, and `EpochSampleRequestDTO`.

**Minimal GREEN:** Implement these exact declarations and explicit coding keys:

```swift
nonisolated struct MeteringAppleCallback: Codable, Equatable, Sendable {
    let activityName: String
    let eventName: String
    let observedAt: Date
}

nonisolated enum EpochRegistrationReasonDTO: String, Codable, Sendable {
    case initial
    case dayRollover = "day_rollover"
    case policyChange = "policy_change"
    case selectionChange = "selection_change"
    case enforcementSetChange = "enforcement_set_change"
    case identityRecovery = "identity_recovery"
    case gateResumeExactRebase = "gate_resume_exact_rebase"
    case gateResumeConservative = "gate_resume_conservative"
}

nonisolated enum EpochStatusDTO: String, Codable, Sendable { case active, paused, exhausted, retired }
nonisolated enum EpochRegistrationStatusDTO: String, Codable, Sendable { case registered, alreadyRegistered = "already_registered" }
nonisolated enum EpochActivationStatusDTO: String, Codable, Sendable { case activated, alreadyActivated = "already_activated", paused }
nonisolated enum MeteringSampleLane: String, Codable, Sendable { case v1, v2 }

nonisolated enum MeteringSampleWireAliases {
    static func activityName(routeID: UUID) -> String {
        "evlin.earned.budget.\(routeID.uuidString.lowercased())"
    }

    static func eventName(thresholdMinutes: Int) -> String {
        "evlin.earned.t\(thresholdMinutes)"
    }

    static func clientSampleID(
        lane: MeteringSampleLane,
        routeID: UUID,
        thresholdMinutes: Int
    ) -> String {
        "earned:\(lane.rawValue):\(routeID.uuidString.lowercased()):t\(thresholdMinutes)"
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
        case childDeviceID = "child_device_id", usageDate = "usage_date"
        case estimatedMinutes = "estimated_minutes", capMinutes = "cap_minutes"
        case childDayState = "child_day_state", usedMinutes = "used_minutes"
        case remainingMinutes = "remaining_minutes", counted, warning
    }
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
        case protocolVersion = "protocol_version", epochID = "epoch_id"
        case deviceID = "device_id", usageDate = "usage_date", timezone
        case policyRevision = "policy_revision"
        case measurementSelectionDigest = "measurement_selection_digest"
        case enforcementSetID = "enforcement_set_id", startedAt = "started_at"
        case baseAcceptedMinutes = "base_accepted_minutes", reason
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
        case deviceID = "device_id", usageDate = "usage_date", timezone
        case activityName = "activity_name", eventName = "event_name"
        case thresholdMinutes = "threshold_minutes", estimatedMinutes = "estimated_minutes"
        case observedAt = "observed_at", clientSampleID = "client_sample_id"
        case protocolVersion = "protocol_version", epochID = "epoch_id"
        case generationArmedAt = "generation_armed_at", generationOffsetMinutes = "generation_offset_minutes"
    }

    var lane: MeteringSampleLane? {
        let v2 = protocolVersion == 2 && epochID != nil && generationArmedAt == nil && generationOffsetMinutes == nil
        let v1MetadataValid = (generationArmedAt == nil && generationOffsetMinutes == nil) || (generationArmedAt != nil && generationOffsetMinutes != nil)
        let v1 = protocolVersion == nil && epochID == nil && v1MetadataValid
        return v2 ? .v2 : (v1 ? .v1 : nil)
    }
}

nonisolated struct EpochActivationRequestDTO: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let deviceID: UUID
    let routeID: UUID
    let verifiedAt: Date
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", deviceID = "device_id"
        case routeID = "route_id", verifiedAt = "verified_at"
    }
}

nonisolated struct EpochRegistrationConflictDTO: Codable, Equatable, Sendable {
    let code: EpochRegistrationConflictCodeDTO
    let authoritativeSnapshot: DeviceDaySnapshotDTO
    enum CodingKeys: String, CodingKey {
        case code, authoritativeSnapshot = "authoritative_snapshot"
    }
}

nonisolated enum EpochRegistrationConflictCodeDTO: String, Codable, Sendable {
    case authoritativeBaseMismatch = "authoritative_base_mismatch"
}

nonisolated struct EpochRegistrationResponseDTO: Codable, Equatable, Sendable {
    let status: EpochRegistrationStatusDTO
    let epochID: UUID
    let meteringProtocolVersion: Int
    let snapshot: DeviceDaySnapshotDTO
    let epochStatus: EpochStatusDTO?
    enum CodingKeys: String, CodingKey {
        case status, snapshot, epochID = "epoch_id"
        case meteringProtocolVersion = "metering_protocol_version"
        case epochStatus = "epoch_status"
    }
}

nonisolated struct EpochActivationResponseDTO: Codable, Equatable, Sendable {
    let status: EpochActivationStatusDTO
    let epochID: UUID
    let epochStatus: EpochStatusDTO
    let meteringProtocolVersion: Int
    let snapshot: DeviceDaySnapshotDTO
    enum CodingKeys: String, CodingKey {
        case status, snapshot, epochID = "epoch_id", epochStatus = "epoch_status"
        case meteringProtocolVersion = "metering_protocol_version"
    }
}
```

Request builders are:

```swift
nonisolated enum MeteringEpochRequests {
    static func childState(baseURL: URL, ownerChildDeviceID: UUID) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("child/state"))
        request.httpMethod = "GET"
        request.setValue(ownerChildDeviceID.uuidString.lowercased(), forHTTPHeaderField: "X-Child-Id")
        return request
    }
    static func registration(baseURL: URL, ownerChildDeviceID: UUID, body: EpochRegistrationRequestDTO) throws -> URLRequest {
        try post(baseURL.appendingPathComponent("child/earned-time/epochs"), owner: ownerChildDeviceID, body: body)
    }
    static func activation(baseURL: URL, ownerChildDeviceID: UUID, epochID: UUID, body: EpochActivationRequestDTO) throws -> URLRequest {
        try post(baseURL.appendingPathComponent("child/earned-time/epochs/\(epochID.uuidString.lowercased())/activation"), owner: ownerChildDeviceID, body: body)
    }
    static func sample(baseURL: URL, ownerChildDeviceID: UUID, body: EpochSampleRequestDTO) throws -> URLRequest {
        try post(baseURL.appendingPathComponent("child/earned-time/sample"), owner: ownerChildDeviceID, body: body)
    }
    private static func post<Body: Encodable>(_ url: URL, owner: UUID, body: Body) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(owner.uuidString.lowercased(), forHTTPHeaderField: "X-Evlin-Child-Device-ID")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }
}
```

Add `meteringProtocolVersion: Int` (default 1 in the existing `ChildStateResponse` initializer) and `policyRevision: String` to `EarnedTimeRuntime`. Update every `EarnedTimeRuntime` initializer call in `BigKidStatePollerTests.swift` with an explicit revision. Because a synthesized nonoptional decode does not honor an initializer default, implement this exact backward-compatible decoder inside `ChildStateResponse` while retaining synthesized `encode(to:)`:

```swift
private enum CodingKeys: String, CodingKey {
    case meteringProtocolVersion, childName, minutesLeft, minutesMax, tasks
    case reflectionRequest, notifyParentCooldownEndsAt
    case dailyCompleteAcknowledged, screenTimeFinishedAcknowledged
    case lastResolvedReflection, usageCountingAllowed, earnedTimeRuntime
}

init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    meteringProtocolVersion = try values.decodeIfPresent(Int.self, forKey: .meteringProtocolVersion) ?? 1
    childName = try values.decode(String.self, forKey: .childName)
    minutesLeft = try values.decode(Int.self, forKey: .minutesLeft)
    minutesMax = try values.decode(Int.self, forKey: .minutesMax)
    tasks = try values.decode([BigKidTask].self, forKey: .tasks)
    reflectionRequest = try values.decodeIfPresent(ReflectionRequest.self, forKey: .reflectionRequest)
    notifyParentCooldownEndsAt = try values.decodeIfPresent(Date.self, forKey: .notifyParentCooldownEndsAt)
    dailyCompleteAcknowledged = try values.decode(Bool.self, forKey: .dailyCompleteAcknowledged)
    screenTimeFinishedAcknowledged = try values.decode(Bool.self, forKey: .screenTimeFinishedAcknowledged)
    lastResolvedReflection = try values.decodeIfPresent(ResolvedReflection.self, forKey: .lastResolvedReflection)
    usageCountingAllowed = try values.decodeIfPresent(Bool.self, forKey: .usageCountingAllowed)
    earnedTimeRuntime = try values.decodeIfPresent(EarnedTimeRuntime.self, forKey: .earnedTimeRuntime)
}
```

Both production fields use the existing `.convertFromSnakeCase` decoder. Add `MeteringEpochWire.swift` to DAM and Push membership.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochWireTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' test
```

Expected GREEN: literal JSON matches Task 3, absent child advertisement maps to 1, absent registration status decodes but cannot activate, and Apple DTO encodes only three fields.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/MeteringEpochWire.swift' 'Evlin iOS/Models/BigKid/BigKidModels.swift' 'Evlin iOSTests/MeteringEpochWireTests.swift' 'Evlin iOSTests/BigKidStatePollerTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
test -z "$(git diff --cached --name-only | rg '^Evlin iOS/Services/APIClient.swift$' || true)"
BACKEND_TASK3_SHA="$(git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend log --format='%H%x09%s' "$(cat .superpowers/evidence/metering-phase3/backend-base-sha.txt)..HEAD" | awk -F '\t' '$2 == "feat: add conservative epoch activation protocol" { print $1 }')"
test "$(printf '%s\n' "$BACKEND_TASK3_SHA" | rg -c '^[0-9a-f]{40}$')" -eq 1
git commit -m 'feat: add exact metering epoch wire DTOs' -m "Phase3-Depends-On: $BACKEND_TASK3_SHA"
```

---

## Task 5: Add The Versioned Atomic Device Epoch Store

**Repository:** iOS.

**Interfaces:** Consumes `ActiveLockPersistenceLock.shared`, the mirrored owner key `evlin.childId`, `MeteringGenerationKey`, exact persisted selection bytes, Task 4 DTOs, and the shared clock. Produces the only App Group metering root and transaction, including the exact v2-to-v2 handoff envelope. No consumer may persist a second generation, epoch, route, handoff, queue, claim, shield-reference, cleanup, rollover, coverage, or ratchet authority.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/DeviceEpochStoreTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/DeviceEpochStoreMigrationTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**Persisted schema:** Implement these declarations in `DeviceEpochStore.swift`; all dates use ISO-8601 through one sorted-key encoder and decoder.

```swift
import Foundation

nonisolated enum MeteringWorkTerminal: String, Codable, Sendable {
    case pending, succeeded, superseded, rejected, abandoned
}

nonisolated struct MeteringRetryState: Codable, Equatable, Sendable {
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastErrorCode: String?
    var terminal: MeteringWorkTerminal
}

nonisolated enum MeteringRetryPolicy {
    static let delays: [TimeInterval] = [0, 5, 15, 60, 300]
    static func nextAttempt(after failureCount: Int, now: Date) -> Date {
        let index = min(max(failureCount, 1), delays.count - 1)
        return now.addingTimeInterval(delays[index])
    }
}

nonisolated struct MeteringPolicyGeneration: Codable, Equatable, Sendable {
    let generationID: UUID
    let protocolVersion: Int
    let childDeviceID: UUID
    let canonicalTimezone: String
    let policyRevision: String
    let measurementSelectionDigest: String
    let enforcementSetID: UUID
    let measurementSelectionBytes: Data
    let createdAt: Date
    var retiredAt: Date?
}

nonisolated enum DeviceDailyEpochStatus: String, Codable, Sendable {
    case active, paused, exhausted, retired
}

nonisolated enum MeteringEpochBaseSource: String, Codable, Sendable {
    case childState200, registration200, registrationConflict409
}

nonisolated enum BaseCorrectionState: String, Codable, Sendable {
    case available, used
}

nonisolated enum MeteringEpochRetireReason: String, Codable, Sendable {
    case dayRollover, policyChange, selectionChange, enforcementSetChange
    case identityRecovery, gateResumeConservative, authoritativeBaseMismatch
    case coverageExpired, activationSuperseded
}

nonisolated struct DeviceDailyEpoch: Codable, Equatable, Sendable {
    let epochID: UUID
    let protocolVersion: Int
    let childDeviceID: UUID
    let usageDate: String
    let canonicalTimezone: String
    let policyRevision: String
    let measurementSelectionDigest: String
    let enforcementSetID: UUID
    let startedAt: Date
    var registeredAt: Date?
    let baseAcceptedMinutes: Int
    let baseSource: MeteringEpochBaseSource
    var lastRawThresholdMinutes: Int
    var excludedWhilePausedMinutes: Int
    var status: DeviceDailyEpochStatus
    var resumeBoundaryPending: Bool
    var retiredAt: Date?
    var retireReason: MeteringEpochRetireReason?
    var exhaustedAt: Date?
    var baseCorrectionState: BaseCorrectionState
}

nonisolated struct DatedSchedulePlan: Codable, Equatable, Sendable {
    let usageDate: String
    let timezoneIdentifier: String
    let calendarIdentifier: String
}

nonisolated struct MeteringEventPlan: Codable, Equatable, Sendable {
    let eventName: String
    let thresholdMinutes: Int
}

nonisolated enum MeteringRouteLifecycle: String, Codable, Sendable {
    case planned, active, retired, tombstoned
}

nonisolated struct MeteringCallbackRoute: Codable, Equatable, Sendable {
    let routeID: UUID
    let activityName: String
    let namespace: String
    let generationID: UUID
    let generationKey: MeteringGenerationKey
    let ownerChildDeviceID: UUID
    let usageDate: String
    let epochID: UUID
    let plannedSchedule: DatedSchedulePlan
    var installedSchedule: DatedSchedulePlan?
    let plannedEvents: [MeteringEventPlan]
    var installedEvents: [MeteringEventPlan]?
    var lifecycle: MeteringRouteLifecycle
    let createdAt: Date
}

nonisolated struct MeteringRouteTombstone: Codable, Equatable, Sendable {
    let routeID: UUID
    let activityName: String
    let eventNames: [String]
    let ownerChildDeviceID: UUID
    let usageDate: String
    let epochID: UUID
    let generationID: UUID
    let canonicalDayEnd: Date
    var stopAcknowledgedAt: Date?
    var referencedWorkIDs: Set<UUID>
    var retainedUntil: Date?
}

nonisolated enum MeteringInstallAuthorization: String, Codable, Sendable {
    case registrationRequired, registered, futurePlanned, offlinePending
}

nonisolated enum ActivityInstallPhase: String, Codable, Sendable {
    case pendingStart, starting, installed, verified, dualActive
    case active, pendingStop, stopped
}

nonisolated struct ActivityInstallClaim: Codable, Equatable, Sendable {
    let token: UUID
    let process: MeteringProcessRole
    let instanceID: UUID
    let claimedAt: Date
    let expiresAt: Date
}

nonisolated struct ActivityInstallWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let routeID: UUID
    var authorization: MeteringInstallAuthorization
    var phase: ActivityInstallPhase
    var claim: ActivityInstallClaim?
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated struct EpochRegistrationWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let epochID: UUID
    let routeID: UUID
    let request: EpochRegistrationRequestDTO
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated struct EpochActivationWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let epochID: UUID
    let routeID: UUID
    let request: EpochActivationRequestDTO
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated enum EpochSampleAuthorization: String, Codable, Sendable {
    case legacyDeliverable, waitingForRegistration, v2Deliverable
}

nonisolated struct EpochSampleWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let epochID: UUID?
    let routeID: UUID?
    let request: EpochSampleRequestDTO
    var authorization: EpochSampleAuthorization
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated enum LegacyCompatibilityPhase: String, Codable, Sendable {
    case activeV1, dualLanePreparingV2, retiringV1, stoppedV1
}

nonisolated struct LegacyGenerationProvenance: Codable, Equatable, Sendable {
    let activityName: String
    let deviceID: String
    let offsetMinutes: Int
    let armSignature: String
    let usageDate: String
    let timezoneIdentifier: String
    let armedAt: Date?
}

nonisolated struct LegacyCompatibilityMonitorState: Codable, Equatable, Sendable {
    let ownerChildDeviceID: UUID
    let lifecycleVersion: Int
    var active: LegacyGenerationProvenance?
    var pending: LegacyGenerationProvenance?
    var retiringActivityNames: [String]
    var breadcrumbActivityNames: [String]
    var scalarActiveActivityName: String?
    var isStopped: Bool
    var phase: LegacyCompatibilityPhase
    var stopAcknowledgedAt: Date?
}

nonisolated enum MonitorCoverageStatus: String, Codable, Sendable {
    case ready, installLimited, coverageExhausted
}

nonisolated struct MonitorCoverageState: Codable, Equatable, Sendable {
    let ownerChildDeviceID: UUID
    let requiredFromUsageDate: String
    let requiredThroughUsageDate: String
    var readyThroughUsageDate: String?
    var status: MonitorCoverageStatus
    var refreshedAt: Date
    var errorCode: String?
}

nonisolated struct EarnedShieldReference: Codable, Equatable, Sendable {
    let operationID: UUID
    let ownerChildDeviceID: UUID
    let generationID: UUID
    let epochID: UUID
    let routeID: UUID
    let recordKey: String
    let expectedRecordBytes: Data
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated struct IdentityCleanupWork: Codable, Equatable, Sendable {
    let workID: UUID
    let oldOwnerChildDeviceID: UUID
    let newOwnerChildDeviceID: UUID?
    let oldEpochIDs: [UUID]
    let oldRouteIDs: [UUID]
    let oldActivityNames: [String]
    let oldRegistrationWorkIDs: [UUID]
    let oldActivationWorkIDs: [UUID]
    let oldSampleWorkIDs: [UUID]
    let oldInstallWorkIDs: [UUID]
    let oldFallbackKeys: [String]
    let oldShieldOperationIDs: [UUID]
    let oldUsageDates: [String]
    var retry: MeteringRetryState
    var terminalizedWorkIDs: Set<UUID>
    var purgedFallbackKeys: Set<String>
    var releasedShieldOperationIDs: Set<UUID>
    var stopAcknowledgedActivityNames: Set<String>
    var clearedUsageDates: Set<String>
    var ownerMirrorTransitionAcknowledged: Bool
    let createdAt: Date
}

nonisolated struct RolloverEffectsWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let fromUsageDate: String
    let toUsageDate: String
    let oldEpochID: UUID
    let newEpochID: UUID
    let oldRouteID: UUID
    let newRouteID: UUID
    var retry: MeteringRetryState
    var earnedSourceResetAcknowledged: Bool
    var perAppResetAcknowledged: Bool
    var taskStateResetAcknowledged: Bool
    var bypassExpiryAcknowledged: Bool
    var registrationAcknowledged: Bool
    var installAcknowledged: Bool
    var activationAcknowledged: Bool
    var oldStopAcknowledged: Bool
    let createdAt: Date
}

nonisolated enum MeteringLocalProtocolSelection: String, Codable, Sendable {
    case v1, dualActive, v2
}

nonisolated enum V2RouteHandoffPhase: String, Codable, Sendable {
    case preparing, dualV2, cutoverReady, committed
}

nonisolated struct V2RouteHandoff: Codable, Equatable, Sendable {
    let handoffID: UUID
    let ownerChildDeviceID: UUID
    let fromGenerationID: UUID
    let fromEpochID: UUID
    let fromRouteID: UUID
    let toGenerationID: UUID
    let toEpochID: UUID
    let toRouteID: UUID
    var phase: V2RouteHandoffPhase
    var priorRouteInputClosedAt: Date?
    var registrationAcknowledgedAt: Date?
    var activationAcknowledgedAt: Date?
    var priorStopAcknowledgedAt: Date?
    let createdAt: Date
}

nonisolated struct MeteringOwnerRatchet: Codable, Equatable, Sendable {
    let ownerChildDeviceID: UUID
    var advertisedVersion: Int
    var localSelection: MeteringLocalProtocolSelection
    var registeredV2At: Date?
    var dualActiveAt: Date?
    var activatedV2At: Date?
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
    var activeRouteID: UUID?
    var tombstones: [UUID: MeteringRouteTombstone]
    var v2RouteHandoff: V2RouteHandoff?
    var legacy: LegacyCompatibilityMonitorState?
    var registrationWork: [UUID: EpochRegistrationWork]
    var activationWork: [UUID: EpochActivationWork]
    var sampleWork: [UUID: EpochSampleWork]
    var installWork: [UUID: ActivityInstallWork]
    var shieldReferences: [UUID: EarnedShieldReference]
    var identityCleanupWork: IdentityCleanupWork?
    var rolloverEffectsWork: RolloverEffectsWork?
    var coverage: MonitorCoverageState?
    var ratchets: [UUID: MeteringOwnerRatchet]
}
```

`MeteringRetryPolicy.nextAttempt` intentionally maps the first failed attempt to `+5`; initial enqueue uses `nextAttemptAt = now`. Failure 2 is `+15`, failure 3 `+60`, failure 4 and every later failure `+300`.
`LegacyCompatibilityMonitorState.isStopped` is preserved only as exact legacy decode provenance; `phase` is the sole post-migration lifecycle authority, and callback/stop authorization never branches on the imported Boolean. Cleanup and rollover recovery advance only the acknowledgement fields above in the same root transaction as each idempotent external effect.

**TDD RED:** Cover absent-root bootstrap, exact round-trip of every field, future-schema refusal, one transaction co-persisting generation+epoch+route+v2 handoff+all work, exact selection bytes/digest preservation, injected lock/read/write/readback failures, owner mismatch before mutation, owner change before write, owner change after readback, and migration of exact active `EarnedActivityGeneration.Lifecycle` into `LegacyCompatibilityMonitorState`. Assert failed transactions leave prior bytes unchanged and never delete legacy keys. A `dualV2` handoff must reference two existing same-owner routes/epochs, leave `activeRouteID` on the prior route until commit, and cannot enter `cutoverReady` while any prior-route sample is pending/in-flight. The barrier transaction records `priorRouteInputClosedAt`; a callback serialized before it creates work and blocks the barrier, while one serialized after it cannot create prior-route work. Collection requires replacement activation and prior-stop acknowledgement.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreMigrationTests' test
```

Expected RED: `DeviceEpochStoreState.currentSchemaVersion`, `DeviceEpochStore`, and legacy migration do not exist.

**Minimal GREEN:** Implement the only persistence boundary:

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
    case appGroupContainerUnavailable
    case lockUnavailable
    case ownerMismatch
    case unsupportedSchema(Int)
    case readbackMismatch
}

nonisolated final class DeviceEpochStore: @unchecked Sendable {
    static let shared = DeviceEpochStore()
    static let fileName = "metering-device-epoch-store-v4.json"

    init(
        fileURL: URL? = nil,
        lock: any DeviceEpochStoreLocking = ActiveLockPersistenceLock.shared,
        fileIO: any DeviceEpochFileIO = SystemDeviceEpochFileIO(),
        ownerProvider: @escaping @Sendable () -> UUID? = MeteringOwnerMirror.current
    )

    func read() throws -> DeviceEpochStoreState

    @discardableResult
    func transaction<Value>(
        expectedOwner: UUID?,
        _ mutate: (inout DeviceEpochStoreState) throws -> Value
    ) throws -> Value
}
```

`transaction` acquires the shared lock, reads one root, migrates only known older roots, checks owner before mutation, mutates a copy, checks owner again, writes atomically, decodes and compares readback, checks owner a third time, then returns. Migration reads the existing `EarnedActivityGeneration.loadLifecycle(defaults:)` and copies all active/pending/retiring/stopped provenance into `legacy`; old keys remain until Task 28. Add app/DAM/Push membership exactly as the table specifies.

**GREEN:** Re-run RED, then build all consuming targets:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreMigrationTests' -only-testing:'Evlin iOSTests/MeteringEpochWireTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
```

Expected GREEN: all fault cases preserve prior bytes; migrated legacy provenance is exact; app, DAM, and Push compile under Swift 5.0.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOSTests/DeviceEpochStoreTests.swift' 'Evlin iOSTests/DeviceEpochStoreMigrationTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: add atomic device epoch store'
```

---

## Task 6: Queue Legacy And Epoch Samples Durably Before Any Switch

**Repository:** iOS.

**Interfaces:** Consumes Task 4 wire, Task 5 root, current `EarnedSampleReporter` v1 semantics, and `URLSession`. Produces durable registration, activation, sample, install, cleanup, and rollover scheduling with one ordering rule. The local protocol selection remains `.v1` throughout this task.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochDelivery.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochDeliveryTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Persist a metadata-free v1 callback, a metadata-bearing v1 callback, and the current legacy retry/fallback payload, destroy the producer, reopen, and require byte-identical requests. Cover network failure, 429/5xx retry, accepted duplicate, `legacy_after_v2`, identity 409, `accounting_paused`, malformed lane, owner change during response, and virtual times `t`, `t+5`, `t+15`, `t+60`, `t+300`, `t+600`. Require due-order keys `(nextAttemptAt, workKindPriority, createdAt, workID.uuidString.lowercased())` where priorities are identity cleanup 0, rollover 1, registration 2, install 3, activation 4, sample 5, shield 6. Require registration work to dispatch before matching install and activation work. Assert `localSelection == .v1` before and after every response.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' test
```

Expected RED: reopened work is absent and retry timings use the legacy mechanism.

**Minimal GREEN:** Implement:

```swift
nonisolated protocol MeteringHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
extension URLSession: MeteringHTTPTransport {}

nonisolated enum EpochSampleHTTPDisposition: Equatable, Sendable {
    case accepted(DeviceDaySnapshotDTO)
    case terminal(code: String, snapshot: DeviceDaySnapshotDTO?)
    case retry(code: String)
}

nonisolated enum EpochRegistrationHTTPDisposition: Equatable, Sendable {
    case registered(EpochRegistrationResponseDTO)
    case authoritativeBaseMismatch(EpochRegistrationConflictDTO)
    case terminal(code: String)
    case retry(code: String)
}

nonisolated enum EpochActivationHTTPDisposition: Equatable, Sendable {
    case acknowledged(EpochActivationResponseDTO)
    case terminal(code: String)
    case retry(code: String)
}

nonisolated final class MeteringEpochDelivery: @unchecked Sendable {
    init(
        baseURL: URL,
        store: DeviceEpochStore = .shared,
        transport: any MeteringHTTPTransport,
        clock: any MeteringClock = MeteringRuntimeClock.live()
    )
    func enqueueV1(_ request: EpochSampleRequestDTO, owner: UUID) throws
    func enqueueRegistration(_ request: EpochRegistrationRequestDTO, owner: UUID, epochID: UUID, routeID: UUID) throws
    func enqueueActivation(_ request: EpochActivationRequestDTO, owner: UUID, epochID: UUID, routeID: UUID) throws
    func fetchChildState(owner: UUID) async throws -> ChildStateResponse
    func drain(owner: UUID) async
}
```

Import legacy retry/fallback payloads once inside the root transaction and remove each legacy key only after root readback succeeds. Existing callback production enqueues v1 first and then calls `drain`; no callback is lost offline. Registration 200 records `registeredV2At` but does not change `localSelection`; only Task 11 may move it through `.dualActive` to `.v2`. Every response transaction rechecks owner and referenced epoch/route. Terminal samples are retained as terminal work until tombstone retention can prove all references terminal.
Add `MeteringEpochDelivery.swift` to DAM membership because DAM drains callback work. Keep it out of Push: Push may persist root work but cannot create the transport/recovery path.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' -only-testing:'Evlin iOSTests/EarnedSampleReporterTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' test
```

Expected GREEN: all retries follow the pinned virtual clock; reopened v1 work drains; queue ordering is deterministic; protocol remains 1.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/MeteringEpochDelivery.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Services/EarnedSampleReporter.swift' 'Evlin iOSTests/MeteringEpochDeliveryTests.swift' 'Evlin iOSTests/EarnedSampleReporterTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: queue legacy and epoch samples durably'
```

---

## Task 7: Extend Backend Phase 3 Vectors Through Real Rows And Ledgers

**Repository:** Backend tests/fixtures only.

**Interfaces:** Consumes Tasks 3 and 6 wire contracts and existing V01-V23. Produces V24-V39 fixture evidence plus real-route DB assertions. Production files are unchanged in this task.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_vector_contract.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_phase3_vectors.py`

**TDD RED:** Require IDs V01-V39 exactly once and executable observations for:

| IDs | Required evidence |
|---|---|
| V24-V26 | eight dated routes, coverage exhaustion zero effects, excessive-activities preservation |
| V27-V29 | route rejection zero effects, install claim races, shield/identity/rollover recovery |
| V30 | real v1, registration 200, activation 200, v2, stale v1 `legacy_after_v2` through rows/ledgers |
| V31-V32 | real `.taskPause` CAS contract and one-shot 409 correction with crash-safe prior→corrected `dualV2` handoff |
| V33-V35 | 60-second app/DAM lease race/adoption, exact retry deadlines/order, exact tombstone retention |
| V36-V39 | all-source app/DAM merge, conservative gate-close/resume `dualV2` handoff, exact legacy v1 migration/survival, cross-stack V30 artifacts |

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python -m pytest -q tests/test_metering_epoch_vector_contract.py
.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_epoch_phase3_vectors.py
```

Expected RED: V33-V39 are missing and V30 cannot activate through a real endpoint.

**Minimal GREEN:** Add concrete UUIDs, UTC instants, dates, exact requests, expected HTTP bodies, and effect counters to the shared JSON. The DB test posts through FastAPI's real routes, then queries `EarnedTimeMeteringEpoch`, `EarnedTimeSample`, `EarnedTimeDeviceDay`, `EarnedTimeDay`, `EarnedTimeLockCommand`, and `Command`; it also snapshots `BigKidStore.get_state(device.id).minutes_left` as the separate legacy bank value. It must assert registration leaves protocol 1, activation changes it to 2, and stale v1 inserts no sample and changes no row, ledger, lock receipt/command, or bank value. V32 proves the corrected candidate has different `epoch_id` and `route_id`, keeps the prior route countable until every prior work item settles and `cutoverReady` closes its input, then counts the corrected route while overlap converges by monotonic max. V33-V36 are cross-process/retry/retention/merge data contracts for Swift production tests. V37 closes the gate at final registration/activation and then proves conservative resume preserves a countable prior route through the same drain/barrier before replacement cutover. V38 carries exact legacy provenance; V39 defines the six-file cross-stack artifact contract consumed in Task 19. No `app/` or Alembic file changes are permitted.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python -m pytest -q tests/test_metering_epoch_vector_contract.py
.venv/bin/python scripts/run_limits_db_regression.py tests/test_target_gate_resume_helpers.py
.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_epoch_phase3_vectors.py tests/test_metering_epoch_registration.py tests/test_metering_epoch_sample_adapter.py tests/test_metering_epoch_phase2_integration.py tests/test_metering_epoch_lifespan.py tests/test_metering_epoch_models.py
```

Expected GREEN: fixture coverage is exact and every DB test executes without skips through the disposable runner.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py
```

Expected full GREEN: the complete disposable-database regression set passes without skips.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
git add tests/fixtures/metering_epoch_vectors.json tests/test_metering_epoch_vector_contract.py tests/test_metering_epoch_phase3_vectors.py
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
test "$(git diff --cached --name-only | wc -l | tr -d ' ')" -eq 3
IOS_TASK6_SHA="$(git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS log --format='%H%x09%s' "$(cat /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/.superpowers/evidence/metering-phase3/ios-base-sha.txt)..HEAD" | awk -F '\t' '$2 == "feat: queue legacy and epoch samples durably" { print $1 }')"
test "$(printf '%s\n' "$IOS_TASK6_SHA" | rg -c '^[0-9a-f]{40}$')" -eq 1
git commit -m 'test: extend backend phase 3 vectors' -m "Phase3-Depends-On: $IOS_TASK6_SHA"
```

---

## Task 8: Mirror Phase 3 Vectors In Swift With Real Shield Types

**Repository:** iOS.

**Interfaces:** Consumes the byte-identical backend fixture, `ShieldRecord`, production `ShieldSource.taskPause`, and Task 5 types. Produces Swift V24-V39 observations and the production compare-and-swap transform consumed by Task 14.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/Fixtures/metering_epoch_vectors.json`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/Fixtures/metering_epoch_phase3_vectors.json`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochContract.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedShieldEffectStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/ShieldRecord.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochGoldenVectorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochVectorCoverageTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringEpochPhase3VectorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/ShieldRecordSourceMigrationTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/ShieldSourceSetTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/TaskPauseShieldMappingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Copy the backend fixture byte-for-byte and require V01-V39. Add P3V01 using a real `ShieldRecord` with sources `[.manual, .taskPause, .earnedTime]`; a mismatched current record must remain byte-identical, while an exact match removes only `.earnedTime`. Add P3V02 with `.limit` plus an unknown future Codable source fixture and prove decode -> merge -> encode preserves the exact unknown raw source instead of coercing it to `.manual`. Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
cmp 'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' -only-testing:'Evlin iOSTests/ShieldRecordSourceMigrationTests' -only-testing:'Evlin iOSTests/ShieldSourceSetTests' -only-testing:'Evlin iOSTests/TaskPauseShieldMappingTests' test
```

Expected RED: V33-V39 and `EarnedShieldCAS.releasingEarnedSource` are absent.

**Minimal GREEN:** Add exact decoders and effect observations, then implement:

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

P3V01 constructs the production `ShieldRecord` memberwise and calls this exact function. The vector adapter must expose production effect counts for queue mutations, starts/stops, shield writes, notifications, backend sends, earned ledger changes, bank changes, and lock-ledger changes; a pure verdict alone does not pass. Add DAM and Push target membership for the store, including its existing `ShieldRecord.swift`, `ShieldTier.swift`, `ShieldSourceLogic.swift`, and `ActiveLockPersistenceLock.swift` closure.

Replace `ShieldSource`'s lossy unknown decode with one raw-value-preserving
Codable/Hashable representation. Keep `.manual`, `.limit`, `.earnedTime`, and
`.taskPause` source-compatible static values and missing legacy fields defaulting
to `.manual`; any nonempty future raw value round-trips unchanged. This is a
provenance compatibility type, not a second lock-state owner.

Update both existing compatibility suites that currently pin unknown scalar
sources to `.manual`, plus the raw initializer assertion:
`ShieldRecordSourceMigrationTests`, `ShieldSourceSetTests`, and
`TaskPauseShieldMappingTests`. Missing or empty legacy fields still default to
`.manual`; a nonempty unknown raw value such as `schedule` survives scalar
decode, set merge, dictionary decode, and encode/decode round trip exactly.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
cmp 'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringEpochContractTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' -only-testing:'Evlin iOSTests/ShieldRecordSourceMigrationTests' -only-testing:'Evlin iOSTests/ShieldSourceSetTests' -only-testing:'Evlin iOSTests/TaskPauseShieldMappingTests' test
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python -m pytest -q tests/test_metering_epoch_vector_contract.py
.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_epoch_phase3_vectors.py
```

Expected GREEN: fixtures are byte-identical, V01-V39 execute on both sides, and P3V01 reaches the real `.taskPause` token and production CAS.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' 'Evlin iOSTests/Fixtures/metering_epoch_phase3_vectors.json' 'Evlin iOS/Services/MeteringEpochContract.swift' 'Evlin iOS/Services/EarnedShieldEffectStore.swift' 'Evlin iOS/Models/ShieldRecord.swift' 'Evlin iOSTests/MeteringEpochGoldenVectorTests.swift' 'Evlin iOSTests/MeteringEpochVectorCoverageTests.swift' 'Evlin iOSTests/MeteringEpochPhase3VectorTests.swift' 'Evlin iOSTests/ShieldRecordSourceMigrationTests.swift' 'Evlin iOSTests/ShieldSourceSetTests.swift' 'Evlin iOSTests/TaskPauseShieldMappingTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
BACKEND_TASK7_SHA="$(git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend log --format='%H%x09%s' "$(cat .superpowers/evidence/metering-phase3/backend-base-sha.txt)..HEAD" | awk -F '\t' '$2 == "test: extend backend phase 3 vectors" { print $1 }')"
test "$(printf '%s\n' "$BACKEND_TASK7_SHA" | rg -c '^[0-9a-f]{40}$')" -eq 1
git commit -m 'test: mirror phase 3 vectors in Swift' -m "Phase3-Depends-On: $BACKEND_TASK7_SHA"
```

---

## Task 9: Plan Immutable Dated Metering Routes

**Repository:** iOS.

**Interfaces:** Consumes the exact six-field generation key, raw selection bytes/digest, canonical runtime, and shared clock. Produces strict names, `datedSchedule(usageDate:timeZone:calendar:)`, and deterministic today-plus-seven planning. `usageDate` remains outside generation identity.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringCallbackRoute.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringDatedSchedule.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetScheduler.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringCallbackRouteTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetSchedulerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Assert exact activity/event names for a fixed UUID; reject malformed UUID, route mismatch, extra segments, invalid/zero threshold, and wrong namespace. Test New York spring/fall DST, Tokyo/New York canonical-date split, invalid date, and `repeats == false`. Reconcile the same authoritative runtime twice and assert one generation ID, eight stable route IDs, eight stable epoch reservations, no queue replacement, and exact persisted selection bytes. Change each of the six fields individually and require a new generation; change usage date, offset, estimate, counter, timestamp, gate, or retry and require no generation replacement.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringCallbackRouteTests' -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' test
```

Expected RED: `MeteringRouteNamespace`, `MeteringHorizonPlanner`, and `datedSchedule` are undefined.

**Minimal GREEN:** Implement:

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

nonisolated enum MeteringDatedSchedule {
    static func datedSchedule(
        usageDate: String,
        timeZone: TimeZone,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> DeviceActivitySchedule

    static func makeEvent(
        selection: FamilyActivitySelection,
        thresholdMinutes: Int
    ) -> DeviceActivityEvent
}

extension EarnedBudgetScheduler {
    nonisolated static func datedSchedule(
        usageDate: String,
        timeZone: TimeZone,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> DeviceActivitySchedule {
        try MeteringDatedSchedule.datedSchedule(
            usageDate: usageDate,
            timeZone: timeZone,
            calendar: calendar
        )
    }
}
```

The shared schedule parser accepts exact `yyyy-MM-dd`, sets the supplied calendar locale to `en_US_POSIX` and timezone, constructs canonical midnight and next-day midnight with absolute year/month/day components, and returns `repeats: false`. It is the schedule/event constructor used by `DatedRouteInstaller` in app and DAM; it decodes the generation's exact persisted selection bytes only for Apple installation and never re-encodes them for identity. `EarnedBudgetScheduler.datedSchedule(usageDate:timeZone:calendar:)` delegates to this shared function while the legacy scheduler remains. Planning creates one immutable `.planned` route and one `.pendingStart` `ActivityInstallWork` for each missing date. Today co-persists a full epoch, registration work, and `.registrationRequired` install authorization; future dates reserve a fresh epoch ID and use `.futurePlanned`. Existing `(generationID, usageDate)` routes and IDs are never replaced by polling.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringCallbackRouteTests' -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' test
```

Expected GREEN: dated schedules are canonical and stable; eight IDs persist; generation identity changes only on one of the six fields.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/MeteringCallbackRoute.swift' 'Evlin iOS/Services/MeteringDatedSchedule.swift' 'Evlin iOS/Services/EarnedBudgetScheduler.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOSTests/MeteringCallbackRouteTests.swift' 'Evlin iOSTests/EarnedBudgetSchedulerTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: plan immutable dated metering routes'
```

---

## Task 10: Arbitrate, Start, And Verify Dated Route Installs

**Repository:** iOS.

**Interfaces:** Consumes Task 9 route/install work, Task 6 registration state, Task 2 center and process identity, and Task 5 transaction. Produces the only app/DAM install state machine, including lease arbitration and daemon adoption. It does not activate protocol v2.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DatedRouteInstaller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/DatedRouteInstallerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Use two store instances and two center fakes with app/DAM process identities. Interleave claims so exactly one process changes pending work to starting and the loser makes zero center/store calls. Crash after claim, after Apple start, after persisted installed, and after verification; at `expiresAt - 0.001` no adoption occurs, at exactly `claimedAt + 60` the adopter inspects `activities`, `schedule(for:)`, and `events(for:)`, acknowledges an exact daemon configuration without another start, and replaces a mismatched daemon configuration only while an older functioning monitor remains. Registration-required current work cannot start before 200; `.futurePlanned` and `.offlinePending` are explicit exceptions. `excessiveActivities` retains verified routes. Finally run the real installer once and require exactly eight starts; run 120 additional real `reconcile` calls ten seconds apart and require zero additional starts and zero stops.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests' test
```

Expected RED: both simulated processes call start and the 121-poll test cannot instantiate a production installer.

**Minimal GREEN:** Implement the exact API:

```swift
nonisolated enum DatedRouteInstallResult: Equatable, Sendable {
    case noWork
    case claimed(workID: UUID, token: UUID)
    case adopted(workID: UUID)
    case verified(workID: UUID)
    case deferred(workID: UUID, code: String)
}

@MainActor
final class DatedRouteInstaller {
    static let claimLeaseSeconds: TimeInterval = 60

    init(
        store: DeviceEpochStore = .shared,
        center: any MeteringDeviceActivityCenter,
        processIdentity: MeteringProcessIdentity,
        clock: any MeteringClock = MeteringRuntimeClock.live()
    )

    func reconcile(ownerChildDeviceID: UUID) throws -> [DatedRouteInstallResult]
}
```

One `reconcile` call drains all due install work in deterministic Task 6 order and returns one result per considered work item, which makes the first real reconciliation's eight starts non-vacuous. Claim acquisition and install-work `.pendingStart` to `.starting` transition occur in one root transaction. A live foreign claim makes that work item a no-op. An expired claim adopter first compares exact daemon activity, schedule, and events; exact state advances through `.installed` to `.verified` without duplicate start. An absent route is started once; a present but mismatched route is replaced and reverified while a prior functioning monitor remains. Route lifecycle remains `.planned` until Task 11 activation. `MonitoringError.excessiveActivities` leaves all current verified installs and active routes untouched, keeps remaining work retryable using Task 6 policy, and updates coverage to `installLimited`. No path stops a prior functioning monitor in this task.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreTests' -only-testing:'Evlin iOSTests/EarnedBudgetSchedulerTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
```

Expected GREEN: every interleaving has one claimant; expired work is adopted without blind start; the non-vacuous real-installer proof reports starts `8` then `0`/stops `0` for the next 120 reconciliations.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/DatedRouteInstaller.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOSTests/DatedRouteInstallerTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: arbitrate and verify dated route installs'
```

---

## Task 11: Activate V2 Without Breaking Legacy Metering

**Repository:** iOS.

**Interfaces:** Consumes backend Task 3, durable queue, verified install, migrated `LegacyCompatibilityMonitorState`, and `V2RouteHandoff`. Produces the sole protocol ratchet and sole route cutover. Functional v1 remains active through registration 200 and v2 start/verification. One durable `dualActive` commit authorizes the initial exact v2 route before the backend ratchet while retaining v1. Every later replacement uses a durable `dualV2` commit before backend registration can retire the prior v2 epoch; the prior route stops only after replacement activation and local cutover commit.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DatedRouteInstaller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochDelivery.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringV2ActivationTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Cover advertised version 1, offline registration, registration retry, registration 200, crash after registration ack, v2 start failure, crash after start, verification failure, crash immediately before and after the durable `dualActive` commit, activation network failure, activation paused due gate close, backend activation commit with a lost response, and app restart at every state. Before `dualActive`, assert real v1 callbacks advance the ledger and no legacy stop occurs. In `dualActive`, route/install provenance accepts exact v2 callbacks while real v1 callbacks remain functional; one overlapping v1/v2 cumulative interval advances the ledger once by monotonic max. After backend activation commit but before local v2-only commit, assert v2 still advances the ledger and delayed v1 is terminal, proving there is no zero-metering window. Replay the same activation after gate close, epoch exhaustion, policy change, and enforcement-set change; each `already_activated` response acknowledges the immutable committed ratchet even when mutable `epoch_status` is no longer active. The local transaction must select v2 and preserve that current status, then schedule any required pause/policy/rollover replacement; it must not wait for a second backend ratchet. A different route or retired epoch remains terminal. On local active commit assert `localSelection == .v2` and route active are one transaction; then and only then legacy becomes retiring, is stopped, absence is verified, and becomes stopped. A paused response from a first, never-committed activation does not ratchet, exits `dualActive` into paused replacement recovery, and waits for a fresh conservative epoch after gate open.

Repeat every crash boundary for an already-v2 owner replacing route A with B: create B while A stays active; start/verify B; commit exact A→B `dualV2`; queue overlapping A/B callbacks; drain every deliverable/in-flight A work; race one final A callback against the atomic no-pending-work barrier; enter `cutoverReady`; send registration; lose the registration response after the backend atomically retires A; reopen; retry registration; activate B; lose activation response; locally commit B active; then stop A. Before the barrier A advances usage and B queues without business effects. A callback that wins the store lock queues and prevents the barrier; one that loses is discarded while B continues queueing. Registration is forbidden before `cutoverReady`. After backend cutover B advances usage even if the response was lost and no undelivered A sample can be stranded as stale. Across the overlap, device-day and child-day advance by `max(A,B)` exactly once, never by sum. At every injected crash at least one route remains countable, and A is not locally retired/tombstoned or physically stopped before B is active.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests' test
```

Expected RED: current migration cannot retain exact legacy state and registration 200 selects v2 too early.

**Minimal GREEN:** Implement:

```swift
@MainActor
final class EarnedMeteringRecoveryDriver {
    init(
        store: DeviceEpochStore = .shared,
        delivery: MeteringEpochDelivery,
        installer: DatedRouteInstaller,
        center: any MeteringDeviceActivityCenter,
        processIdentity: MeteringProcessIdentity,
        clock: any MeteringClock = MeteringRuntimeClock.live()
    )

    func recover(ownerChildDeviceID: UUID) async throws
}
```

Recovery order is cleanup, rollover, candidate install, dual-lane/dual-v2 commit, prior-route sample drain/barrier, registration, activation, candidate sample drain, shield, and prior stop. Initial migration registration may precede install; it sets matching install authorization to `.registered` and records `registeredV2At` but never changes the backend ratchet. Initial install `.verified` transitions in one owner/epoch/route/generation transaction to `.dualActive`, records exact v2 callback authorization, preserves legacy v1 delivery, and creates exactly one activation work. Either `activated` or same-route `already_activated` with protocol 2 is a durable activation acknowledgement. For `already_activated`, mutable paused/exhausted/policy/enforcement drift is reconciled only after the local v2-selection commit; it cannot leave the device in `.dualActive` with a terminal v1 lane.

For an already-v2 owner, candidate install and daemon verification happen while the prior route remains active. One transaction creates/advances the exact `V2RouteHandoff` to `.dualV2`; it leaves `activeRouteID` and the prior route lifecycle unchanged and authorizes callbacks from both exact routes. Candidate callbacks remain durable waiting work. Recovery sends and terminally settles all deliverable prior-route work, waits for in-flight delivery to finish, then uses the same root lock as callback enqueue to require zero nonterminal prior work, records `priorRouteInputClosedAt`, advances to `.cutoverReady`, and makes registration due. After that barrier prior callbacks are byte-identical discards and only candidate work queues. Registration 200 or idempotent retry records the handoff acknowledgement; a lost response cannot remove local authorization. Active/already-active activation then atomically makes the candidate route active, marks the handoff `.committed`, retires/tombstones the prior local route, and appends its pending stop. Only absence acknowledgement terminalizes the prior stop and permits handoff collection.

Callback trust accepts the exact initial route in `.dualActive`/`.active`; during handoff it accepts both exact routes in `.dualV2`, then only the candidate route in `.cutoverReady`. No other pre-active phase is accepted. All same-owner/day overlap is cumulative monotonic max. Only a later step changes legacy to `.retiringV1` and asks Apple to stop; absence acknowledgement changes it to `.stoppedV1`. Paused registration/activation never becomes v2-only, never retires the prior functioning local route, and schedules fresh conservative replacement only after authoritative child state reports the gate open.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests' -only-testing:'Evlin iOSTests/DeviceEpochStoreMigrationTests' test
```

Expected GREEN: v1 survives offline, unadvertised, failed-v2, and restart paths; every initial and v2-to-v2 crash boundary has a countable lane; `dualActive` and `dualV2` overlap are monotonic rather than additive; only active activation ratchets and only the later local commit retires the prior monitor/route.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' 'Evlin iOS/Services/DatedRouteInstaller.swift' 'Evlin iOS/Services/MeteringEpochDelivery.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOSTests/MeteringV2ActivationTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: activate v2 without breaking legacy metering'
```

---

## Task 12: Authorize Every Callback Through Immutable Route Provenance

**Repository:** iOS.

**Interfaces:** Consumes names-only `MeteringAppleCallback`, strict parser, full route, tombstones, active epoch/generation/ratchet, and durable queue. Produces the only callback side-effect boundary. Default early jitter is 30 seconds, injected maximum is 60, and delayed callbacks have no age lower bound.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochDelivery.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedMeteringCallbackTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Drive malformed names, route mismatch, unknown route, real old-route tombstone after rollover, planned/retired/tombstoned route, matching install work in pendingStart/starting/installed/verified/pendingStop/stopped, wrong owner/day/epoch/generation/policy/namespace, local selection `.v1`, unregistered route, exhausted/retired epoch, coverage exhausted, 31 seconds early, configured 61-second jitter, and one-day-delayed valid callback. For each hard rejection compare full root bytes and assert zero queue, usage, ledger, network, notification, shield, center, and auto-lock effects. Separately test the only bounded metadata-only outcomes: (a) a paused epoch while the gate remains closed may change only `lastRawThresholdMinutes`, `excludedWhilePausedMinutes`, and one diagnostic; (b) a callback on that old paused route after the gate reopens is byte-identical and schedules no work; (c) the first fresh `resumeBoundaryPending` callback changes only its boundary fields. A valid exact route in install `.dualActive` or `.active` queues one v2 sample; `.dualActive` is valid even while the backend ratchet is still 1. During exact `V2RouteHandoff.dualV2`, both from/to routes queue, but same-owner/day cumulative overlap advances accepted usage by monotonic max only; before backend registration the to-route work remains waiting. Race an A callback with the no-pending-A barrier: if enqueue wins, barrier fails/retries; if barrier wins, phase is `cutoverReady`, A is a byte-identical discard and B still queues. Registration is not due before that phase. After backend cutover no undelivered A work exists, and B work survives a lost response. A route merely present in a handoff with the wrong phase or IDs is rejected byte-identically. An offline registered route queues once without transport. A tombstoned prior-date callback proves zero effects by resolving the tombstone, not by comparing only current state.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' test
```

Expected RED: no production boundary accepts only the Apple-shaped DTO.

**Minimal GREEN:** Implement:

```swift
nonisolated enum EarnedMeteringCallbackOutcome: Equatable, Sendable {
    case queued(sampleWorkID: UUID)
    case discarded(reason: String)
}

nonisolated final class EarnedMeteringCallback: @unchecked Sendable {
    static let defaultJitterSeconds = 30
    static let maximumJitterSeconds = 60

    init(
        store: DeviceEpochStore = .shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        jitterSeconds: Int = defaultJitterSeconds
    )

    func handle(
        _ callback: MeteringAppleCallback,
        expectedOwnerChildDeviceID: UUID
    ) throws -> EarnedMeteringCallbackOutcome
}
```

The initializer rejects jitter outside `0...60`. `handle` parses both names, resolves route or tombstone, validates all independent provenance and either initial local selection `.dualActive`/`.v2`, exact `V2RouteHandoff.dualV2` membership, or candidate-route membership in `.cutoverReady` before mutation, then repeats owner/route/epoch/handoff checks inside one root transaction before advancing high-water and appending a sample. In `.cutoverReady`, the prior route returns `.discarded(reason: "handoff_prior_input_closed")` without changing root bytes. The prior and candidate routes maintain independent raw high-water values; accepted owner/day usage is the monotonic maximum of their cumulative estimates and is never added. A closed-gate paused callback may update only its registered high-water/diagnostic fields. A reopened old paused route has zero mutation. For `resumeBoundaryPending`, the transaction records the callback threshold as both `lastRawThresholdMinutes` and the excluded boundary, clears `resumeBoundaryPending`, and returns `.discarded` without changing accepted usage or creating sample/network/shield work. Unknown/uncovered/tombstoned input cannot create usage. Transport and shield work occur later and repeat authorization.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' test
```

Expected GREEN: hard rejections are byte-identical; the two registered boundary/high-water cases mutate only their named metadata; every case has zero unintended effects; delayed valid callback is accepted and early jitter is bounded.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedMeteringCallback.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Services/MeteringEpochDelivery.swift' 'Evlin iOSTests/EarnedMeteringCallbackTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: authorize earned callbacks by immutable route'
```

---

## Task 13: Replace Route On Authoritative Base Correction

**Repository:** iOS.

**Interfaces:** Consumes registration 409 authoritative snapshot and the v2-to-v2 handoff safety order. Produces exactly one corrected immutable candidate epoch, fresh route, fresh registration/install/activation work, rejected-candidate terminal handling, and a dual-v2 cutover that leaves the prior functioning route countable until the correction is active.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringEpochDelivery.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringAuthoritativeBaseCorrectionTests.swift`

**TDD RED:** Inject a crash after each boundary: receive 409 before transaction; terminalize the rejected candidate epoch/route/sample work; create corrected candidate epoch and route; authorize install; Apple start; daemon verify; commit prior→corrected `dualV2`; settle prior-route queued/in-flight work; race a final prior callback against the atomic `cutoverReady` barrier; enqueue/send registration; lose the registration response after backend cutover; recover registration; activation ack; lose activation response; local corrected activation; prior route retirement/tombstone and pending stop; Apple stop; stop acknowledgement. Reopen after each and require convergence with stable corrected IDs. Assert corrected base equals only `authoritative_snapshot.estimated_minutes`; rejected and corrected candidate IDs differ; prior functioning IDs remain unchanged until local corrected activation; rejected-candidate samples never send; no prior work is stranded stale; corrected-route samples count after cutover; overlap advances by monotonic max; a second 409 is terminal only for the candidate; and the prior functioning legacy or v2 monitor is not retired or stopped before corrected route active.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringAuthoritativeBaseCorrectionTests' test
```

Expected RED: existing recovery reuses the conflicted route or loops the same registration.

**Minimal GREEN:** Consume the rejected candidate's Task 5 `BaseCorrectionState.available` by changing it to `.used` in the same transaction that terminalizes only its IDs and creates all corrected candidate work. Do not add a standalone defaults flag or Boolean. Rejected-candidate sample work transitions to `.superseded` with `lastErrorCode = "authoritative_base_mismatch"`; it remains referenced until candidate tombstone collection. Drive corrected install/verification, `dualV2`, prior drain/`cutoverReady`, registration, activation, and prior stop through Tasks 6/10/11. The prior functioning epoch/route stays active through candidate installation and is locally retired/tombstoned only in the corrected active commit. A conflict when state is already `.used` retires the corrected candidate and leaves the prior functioning monitor untouched.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringAuthoritativeBaseCorrectionTests' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' test
```

Expected GREEN: every crash point converges; exactly one fresh correction exists; rejected-candidate work has zero effects; prior/corrected overlap is monotonic; monitor continuity holds.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Services/MeteringEpochDelivery.swift' 'Evlin iOSTests/MeteringAuthoritativeBaseCorrectionTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'fix: replace route on authoritative base correction'
```

---

## Task 14: Persist Earned Shield Effects Across Processes

**Repository:** iOS.

**Interfaces:** Consumes the real `ShieldRecord`, all `ShieldSource` values, `ActiveLockPersistenceLock`, Task 8 CAS, and Task 5 shield references. Produces a write-ahead `EarnedShieldEffectEnvelope` and a narrow shared persistence utility compiled by app, DAM, and Push. The existing app/Push `ActiveLockStore` actor delegates earned effects to the utility and is not added to DAM.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedShieldEffectStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/ActiveLockStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/ShieldRecord.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedShieldEffectStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/ActiveLockStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**Persisted interface:**

```swift
nonisolated enum EarnedShieldEffectPhase: String, Codable, Sendable {
    case prepared, applied, releasePending, released, conflicted
}

nonisolated enum EarnedShieldEffectError: Error, Equatable {
    case defaultsUnavailable
    case lockUnavailable
    case authorizationChanged
    case envelopeMissing(UUID)
    case durableReadbackMismatch
}

nonisolated struct EarnedShieldEffectEnvelope: Codable, Equatable, Sendable {
    let operationID: UUID
    let ownerChildDeviceID: UUID
    let generationID: UUID
    let epochID: UUID
    let routeID: UUID
    let recordKey: String
    let beforeRecord: ShieldRecord?
    let intendedAfterRecord: ShieldRecord?
    var phase: EarnedShieldEffectPhase
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated final class EarnedShieldEffectStore: @unchecked Sendable {
    static let envelopeKey = "evlin.earnedShieldEffectEnvelopes.v1"
    static let shieldsKey = "evlin.shieldRecords"
    static let blocksKey = "evlin.blockRecords"

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios"),
        lock: ActiveLockPersistenceLock = .shared,
        epochStore: DeviceEpochStore = .shared
    )

    func apply(_ envelope: EarnedShieldEffectEnvelope) throws
    func release(operationID: UUID, expectedOwner: UUID) throws
    func recover(expectedOwner: UUID) throws
}
```

**TDD RED:** Inject crashes before/after prepared-envelope write, shield write/readback, applied-envelope write, recompute, release-pending write, CAS release/readback, and released write. Recover from `current == before`, `current == intendedAfter`, and CAS conflict. Include manual, taskPause, limit, earnedTime, block records, per-app records, and a third-party/future source record whose unknown raw value must survive every reopen and re-encode. Add the required real production race: DAM `EarnedShieldEffectStore.apply` writes earnedTime; an already-live `ActiveLockStore` actor performs an unrelated manual/taskPause/limit mutation; durable readback still contains earnedTime and every other source. Force a CAS conflict and prove no source is removed.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' -only-testing:'Evlin iOSTests/ActiveLockStoreTests' test
```

Expected RED: the live actor overwrites DAM's earnedTime source from its stale cache and no durable envelope can recover the crash.

**Minimal GREEN:** Under `ActiveLockPersistenceLock`, every `ActiveLockStore` mutation (`addShield`, receipt add/rollback, remove, unshield, category removal, token drop, limit removal, block add/rollback/remove/unblock, expiry, reapply, rekey/rollback, and `removeSource`) calls `reloadDurableState()` before applying its operation. That reload replaces both cached shield and block dictionaries with all persisted records; it must not filter to `.limit`. Before apply, the narrow effect store rechecks exact owner, generation, active route, active epoch, and operation reference in the Device Epoch root; before release, it requires the exact operation reference plus an authorized correction, retirement, rollover, or identity-cleanup state. A failed recheck performs no envelope or shield mutation. The utility uses the same keys and lock, writes/reads the envelope around exact record CAS, and verifies durable readback. The Device Epoch root retains `EarnedShieldReference` IDs; the envelope is not deleted until epoch/identity cleanup terminally acknowledges the reference.

Do not add `ActiveLockStore.swift` or `ActiveLockStoreTypes.swift` to DAM; they remain in their verified app/Push targets. Add `EarnedShieldEffectStore.swift` and its complete narrow closure (`ShieldRecord.swift`, `ShieldTier.swift`, `ShieldSourceLogic.swift`, `ActiveLockPersistenceLock.swift`) to DAM and Push. This makes the CAS utility genuinely available to DAM without importing the actor's dependency graph.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' -only-testing:'Evlin iOSTests/ActiveLockStoreTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
```

Expected GREEN: P3V01 reaches production persistence; the stale-actor race preserves every source; all crash states converge or remain explicit conflict.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedShieldEffectStore.swift' 'Evlin iOS/Services/ActiveLockStore.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Models/ShieldRecord.swift' 'Evlin iOSTests/EarnedShieldEffectStoreTests.swift' 'Evlin iOSTests/ActiveLockStoreTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: persist earned shield effects across processes'
```

---

## Task 15: Retire Metering Identity Atomically

**Repository:** iOS.

**Interfaces:** Consumes owner-independent `IdentityCleanupWork`, tombstones, all queues/effects, both monitor lanes, and existing identity entry points. Produces a durable cleanup envelope that survives owner mirror removal and prevents every delayed old-owner mutation.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/Auth/AuthService.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/FamilyGoneDetector.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Views/Child/BigKid/BigKidRootView.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringIdentityCleanupTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetArmingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AuthServiceTests.swift`

**TDD RED:** Crash before/after cleanup preparation, epoch retirement, every route tombstone, owner mirror swap/removal, every registration/activation/sample/install retry terminal mark, legacy fallback deletion, shield release, each canonical activity stop, each absence acknowledgement, old-day state clear, and cleanup terminal mark. At each boundary require the matching `terminalizedWorkIDs`, `purgedFallbackKeys`, `releasedShieldOperationIDs`, `stopAcknowledgedActivityNames`, `clearedUsageDates`, or `ownerMirrorTransitionAcknowledged` value to survive reopen. Race an old callback and old HTTP response at every boundary. Require all canonical old activity names from routes and legacy state to stop; old work never sends or mutates; manual/taskPause/reflection/block/per-app/limit sources survive; a new owner's root is not cleared. Reopen after owner key removal and prove cleanup continues by work ID.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' -only-testing:'Evlin iOSTests/AuthServiceTests' test
```

Expected RED: current cleanup loses queue/fallback authority after clearing the owner mirror.

**Minimal GREEN:** Add an owner-independent transaction used only for an existing cleanup envelope:

```swift
extension DeviceEpochStore {
    @discardableResult
    func identityCleanupTransaction<Value>(
        workID: UUID,
        _ mutate: (inout DeviceEpochStoreState, inout IdentityCleanupWork) throws -> Value
    ) throws -> Value
}
```

It acquires the same lock, requires the root's exact cleanup work ID, and rechecks that ID before write/readback; it does not trust the mutable owner mirror. Identity entry points first create the envelope with exact old epoch/route/activity IDs, category-specific registration/activation/sample/install IDs, fallback keys, shield operation IDs, and usage dates, then retire/tombstone old authority in one transaction. Only then may they change the mirror. Recovery records each category-specific acknowledgement while terminally marking old work, purging fallback files, releasing only expected earnedTime effects by CAS, stopping/verifying every old route and legacy activity, and clearing old-day metering state; it marks cleanup succeeded only when every captured item appears in its corresponding acknowledgement set. Delayed old callbacks encounter tombstones and have zero effects.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' -only-testing:'Evlin iOSTests/AuthServiceTests' test
```

Expected GREEN: all crash/race paths converge after owner removal; old effects are zero; unrelated lock sources and new-owner state survive.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' 'Evlin iOS/Services/EarnedBudgetArming.swift' 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOS/Services/Auth/AuthService.swift' 'Evlin iOS/Services/FamilyGoneDetector.swift' 'Evlin iOS/Views/Child/BigKid/BigKidRootView.swift' 'Evlin iOSTests/MeteringIdentityCleanupTests.swift' 'Evlin iOSTests/EarnedBudgetArmingTests.swift' 'Evlin iOSTests/AuthServiceTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: retire metering identity atomically'
```

---

## Task 16: Recover Canonical Rollover Effects

**Repository:** iOS.

**Interfaces:** Consumes canonical timezone/day, current active epoch/route, next reserved epoch/route, queues, shields, and installer. Produces one owner-scoped but epoch-independent `RolloverEffectsWork` with exact old/new IDs.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringRolloverRecoveryTests.swift`

**TDD RED:** Trigger the same rollover from app poll, DAM interval callback, delayed old callback, and cold reopen concurrently. Crash before/after new epoch materialization, reserved-route adoption, candidate install verification, exact old→new `dualV2` commit, old-date queue/in-flight drain, callback/barrier race, `cutoverReady`, registration creation/backend cutover/lost response, shield release, pause/task/bypass reset acknowledgement, new activation/local cutover, old route retirement/tombstone, old stop, and old stop acknowledgement. Require one work ID and exact `fromUsageDate`, `toUsageDate`, `oldEpochID`, `newEpochID`, `oldRouteID`, `newRouteID`. Before the barrier, delayed old-date callbacks remain attributable only to the old usage date; after it they cannot create work. New-route callbacks remain durable and count the new day after cutover. New local activation precedes old retirement and stop.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringRolloverRecoveryTests' test
```

Expected RED: current midnight path strips earned shields but has no durable old/new epoch and route transaction.

**Minimal GREEN:** Keep and implement the exact Task 5 declaration:

```swift
nonisolated struct RolloverEffectsWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let fromUsageDate: String
    let toUsageDate: String
    let oldEpochID: UUID
    let newEpochID: UUID
    let oldRouteID: UUID
    let newRouteID: UUID
    var retry: MeteringRetryState
    var earnedSourceResetAcknowledged: Bool
    var perAppResetAcknowledged: Bool
    var taskStateResetAcknowledged: Bool
    var bypassExpiryAcknowledged: Bool
    var registrationAcknowledged: Bool
    var installAcknowledged: Bool
    var activationAcknowledged: Bool
    var oldStopAcknowledged: Bool
    let createdAt: Date
}
```

The first trigger atomically materializes the reserved new epoch/route and creates the envelope while leaving the old epoch/route locally active. Other triggers adopt it. Recovery verifies the new install, enters exact old→new `dualV2`, settles all old-route work, atomically closes old input at `cutoverReady`, registers and activates the new epoch, and only in the local active commit retires/tombstones the old route and schedules its stop. It flips each exact acknowledgement only in the transaction that verifies its earned-source, per-app, task, bypass, registration, install, activation, or old-stop effect. Same-day overlap uses monotonic max; cross-day callbacks remain isolated by `usageDate`. Tombstone collection requires all references terminal and stop acknowledged, then computes `retainedUntil = max(canonicalDayEnd + 48h, stopAcknowledgedAt + 24h)`; no earlier deletion is legal.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringRolloverRecoveryTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests' -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' test
```

Expected GREEN: all triggers converge on one exact ID tuple; delayed old route is zero-effect; retention obeys both lower bounds.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' 'Evlin iOS/Services/EarnedMeteringCallback.swift' 'Evlin iOSTests/MeteringRolloverRecoveryTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: recover canonical rollover effects'
```

---

## Task 17: Resume Metering With Conservative Epoch And Route Replacement

**Repository:** iOS plus verification against the committed backend protocol.

**Interfaces:** Consumes backend `gate_resume_conservative`, authoritative child-state/registration snapshot, paused high-water, and route replacement machinery. Produces continuous pause accounting with one conservative discard. It never queries or invents exact raw usage.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedMeteringCallback.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringConservativeResumeTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedMeteringCallbackTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`

**TDD RED:** Close the task/reflection gate while a route is active: callback high-water advances excluded paused minutes but the serialized diff is limited to the two registered high-water fields plus diagnostics; no sample/shield/earned effect and no monitor stop occurs. Reopen and prove another callback on that old paused route is byte-identical. With backend `estimated_minutes = 17`, keep the old paused epoch/route as the prior functioning route while a fresh candidate epoch/route uses base 17 and `gate_resume_conservative`; install/verify, exact old→new `dualV2`, prior drain/`cutoverReady`, registration, activation, and local cutover run in that order. Inject crashes, callback/barrier races, and lost registration/activation responses at every boundary. The first callback on the new route clears `resumeBoundaryPending` with only its bounded metadata diff and zero effects; the second reports cumulative estimate from base 17. The old route is retired/tombstoned only after the new local active commit. Race gate close during registration and activation; backend 200 paused preserves the prior local selection and prior functioning monitor (`.v1` during initial migration, `.v2` during later replacement), creates no locally active new epoch, and recovery waits for another open snapshot. Test gate close does not stop an earned monitor merely because task/reflection closes.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringConservativeResumeTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' test
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_epoch_registration.py tests/test_metering_epoch_phase3_vectors.py tests/test_metering_epoch_sample_adapter.py
```

Expected RED: current iOS stop-on-pause behavior removes monitoring and the invented old exact-rebase path cannot satisfy the new route assertions.

**Minimal GREEN:** Gate close changes epoch status to paused and records high-water/excluded counters only; it does not call scheduler stop. A later authoritative open state creates a candidate epoch and route in one transaction with registration reason `.gateResumeConservative`, base only from `EarnedTimeRuntime.estimatedMinutes`, and `resumeBoundaryPending = true`, while preserving the prior paused route until candidate cutover. Paused epochs never return active. The candidate completes Task 11's `dualV2` plus prior-drain/`cutoverReady` handoff; Task 12 discards the first callback on the fresh route and clears the boundary; no raw threshold is manufactured. Backend `epoch_status != active` prevents local cutover even on HTTP 200 and leaves the prior route intact.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringConservativeResumeTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' -only-testing:'Evlin iOSTests/EarnedTimeStoreTests' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' test
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_epoch_registration.py tests/test_metering_epoch_phase3_vectors.py tests/test_metering_epoch_sample_adapter.py tests/test_metering_epoch_lifespan.py
```

Expected GREEN: paused-to-open uses backend-authoritative base, fresh epoch+route, one discard, no stop-on-gate-close, and full gate-race coverage.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/BigKidStatePoller.swift' 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' 'Evlin iOS/Services/EarnedMeteringCallback.swift' 'Evlin iOSTests/MeteringConservativeResumeTests.swift' 'Evlin iOSTests/EarnedMeteringCallbackTests.swift' 'Evlin iOSTests/BigKidStatePollerTests.swift' 'Evlin iOSTests/EarnedTimeStoreTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: resume metering with conservative replacement'
```

---

## Task 18: Wire Production Metering And A Real V30 Encoder

**Repository:** iOS.

**Interfaces:** Consumes Tasks 2-17 and the existing app/DAM entry points. Produces exact app/DAM composition, real names-only callback routing, real child-state reconciliation, and a production encoder callable by Task 19. Push persists work only and never owns monitoring.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringProductionComposition.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringV30ScenarioEncoder.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Evlin_iOSApp.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/CommandPoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetScheduler.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringProductionIntegrationTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringV30ProductionEncoderTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

`/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/APIClient.swift` is explicitly excluded; preserve its dirty bytes and stage no hunk from it.

**TDD RED:** First add a link test that references the exact production factories and `MeteringV30ScenarioEncoder.writeScenario(to:)`; because both files are genuinely absent, RED must be `cannot find 'MeteringProductionComposition' in scope` and `cannot find 'MeteringV30ScenarioEncoder' in scope`, not a behavioral assertion against a test fake. Then drive real v1 callback, advertisement 1/offline/restart, advertisement 2 registration, v2 start/verify/activate, real v2 callback, and stale v1. Assert production callbacks reach durable work and real effect adapters. Require app and DAM both to invoke pendingStart recovery; Push has no center factory. Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringProductionIntegrationTests' -only-testing:'Evlin iOSTests/MeteringV30ProductionEncoderTests' test
```

Expected RED: both exact missing-symbol compiler diagnostics appear.

**Minimal GREEN:** Implement exact composition:

```swift
nonisolated enum MeteringProductionComposition {
    @MainActor static func makeRecoveryDriver(
        baseURL: URL,
        role: MeteringProcessRole,
        instanceID: UUID,
        store: DeviceEpochStore = .shared,
        center: any MeteringDeviceActivityCenter = SystemMeteringDeviceActivityCenter(),
        transport: any MeteringHTTPTransport = URLSession.shared,
        clock: any MeteringClock = MeteringRuntimeClock.live()
    ) -> EarnedMeteringRecoveryDriver {
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: clock)
        let identity = MeteringProcessIdentity(role: role, instanceID: instanceID)
        let installer = DatedRouteInstaller(store: store, center: center, processIdentity: identity, clock: clock)
        return EarnedMeteringRecoveryDriver(store: store, delivery: delivery, installer: installer, center: center, processIdentity: identity, clock: clock)
    }

    nonisolated static func makeCallback(
        store: DeviceEpochStore = .shared,
        clock: any MeteringClock = MeteringRuntimeClock.live()
    ) -> EarnedMeteringCallback {
        EarnedMeteringCallback(store: store, clock: clock)
    }
}
```

The app uses role `.app` from `Evlin_iOSApp` active/onAppear recovery. DAM uses `.deviceActivityMonitor` in both `intervalDidStart` and `eventDidReachThreshold`, constructs `MeteringAppleCallback(activityName:eventName:observedAt:)`, and calls the production callback before every earned side effect. Both obtain the base URL from the exact shared App Group key `evlin.baseURL` and owner from `evlin.childId`; absence leaves durable work untouched. Command and state pollers feed authoritative runtime into planning. Existing v1 path remains until Task 11 ratchet. No factory permits `.deviceActivityMonitor` for Push and no NSE call owns `startMonitoring`.

Implement the encoder:

```swift
nonisolated enum MeteringV30ScenarioEncoder {
    static let ownerID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000030")!
    static let epochID = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000030")!
    static let routeID = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000030")!
    static let enforcementSetID = UUID(uuidString: "cccccccc-0000-0000-0000-000000000030")!
    static let usageDate = "2026-07-15"
    static let timezone = "America/New_York"
    static let policyRevision = "30000000-0000-0000-0000-000000000030:40000000-0000-0000-0000-000000000030"
    static let selectionDigest = String(repeating: "3", count: 64)
    static let startedAt = Date(timeIntervalSince1970: 1_784_124_300)
    static let verifiedAt = Date(timeIntervalSince1970: 1_784_124_302)
    static let v2ObservedAt = Date(timeIntervalSince1970: 1_784_124_600)
    static let staleV1ObservedAt = Date(timeIntervalSince1970: 1_784_124_900)

    static let fileNames = [
        "01-v1.json", "02-registration.json", "03-activation.json",
        "04-v2.json", "05-stale-v1.json", "manifest.json",
    ]

    static func writeScenario(to directory: URL) throws -> [URL]
}
```

It constructs the production Task 4 DTOs from those exact V39 constants and writes sorted-key, ISO-8601 bytes. The scenario is pool 20/device cap 10: metadata-free `01-v1` reports threshold/estimate 5; registration uses authoritative base 5; activation uses the fixed route; `04-v2` reports route threshold 5 and cumulative estimate 10; metadata-free `05-stale-v1` reports threshold/estimate 10. Registration and activation use their exact request DTO bodies, and activation/v2 use the same route UUID. `manifest.json` records filename, byte count, and SHA-256 for exactly the five request files; it lists itself only as the manifest schema/version and never attempts a self-hash. The test requires exactly six nonempty regular files, recomputes all five request hashes, and verifies the manifest separately. Add `MeteringProductionComposition.swift` to DAM, keep `MeteringV30ScenarioEncoder.swift` app-only, and add neither to Push.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringProductionIntegrationTests' -only-testing:'Evlin iOSTests/MeteringV30ProductionEncoderTests' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
```

Expected GREEN: production app/DAM composition links, both recover pendingStart, V30 bytes are nonempty and hashed, and v1 remains functional until verified activation.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/MeteringProductionComposition.swift' 'Evlin iOS/Services/MeteringV30ScenarioEncoder.swift' 'Evlin iOS/Evlin_iOSApp.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOS/Services/BigKidStatePoller.swift' 'Evlin iOS/Services/CommandPoller.swift' 'Evlin iOS/Services/EarnedBudgetArming.swift' 'Evlin iOS/Services/EarnedBudgetScheduler.swift' 'Evlin iOS/Services/EarnedSampleReporter.swift' 'Evlin iOSTests/MeteringProductionIntegrationTests.swift' 'Evlin iOSTests/MeteringV30ProductionEncoderTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
test -z "$(git diff --cached --name-only | rg '^Evlin iOS/Services/APIClient.swift$' || true)"
git commit -m 'feat: wire production metering and V30 encoder'
```

---

## Task 19: Verify V30 Production Bytes Across Swift And Backend

**Repository:** Backend.

**Interfaces:** Consumes Task 18's production encoder and Task 3's real routes. Produces one guarded orchestrator that passes the exact Swift-emitted bytes to a disposable PostgreSQL backend test. Hand-built Python request bodies do not satisfy this task.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_metering_v30_cross_stack.sh`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_v30_cross_stack.py`

**TDD RED:** Create the backend test first. It requires `EVLIN_V30_ARTIFACT_DIR`, exactly six regular nonempty files, exact manifest byte counts/SHA-256, and no extra JSON. Run it without the orchestrator artifact:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_v30_cross_stack.py
```

Expected RED: hard failure `EVLIN_V30_ARTIFACT_DIR is required`; no skip is allowed.

**Minimal GREEN:** Implement `scripts/run_metering_v30_cross_stack.sh` with this exact interface:

```bash
#!/usr/bin/env bash
set -euo pipefail
IOS=/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
BACKEND=/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
ARTIFACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/evlin-v30.XXXXXX")"
SIM_RUNTIME='com.apple.CoreSimulator.SimRuntime.iOS-26-3'
SIM_RUNTIME_VERSION="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtime = next((r for r in json.load(sys.stdin)["runtimes"] if r["identifier"] == sys.argv[1]), None)
assert runtime is not None and runtime.get("isAvailable", True)
print(runtime["version"])
' "$SIM_RUNTIME")"
test "$SIM_RUNTIME_VERSION" = '26.3.1'
SIM_UDID="$(xcrun simctl list devices -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"].get(sys.argv[1], [])
matches = [d for d in devices if d["name"] == "iPhone 17 Pro" and d.get("isAvailable", False)]
assert len(matches) == 1, matches
print(matches[0]["udid"])
' "$SIM_RUNTIME")"
test -n "$SIM_UDID"
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_UDID" -b
xcrun simctl spawn "$SIM_UDID" launchctl setenv EVLIN_V30_ARTIFACT_DIR "$ARTIFACT_DIR"
test "$(xcrun simctl spawn "$SIM_UDID" launchctl getenv EVLIN_V30_ARTIFACT_DIR)" = "$ARTIFACT_DIR"
cleanup() {
  xcrun simctl spawn "$SIM_UDID" launchctl unsetenv EVLIN_V30_ARTIFACT_DIR >/dev/null 2>&1 || true
  rm -rf "$ARTIFACT_DIR"
}
trap cleanup EXIT

cd "$IOS"
xcodebuild \
  -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -parallel-testing-enabled NO \
  IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' \
  -only-testing:'Evlin iOSTests/MeteringV30ProductionEncoderTests/testWritesCrossStackArtifact' test

test "$(find "$ARTIFACT_DIR" -type f | wc -l | tr -d ' ')" -eq 6
test "$(find "$ARTIFACT_DIR" -type f -size +0c | wc -l | tr -d ' ')" -eq 6
find "$ARTIFACT_DIR" -type f -print0 | sort -z | xargs -0 shasum -a 256

cd "$BACKEND"
export EVLIN_V30_ARTIFACT_DIR="$ARTIFACT_DIR"
.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_v30_cross_stack.py
```

The Python test reads each raw file with `Path.read_bytes()`, verifies the Swift manifest before JSON decoding, and sends those bytes unchanged as HTTP request content to FastAPI's real registration, activation, and sample routes. It seeds the exact V39 owner/config/cap/enforcement IDs, pool 20, device cap 10, and a BigKid bank value of 120, then pins `screen_time_clock.now_utc()` to `2026-07-15T14:20:00Z`. Sequence: v1 200 to estimate 5; registration 200 with backend device still version 1; activation 200 with version 2; v2 200 to estimate 10 and cap lock; stale v1 terminal `legacy_after_v2`. Query exact production symbols `EarnedTimeMeteringEpoch`, `EarnedTimeSample`, `EarnedTimeDeviceDay`, `EarnedTimeDay`, `EarnedTimeLockCommand`, and `Command`, plus `BigKidStore.get_state(device.id).minutes_left`. Require one activated epoch, exactly two sample rows (v1 and v2), device/child estimates 10, one cap receipt/command, bank value 120, and byte/row snapshots unchanged by stale v1. The existing runner supplies a unique local disposable `EVLIN_TEST_DATABASE_URL` and refuses a non-local database.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
bash scripts/run_metering_v30_cross_stack.sh
```

Expected GREEN: Swift encoder runs in the simulator, six files and hashes are non-vacuous, and those exact bytes traverse backend routes and database rows.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py
```

Expected full GREEN: the complete disposable-database regression set passes without skips.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
git add scripts/run_metering_v30_cross_stack.sh tests/test_metering_v30_cross_stack.py
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
IOS_TASK18_SHA="$(git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS log --format='%H%x09%s' "$(cat /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/.superpowers/evidence/metering-phase3/ios-base-sha.txt)..HEAD" | awk -F '\t' '$2 == "feat: wire production metering and V30 encoder" { print $1 }')"
test "$(printf '%s\n' "$IOS_TASK18_SHA" | rg -c '^[0-9a-f]{40}$')" -eq 1
git commit -m 'test: verify V30 exact bytes across the stack' -m "Phase3-Depends-On: $IOS_TASK18_SHA"
```

---

## Task 20: Surface Bounded Metering Coverage

**Repository:** iOS.

**Interfaces:** Consumes the real eight-date installer, `excessiveActivities`, app-run refresh, and strict callback boundary. Produces explicit `ready`, `installLimited`, and `coverageExhausted` state. Coverage failure has zero metering effects and never fails closed with an earned-time lock.

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

**TDD RED:** Start from Task 10's real eight installs, advance one canonical day while app runs, and require one new tail start with existing seven unchanged. Simulate force-quit until `readyThroughUsageDate + 1`, inject unknown/uncovered callbacks, reopen/refill, and inject `MonitoringError.excessiveActivities` after four verified routes. Assert actual ready-through/error state, no destructive stop, zero usage/queue/backend/earned/shield effects while uncovered, and byte-identical manual/taskPause/reflection/admin/block/limit/per-app records. An existing earnedTime source may be removed only through its exact Task 14 envelope CAS; no new earned lock is applied.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringCoverageIntegrationTests' test
```

Expected RED: production readiness has no coverage-exhausted projection and legacy arming replaces monitors.

**Minimal GREEN:** On every app authoritative poll and activation, reconcile required dates today through +7. Derive status only from verified center state. `excessiveActivities` records `errorCode = "excessiveActivities"`, preserves every verified route, and leaves pending work retryable. If canonical today is later than ready-through, persist `.coverageExhausted`; Task 12 rejects unknown/uncovered callbacks before mutation. Reopen appends only missing dates with stable existing IDs. Manual, task-pause, reflection, admin, block, limit, and per-app sources remain independent.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringCoverageIntegrationTests' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' test
```

Expected GREEN: horizon refill is append-only; exhausted callbacks are zero-effect; excessive-activities posture is conservative and explicit.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedBudgetArming.swift' 'Evlin iOS/Services/EarnedBudgetScheduler.swift' 'Evlin iOS/Services/BigKidStatePoller.swift' 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'Evlin iOS/Services/EarnedMeteringRecoveryDriver.swift' 'Evlin iOSTests/MeteringCoverageIntegrationTests.swift' 'Evlin iOSTests/EarnedBudgetArmingTests.swift' 'Evlin iOSTests/BigKidStatePollerTests.swift' 'Evlin iOSTests/EarnedTimeStoreTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
BACKEND_TASK19_SHA="$(git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend log --format='%H%x09%s' "$(cat .superpowers/evidence/metering-phase3/backend-base-sha.txt)..HEAD" | awk -F '\t' '$2 == "test: verify V30 exact bytes across the stack" { print $1 }')"
test "$(printf '%s\n' "$BACKEND_TASK19_SHA" | rg -c '^[0-9a-f]{40}$')" -eq 1
git commit -m 'feat: surface bounded metering coverage' -m "Phase3-Depends-On: $BACKEND_TASK19_SHA"
```

---

## Task 21: Recover Every Metering Process Entry Point

**Repository:** iOS.

**Interfaces:** Consumes exact Task 18 composition. Produces concrete app and DAM entry types, all cold-reopen triggers, and target membership closure before demolition. Push can persist queued policy/work but has no monitor entry.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/MeteringProcessEntries.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Evlin_iOSApp.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinPushApplier/NotificationService.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/Auth/AuthService.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/FamilyGoneDetector.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Views/Child/BigKid/BigKidRootView.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringColdReopenRecoveryTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringTargetMembershipTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS.xcodeproj/project.pbxproj`

**TDD RED:** Seed each persisted work phase, launch only the app entry, then only the DAM entry, and require due recovery. Cover app active/onAppear, DAM interval start/threshold, auth sign-out, family gone, root owner change, Push policy persistence, owner change during async response, offline restart, future-day install, expired install claim adoption, shield envelope, identity cleanup, rollover, and tombstone collection. Assert Push never creates a center or invokes start/stop. Compile all three targets and require exact membership. Pin the current zero-availability-guard baseline for `NotificationService.swift`: source tests reject `#available`/`@available` gates for iOS 18 through 26 and reject every Task 21 symbol whose SDK declaration is introduced after iOS 17.6. An unavailable unguarded symbol must fail the 17.6 build; an availability wrapper must fail the source test.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringColdReopenRecoveryTests' -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests' test
```

Expected RED: named app/DAM entries do not exist and DAM cannot independently adopt pendingStart.

**Minimal GREEN:** Implement exact types in the shared source:

```swift
@MainActor
final class AppMeteringEntry {
    static let shared = AppMeteringEntry()
    init(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios"),
        store: DeviceEpochStore = .shared,
        center: any MeteringDeviceActivityCenter = SystemMeteringDeviceActivityCenter(),
        transport: any MeteringHTTPTransport = URLSession.shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        instanceID: UUID = UUID()
    )
    func recoverIfConfigured() async
}

@MainActor
final class DAMMeteringEntry {
    static let shared = DAMMeteringEntry()
    init(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios"),
        store: DeviceEpochStore = .shared,
        center: any MeteringDeviceActivityCenter = SystemMeteringDeviceActivityCenter(),
        transport: any MeteringHTTPTransport = URLSession.shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        instanceID: UUID = UUID()
    )
    func recoverIfConfigured() async
    func handle(activityName: String, eventName: String, observedAt: Date) throws -> EarnedMeteringCallbackOutcome
}
```

Both read exact `evlin.baseURL` and `evlin.childId`; malformed or absent values no-op without deleting work. `AppMeteringEntry` calls Task 18 factory with `.app`; `DAMMeteringEntry` calls it with `.deviceActivityMonitor` and retains one instance ID for process lifetime. `Evlin_iOSApp` calls app recovery on appear/active. DAM calls recovery on both callback kinds and routes earned names through `handle` before effects. Push may write root policy/work under the lock but the source scan must prove it has no `DeviceActivityCenter`, `DatedRouteInstaller`, `startMonitoring`, or `stopMonitoring` token. It also proves no `#available`/`@available` gate can conceal an iOS-26-only path from the 17.6 build, and records the SDK availability of every newly referenced Push API.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringColdReopenRecoveryTests' -only-testing:'Evlin iOSTests/MeteringTargetMembershipTests' -only-testing:'Evlin iOSTests/MeteringProductionIntegrationTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'Evlin iOS' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
```

Expected GREEN: app and DAM independently recover all due states; target closures compile; Push remains a non-owner.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/MeteringProcessEntries.swift' 'Evlin iOS/Evlin_iOSApp.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'EvlinPushApplier/NotificationService.swift' 'Evlin iOS/Services/Auth/AuthService.swift' 'Evlin iOS/Services/FamilyGoneDetector.swift' 'Evlin iOS/Views/Child/BigKid/BigKidRootView.swift' 'Evlin iOSTests/MeteringColdReopenRecoveryTests.swift' 'Evlin iOSTests/MeteringTargetMembershipTests.swift' 'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'feat: recover every metering process entry point'
```

---

## Task 22: Demolish R-16 T1 Arm Signature Churn

**Repository:** iOS.

**Interfaces:** Consumes six-field generation identity, exact raw-byte digest, real installer no-churn proof, and V01/V02/V03/V06/V07/V24. Produces absence of scalar arm signatures and decode/re-encode fingerprints.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetArmingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT1DemolitionTests.swift`

**TDD RED:** Add a source architecture test requiring absence of `armSignatureKey`, `makeArmSignature`, `shouldStartMonitoring`, `previousArmSignature`, `selectionFingerprint`, `currentArmSignature`, and the persisted `armSignature` generation field. Pair it with Task 10's starts `8,0`/stops `0` proof.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT1DemolitionTests' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests' test
```

Expected RED: the source test finds `armSignatureKey` in `EarnedBudgetArming.swift`.

**Minimal GREEN:** Delete exactly the named symbols, scalar writes/migration, and direct obsolete assertions. Generation decisions use `MeteringEpochContract.selectionDigest(persistedBytes:)` and compare `MeteringGenerationKey`. Add no debounce, last-arm digest, rearm-needed state, or offset veto.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT1DemolitionTests' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests' -only-testing:'Evlin iOSTests/MeteringCoverageIntegrationTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' test
```

Expected GREEN: one generation/eight routes survive polling and mutable date/offset/estimate state.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedBudgetArming.swift' 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOSTests/EarnedBudgetArmingTests.swift' 'Evlin iOSTests/EarnedTimeStoreTests.swift' 'Evlin iOSTests/MeteringT1DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove earned arm signature churn'
```

---

## Task 23: Demolish R-16 T2 Raw Threshold Ceiling

**Repository:** iOS.

**Interfaces:** Consumes immutable route provenance, tombstones, owner/epoch trust, and physical bounds. Produces absence of the inline `n > min(pool, cap)` stale-ladder defense without weakening zero-effect rejection.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedMeteringCallbackTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT2DemolitionTests.swift`

**TDD RED:** Require `stale_ladder_drop` and its pool/cap raw ceiling branch to be absent. Prove a delayed event planned by its immutable route remains valid across mutable usage/remaining changes that do not alter the six-field generation. A real policy revision change must create a new generation, retire/tombstone the old route, and make its delayed event zero-effect; an independently old-date tombstone remains zero-effect as well.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT2DemolitionTests' test
```

Expected RED: DAM source still contains `stale_ladder_drop`.

**Minimal GREEN:** Delete only that branch and diagnostic. Preserve strict route/owner/day/epoch/policy/namespace and elapsed-time checks. Add no raw ceiling, quarantine, or renamed guard.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT2DemolitionTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' -only-testing:'Evlin iOSTests/MeteringRolloverRecoveryTests' test
```

Expected GREEN: delayed trusted callback is accepted and stale routes remain zero-effect.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/EarnedMeteringCallbackTests.swift' 'Evlin iOSTests/MeteringT2DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove stale raw threshold ceiling'
```

---

## Task 24: Demolish R-16 T3 Fresh-At-Fire Gate

**Repository:** iOS.

**Interfaces:** Consumes strict callback trust, epoch gate status, terminal event plan, override semantics, and shield envelope. Produces absence of `shouldApplyEarnedShieldFresh` and any renamed freshness window.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedGateTautologyTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedShieldEffectStoreTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT3DemolitionTests.swift`

**TDD RED:** Require helper and DAM call absence. Drive early terminal event to strict rejection, delayed trusted terminal event through the real effect envelope, paused/reflection event to zero effects, and override to source-specific suppression.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT3DemolitionTests' test
```

Expected RED: production still contains `shouldApplyEarnedShieldFresh`.

**Minimal GREEN:** Delete the helper, branch, and obsolete direct assertions. Trusted terminal route plus active epoch invokes Task 14; no freshness or first-threshold flag replaces it.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT3DemolitionTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' -only-testing:'Evlin iOSTests/MeteringConservativeResumeTests' test
```

Expected GREEN: early/paused events remain zero-effect; delayed trusted exhaustion creates one recoverable envelope.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedSampleReporter.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/EarnedGateTautologyTests.swift' 'Evlin iOSTests/EarnedShieldEffectStoreTests.swift' 'Evlin iOSTests/MeteringT3DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove earned fresh-at-fire gate'
```

---

## Task 25: Demolish The Phase 3 Portion Of R-16 T4

**Repository:** iOS.

**Interfaces:** Consumes trusted local lock, exact effect envelope/CAS, and P3V01. Produces absence of the 600-second/five-minute backend headroom veto; backend correction releases only recorded exact earned provenance.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedGateTautologyTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedShieldEffectStoreTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT4DemolitionTests.swift`

**TDD RED:** Require `backendVetoesSelfLock`, `freshnessSeconds`, and `marginMinutes` to be absent from self-lock. Feed fresh backend headroom before a trusted terminal callback and require local lock; then apply correction and require exact CAS release. A newer manual/taskPause mutation makes release no-op.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT4DemolitionTests' test
```

Expected RED: old backend veto suppresses the trusted lock.

**Minimal GREEN:** Delete helper, branch, and old assertions. Route correction to `EarnedShieldEffectStore.release(operationID:expectedOwner:)`; retain no waiting/headroom flag.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT4DemolitionTests' -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' -only-testing:'Evlin iOSTests/ActiveLockStoreTests' test
```

Expected GREEN: trusted lock is immediate; correction removes only exact earnedTime provenance; conflicts preserve bytes.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedSampleReporter.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/EarnedGateTautologyTests.swift' 'Evlin iOSTests/EarnedShieldEffectStoreTests.swift' 'Evlin iOSTests/MeteringT4DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove earned backend headroom veto'
```

---

## Task 26: Demolish R-16 T11 Device Plus-Five Heuristic

**Repository:** iOS.

**Interfaces:** Consumes strict elapsed-time check with 30-second default/60-second maximum jitter. Produces absence of `EarnedThresholdPlausibility.toleranceMinutes = 5`. This is the iOS T11 mechanism; backend T5 was removed and evidenced in Phase 2.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT11DemolitionTests.swift`

**TDD RED:** Require `EarnedThresholdPlausibility`, `toleranceMinutes`, and elapsed-plus-five arithmetic absence. Exercise immediate t5 rejection; elapsed 269/270/271 with 30-second jitter; 60-second configured boundary accepted; 61-second configuration rejected; one-day delayed callback accepted.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT11DemolitionTests' test
```

Expected RED: `EarnedThresholdPlausibility.toleranceMinutes` remains.

**Minimal GREEN:** Delete enum, call sites, and obsolete assertions. Both legacy and v2 lanes use `MeteringEpochContract.callbackVerdict`; add no whole-bucket allowance.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT11DemolitionTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/MeteringProductionIntegrationTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' test
```

Expected GREEN: strict upper bounds hold and there is no lower-age rejection.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedTimeStore.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/EarnedTimeStoreTests.swift' 'Evlin iOSTests/MeteringT11DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove earned plus-five heuristic'
```

---

## Task 27: Demolish R-16 T7 Counter Recovery Flags

**Repository:** iOS.

**Interfaces:** Consumes committed paused epoch high-water, `excludedWhilePausedMinutes`, and one `resumeBoundaryPending`. Produces absence of legacy pending-uncounted/counter-recovery state and same-day-decrease latch.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT7DemolitionTests.swift`

**TDD RED:** Require absence of `counterRecoveryRequired`, `pendingUncountedReconciliation`, `requiresCounterRecovery`, their persisted prefixes, and rearm/decrease exceptions. Feed paused counted-false response, restart, conservative replacement, and two thresholds; require terminal queue cleanup and exactly one boundary discard.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT7DemolitionTests' test
```

Expected RED: persisted prefixes and poller flag remain.

**Minimal GREEN:** Delete exactly the named flags, producers, consumers, prefixes, and obsolete assertions. Keep `resumeBoundaryPending` only inside `DeviceDailyEpoch`; add no recovery latch.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT7DemolitionTests' -only-testing:'Evlin iOSTests/MeteringConservativeResumeTests' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' test
```

Expected GREEN: pause/restart converges through one epoch-scoped boundary and no legacy recovery state.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOS/Services/EarnedSampleReporter.swift' 'Evlin iOS/Services/BigKidStatePoller.swift' 'Evlin iOSTests/EarnedTimeStoreTests.swift' 'Evlin iOSTests/EarnedSampleReporterTests.swift' 'Evlin iOSTests/BigKidStatePollerTests.swift' 'Evlin iOSTests/MeteringT7DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'refactor: remove earned counter recovery flags'
```

---

## Task 28: Retire Duplicate Earned Activity Lifecycle Without Removing V1 Behavior

**Repository:** iOS.

**Interfaces:** Consumes compile-green Task 21 entries, `LegacyCompatibilityMonitorState`, route/tombstone/install authority, identity cleanup, and one-shot legacy import. Produces deletion of the `EarnedActivityGeneration` implementation and duplicate keys while preserving functional v1 callbacks until each owner's verified v2 activation.

**Files:**

- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/Auth/AuthService.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetArming.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedBudgetScheduler.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedSampleReporter.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/DeviceEpochStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/AuthServiceTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetArmingTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedBudgetSchedulerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedSampleReporterTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT8DemolitionTests.swift`

**TDD RED:** First build app, DAM, Push, and replacement tests while the old type still exists. Then require absence of `EarnedActivityGeneration`, `evlin.earned.activityLifecycle`, `evlin.earned.activityBreadcrumbs`, and `evlin.earned.activeActivityName` as live authorities. Construct each forbidden test token from string segments (for example `let oldType = ["Earned", "Activity", "Generation"].joined()`) so the architecture test does not match itself during the final repository scan. Seed a pre-Phase3 lifecycle with pending/retiring/active, legacy `evlin.earned.budget`, scalar, and breadcrumb names; one schema-v4 migration must capture exact provenance and deduplicated stop targets before key deletion. Repeat offline, advertisement 1, registration-only, failed-v2, and restart v1 tests to prove behavior remains functional.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringColdReopenRecoveryTests' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT8DemolitionTests' test
```

Expected RED: pre-demolition compile is green, then the architecture test finds the enum and duplicate keys.

**Minimal GREEN:** First migrate every listed consumer to `DeviceEpochStoreState.legacy`, route/install APIs, and process entries while leaving the old enum implementation present. Before deleting it, run the app/DAM/Push builds and `MeteringV2ActivationTests`, and require `rg -l 'EarnedActivityGeneration'` to name only the old declaration plus migration-specific tests being replaced in this task. Only after that intermediate compile is green may the same task delete the enum. Keep a private schema-specific legacy decoder in `DeviceEpochStore` that runs only when schema-v4 root is absent, commits `LegacyCompatibilityMonitorState` plus stop work, verifies readback, then deletes old keys. It cannot authorize callbacks or overwrite an existing root. V1 callbacks use `LegacyCompatibilityMonitorState` and remain active until Task 11 activation.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
test -z "$(rg -l 'EarnedActivityGeneration' 'Evlin iOS' 'EvlinDeviceActivityMonitor' 'Evlin iOSTests' --glob '*.swift' || true)"
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT8DemolitionTests' -only-testing:'Evlin iOSTests/MeteringColdReopenRecoveryTests' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests' -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' -only-testing:'Evlin iOSTests/AuthServiceTests' test
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'Evlin iOS' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
xcodebuild -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Debug -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
```

Expected GREEN: all old consumers compile against replacements, v1 remains functional in pre-activation states, and duplicate lifecycle authority is absent.

**Full GREEN before staging:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
```

Expected full GREEN: every test present at this commit passes.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOS/Services/Auth/AuthService.swift' 'Evlin iOS/Services/EarnedBudgetArming.swift' 'Evlin iOS/Services/EarnedBudgetScheduler.swift' 'Evlin iOS/Services/EarnedSampleReporter.swift' 'Evlin iOS/Services/EarnedTimeStore.swift' 'Evlin iOS/Services/DeviceEpochStore.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOSTests/AuthServiceTests.swift' 'Evlin iOSTests/EarnedBudgetArmingTests.swift' 'Evlin iOSTests/EarnedBudgetSchedulerTests.swift' 'Evlin iOSTests/EarnedSampleReporterTests.swift' 'Evlin iOSTests/EarnedTimeStoreTests.swift' 'Evlin iOSTests/MeteringT8DemolitionTests.swift'
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'refactor: retire duplicate earned activity lifecycle'
```

---

## Task 29: Add The Phase 3 Completion Verifier

**Repository:** iOS.

**Interfaces:** Consumes immutable baseline files, exact 30-subject manifest, both Git histories, all automated suites, real V30 harness, all six Release products, and R-16 hash. Produces raw logs, hashes, commit/order proof, product manifest, and machine-readable automated status. It cannot mark physical gates passed.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase3_completion.sh`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/test_verify_metering_phase3_completion.py`

**TDD RED:** Run a real host-side subprocess test before the script exists. The
test invokes the actual shell verifier against temporary fixture repositories;
it is not an app-hosted XCTest and does not copy verifier logic. Fixtures must
cover missing subject, duplicate subject, duplicate SHA, reversed same-repo
ancestry, absent/wrong cross-repo dependency trailer, base not ancestor, empty
log, a content change beneath an existing untracked path with unchanged name,
zero Release products, missing exact XCTest executable, DEBUG token in
Release, wrong fixture hash, and a report that claims a physical pass. Also
assert Task 29 pre-report mode expects Tasks 01-29 exactly once and final mode
expects Tasks 01-30 exactly once.

The real subprocess test uses one explicit verifier-test-only interface:

```text
METERING_PHASE3_VERIFIER_TEST_MODE=1
METERING_PHASE3_FIXTURE_ROOT=<temporary directory>
METERING_PHASE3_COMMAND_SHIM=<temporary executable>
```

In test mode the fixture root contains synthetic `ios`, `backend`, `rulebook`,
and `evidence` trees, and the command shim receives stable gate IDs and writes
their synthetic raw logs. The verifier writes an access trace of every resolved
path and command ID; the test asserts every absolute path is below the temporary
fixture root and neither real repository nor the real rulebook was read. Test
mode is rejected unless all three variables are present and the fixture contains
a `.metering-phase3-verifier-fixture` marker. In normal `pre-report`/`final`
mode the script rejects all three variables, hard-codes the real repository and
rulebook paths, and executes the real commands. No production-mode root or
command-runner injection exists.

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest -q scripts/test_verify_metering_phase3_completion.py
```

Expected RED: script is missing and fixture invocation exits 127.

**Minimal GREEN:** Implement this public interface:

```bash
scripts/verify_metering_phase3_completion.sh pre-report
REPORT_COMMIT="$(git rev-parse HEAD)"
scripts/verify_metering_phase3_completion.sh final "$REPORT_COMMIT"
```

The script uses `set -euo pipefail`, selects the fixture-only interface above or
fixed production paths before any read, reads immutable bases from
`.superpowers/evidence/metering-phase3/{ios,backend}-base-sha.txt`, and refuses a
base that is not an ancestor. Its ordered manifest contains task number,
repository, and exact subject from this plan. For each included task it requires
exactly one matching commit in `base..HEAD`, one unique SHA globally, and
same-repository ancestry in task order. It verifies these required
cross-repository trailers:

```text
Task 03 backend depends on Task 02 iOS
Task 04 iOS depends on Task 03 backend
Task 07 backend depends on Task 06 iOS
Task 08 iOS depends on Task 07 backend
Task 19 backend depends on Task 18 iOS
Task 20 iOS depends on Task 19 backend
```

The same stdlib parser used by the fixture test mechanically pins this plan to
30 task headings, 30 commit commands/unique subjects, 51 `Create` declarations,
142 `Modify` declarations, 193 total declarations, 95 unique declared paths,
94 literal `xcodebuild` commands. The Release scheme build is one dependency-
graph invocation rather than an invalid per-target loop. It rejects a changed count unless the plan,
fixture expectation, and review map are revised together; prose-only arithmetic
does not satisfy this gate.

`pre-report` runs after Task 29 commit and proves 01-29; it does not expect Task 30. `final` proves 01-30, requires its argument equal the unique Task 30 commit, requires that commit to contain the report, and records the report blob hash plus commit SHA in a hash-verified external post-commit attestation. The attestation is deliberately not described as a committed or self-authenticating artifact; downstream phases must rerun final mode against the named report commit and bind the resulting attestation hash in their own committed report. This explicitly avoids the impossible claim that a committed report embeds its own commit SHA.

The verifier writes every command's unfiltered stdout/stderr to a nonempty file below `.superpowers/evidence/metering-phase3/logs`, then writes `raw-log-sha256.txt` only after checking each file is nonempty. It runs:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python -m pytest -q tests/test_metering_epoch_vector_contract.py
.venv/bin/python scripts/run_limits_db_regression.py tests/test_target_gate_resume_helpers.py
.venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_epoch_models.py tests/test_metering_epoch_registration.py tests/test_metering_epoch_sample_adapter.py tests/test_metering_epoch_phase2_integration.py tests/test_metering_epoch_lifespan.py tests/test_metering_epoch_phase3_vectors.py
bash scripts/run_metering_v30_cross_stack.sh

cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -skip-testing:'Evlin iOSTests/ProfileSnapshotTests' test
```

The iPad run excludes only `ProfileSnapshotTests`, whose checked-in baselines
are intentionally pinned to iPhone 17 Pro and iPad (A16). The iPhone run still
executes that suite; this exception is recorded in raw evidence and cannot be
used to skip a Phase 3 test.

Build Release before any binary scan using a fresh derived directory:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
DERIVED="$PWD/.superpowers/evidence/metering-phase3/DerivedData-Release"
rm -rf "$DERIVED"
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build-for-testing
```

The shared `Evlin iOS` scheme's `build-for-testing` dependency graph must emit
all six products below into this one DerivedData tree. No `-target` command may
combine with `-derivedDataPath`; absence of any product fails before scanning.

Assert these exact six nonempty Mach-O products, including the corrected test executable path:

```text
Release-iphoneos/Evlin iOS.app/Evlin iOS
Release-iphoneos/Evlin iOS.app/PlugIns/EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor
Release-iphoneos/Evlin iOS.app/Extensions/EvlinDeviceActivityReport.appex/EvlinDeviceActivityReport
Release-iphoneos/Evlin iOS.app/PlugIns/EvlinShieldConfig.appex/EvlinShieldConfig
Release-iphoneos/Evlin iOS.app/PlugIns/EvlinPushApplier.appex/EvlinPushApplier
Release-iphoneos/Evlin iOS.app/PlugIns/Evlin iOSTests.xctest/Evlin iOSTests
```

Require product count exactly six, each `test -s`, and each `file` output contains `Mach-O`. The verifier fixture pins these same six literal paths, including `Extensions/EvlinDeviceActivityReport.appex` while the other app extensions remain under `PlugIns`; wrong-directory fixtures fail. Run `strings` on all six and fail if any contains `DebugAppGroupMeteringClock` or `evlin.metering.debugClockNow`. Separately preprocess/compile the Release source and require the DEBUG provider symbol absent, so the binary scan cannot pass vacuously through a missing product. Hash the six products, both vector fixtures, every raw log, commit manifest, target-membership manifest, status-before files, dirty-diff-before hashes, path-plus-type/mode/content untracked manifests and their hashes, and R-16 before/after hashes. Final mode regenerates the untracked manifests with the same evidence-directory exclusion and requires byte identity, so edits beneath an existing untracked WIP path cannot hide behind an unchanged filename list.

The verifier parses the rulebook registration table and Task 30 demolition table
as structured Markdown and compares every row's exact required vector set to
the committed R-16 map. A state name in prose, a missing V36/V37/V38, or an
extra substitute vector fails. The final JSON status is `automated: passed`,
`physical: pending`, `releasable: false`; any skipped DB test, empty artifact,
absent product, dirty-baseline mismatch, report physical-pass claim, or hash
mismatch fails.

**GREEN:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest -q scripts/test_verify_metering_phase3_completion.py
```

Expected GREEN: verifier fixture tests pass. The real Tasks 01-29 history and automated evidence check runs immediately after the Task 29 commit below.

**Full GREEN before staging:** Run the complete backend disposable-DB suite, the only valid V30 orchestrator entry, and both literal simulator destinations:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py
bash scripts/run_metering_v30_cross_stack.sh
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' test
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -skip-testing:'Evlin iOSTests/ProfileSnapshotTests' test
```

Expected full GREEN: all backend tests execute without skips, the V30 harness consumes nonempty Swift artifacts, and both simulator schemes pass. Task 29 post-commit `pre-report` still remains mandatory because commit ancestry cannot be proved before this task's commit exists.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add scripts/verify_metering_phase3_completion.sh scripts/test_verify_metering_phase3_completion.py
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
git commit -m 'test: add metering phase 3 completion verifier'
bash scripts/verify_metering_phase3_completion.sh pre-report
```

---

## Task 30: Record Automated Evidence And Physical Pending Gates

**Repository:** iOS.

**Interfaces:** Consumes Task 29 pre-report evidence and all task SHAs. Produces the Phase 3 completion report; it records automated evidence but cannot claim Phase 3 complete or releasable.

**Files:**

- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md`

**TDD RED:** Add the report with status `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE`, immutable bases, Tasks 01-29 SHAs, test/product/log hashes, and the exact table below. Before populating it, run final mode with a nonexistent SHA:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
bash scripts/verify_metering_phase3_completion.sh final 0000000000000000000000000000000000000000
```

Expected RED: Task 30 commit is absent and supplied report SHA does not exist.

**Minimal GREEN:** Include this exact heading and rows, filling evidence cells with committed test/vector IDs and raw-log hashes rather than prose claims:

```markdown
## 本阶段拆除清单 + 向量证据

| R-16 item | Removed production mechanism | Authoritative replacement | Vector / production evidence | Result |
|---|---|---|---|---|
| T1 | scalar arm signature churn | six-field generation + eight dated routes | V01/V02/V03/V06/V07/V24 + real-installer 121 reconciliation log | AUTOMATED PASS |
| T2 | raw pool/cap stale-ladder ceiling | immutable route provenance + tombstone | V04/V05/V08/V13/V27 + T2 log | AUTOMATED PASS |
| T3 | fresh-at-fire shield gate | strict callback trust + shield envelope | V04/V05/V10/V12/P3V01 + T3 log | AUTOMATED PASS |
| Phase 3 T4 | backend headroom veto | local effect envelope + exact CAS release | V15/V16/P3V01/P3V02/V36 + T4 log | AUTOMATED PASS |
| T5 | backend `_sample_is_plausible` `+5` branch | Phase 2 strict canonical/accounting validation | Phase 2 report + backend tests | PHASE 2 PASS |
| T11 | iOS device plus-five heuristic | 30-second default / 60-second maximum jitter | V04/V05/V19/V30 + T11 log | AUTOMATED PASS |
| T7 | counter-recovery flags | paused high-water + conservative replacement + one boundary discard | V06/V10/V11/V12/V37 + T7 log | AUTOMATED PASS |
| T8 | dual activity lifecycle implementation | Device Epoch Store + LegacyCompatibilityMonitorState | V01/V08/V09/V13/V21/V22/V28/V38 + T8 log | AUTOMATED PASS |
```

The report must state that neither its own commit SHA nor its own Git blob/SHA-256 can be embedded recursively. It contains no self-hash field. It does contain the exact anchored structured fields `status_code: AUTOMATED_PASSED_PHYSICAL_PENDING`, `phase_complete: false`, and `releasable: false`, plus display status `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE`. After the report-only commit, Task 29 final mode computes the committed report blob, content SHA-256, and exact commit SHA and writes all three to `.superpowers/evidence/metering-phase3/report-commit-attestation.json`. Final mode must be idempotent: rerunning it against the same report commit reproduces or validates the same semantic attestation, and downstream phases rerun it before trusting the external file. List all physical gates as `PENDING`.

**Full GREEN before staging:** Re-run Task 29 pre-report mode against committed Tasks 01-29 and the populated uncommitted report:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
bash scripts/verify_metering_phase3_completion.sh pre-report
```

Expected full GREEN: all automated logs/products/hashes and Tasks 01-29 remain valid, the report contains no physical-pass claim, and only the recursive report-commit attestation remains for post-commit final mode.

**Review and commit:**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md
git diff --cached --check && git diff --cached --stat && git diff --cached && git diff --cached --name-only
test "$(git diff --cached --name-only | wc -l | tr -d ' ')" -eq 1
git commit -m 'docs: record metering phase 3 evidence'
REPORT_COMMIT="$(git rev-parse HEAD)"
bash scripts/verify_metering_phase3_completion.sh final "$REPORT_COMMIT"
```

Expected GREEN: Tasks 01-30 are exact, unique, ordered, ancestral, and hash-attested; report is the only Task 30 committed file; the external post-commit attestation is nonempty and final mode can validate it again; status remains `phase_complete: false`, physical pending, and not releasable.

---

## Automated Completion Gate

The implementation may report **AUTOMATED PASSED** only when Task 29 final mode exits zero and all of the following are recorded with raw-log hashes:

1. Backend pure tests and disposable-DB suites pass without skips; V30 consumes Swift production bytes through real routes and rows.
2. Full iPhone 17 Pro and iPad Pro simulator schemes pass at deployment target 17.6 on installed runtime 26.3.1; only the unrelated device-pinned `ProfileSnapshotTests` suite is excluded from the M5 iPad run and remains executed on its supported iPhone destination.
3. App, DAM, Report, Shield Config, Push, and XCTest Release products are built first, exactly six nonempty Mach-O paths are found, and DEBUG clock tokens are absent.
4. V01-V39 and P3V01/P3V02 reach their required production effects; rejected routes have zero effects; corrected/resumed/rolled epochs always have fresh route IDs.
5. Every persisted work item has owner, retry schedule, terminal condition, R-16 row, and a tested app/DAM/Push-appropriate recovery trigger.
6. Every task subject occurs exactly once; SHAs are unique; same-repo ancestry and six cross-repo dependency trailers prove order from immutable bases.
7. Pre-existing tracked dirty diffs and path-plus-type/mode/content untracked manifests match the baseline after excluding declared task files and evidence; `APIClient.swift`, onboarding/beta WIP, Phase 2 files, Profile semantics, and production infrastructure remain untouched.

Automated passing does not mean Phase 3 complete or releasable.

## Physical-Device Pending Gate

Record each item as `PENDING` until executed on the named physical environment:

| Gate | Required evidence | Status |
|---|---|---|
| Earned threshold | 6-7 minute earned threshold, including force-kill delivery and no duplicate attribution | PENDING |
| Per-app DEBUG | DEBUG one-minute per-app threshold and shield transition | PENDING |
| Two-device | two distinct physical devices; usage attributed only to reporting device | PENDING |
| TestFlight overnight | eight-date horizon, force-quit overnight callback/rollover/refill, no churn, and any `excessiveActivities` capacity result | PENDING |
| Minimum floor | physical iOS/iPadOS 17.6 start/callback/replacement/stop/day-boundary ownership; required because no local 17.6 runtime exists | PENDING |

No report, verifier, simulator, snapshot, or local SDK inspection may mark these physical gates passed. The eight-date horizon changes only if the TestFlight capacity evidence requires a later reviewed reduction.

## Requirements Trace

| Canonical requirement | Owning tasks |
|---|---|
| §3 failure model, R-16 replacements, zero-effect rejection | 1, 7, 8, 12, 22-28 |
| §6 generation, dated routes, epochs, backend registry, root, queues, shield/cleanup/rollover | 3-17 |
| §7 exact wire, v1 compatibility, registration/activation ratchet | 3, 4, 6, 7, 11, 18, 19 |
| §8 eight-date no-churn, install ordering, 60-second arbitration, coverage | 9-11, 13, 20, 21 |
| §10 callback trust, 30/60 jitter, delayed callbacks, pause/resume | 12, 17, 23, 24, 26, 27 |
| §11 separate legacy device-total counter remains inventoried and undeleted | 18, 21, 28, 29 |
| §13 vectors and cross-stack production evidence | 7, 8, 18, 19, 29 |
| §14 five physical-device gates | 30 and the separate physical PENDING gate |
| §15 rollout, v1 preservation, per-owner v2 activation, R-16 completion | 1, 3, 6, 11, 18-30 |
| §16 completion and physical gates | 29, 30 |
| Rulebook §11/R-16 T1/T2/T3/Phase3-T4/T7/T8/T11 plus Phase2-T5 evidence | 1, 22-30 |

## Protocol Field Trace

| Additive field/reason | Pydantic/model/service/route | Python evidence | Swift Codable/queue/production | Fixture/vector |
|---|---|---|---|---|
| `gate_resume_conservative` | Task 3 enum, contract mapping, registry validation, DB reason constraint | registration/lifespan/phase3 vector DB tests | Task 4 reason enum; Tasks 5-6 registration work; Tasks 11/17 recovery | V10-V12,V37 |
| registration `epoch_status` | Task 3 optional response field populated from final gate check | active/paused registration and close-race tests | Task 4 optional decode; absent/paused remains non-activating in Tasks 6/11 | V30,V37,V39 |
| activation `protocol_version`, `device_id`, `route_id`, `verified_at` | Task 3 request, ownership route, row-locked service, `activation_route_id`/`activated_at` | idempotent, mismatch, close-race, migration tests | Task 4 request; Tasks 5-6 activation work; Task 11 verified-route producer | V30,V37,V39 |
| activation `status`, `epoch_id`, `epoch_status`, `metering_protocol_version`, `snapshot` | Task 3 response and active-only ratchet | active/already/paused and stale route tests | Task 4 response; Task 6 disposition; Task 11 sole local ratchet | V30,V37,V39 |
| `gate_resume_conservative_required` | Task 3 sample service/route warning while old warning remains decodable | sample adapter and phase3 DB tests | Task 4 snapshot warning; Tasks 6/17 terminal sample then authoritative-state recovery | V37 |

## Dependency Safety Review

- Queue/backfill is active in Task 6 before any registration or local v2 transition in Tasks 9-11.
- New registration/start/verification/activation tests land before legacy stop; no task permits neither functional v1 nor verified v2.
- Every immutable replacement in Tasks 13, 16, and 17 creates a fresh epoch and fresh route in the same transaction.
- Shield, identity, rollover, install, and delivery work have explicit owner, retries `0/5/15/60/300`, terminal state, R-16 registration, and recovery trigger.
- T1/T2/T3/T4/T7/T8/T11 deletion begins only after Tasks 2-21 install and test authoritative replacements. Backend T5 is evidence-only here because Phase 2 already removed it. T8 is last and first compiles all consumers against replacements.
- `MeteringEpochWire.swift` is app/DAM/Push; center/install entries are app/DAM only; the narrow shield utility carries its complete DAM closure; Push has no monitor owner.
- `#if DEBUG` clock override source and post-build six-product Release scans prove compile-time exclusion non-vacuously.
- Simulator runtime 26.3.1 is separated from deployment target 17.6; physical 17.6 behavior remains pending.
