# Metering Epoch Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan one task at a time, with a fresh worker and two-level review after each task. Do not let a worker delegate again.

**Goal:** Turn the metering rules into a byte-identical, executable Swift/Python contract and resolve the Apple process-capability unknown: whether the DeviceActivity monitor extension and Notification Service Extension can start, replace, and stop a monitor with explicit schedule timezone while the main app is absent. This phase may prove process capability; it cannot prove canonical-midnight behavior or enable the exact-rebase branch.

**Architecture:** Phase 1 adds a pure, side-effect-free contract layer shared by later production adapters. Stable generation identity, daily epoch identity, callback trust, day/gate transitions, multi-device projection, protocol ratchet, manual-source isolation, and per-app command ordering are evaluated from one canonical JSON fixture in both languages. A fake monitor installer and injected clock prove churn and midnight rule math without waiting. A DEBUG-only physical probe records whether DAM/NSE monitor start, same-name replacement, stop, explicit-timezone scheduling, and `intervalDidStart` behave while the app is absent. That result is only a process-capability observation for later planning. Phase 3 must retain the conservative continuous-monitor fallback until a later physical canonical-day-boundary gate passes. No production earned-time or app-limit scheduler is rewired in this phase.

**Tech Stack:** Swift with the current Xcode 26 toolchain (project language mode `SWIFT_VERSION=5.0`), Foundation, CryptoKit, DeviceActivity, XCTest, the backend venv's Python 3.11, and pytest. Minimum deployment target remains iOS/iPadOS 17.6.

## Global Constraints

- Canonical behavior is `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/specs/2026-07-15-metering-epoch-design.md`, especially Sections 6, 8, 13.1, and Phase 1.
- Execute sequentially in the existing main work directories. Do not create a worktree, stash, reset, or discard unrelated beta-agreement changes.
- Before Task 1, record non-mutating recovery pointers with `git stash create` in both repositories and save the printed SHAs in the task log.
- The canonical vector copies must remain byte-identical:
  - iOS: `Evlin iOSTests/Fixtures/metering_epoch_vectors.json`
  - backend: `tests/fixtures/metering_epoch_vectors.json`
- Vector evaluators dispatch by `kind`, never by vector ID. A switch such as `case "V14": return expected` is a test fake and fails review.
- Production/reference evaluators accept only typed `input` values. Fixture IDs, descriptions, and `expected` observations stay in the test target and are unavailable to the evaluator module.
- Stable generation identity contains only protocol version, child-device ID, canonical timezone, policy revision, exact persisted selection-byte digest, and enforcement-set ID. It excludes usage date, offset, estimates, remaining minutes, timestamps, callback counts, gate state, and retry state.
- SHA-256 is computed over the exact persisted selection bytes. Neither implementation may decode and re-encode those bytes before hashing.
- Callback plausibility is an upper bound only. There is no lower-bound freshness check and no `+5 minutes` allowance.
- Every rejected callback has a zero `MeteringEffects` value: no local mutation, retry, network dispatch, backend row/ledger mutation, notification, shield mutation, arm, or stop.
- The DEBUG capability probe must use a dedicated `evlin.metering.probe.*` namespace and App Group keys. It must not touch earned/app-limit activity names, offsets, rules, shields, ledgers, or command acknowledgements.
- The probe is compiled out of Release with `#if DEBUG`; the backend sender remains a local diagnostic script, not a production route.
- `--monitor-probe` is fail-closed: it requires exactly one explicit, nonempty APNs token and must never fall back to the script's normal all-child-device broadcast behavior.
- A successful short probe may be recorded only as `process-capable`. It never unlocks exact canonical-midnight rebase/schedule ownership. Phase 3 uses the conservative continuous-monitor fallback until Phase 5 or the overnight gate supplies physical day-boundary evidence.
- No migrations, Render deployment, production protocol advertisement, epoch persistence, sample-route changes, or production scheduler rewiring belong in Phase 1.
- Every commit must pass `git diff --cached --check`, and staged diffs must exclude all pre-existing unrelated worktree changes.

---

### Task 1: Freeze the Canonical 23-Vector Fixture

**Files:**
- Create: `Evlin iOSTests/Fixtures/metering_epoch_vectors.json`
- Create: `Evlin iOSTests/MeteringEpochVectorCoverageTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_vector_contract.py`

**Interfaces:**
- Top-level JSON object:

```json
{
  "schema_version": 1,
  "generation_cases": [],
  "callback_cases": [],
  "gate_cases": [],
  "ledger_cases": [],
  "manual_cases": [],
  "protocol_cases": [],
  "per_app_ordering_cases": []
}
```

- Every case has `id`, `description`, `input`, and `expected`.
- All timestamps are integer Unix seconds. Dates are canonical `yyyy-MM-dd` strings. Selection bytes are base64 strings. Ordering tokens are integers in the reference fixture; Phase 2 decides the production database representation.
- Exact ownership by group:

| Group | Vector IDs | Contract exercised |
|---|---|---|
| `generation_cases` | V01, V02, V03, V07 | unchanged-poll churn, mutable offset exclusion, raw-byte digest, first-launch readiness |
| `callback_cases` | V04, V05, V06, V08, V13 | early reject, delayed accept, accepted progress plus polls, stale day, identity firewall |
| `gate_cases` | V09, V10, V11, V12, V21, V22 | canonical rollover, pause/resume, task bypass, reflection precedence, device/canonical timezone split, canonical timezone replacement |
| `ledger_cases` | V14, V15, V16, V17 | two-device attribution, own cap, shared exhaustion fanout, exact per-app lock |
| `manual_cases` | V18 | manual-only source mutation and byte-identical metering state |
| `protocol_cases` | V19, V20 | old-client compatibility before ratchet and terminal v1 drop after ratchet |
| `per_app_ordering_cases` | V23 | newer set, clear tombstone, duplicate idempotency, out-of-order delivery |

- `expected.effects` always contains all counters, even when zero:

```json
{
  "local_estimate_mutations": 0,
  "retry_enqueues": 0,
  "network_dispatches": 0,
  "backend_sample_rows": 0,
  "ledger_mutations": 0,
  "notifications": 0,
  "shield_mutations": 0,
  "monitor_starts": 0,
  "monitor_stops": 0,
  "epoch_replacements": 0
}
```

- [ ] **Step 1: Add failing coverage and byte-parity tests before adding the fixtures**

In Swift, resolve the source fixture relative to `#filePath`, decode only the top-level metadata initially, flatten all seven arrays, and assert:

```swift
XCTAssertEqual(suite.schemaVersion, 1)
XCTAssertEqual(allIDs, (1...23).map { String(format: "V%02d", $0) })
XCTAssertEqual(Set(allIDs).count, 23)
```

Also locate the backend sibling copy at:

```swift
sourceURL
    .deletingLastPathComponent() // Fixtures
    .deletingLastPathComponent() // Evlin iOSTests
    .deletingLastPathComponent() // Evlin-iOS
    .deletingLastPathComponent() // code.nosync
    .appendingPathComponent("Evlin-Backend/tests/fixtures/metering_epoch_vectors.json")
```

In the local dual-repository checkout, assert the sibling exists and then
assert raw `Data` equality; absence is a failure, not a silent skip. A
backend-only/iOS-only CI job may skip only this sibling comparison behind an
explicit CI-environment condition. The Phase 1 gate always runs `cmp` with both
repositories present.

In Python, mirror the ID/schema checks and compare raw bytes with the real iOS
sibling path (the repository directory is hyphenated):

```python
FIXTURE_PATH.parents[3] / "Evlin-iOS" / "Evlin iOSTests" / "Fixtures" / "metering_epoch_vectors.json"
```

Do not copy the existing app-limit test's stale `"Evlin iOS"` sibling spelling.
In the local dual-repository checkout, a missing sibling is a test failure, not
a skip. Backend-only CI may skip this one raw-byte comparison only through an
explicit CI environment condition; schema/ID/vector execution never skips.

- [ ] **Step 2: Run both tests and verify they fail because the fixture files do not exist**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/MeteringEpochVectorCoverageTests

cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/pytest tests/test_metering_epoch_vector_contract.py -q
```

Expected: both fail at the missing canonical fixture, not at an unrelated compile/import error.

- [ ] **Step 3: Populate all 23 cases from spec Section 13.1**

Use these non-negotiable numeric anchors:

- V01: 121 polls from `t=0` through `t=1200` seconds, one monitor start.
- V02: accepted offset sequence `0,5,10,15`; generation identity remains one value and monitor starts remain one.
- V03: persisted bytes `AQIDBAUG` hash exactly to `7192385c3c0605de55bb9476ce1d90748190ecb32a8eed7f5207b30cf6a1fe89`; a different byte order produces a different digest.
- V04: epoch starts at `t=1000`; adjusted estimate `5` at `t=1001` is rejected with all effects zero. Repeat the same rule for a 60-minute per-app callback at `t=1001`.
- V05: epoch starts at `t=1000`; adjusted estimate `5` at `t=1300` is accepted with default jitter 30.
- V06: accept estimates 5 and 10 at physically possible times, then run 120 ordinary polls; accepted value remains 10 and monitor starts remain one.
- V07: configured/authorized/selection-present/identity-present starts once and exposes first threshold; each missing prerequisite separately stays unarmed and reports not ready.
- V08: active date `2026-07-16`; callback date `2026-07-15`; reject before every effect.
- V09: canonical midnight retires yesterday's epoch and creates exactly one new epoch without replacing the repeating monitor.
- V10: pause, a bucket crossing the boundary, and resume with no app-process event; discard only the crossing bucket, then accept the first fully post-resume bucket.
- V11: task bypass enables counting for `2026-07-15`, but not `2026-07-16`.
- V12: reflection active keeps counting paused even when task bypass is active.
- V13: callback/retry owner A presented under owner B; reject and remove old-owner queued work without any new-owner mutation.
- V14: A accepts 5 under pool 120; shared remaining is 115, A own remaining falls by 5, B own remaining is unchanged.
- V15: A reaches cap; add only A's device-cap/earned source.
- V16: shared pool reaches zero; add separate earned receipts/sources for A and B.
- V17: one rule reaches its limit; mutate only that rule/app/device shield source.
- V18: apply manual lock then manual unlock; only `manual` changes. Serialize metering state before/after and require identical bytes.
- V19: v1 request before ratchet is accepted through the compatibility branch.
- V20: after device ratchets to v2, v1 is `counted=false`, terminal, and not retried.
- V21: device timezone `Asia/Tokyo`, canonical `America/New_York`; Tokyo midnight causes no rollover, New York midnight causes exactly one.
- V22: canonical timezone changes while device timezone stays fixed; retire once, replace once, reject old callbacks, project the new canonical date, and leave old-date bypass/override markers inactive rather than migrating them.
- V23: deliver set version 2, set version 1, clear version 3, set version 2, clear version 3. Final state is cleared with tombstone 3; older commands do nothing and equal version is idempotent.

Copy the finished iOS JSON bytes directly to the backend path. Do not independently pretty-print the second copy.

- [ ] **Step 4: Run coverage/parity tests**

Run the Step 2 commands again.

Expected: Swift and Python pass; `cmp` returns success:

```bash
cmp \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json
```

- [ ] **Step 5: Commit each repository's fixture/tests without unrelated files**

Commit backend first, then iOS:

```bash
git add tests/fixtures/metering_epoch_vectors.json tests/test_metering_epoch_vector_contract.py
git diff --cached --check
git commit -m 'test: freeze metering epoch vectors'
```

```bash
git add 'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' \
        'Evlin iOSTests/MeteringEpochVectorCoverageTests.swift'
git diff --cached --check
git commit -m 'test: freeze metering epoch vectors'
```

---

### Task 2: Implement the Swift Pure Epoch Contract and Fake Monitor

**Files:**
- Create: `Evlin iOS/Services/MeteringEpochContract.swift`
- Create: `Evlin iOSTests/MeteringEpochContractTests.swift`
- Modify: `Evlin iOS.xcodeproj/project.pbxproj`

**Interfaces:**

```swift
nonisolated protocol MeteringClock: Sendable { var now: Date { get } }

nonisolated struct MeteringGenerationKey: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let childDeviceID: UUID
    let canonicalTimezone: String
    let policyRevision: String
    let measurementSelectionDigest: String
    let enforcementSetID: UUID
}

nonisolated struct MeteringEpochKey: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let childDeviceID: UUID
    let usageDate: String
    let canonicalTimezone: String
    let policyRevision: String
    let measurementSelectionDigest: String
    let enforcementSetID: UUID
}

nonisolated enum MeteringGenerationDecision: Equatable, Sendable {
    case keep
    case install(MeteringGenerationKey)
}

nonisolated enum MeteringCallbackVerdict: String, Codable, Sendable {
    case accept
    case rejectOwner
    case rejectEpoch
    case rejectUsageDate
    case rejectPolicy
    case rejectNamespace
    case rejectNegativeDelta
    case rejectTooEarly
}

nonisolated struct MeteringCallbackInput: Equatable, Sendable {
    let activeEpochID: UUID
    let callbackEpochID: UUID
    let activeOwnerDeviceID: UUID
    let callbackOwnerDeviceID: UUID
    let activeUsageDate: String
    let callbackUsageDate: String
    let activePolicyRevision: String
    let callbackPolicyRevision: String
    let expectedEventNamespace: String
    let callbackEventNamespace: String
    let adjustedEstimateMinutes: Int
    let baseAcceptedMinutes: Int
    let startedAt: Date
    let callbackAt: Date
    let jitterSeconds: Int
}

nonisolated struct MeteringEffects: Codable, Equatable, Sendable {
    var localEstimateMutations = 0
    var retryEnqueues = 0
    var networkDispatches = 0
    var backendSampleRows = 0
    var ledgerMutations = 0
    var notifications = 0
    var shieldMutations = 0
    var monitorStarts = 0
    var monitorStops = 0
    var epochReplacements = 0
}
```

Required pure functions:

```swift
MeteringEpochContract.defaultJitterSeconds == 30
MeteringEpochContract.maximumJitterSeconds == 60
MeteringEpochContract.selectionDigest(persistedBytes: Data) -> String
MeteringEpochContract.generationDecision(active:next:) -> MeteringGenerationDecision
MeteringEpochContract.callbackVerdict(_ input: MeteringCallbackInput) -> MeteringCallbackVerdict
MeteringEpochContract.effects(for:) -> MeteringEffects
MeteringEpochContract.canonicalUsageDate(at:timezoneIdentifier:) -> String?
```

Required monitor seam:

```swift
nonisolated protocol MeteringMonitorInstalling {
    mutating func install(_ key: MeteringGenerationKey) throws
    mutating func stop(_ key: MeteringGenerationKey)
}

nonisolated struct MeteringGenerationReconciler {
    private(set) var active: MeteringGenerationKey?
    mutating func reconcile<Installer: MeteringMonitorInstalling>(
        next: MeteringGenerationKey,
        installer: inout Installer
    ) throws
}
```

- [ ] **Step 1: Write failing direct contract tests**

Pin these before implementation:

1. generation key equality does not observe a separate offset/estimate argument;
2. exact persisted bytes have a stable lowercase 64-hex digest;
3. changing any of the six stable key fields changes equality;
4. 121 reconciles over 20 virtual minutes install once;
5. an install failure preserves the previous active key;
6. delta 5 at elapsed 1 second rejects too early with zero effects;
7. delta 5 at elapsed 300 seconds accepts;
8. a late callback remains accepted;
9. owner/date/policy/namespace mismatches win before plausibility;
10. the default jitter constant is 30 and an injected value above 60 is clamped to the 60-second hard maximum;
11. a callback timestamp before `startedAt` rejects as `.rejectTooEarly` even when delta is zero;
12. canonical usage-date projection ignores the process/device timezone.

Use a mutable `FakeMonitorInstaller` and `TestMeteringClock`; never sleep or instantiate `DeviceActivityCenter` in unit tests.

- [ ] **Step 2: Run the test and verify compile failure on missing contract types**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/MeteringEpochContractTests
```

- [ ] **Step 3: Implement the pure contract**

Rules:

- `selectionDigest` hashes `Data` directly with `SHA256.hash(data:)`.
- `generationDecision` is `.keep` only on exact six-field equality; it has no offset/date overload.
- `callbackVerdict` checks owner, epoch ID, canonical usage date, policy
  revision, namespace, then computes
  `deltaMinutes = adjustedEstimateMinutes - baseAcceptedMinutes`. A negative
  delta returns `.rejectNegativeDelta`; `callbackAt < startedAt` returns
  `.rejectTooEarly`; otherwise evaluate:

```swift
deltaMinutes * 60 <= elapsedSeconds + min(max(jitterSeconds, 0), 60)
```

- `effects(for:)` returns all zero for every rejection. For `.accept`, it returns one local mutation, retry enqueue, and network dispatch; later adapters are responsible for backend/shield effects.
- `canonicalUsageDate` rejects an unknown timezone identifier, then uses
  `Calendar(identifier: .gregorian)` with that explicit timezone and formats
  zero-padded year/month/day components. It never reads `Calendar.current`,
  `TimeZone.current`, locale calendar preferences, or wall clock.
- `MeteringGenerationReconciler` changes `active` only after `installer.install` returns successfully. Ordinary repeated calls are no-ops.

- [ ] **Step 4: Add the shared file to both extension target exception lists**

In `project.pbxproj`, add exactly:

```text
Services/MeteringEpochContract.swift,
```

to the `EvlinDeviceActivityMonitor` and `EvlinPushApplier` membership exception arrays. This is a compile guard for later phases; Phase 1 does not call it from either extension yet.

- [ ] **Step 5: Run focused tests and compile all relevant targets**

```bash
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/MeteringEpochContractTests

xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'generic/platform=iOS Simulator'
```

Inspect the build log and confirm `MeteringEpochContract.swift` compiles in the app, DAM, and PushApplier target compile phases.

- [ ] **Step 6: Commit the isolated Swift contract**

```bash
git add 'Evlin iOS/Services/MeteringEpochContract.swift' \
        'Evlin iOSTests/MeteringEpochContractTests.swift' \
        'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git commit -m 'feat: add pure metering epoch contract'
```

---

### Task 3: Execute Every Golden Vector in Swift

**Files:**
- Modify: `Evlin iOS/Services/MeteringEpochContract.swift`
- Create: `Evlin iOSTests/MeteringEpochGoldenVectorTests.swift`

**Interfaces:**
- `MeteringGoldenVectorSuite`: typed `Decodable` fixture model with seven arrays.
- `MeteringReferenceRules.evaluateGeneration(_ input: GenerationInput) -> GenerationObservation`
- `MeteringReferenceRules.evaluateCallback(_ input: CallbackVectorInput) -> CallbackObservation`
- `MeteringReferenceRules.evaluateGate(_ input: GateInput) -> GateObservation`
- `MeteringReferenceRules.evaluateLedger(_ input: LedgerInput) -> LedgerObservation`
- `MeteringReferenceRules.evaluateManual(_ input: ManualInput) -> ManualObservation`
- `MeteringReferenceRules.evaluateProtocol(_ input: ProtocolInput) -> ProtocolObservation`
- `MeteringReferenceRules.evaluatePerAppOrdering(_ input: PerAppOrderingInput) -> PerAppOrderingObservation`

Each function accepts only the typed `input` and returns an independently
computed observation. The fixture wrapper containing `id`, `description`, and
`expected` exists only in the test target. `Expected*` types must not be
declared in or imported by `MeteringEpochContract.swift`. Dispatch is by input
`kind` where a group has variants, never by vector ID.
- Additional pure rules:

```swift
MeteringEpochContract.nextEpoch(
    active: MeteringEpochRuntime?,
    context: MeteringEpochContext
) -> MeteringEpochTransition
MeteringEpochContract.countingAllowed(
    tasksDone: Bool,
    taskBypassDate: String?,
    reflectionActive: Bool,
    usageDate: String
) -> Bool
MeteringEpochContract.projectLedger(
    pool: Int,
    acceptedByDevice: [UUID: Int],
    caps: [UUID: Int]
) -> MeteringLedgerProjection
nonisolated struct MeteringStateSnapshot: Codable, Equatable, Sendable {
    let generationID: UUID
    let epochID: UUID
    let usageDate: String
    let baseAcceptedMinutes: Int
    let localEstimateMinutes: Int
    let latestRawThresholdMinutes: Int
    let excludedRawMinutes: Int
    let pendingRetryIDs: [UUID]
    let monitorArmed: Bool
}
nonisolated enum ManualSourceAction: String, Codable, Equatable, Sendable {
    case lock
    case unlock
}
nonisolated struct ManualInput: Codable, Equatable, Sendable {
    let sourceSets: [UUID: Set<String>]
    let meteringState: MeteringStateSnapshot
    let action: ManualSourceAction
}
nonisolated struct ManualObservation: Codable, Equatable, Sendable {
    let sourceSets: [UUID: Set<String>]
    let meteringState: MeteringStateSnapshot
}
MeteringEpochContract.applyManual(_ input: ManualInput) -> ManualObservation
MeteringEpochContract.protocolDisposition(
    advertisedVersion: Int,
    deviceRatchet: Int?,
    sampleVersion: Int
) -> MeteringProtocolDisposition
MeteringEpochContract.applyPerAppCommand(
    state: PerAppVersionState,
    command: PerAppVersionCommand
) -> PerAppOrderingResult
```

- [ ] **Step 1: Add one test per fixture group and require all 23 IDs to execute**

Each test loads the source JSON, decodes its typed cases, passes only
`case.input` through the corresponding pure rule, and compares the full
observation including `MeteringEffects` against the separately held
`case.expected`:

```swift
let actual = MeteringReferenceRules.evaluateGeneration(testCase.input)
XCTAssertEqual(actual, testCase.expected)
```

Add a source-boundary assertion or compile-time visibility test proving the
production evaluator module cannot see fixture IDs or expected-observation
wrappers. An evaluator that accepts a complete fixture case fails review even
if it does not currently read `.expected`.

The callback reference evaluator composes both halves of a successful virtual
round trip: the device trust decision produces local/retry/network effects, and
the simulated accepted backend leg produces the expected sample-row/ledger and
optional fanout effects. A rejected device decision stops before that backend
leg, so every effect remains zero.

Add a shared `executedIDs` assertion in one all-vectors test:

```swift
XCTAssertEqual(executedIDs.sorted(), (1...23).map { String(format: "V%02d", $0) })
```

For V18, put both `sourceSets` and `meteringState` inside `ManualInput`, return
both in `ManualObservation`, then encode the input and returned metering states
with a sorted-key JSON encoder and assert byte equality. The test must not hold
the "after" state outside the algorithm and compare two fixture values to each
other. For V23, retain the latest token independently of the active rule so
clear version 3 leaves a tombstone.

- [ ] **Step 2: Run and verify the new tests fail on unimplemented rule functions**

```bash
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/MeteringEpochGoldenVectorTests
```

- [ ] **Step 3: Implement the minimum generic rules needed by the fixture**

Hard rules:

- day rollover is computed in `canonicalTimezone`, never `TimeZone.current`;
- device-local midnight alone is no event;
- canonical timezone change is a named replacement and old callbacks fail before effects;
- day-scoped task-bypass/override markers are re-evaluated under the newly projected canonical date; old-date markers never migrate to the new date;
- gate is `((tasksDone || taskBypassDate == usageDate) && !reflectionActive)`;
- a pause/resume boundary bucket is conservatively discarded;
- shared remaining sums accepted usage across devices; own remaining reads only that device;
- manual source changes copy the metering snapshot untouched;
- v1 after a persisted v2 ratchet is terminal and non-retryable;
- per-app comparison is newest token wins, equal token idempotent, and clear retains its token tombstone.

- [ ] **Step 4: Run Swift vector and direct-contract suites**

```bash
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/MeteringEpochContractTests \
  -only-testing:Evlin\ iOSTests/MeteringEpochGoldenVectorTests \
  -only-testing:Evlin\ iOSTests/MeteringEpochVectorCoverageTests
```

Expected: all 23 vectors execute and pass; V01 reports one start, V04/V08/V13 report all-zero effects, and V18 reports byte-identical meter state.

- [ ] **Step 5: Commit**

```bash
git add 'Evlin iOS/Services/MeteringEpochContract.swift' \
        'Evlin iOSTests/MeteringEpochGoldenVectorTests.swift'
git diff --cached --check
git commit -m 'test: execute metering rules in Swift'
```

---

### Task 4: Implement the Python Mirror and Enforce Cross-Language Parity

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_epoch_contract.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_vector_contract.py`

**Interfaces:**
- Python dataclasses/enums mirror the Swift stable keys, verdicts, effects, transitions, projections, ratchet, and per-app tombstone state.
- Public functions use the same names in snake_case:

```python
selection_digest(persisted_bytes: bytes) -> str
generation_decision(active: GenerationKey | None, next_key: GenerationKey) -> GenerationDecision
callback_verdict(value: CallbackInput) -> CallbackVerdict
effects_for(verdict: CallbackVerdict) -> MeteringEffects
canonical_usage_date(at_utc: datetime, timezone_identifier: str) -> str
counting_allowed(value: GateInput) -> bool
project_ledger(value: LedgerInput) -> LedgerProjection
apply_manual(value: ManualInput) -> ManualObservation
protocol_disposition(value: ProtocolInput) -> ProtocolDisposition
apply_per_app_command(state: PerAppVersionState, command: PerAppVersionCommand) -> PerAppOrderingResult
```

- [ ] **Step 1: Expand the Python fixture tests to evaluate every case**

Require exactly the same 23 IDs and full expected observations as Swift. Each
contract function receives only `case["input"]`; the pytest layer retains and
compares `case["expected"]`. No contract function accepts a case wrapper or an
expected value. Add direct tests for raw bytes and the upper-bound inequality
so a fixture-parser mistake cannot hide an algorithm error. For V18, pass the
metering snapshot into `apply_manual` and compare the returned snapshot bytes,
not two values both read from the fixture.

- [ ] **Step 2: Run and verify import failure**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/pytest tests/test_metering_epoch_vector_contract.py -q
```

Expected: fail because `app.services.metering_epoch_contract` does not exist.

- [ ] **Step 3: Implement the Python mirror without importing routes, ORM, or wall clock**

Use `hashlib.sha256`, `zoneinfo.ZoneInfo`, immutable dataclasses, and explicit injected timestamps. Do not call `datetime.now()` in any contract function.

- [ ] **Step 4: Run Python and byte-parity gates**

```bash
.venv/bin/pytest tests/test_metering_epoch_vector_contract.py -q
cmp \
  tests/fixtures/metering_epoch_vectors.json \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/'Evlin iOSTests/Fixtures/metering_epoch_vectors.json'
```

Expected: all Python vector tests pass and fixture bytes match.

- [ ] **Step 5: Commit**

```bash
git add app/services/metering_epoch_contract.py \
        tests/test_metering_epoch_vector_contract.py
git diff --cached --check
git commit -m 'feat: mirror metering epoch contract in Python'
```

---

### Task 5: Add a DEBUG-Only DAM/NSE Monitor Capability Probe

**Files:**
- Create: `Evlin iOS/Services/MeteringMonitorCapabilityProbe.swift`
- Modify: `EvlinPushApplier/NotificationService.swift`
- Modify: `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `Evlin iOS/Components/Debug/CommandDeliveryDiagnosticsView.swift`
- Modify: `Evlin iOS.xcodeproj/project.pbxproj`
- Test: `Evlin iOSTests/MeteringMonitorCapabilityProbeTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/send_test_nse_push.py`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/services/test_metering_monitor_probe_payload.py`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_command_delivery_apns.py`

**Interfaces:**

```swift
#if DEBUG
nonisolated enum MeteringMonitorCapabilityProbe {
    static let activityPrefix = "evlin.metering.probe."
    static let logKey = "evlin.spike.meteringMonitorProbeLog"
    static let callbackKey = "evlin.spike.meteringMonitorProbeCallback"

    static func activityName(origin: String, sequence: Int, role: String) -> String
    static func isProbeActivity(_ raw: String) -> Bool
    static func schedulePlan(
        origin: String,
        sequence: Int,
        now: Date,
        canonicalTimezone: String
    ) -> ProbeSchedulePlan?
    static func append(_ line: String, defaults: UserDefaults?)
}

nonisolated struct ProbeSchedulePlan: Equatable, Sendable {
    let stoppedActivityName: String
    let activeActivityName: String
    let stoppedStart: Date
    let supersededActiveStart: Date
    let replacementActiveStart: Date
    let end: Date
    let canonicalTimezone: String
}
#endif
```

NSE payload:

```json
{
  "aps": {"alert": {"title": "Evlin", "body": "Metering monitor probe"}, "mutable-content": 1},
  "evlin": {"kind": "metering_monitor_probe", "command_id": "00000000-0000-0000-0000-000000000007", "seq": 7, "canonical_timezone": "Asia/Tokyo"}
}
```

- [ ] **Step 1: Write failing Swift pure-name/log tests and Python payload test**

Swift pins namespace parsing, capped append behavior, stopped/active role names, and rejects earned/limit/heartbeat names as probe names. Add a pure schedule-plan test that receives `now` and an explicit timezone different from `TimeZone.current`, then emits:

1. a `stopped` activity scheduled for `now+45s` and immediately stopped;
2. an `active` activity first scheduled for `now+30s`, then replaced under the same name with `now+60s`;
3. all `DateComponents` carrying the requested canonical timezone.

Expose a pure async script seam:

```python
async def send_monitor_probe(
    sender: ApnsSender,
    *,
    token: str,
    sequence: int,
    canonical_timezone: str,
) -> ApnsResult
```

The script test stubs `ApnsSender.send_alert_nag` and asserts
`kind="metering_monitor_probe"`, integer `seq`, and `canonical_timezone`
passthrough. Separately extend `test_command_delivery_apns.py` to call the real
`send_alert_nag` transport seam and assert the serialized APNs body contains
`aps.mutable-content == 1`, the custom kind, sequence, and timezone. Do not
claim a stubbed method proves payload serialization.

Add parser/dispatch tests for the probe's single-device safety boundary:

- no positional token -> `SystemExit` before constructing/calling a sender;
- an empty/whitespace token -> `SystemExit` with zero sends;
- two or more tokens -> `SystemExit` with zero sends;
- exactly one nonempty explicit token -> exactly one send to that token.

These rules apply only to `--monitor-probe`; do not change the script's
existing production block/clear broadcast behavior in this phase.

- [ ] **Step 2: Run tests and verify failures**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/MeteringMonitorCapabilityProbeTests

cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/pytest \
  tests/services/test_metering_monitor_probe_payload.py \
  tests/test_command_delivery_apns.py::test_metering_monitor_probe_serializes_mutable_alert \
  -q
```

- [ ] **Step 3: Add shared DEBUG-only probe persistence, target membership, and the real minimum deployment target**

Add `Services/MeteringMonitorCapabilityProbe.swift` to both DAM and PushApplier exception arrays. All declarations and every call site are inside `#if DEBUG` so Release contains no probe namespace or App Group mutation.

`EvlinPushApplier` currently has no target-level deployment override and
inherits the project's `IPHONEOS_DEPLOYMENT_TARGET = 26.2`, while DAM is pinned
to 17.6. Add `IPHONEOS_DEPLOYMENT_TARGET = 17.6;` to both the PushApplier Debug
and Release build configurations in `project.pbxproj`. Do not change the app or
DAM target values. Verify both configurations with `xcodebuild
-showBuildSettings -target EvlinPushApplier`; a successful build on the current
SDK is not evidence that the extension can deploy to 17.6.

- [ ] **Step 4: Add the NSE start attempt before the lock-command guard**

In `NotificationService.didReceive`, if `kind == "metering_monitor_probe"`:

1. validate `seq` and `canonical_timezone`;
2. build the injected-time schedule plan above;
3. start then immediately stop the `stopped` name;
4. start the `active` name at `now+30s`, then call `startMonitoring` again for the same name at `now+60s`;
5. append each operation's exact result and expected callback timestamp;
6. call `finish()` and return without fetching/acking any command.

Import `DeviceActivity` only inside the DEBUG build path. Never use an earned or app-limit activity name.

- [ ] **Step 5: Record actual callback in DAM**

At the beginning of `intervalDidStart`, before earned/heartbeat routing, detect the probe namespace. Append `dam callback` with timestamp/activity to the same App Group log, set `callbackKey`, and return. This proves daemon dispatch, not merely that `startMonitoring` failed to throw. A callback for the `stopped` name or near the superseded `now+30s` active schedule is a failed probe.

Retain the existing `evlin.command.heartbeat` DAM self-rearm probe. From that DEBUG heartbeat callback, execute the same stopped/active replacement plan with origin `dam`. Phase 1 records both:

- DAM-origin start/stop/same-name replacement operation log plus callback timing;
- NSE-origin start/stop/same-name replacement operation log plus callback timing.

- [ ] **Step 6: Surface the probe log in existing diagnostics**

Add one unframed diagnostics section under the existing heartbeat/NSE sections with the latest result and capped history. Add a DEBUG `Run DAM monitor probe` button that clears only the probe keys and calls the existing `startCommandHeartbeatSpike(delaySeconds: 30)`; the resulting heartbeat callback runs the DAM-origin plan. Add a separate clear button that removes only `logKey` and `callbackKey`.

- [ ] **Step 7: Extend the local sender with fail-closed targeting**

Add `--monitor-probe` and optional `--probe-timezone` to `scripts/send_test_nse_push.py`. It calls the existing `send_alert_nag` with custom kind `metering_monitor_probe`, time-sensitive interruption, `extra={"seq": seq, "canonical_timezone": probe_timezone}`, and a fresh UUID. It does not create a command row and does not target Render unless the operator's local environment explicitly points there.

For this mode, require exactly one explicit nonempty APNs token. Validate the
token count/value before any database token lookup or sender creation, and
never fall back to querying all child tokens. Missing, blank, or multiple
tokens exit nonzero without sending. Keep normal block/clear mode behavior
unchanged.

- [ ] **Step 8: Run tests and compile Debug plus Release**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/MeteringMonitorCapabilityProbeTests
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -configuration Debug -destination 'generic/platform=iOS'
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -configuration Release -destination 'generic/platform=iOS'
xcodebuild -showBuildSettings -project 'Evlin iOS.xcodeproj' \
  -target EvlinPushApplier -configuration Debug \
  | rg 'IPHONEOS_DEPLOYMENT_TARGET = 17.6'
xcodebuild -showBuildSettings -project 'Evlin iOS.xcodeproj' \
  -target EvlinPushApplier -configuration Release \
  | rg 'IPHONEOS_DEPLOYMENT_TARGET = 17.6'

cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/pytest \
  tests/services/test_metering_monitor_probe_payload.py \
  tests/test_command_delivery_apns.py::test_metering_monitor_probe_serializes_mutable_alert \
  -q
```

Expected: Debug builds all four relevant targets; Release also builds with
probe code absent; both PushApplier configurations report deployment target
17.6; probe sender tests prove zero sends for missing/blank/multiple tokens.

- [ ] **Step 9: Commit in each repository**

Backend:

```bash
git add scripts/send_test_nse_push.py \
        tests/services/test_metering_monitor_probe_payload.py \
        tests/test_command_delivery_apns.py
git diff --cached --check
git commit -m 'test: add NSE monitor capability probe sender'
```

iOS:

```bash
git add 'Evlin iOS/Services/MeteringMonitorCapabilityProbe.swift' \
        EvlinPushApplier/NotificationService.swift \
        EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift \
        'Evlin iOS/Components/Debug/CommandDeliveryDiagnosticsView.swift' \
        'Evlin iOSTests/MeteringMonitorCapabilityProbeTests.swift' \
        'Evlin iOS.xcodeproj/project.pbxproj'
git diff --cached --check
git commit -m 'test: probe extension monitor installation capability'
```

---

### Task 6: Run the Physical Capability Spike and Record the Branch Decision

**Files:**
- Create: `docs/superpowers/research/2026-07-15-metering-monitor-capability-results.md`

**Human involvement:** The operator only unlocks/authorizes the iPhone/iPad, taps the named DEBUG probe button, and confirms the visible probe notification. Codex drives build, install, force-quit, APNs send, waits, App Group extraction, and evidence comparison.

- [ ] **Step 1: Discover connected physical devices and record OS/build identifiers**

```bash
xcrun devicectl list devices
```

Use one connected iPhone and one connected iPad. Record UDID, model, OS version, app commit, backend commit, and the verified build-setting value for each target (including PushApplier 17.6 in Debug and Release). Do not claim runtime proof on iOS 17.6 unless a physical 17.6 device was actually used.

- [ ] **Step 2: Install the same verified Debug build on each device**

Build once with `generic/platform=iOS`, locate the `.app`, install with `xcrun devicectl device install app`, launch once, authorize Family Controls if needed, open Command Delivery diagnostics, tap `Run DAM monitor probe`, then terminate the main Evlin app.

- [ ] **Step 3: Verify DAM-origin self-rearm evidence**

Wait 110 seconds after arming the 30-second heartbeat. Require the DAM-origin plan's operation log, no callback for the stopped name, no callback at the superseded active schedule, and one callback for the replacement active schedule. A thrown/failed result is valid evidence; absence of the expected active callback is not success.

- [ ] **Step 4: Send the NSE-origin probe with the main app force-killed**

From the configured local backend environment:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
APNS_TOKEN='paste the token read from the selected local child-device row'
.venv/bin/python -m scripts.send_test_nse_push \
  --monitor-probe --probe-timezone Asia/Tokyo "$APNS_TOKEN"
```

Choose a probe timezone different from the device's current timezone. Wait 100 seconds. The wait is only for Apple's real daemon callback; all contract/midnight/churn tests remain virtual and take milliseconds.

- [ ] **Step 5: Extract the App Group plist from each device**

```bash
mkdir -p /tmp/evlin-metering-probe
DEVICE_UDID='paste the connected UDID selected in Step 1'
DEVICE_CLASS='iphone' # use ipad for the second run
xcrun devicectl device copy from \
  --device "$DEVICE_UDID" \
  --domain-type appGroupDataContainer \
  --domain-identifier group.com.evlin.ios \
  --source Library/Preferences/group.com.evlin.ios.plist \
  --destination "/tmp/evlin-metering-probe/$DEVICE_CLASS.plist"
plutil -p "/tmp/evlin-metering-probe/$DEVICE_CLASS.plist"
```

Substitute the values discovered in Step 1; do not commit tokens, UDIDs, or plist files.

- [ ] **Step 6: Record a four-cell result table**

For iPhone and iPad separately record:

| Origin | start/replace/stop results | stopped/superseded callback absent | replacement callback observed at expected instant | Decision |
|---|---|---|---|---|
| DAM heartbeat | exact log | yes/no | yes/no + delta seconds | process-capable/not proven |
| NSE push | exact log | yes/no | yes/no + delta seconds | process-capable/not proven |

Branch rule for later plans:

- only successful start/replace operations, an absent stopped/superseded callback, and the matching replacement callback in the explicit canonical-timezone schedule count as process-capable;
- throw, missing callback, or ambiguous evidence selects the conservative branch;
- conservative branch means NSE persists newest policy/rule/tombstone and wakes state, while DAM/main-app remains monitor owner; UI cannot claim enforcement before applied-version readback;
- a successful result does **not** permit Phase 3 to choose exact canonical-midnight rebase or NSE-primary production ownership. It records process capability only. Phase 3 must implement the conservative continuous-monitor fallback with stable generation CAS and acknowledgement.
- only a later physical canonical-day-boundary test (Phase 5 or the TestFlight overnight gate) may unlock a context-specific exact-rebase/NSE-primary branch through a separately reviewed plan.

This short probe does not claim canonical-midnight daemon behavior. Virtual
vectors prove rule math, not daemon wakeup at the boundary. The TestFlight
overnight gate remains the physical day-boundary proof, so the conservative
continuous-monitor branch stays mandatory until that gate passes.

- [ ] **Step 7: Commit only the redacted research result**

```bash
git add docs/superpowers/research/2026-07-15-metering-monitor-capability-results.md
git diff --cached --check
git commit -m 'docs: record metering monitor capability spike'
```

---

### Task 7: Run the Phase 1 Gate

**Files:**
- Verify only: all Phase 1 files and existing identity/source/limit suites.

- [ ] **Step 1: Run all Swift Phase 1 tests plus existing regression pins**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/MeteringEpochVectorCoverageTests \
  -only-testing:Evlin\ iOSTests/MeteringEpochContractTests \
  -only-testing:Evlin\ iOSTests/MeteringEpochGoldenVectorTests \
  -only-testing:Evlin\ iOSTests/MeteringMonitorCapabilityProbeTests \
  -only-testing:Evlin\ iOSTests/EarnedBudgetArmingTests \
  -only-testing:Evlin\ iOSTests/EarnedSampleReporterTests \
  -only-testing:Evlin\ iOSTests/AppLimitWireContractTests \
  -only-testing:Evlin\ iOSTests/TaskPauseShieldMappingTests \
  -only-testing:Evlin\ iOSTests/SelectedSetClientTests
```

- [ ] **Step 2: Run Python Phase 1 and adjacent contracts**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
EVLIN_TEST_DATABASE_URL='postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test' \
  .venv/bin/pytest \
  tests/test_metering_epoch_vector_contract.py \
  tests/services/test_metering_monitor_probe_payload.py \
  tests/test_command_delivery_apns.py::test_metering_monitor_probe_serializes_mutable_alert \
  tests/test_earned_time_sample.py \
  tests/test_metering_gate.py \
  tests/test_app_limit_wire_contract.py \
  tests/test_app_limit_delivery.py \
  tests/test_selected_set_lock.py \
  -q
```

- [ ] **Step 3: Rebuild all iOS device classes/configurations**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPad (A16)'
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -configuration Release -destination 'generic/platform=iOS'
```

- [ ] **Step 4: Audit fixture and worktree boundaries**

```bash
cmp \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json
git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS status --short
git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend status --short
```

Expected: unrelated pre-existing dirty files may remain, but no credentials, APNs token, UDID, extracted plist, DerivedData, `.DS_Store`, or debugger state is staged.

- [ ] **Step 5: Review checkpoint**

Do not start Phase 2 until review confirms:

1. all 23 vectors execute in both languages from byte-identical input;
2. V01 proves one install over 20 virtual minutes and V02 proves offset is not identity;
3. every rejected callback has exactly zero effects;
4. V21/V22 use canonical timezone, not process timezone;
5. V18 leaves meter state byte-identical;
6. V23 preserves a clear tombstone and newest-wins ordering;
7. physical DAM/NSE capability results are explicit and reproducible, use only
   `process-capable`/`not proven` labels, and leave Phase 3 on the conservative
   continuous-monitor branch regardless of the short-probe result;
8. PushApplier Debug and Release both advertise deployment target 17.6;
9. `--monitor-probe` cannot broadcast and sends only with exactly one explicit token.

Phase 1 completion does **not** mean the three time products are fixed. It means their rules are executable and the Apple process-owner decision is known. Production migration begins in Phase 2 and is not complete until Phases 2-5 plus the physical gates pass.
