# Metering Epoch Phase 6 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish C-3 single-writer closure, reconcile R-16 T1-T10 with independently reversible demolition evidence, and prepare the legacy device-total counter for removal without crossing its one-release observation gate or Fred's T10 approval gate.

**Architecture:** Phase 3's Device Epoch Store, immutable routes, physical trust function, and earned-effect CAS are the replacement authority. Phase 6 does not invent another metering guard. It first proves C-3 is complete, then attests the already independent Phase 3 demolitions for T1-T5/T7/T8, adds a registered and removable T6 observation switch, removes the truly dead T9 blob in its own commit, and produces a machine-readable ledger. T6 remains `PENDING_ONE_RELEASE`; T10 remains `PENDING_FRED_APPROVAL`. Therefore this plan can finish all local automation while truthfully leaving Phase 6 incomplete and not releasable.

**Tech Stack:** Python 3.11 through the Backend virtual environment, FastAPI, SQLAlchemy 2, PostgreSQL disposable regression runner, Swift 5, XCTest, DeviceActivity, ManagedSettings, Xcode 26.3, JSON evidence ledgers.

## Global Constraints

- Work only in `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS` and `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend`; do not create a worktree.
- Before every task, record `git status --short` in both repositories. Never restore, stage, or edit a pre-existing dirty path unless the task explicitly lists it and its baseline diff is captured first.
- C-3 is Gate 0. All three commits and its completion report must exist before Task 1. Phase 6 may not absorb, squash, rename, or silently reimplement those commits.
- The canonical Phase 3, Phase 4, and Phase 5 automated handoffs and their immutable attestations must pass before demolition. Their legal status is `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE`; physical completion is not required and must not be inferred. A missing predecessor commit or vector returns execution to that phase's plan; Phase 6 does not patch around it.
- Every `REMOVED` R-16 row must name its replacement contract, exact vector IDs, raw evidence hashes, repository, independently revertible demolition SHA, and literal `git revert <sha>` command. A commit subject alone is insufficient.
- Existing Phase 3 removal commits for T1-T5/T7/T8 remain the demolition commits. Their Phase 6 tasks add fail-closed attestation only. Do not make duplicate production edits when source-absence tests are already green.
- T6 must remain `PENDING_ONE_RELEASE`. This plan may add the default-off observation switch and telemetry, but contains no step that deletes `BigKidActivityScheduler`, `evlin.bigkid.freeplay`, `evlin.bigkid.chunk`, `BigKidExtensionReporter.reportChunk`, or `/child/time-consumption`.
- T10 must remain `PENDING_FRED_APPROVAL`. No test result, elapsed time, release evidence, issue comment, or agent inference counts as Fred's approval. This plan contains no step that deletes or changes the compatibility endpoints.
- Preserve all manual, task-pause, reflection, limit, admin, block, and unknown future lock sources. Profile/Home manual actions never remove automatic sources or create an automatic override.
- R-16 final target is exactly two earned guards, identity match and physical trust, plus explicit gate state. Any additional Boolean, veto, latch, freshness window, ceiling, or alternate lifecycle fails the recount unless registered with replacement and deletion criteria.
- Use literal installed destinations `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1` and `platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1`, with `IPHONEOS_DEPLOYMENT_TARGET=17.6`, `TARGETED_DEVICE_FAMILY='1,2'`, and `-parallel-testing-enabled NO`.
- Pure Backend tests use `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest`. Every touched DB suite also uses `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py`; skipped DB tests are failures, not evidence.
- Do not push, deploy, upload TestFlight, contact production APNs, access production services, read or mutate a production database, change production feature flags, or create a release. Local DB commands use only the guarded disposable runner.
- Each task is RED -> minimal implementation or attestation -> focused GREEN -> full affected regression -> exact-path staging -> precise commit. A demolition and its later SHA attestation are separate commits when self-reference would otherwise be impossible.
- Before every commit run `git diff --cached --check`, inspect `git diff --cached`, and require `git diff --cached --name-only` to contain only the paths listed by that step. Never use `git add .` or `git add -A`.

## Required Completion Inputs

| Input | Fixed path or proof | Required state |
|---|---|---|
| C-3 plan | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/plans/2026-07-15-lock-single-writer-c3.md` | all three exact commits present |
| C-3 report | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-15-lock-single-writer-c3-completion.md` | writer inventory closed |
| Phase 3 report | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md` | automated pass, physical truth preserved |
| Phase 3 Task 29 attestation | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/.superpowers/evidence/metering-phase3/report-commit-attestation.json` plus `scripts/verify_metering_phase3_completion.sh` and `MeteringPhase3CompletionVerifierTests.swift` | report blob/commit bound; final mode zero |
| Phase 4 report | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md` | newest-token/tombstone pass |
| Phase 4 gate | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase4.sh` and `Evlin iOSTests/MeteringPhase4CompletionVerifierTests.swift` | `--automated` zero; `--release` fails `physical_gate_pending` |
| Phase 5 report | `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-5-completion.md` | G-17/G-18/G-19 automated pass |
| Rule-book hash | `/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md` section 11 | T1-T10/R-16 content hash recorded |

Each Phase 3/4/5 report row above must contain exactly `AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE`. Phase 3 plan `PASS` is not evidence. Phase 4 Task 17 directly creates the canonical completion report; no subordinate automated report is a dependency. Task 18's separate `2026-07-17-metering-phase4-physical.md` may be hash-attested as pending evidence but never replaces the canonical handoff.

## Gate 0: Complete C-3 As Its Own Work Item

Gate 0 is not a Phase 6 implementation task. Execute the existing C-3 plan exactly, including its RED/GREEN cycles and these independent commits:

```text
fix: route reflection web access through lock records
fix: route home lock controls through records
refactor: remove dead screen time shield writers
```

The C-3 plan predates the final Phase 3/4/5 interfaces. Before running its first RED test, mechanically re-anchor its assumptions against the current `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/ActiveLockStore.swift`, `Evlin iOS/Models/ShieldRecord.swift`, `Evlin iOS/Services/ScreenTimeManager.swift`, and `Evlin iOS/Views/Child/BigKid/Reflection/BigKidVideoView.swift`, plus a repository-wide main-app ManagedSettings writer inventory. Naming, initializer, and line-number drift may be recorded as a naming-only re-anchor in the C-3 completion report. Any semantic drift, file-ownership drift, changed projection/source precedence, or different writer inventory requires a C-3 plan revision and fresh review before implementation. Do not execute against stale line numbers, create another writer, or route around `ActiveLockStore`.

- [ ] Record the current declarations/callers for `ActiveLockStore`, `ShieldRecord`, `ScreenTimeManager`, and `BigKidVideoView`, and compare them field-by-field with C-3 Tasks 1-3.
- [ ] Inventory every production assignment to ManagedSettings shield/block fields by target/process. Require `ActiveLockStore` to remain the only main-app writer; target-specific DAM/Push behavior must match the reviewed ownership map.
- [ ] Classify every difference as naming/line-only or semantic/ownership. Stop for plan revision and re-review on the latter; do not add an adapter writer.
- [ ] Run the C-3 focused tests on the installed phone simulator and its Release build exactly as the C-3 plan specifies.
- [ ] Require `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-15-lock-single-writer-c3-completion.md` to name all remaining target/process-specific ManagedSettings writers and no unexplained main-app writer.
- [ ] Verify each subject resolves exactly once between the recorded C-3 base and report SHA, and that every later commit contains only its declared C-3 paths.
- [ ] Run the final architecture scans from the C-3 plan. Any direct reflection/Home writer or surviving dead API stops Phase 6.
- [ ] Do not amend, squash, or fold C-3 into Task 1. Record its three SHAs as Phase 6 dependencies.

## Demolition Ledger Contract

The fixed ledger path is `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`. It contains exactly T1-T10 once each. Each row has:

```json
{
  "id": "T1",
  "status": "REMOVED",
  "legacy_mechanism": "scalar arm signature churn",
  "replacement": ["MeteringGenerationKey", "immutable dated routes"],
  "deletion_criterion": "replacement vectors and source-absence test pass",
  "replacement_commits": [{"repository": "ios", "sha": "40 lowercase hex"}],
  "vectors": ["V01", "V02"],
  "evidence": [{"path": "absolute path", "sha256": "64 lowercase hex"}],
  "demolition_commit": {"repository": "ios", "sha": "40 lowercase hex"},
  "revert_command": "git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS revert <sha>",
  "forbidden_symbols": ["symbol assembled by verifier"],
  "release_observation": null,
  "fred_approval": null
}
```

Development status `UNATTESTED` is allowed only with `--allow-unattested`. Final mode permits `REMOVED`, `PENDING_ONE_RELEASE`, `PENDING_FRED_APPROVAL`, or `RETAINED_FRED_WAIVER`; this plan permits no waiver. A pending row has `demolition_commit: null` and `revert_command: null`. T6 additionally names its observation commits and deletion criterion; T10 names the exact written approval artifact that is absent.

---

### Task 1: Establish the Fail-Closed R-16 Ledger and Verifier

**Repository:** iOS.

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`

**Interfaces:** The verifier accepts `--ios-root`, `--backend-root`, `--ledger`, `--allow-unattested`, and `--final`. It parses JSON structurally, resolves commits in the named repository, checks ancestry and exact subjects, hashes evidence files, scans forbidden production symbols without matching test literals, and refuses to promote pending rows.

- [ ] **Step 1: Write RED tests before the verifier exists**

Fixture tests cover duplicate/missing T IDs, unknown status, malformed SHA, commit outside prerequisite ancestry, subject-only evidence, wrong evidence hash, replacement commit after demolition, missing revert command, revert SHA mismatch, missing vector, forbidden symbol present, T6 marked removed, T10 marked removed, and any pending row carrying a demolition SHA.

```swift
func test_t6CannotBeRemovedByAutomation() throws {
    let result = try runVerifier(fixture: "t6-removed", mode: .final)
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("T6_requires_one_release"))
}

func test_t10CannotBeApprovedByInference() throws {
    let result = try runVerifier(fixture: "t10-auto-approved", mode: .final)
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("T10_requires_Fred_written_approval"))
}
```

- [ ] **Step 2: Run RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests'
```

Expected RED: the script and ledger are absent.

- [ ] **Step 3: Implement schema validation and seed rows**

Seed T1-T5/T7-T9 as `UNATTESTED`, T6 as `PENDING_ONE_RELEASE`, and T10 as `PENDING_FRED_APPROVAL`. Register the T6 switch as net-new temporary deprecation state that replaces no runtime safety guard and must be deleted with T6 after one observed release. Build forbidden tokens from segments in tests/verifier so source scans do not match themselves.

- [ ] **Step 4: Run structural GREEN, then prove final mode is still RED**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --allow-unattested
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --final
```

Expected: XCTest and `--allow-unattested` pass; `--final` fails with exactly the unattested rows, while T6/T10 are accepted only as pending.

- [ ] **Step 5: Commit exact files**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- scripts/verify_metering_phase6_demolition.py 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'test: establish R-16 demolition ledger'
```

---

### Task 2: Attest R-16 T1 Arm-Signature Demolition

**Repository:** iOS.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`

**Replacement:** Six-field `MeteringGenerationKey`, raw persisted-selection digest, and eight immutable dated routes. **Vectors:** V01/V02/V03/V06/V07/V24 plus the 121-reconciliation real-installer log. **Demolition subject:** `refactor: remove earned arm signature churn`.

- [ ] **Step 1: Add a failing T1 ledger/source test**

Require T1 `REMOVED`, replacement and exact vectors, valid predecessor SHA, and absence of the scalar key/helper/fingerprint family. Assemble each forbidden string from pieces. Run:

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT1Attestation'
```

Expected RED: T1 is `UNATTESTED`.

- [ ] **Step 2: Verify replacement before changing the ledger**

Run the original Phase 3 T1 source test and replacement vectors:

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT1DemolitionTests' -only-testing:'Evlin iOSTests/DatedRouteInstallerTests' -only-testing:'Evlin iOSTests/MeteringCoverageIntegrationTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests'
```

Expected GREEN: starts remain `8,0`, stops remain `0`, and the forbidden family is absent. If the exact demolition subject is missing or any source symbol survives, stop and execute Phase 3 Task 22; do not edit production here.

- [ ] **Step 3: Add exact immutable evidence**

Resolve the unique removal SHA between the Phase 3 base and completion SHA, hash the focused log, set T1 to `REMOVED`, and record `git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS revert <exact-sha>`.

- [ ] **Step 4: Run GREEN and commit attestation only**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT1Attestation'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --allow-unattested
git add -- 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: attest R-16 T1 demolition'
```

---

### Task 3: Attest R-16 T2 Raw-Ceiling Demolition

**Repository:** iOS.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`

**Replacement:** Owner/epoch identity, immutable route provenance, route tombstone, and physical trust. **Vectors:** V04/V05/V08/V13/V27. **Demolition subject:** `refactor: remove stale raw threshold ceiling`.

- [ ] **Step 1: Add and run RED**

Require a T2 `REMOVED` row, its replacement, exact vectors, unique SHA/revert command, source absence, delayed trusted acceptance, and old-route zero effects.

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT2Attestation'
```

Expected RED: T2 is `UNATTESTED`.

- [ ] **Step 2: Verify predecessor removal and replacement GREEN**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT2DemolitionTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' -only-testing:'Evlin iOSTests/MeteringRolloverRecoveryTests'
```

If the exact subject or GREEN evidence is absent, return to Phase 3 Task 23. Add no renamed ceiling, quarantine, or latch.

- [ ] **Step 3: Record SHA, log hash, vectors, and literal revert command**

Set only T2 to `REMOVED`; leave every later row unchanged.

- [ ] **Step 4: Run GREEN and commit**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT2Attestation'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --allow-unattested
git add -- 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: attest R-16 T2 demolition'
```

---

### Task 4: Attest R-16 T3 Fresh-At-Fire Demolition

**Repository:** iOS.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`

**Replacement:** Strict callback trust, active epoch gate, terminal event plan, and earned shield effect envelope. **Vectors:** V04/V05/V10/V12/P3V01. **Demolition subject:** `refactor: remove earned fresh-at-fire gate`.

- [ ] **Step 1: Add and run RED**

Require T3 `REMOVED`, exact vector/log/SHA evidence, absence of the old helper and any renamed freshness window, immediate impossible rejection, delayed trusted lock, and paused/reflection zero effects.

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT3Attestation'
```

Expected RED: T3 is `UNATTESTED`.

- [ ] **Step 2: Verify predecessor GREEN before attestation**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT3DemolitionTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' -only-testing:'Evlin iOSTests/MeteringConservativeResumeTests'
```

If absent or red, return to Phase 3 Task 24; do not create a replacement freshness Boolean.

- [ ] **Step 3: Record T3 evidence, run GREEN, and commit**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT3Attestation'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --allow-unattested
git add -- 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: attest R-16 T3 demolition'
```

---

### Task 5: Attest R-16 T4 Backend-Headroom-Veto Demolition

**Repository:** iOS, consuming Backend and Phase 5 evidence without editing Backend.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`

**Replacement:** Trusted local exhaustion, durable earned-effect envelope, exact-source CAS correction, and Phase 5 per-device owner/source readback. **Vectors:** V15/V16/P3V01/P3V02 plus P5V08/P5V09/P5V10/P5V12. **Demolition subject:** `refactor: remove earned backend headroom veto`.

- [ ] **Step 1: Add and run RED**

Require T4 `REMOVED`, both phase dependency SHAs, exact vectors, no 600-second/five-minute self-lock veto, immediate trusted local lock, exact-source correction, and stale-actor byte preservation.

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT4Attestation'
```

Expected RED: T4 is `UNATTESTED`.

- [ ] **Step 2: Verify replacement through both phases**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT4DemolitionTests' -only-testing:'Evlin iOSTests/EarnedShieldEffectStoreTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase5VectorTests' -only-testing:'Evlin iOSTests/ActiveLockStoreTests'
```

Expected GREEN: local lock does not wait for backend headroom; later correction releases only the recorded earned effect; Phase 5 readback preserves device/source attribution. If not, return to Phase 3 Task 25 or Phase 5 Task 9 as identified by the failing vector.

- [ ] **Step 3: Record both replacement lineages and commit**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT4Attestation'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --allow-unattested
git add -- 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: attest R-16 T4 demolition'
```

---

### Task 6: Attest R-16 T5 Plus-Five Demolition Across Both Repositories

**Repository:** iOS ledger, consuming iOS and Backend evidence.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`

**Replacement:** One strict physical bound, `delta_minutes * 60 <= elapsed_seconds + jitter`, with 30-second default and 60-second maximum. **Vectors:** V04/V05/V19/V30. **Demolition subject:** `refactor: remove earned plus-five heuristic`.

- [ ] **Step 1: Add and run RED**

Require T5 `REMOVED`, exact SHA and vectors, no five-minute allowance in iOS or Backend, immediate t5 rejection, 269/270/271 boundary behavior at 30-second jitter, 60-second maximum, and delayed physically possible acceptance.

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT5Attestation'
```

Expected RED: T5 is `UNATTESTED`.

- [ ] **Step 2: Verify iOS replacement and Backend contract**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT5DemolitionTests' -only-testing:'Evlin iOSTests/EarnedMeteringCallbackTests' -only-testing:'Evlin iOSTests/MeteringProductionIntegrationTests' -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests'
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest -q tests/test_metering_epoch_vector_contract.py
```

Expected GREEN: both languages implement the same strict inequality. If the Backend still has a distinct `_sample_is_plausible` plus-five branch, stop and add its RED/removal as a separately reviewed Backend demolition commit before attestation; never hide it under the iOS SHA.

- [ ] **Step 3: Record cross-repository source scan hashes, run GREEN, and commit**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT5Attestation'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --allow-unattested
git add -- 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: attest R-16 T5 demolition'
```

---

### Task 7: Add Backend T6 Observation Mode Without Removing the Legacy Endpoint

**Repository:** Backend.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/core/settings.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/schemas/bigkid.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/bigkid_child.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/screen_time_event_service.py` only if its existing emitter cannot express the row below
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_legacy_device_total_observation.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_bigkid_endpoints.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_gate.py`

**Interfaces:** Add additive `ChildStateResponse.legacy_device_total_mode: Literal["active", "observe_disabled"] = "active"` and local setting `metering_legacy_device_total_mode`, default `active`. Only a verified protocol-2 device may receive `observe_disabled`. Missing fields and protocol-1 devices remain active. A request to `/child/time-consumption` in observation mode records a durable per-device event and returns current legacy state without decrementing `BigKidStore`; the endpoint remains present and wire-compatible.

The event contract is:

```text
kind=sample
source=legacyDeviceTotal
reason=accepted_active | observed_while_disabled
device_id=<authenticated device>
metadata.mode=active | observe_disabled
metadata.metering_protocol_version=1 | 2
metadata.minutes_used=<request value>
```

- [ ] **Step 1: Write the failing compatibility and real-row tests**

Pin all matrix rows:

| Device/setting | State response | `/time-consumption` effect |
|---|---|---|
| protocol 1 / active | active | one legacy-bank decrement + `accepted_active` |
| protocol 1 / observe setting | active | one legacy-bank decrement + `accepted_active` |
| protocol 2 / active | active | one legacy-bank decrement + `accepted_active` |
| protocol 2 / observe setting | observe_disabled | zero bank mutation + `observed_while_disabled` |
| wrong device identity | no trusted response | zero bank/event mutation |

Also require the observation row to survive a fresh SQLAlchemy session and process-local `BigKidStore` recreation.

- [ ] **Step 2: Run RED through real entry points**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/test_metering_legacy_device_total_observation.py tests/test_bigkid_endpoints.py tests/test_metering_gate.py
```

Expected RED: response field, setting, no-mutation branch, and durable observation row are absent. The DB runner itself must execute; a skip is not RED evidence.

- [ ] **Step 3: Implement the smallest registered T6 switch**

Use one enum-valued setting, not parallel Booleans. Resolve effective mode from authenticated device protocol and setting. Emit through `screen_time_event_service` in the caller transaction. Do not create another table or migration. Do not delete or rename `/child/time-consumption`, and do not alter task/reflection counting gates for active legacy clients.

- [ ] **Step 4: Run focused and full Backend GREEN**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/test_metering_legacy_device_total_observation.py tests/test_bigkid_endpoints.py tests/test_metering_gate.py tests/test_screen_time_events_api.py tests/test_earned_time_protocol_ratchet.py
```

Expected GREEN: compatibility matrix and durable rows pass without skips; protocol 1 remains functional; observation mode mutates no legacy bank.

- [ ] **Step 5: Commit only Backend observation code**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
git add -- app/core/settings.py app/schemas/bigkid.py app/api/routes/bigkid_child.py app/services/screen_time_event_service.py tests/test_metering_legacy_device_total_observation.py tests/test_bigkid_endpoints.py tests/test_metering_gate.py
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'feat: observe disabled legacy device totals'
```

If `screen_time_event_service.py` required no edit, omit it from `git add`. Record this Backend SHA for Task 8; do not deploy or change a production setting.

---

### Task 8: Honor T6 Observation Mode on iOS and Keep T6 Pending

**Repository:** iOS, consuming Task 7's Backend SHA.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Models/BigKid/BigKidModels.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/BigKidStatePoller.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidModelsTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/BigKidStatePollerTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/LegacyDeviceTotalObservationTests.swift`
- Modify after the code commit: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Modify after the code commit: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`

**Interfaces:** Decode missing `legacy_device_total_mode` as `.active`. On `.observeDisabled`, `BigKidStatePoller` stops only `evlin.bigkid.freeplay`, does not start/restart that legacy activity, and keeps earned v2 recovery, command polling, and command-heartbeat diagnostics unchanged. A late chunk remains harmless because Task 7 makes the endpoint no-op in this mode.

- [ ] **Step 1: Write RED before changing models or poller**

Test missing-field decode, known enum decode, unknown-value fail-safe to active, active start, disabled stop, disabled restart, transition active -> disabled -> active, protocol-1 compatibility, and independence from `EarnedMeteringRecoveryDriver`. Source tests require the four T6 chain symbols to remain present because this task is observation, not deletion.

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/BigKidModelsTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' -only-testing:'Evlin iOSTests/LegacyDeviceTotalObservationTests'
```

Expected RED: wire enum and disabled transition do not exist.

- [ ] **Step 2: Implement additive decoding and one poller branch**

Use an enum with custom unknown-value fallback to `.active`. Inject legacy start/stop actions into the existing poller test seam. Do not add a persisted disabled latch: each authoritative child-state response owns the mode, and missing/unknown data remains active for rollback safety.

- [ ] **Step 3: Run focused and affected GREEN**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/BigKidModelsTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests' -only-testing:'Evlin iOSTests/LegacyDeviceTotalObservationTests' -only-testing:'Evlin iOSTests/MeteringProductionIntegrationTests' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests'
```

Expected GREEN: only legacy freeplay scheduling stops; v2 metering and command delivery remain active.

- [ ] **Step 4: Commit iOS behavior separately**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- 'Evlin iOS/Models/BigKid/BigKidModels.swift' 'Evlin iOS/Services/BigKidStatePoller.swift' 'Evlin iOSTests/BigKidModelsTests.swift' 'Evlin iOSTests/BigKidStatePollerTests.swift' 'Evlin iOSTests/LegacyDeviceTotalObservationTests.swift'
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'feat: honor legacy total observation mode'
```

- [ ] **Step 5: RED the T6 ledger, then attest pending state**

Extend `testT6PendingOneRelease` to require the exact Backend and iOS observation SHAs, compatibility vectors, local log hashes, null demolition/revert fields, and these unfulfilled physical fields:

```json
{
  "release_observation": {
    "release_id": null,
    "started_at": null,
    "ended_at": null,
    "eligible_devices": null,
    "legacy_callbacks_after_disable": null,
    "earned_runtime_failures": null,
    "evidence_sha256": null
  }
}
```

Run the focused test before editing the ledger and require RED because observation SHAs are absent. Then set only those automated fields; status stays `PENDING_ONE_RELEASE`.

- [ ] **Step 6: Verify and commit pending attestation**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT6PendingOneRelease'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --allow-unattested
git add -- 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: record T6 one-release gate pending'
```

There is intentionally no deletion task after this step. A later human-reviewed plan may remove T6 only after a real released version fills every observation field and independently verifies no remaining production consumer.

---

### Task 9: Attest R-16 T7 Counter-Recovery-Flag Demolition

**Repository:** iOS.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`

**Replacement:** Epoch-scoped paused high-water, `excludedWhilePausedMinutes`, one `resumeBoundaryPending`, conservative replacement, and deterministic recovery work. **Vectors:** V06/V10/V11/V12/V33/V34. **Demolition subject:** `refactor: remove earned counter recovery flags`.

- [ ] **Step 1: Add and run RED**

Require T7 `REMOVED`, exact vectors/SHA/revert command, no counter-recovery or pending-uncounted flag/key family, restart convergence, and exactly one boundary discard.

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT7Attestation'
```

Expected RED: T7 is `UNATTESTED`.

- [ ] **Step 2: Verify predecessor and replacement GREEN**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT7DemolitionTests' -only-testing:'Evlin iOSTests/MeteringConservativeResumeTests' -only-testing:'Evlin iOSTests/MeteringEpochDeliveryTests' -only-testing:'Evlin iOSTests/BigKidStatePollerTests'
```

If the subject or evidence is absent, return to Phase 3 Task 27. Do not add another recovery latch.

- [ ] **Step 3: Attest, run GREEN, and commit**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT7Attestation'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --allow-unattested
git add -- 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: attest R-16 T7 demolition'
```

---

### Task 10: Attest R-16 T8 Duplicate-Lifecycle Demolition

**Repository:** iOS.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`

**Replacement:** Device Epoch Store route/install lifecycle, `LegacyCompatibilityMonitorState`, identity cleanup work, and one-shot schema import. **Vectors:** V01/V08/V09/V13/V21/V22/V28/V36/V37/V38. **Demolition subject:** `refactor: retire duplicate earned activity lifecycle`.

- [ ] **Step 1: Add and run RED**

Require T8 `REMOVED`, exact vectors/SHA/revert command, absence of the old type/key authority, and functional v1 behavior through offline, registration-only, failed-v2, restart, and verified activation states.

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT8Attestation'
```

Expected RED: T8 is `UNATTESTED`.

- [ ] **Step 2: Verify all replacement targets and compatibility**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT8DemolitionTests' -only-testing:'Evlin iOSTests/MeteringColdReopenRecoveryTests' -only-testing:'Evlin iOSTests/MeteringV2ActivationTests' -only-testing:'Evlin iOSTests/MeteringIdentityCleanupTests' -only-testing:'Evlin iOSTests/AuthServiceTests'
xcodebuild build -project 'Evlin iOS.xcodeproj' -target 'Evlin iOS' -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2'
xcodebuild build -project 'Evlin iOS.xcodeproj' -target 'EvlinDeviceActivityMonitor' -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2'
xcodebuild build -project 'Evlin iOS.xcodeproj' -target 'EvlinPushApplier' -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2'
```

If the predecessor subject or any replacement target is absent, return to Phase 3 Task 28. Do not remove v1 compatibility behavior itself.

- [ ] **Step 3: Attest, run GREEN, and commit**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT8Attestation'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --allow-unattested
git add -- 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: attest R-16 T8 demolition'
```

---

### Task 11: Remove and Independently Attest R-16 T9 Dead Token Data

**Repository:** iOS.

**Files for demolition commit:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Services/ActionExecutor.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOS/Components/Debug/CommandDeliveryDiagnosticsView.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/EarnedTimeStoreTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/ActionExecutorTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/RecordKeyMigrationTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/LockedSetFullCoverageTests.swift`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringT9DemolitionTests.swift`

**Files for later attestation commit:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`

**Replacement:** No new mechanism. `DefaultLockGroupStore` remains token authority, and `ActiveLockStore` plus `EarnedShieldEffectStore` remain source/effect authority. **Vectors:** P3V01/P3V02, `LockedSetFullCoverageTests`, `DefaultLockGroupStoreTests`, `ActiveLockStoreTests`, and `ActionExecutorTests`.

- [ ] **Step 1: Write the failing source and behavior tests**

Build the legacy property/key token from segments and require zero matches in production Swift. Prove full default-group coverage in DAM, exact-source shield CAS, and ActionExecutor rollback without snapshotting the dead blob. Require unrelated `earned.lockedSetID`, alias, and all-selected state to remain unchanged.

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT9DemolitionTests' -only-testing:'Evlin iOSTests/LockedSetFullCoverageTests' -only-testing:'Evlin iOSTests/ActionExecutorTests'
```

Expected RED: the store property/key, DAM fallback, ActionExecutor snapshot, diagnostics, and legacy tests still reference the blob.

- [ ] **Step 2: Delete only the dead path**

Remove the property, key constant, round-trip/reset assertions, DAM fallback/comments, ActionExecutor snapshot/restore field, and debug row. Do not replace it with another optional blob, do not alter selected-set identity, and do not weaken default-group full-coverage logic. Existing orphaned UserDefaults bytes are ignored; no live migration authority is added for a value whose two writers were already nil.

- [ ] **Step 3: Run focused and full affected GREEN**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringT9DemolitionTests' -only-testing:'Evlin iOSTests/LockedSetFullCoverageTests' -only-testing:'Evlin iOSTests/DefaultLockGroupStoreTests' -only-testing:'Evlin iOSTests/ActiveLockStoreTests' -only-testing:'Evlin iOSTests/ActionExecutorTests' -only-testing:'Evlin iOSTests/MeteringEpochPhase3VectorTests'
```

Expected GREEN: forbidden path is absent and all replacement/source-union behavior passes.

- [ ] **Step 4: Commit the demolition by itself**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- 'Evlin iOS/Services/EarnedTimeStore.swift' 'EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift' 'Evlin iOS/Services/ActionExecutor.swift' 'Evlin iOS/Components/Debug/CommandDeliveryDiagnosticsView.swift' 'Evlin iOSTests/EarnedTimeStoreTests.swift' 'Evlin iOSTests/ActionExecutorTests.swift' 'Evlin iOSTests/RecordKeyMigrationTests.swift' 'Evlin iOSTests/LockedSetFullCoverageTests.swift' 'Evlin iOSTests/MeteringT9DemolitionTests.swift'
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'refactor: remove dead earned locked token data'
```

- [ ] **Step 5: RED then record the now-known demolition SHA**

Add `testT9Attestation`; run it before the ledger edit and require RED. Resolve the unique exact-subject SHA, hash the GREEN log, set T9 `REMOVED`, and record the literal revert command. The ledger commit must not include production files.

- [ ] **Step 6: Verify and commit T9 attestation separately**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testT9Attestation'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --allow-unattested
git add -- 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: attest R-16 T9 demolition'
```

---

### Task 12: Recount Guards, Freeze T10 Pending, and Record the Honest Boundary

**Repository:** iOS report/verifier, consuming both repositories' immutable evidence.

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-completion.md`

**T10 replacement:** Pure manual selected-set CTA plus separate earned override endpoint/action. **Evidence:** Backend `tests/test_selected_set_lock.py`, `tests/test_earned_time_lock_receipts.py`, iOS `ReceiptUnlockRoutingTests`, `OverrideSuppressionTests`, `ProfileSnapshotTests`, and C-3 Home routing evidence. **Status:** exactly `PENDING_FRED_APPROVAL`; `demolition_commit`, `revert_command`, and `fred_approval` remain null.

- [ ] **Step 1: Write final-mode RED tests**

Require:

1. T1-T5/T7-T9 are `REMOVED` with valid replacement-before-demolition ancestry, vectors, hashes, SHA, and revert command.
2. T6 is `PENDING_ONE_RELEASE` with exact observation commits but null release evidence and no demolition SHA.
3. T10 is `PENDING_FRED_APPROVAL`, old compatibility routes still exist, pure manual and separate override replacements pass, and approval is null.
4. Production earned guards recount to identity match + physical trust + gate state only.
5. No unregistered guard/flag/veto exists, except the ledgered temporary T6 observation enum.
6. The completion report cannot contain `COMPLETE`, `RELEASABLE`, or physical pass language while T6/T10 are pending.

Run before adding final checks/report:

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests/testFinalReconciliation'
```

Expected RED: final report and recount contract are absent; T10 automated evidence is not yet pinned.

- [ ] **Step 2: Verify T10 replacements without changing compatibility behavior**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/test_selected_set_lock.py tests/test_earned_time_lock_receipts.py tests/test_effective_state_sources.py
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' -only-testing:'Evlin iOSTests/ReceiptUnlockRoutingTests' -only-testing:'Evlin iOSTests/OverrideSuppressionTests' -only-testing:'Evlin iOSTests/ProfileSnapshotTests'
```

Expected GREEN: manual unlock removes only manual coverage; earned/task/reflection/limit sources survive; override remains a separate explicit action. Do not edit `/parent/device/unlock-selected` or `/parent/child/unlock-selected`.

- [ ] **Step 3: Implement final ledger checks and report**

Set T10's automated replacement vectors/hashes while leaving its approval fields null. Extend final mode to inventory all guards from production source and compare to a named allowlist generated from the Phase 3 contract; a raw numeric count without symbol names fails. The completion report includes this exact table shape:

| Row | Legacy mechanism | Replacement | Vector/log evidence | Demolition SHA/revert | Status |
|---|---|---|---|---|---|
| T1-T5 | one row each | exact contract | exact IDs + SHA-256 | exact SHA/command | REMOVED |
| T6 | legacy device-total chain | earned runtime authority | automated observation only | none | PENDING_ONE_RELEASE |
| T7-T9 | one row each | exact contract | exact IDs + SHA-256 | exact SHA/command | REMOVED |
| T10 | superseded unlock contract | manual CTA + separate override | automated replacement only | none | PENDING_FRED_APPROVAL |

The only allowed overall status is:

```text
AUTOMATED DEMOLITION READY; T6/T10 PENDING; PHASE 6 INCOMPLETE; NOT RELEASABLE
```

- [ ] **Step 4: Run complete local automation on both simulators**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend'
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python -m pytest -q tests/test_metering_epoch_vector_contract.py
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py tests/test_metering_legacy_device_total_observation.py tests/test_selected_set_lock.py tests/test_earned_time_lock_receipts.py tests/test_metering_gate.py
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2'
xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2'
DERIVED="$PWD/.superpowers/evidence/metering-phase6/DerivedData-Release"
rm -rf "$DERIVED"
xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build-for-testing
for target in 'Evlin iOS' 'EvlinDeviceActivityMonitor' 'EvlinDeviceActivityReport' 'Evlin iOSTests' 'EvlinShieldConfig' 'EvlinPushApplier'; do
  xcodebuild -project 'Evlin iOS.xcodeproj' -target "$target" -configuration Release -destination 'generic/platform=iOS' -sdk iphoneos -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build
done
/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/scripts/verify_metering_phase6_demolition.py --final
```

Assert exactly these six nonempty products under `$DERIVED/Build/Products/Release-iphoneos`, and require `file` output for each to contain `Mach-O`:

```text
Evlin iOS.app/Evlin iOS
Evlin iOS.app/PlugIns/EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor
Evlin iOS.app/PlugIns/EvlinDeviceActivityReport.appex/EvlinDeviceActivityReport
Evlin iOS.app/PlugIns/EvlinShieldConfig.appex/EvlinShieldConfig
Evlin iOS.app/PlugIns/EvlinPushApplier.appex/EvlinPushApplier
Evlin iOS.app/PlugIns/Evlin iOSTests.xctest/Evlin iOSTests
```

The verifier counts this manifest, runs `test -s` and `file` on every path, rejects any seventh product, and hashes all six. Expected GREEN: all automated tests, disposable DB suites without skips, both literal simulators, six Release-iphoneos Mach-O products, ledger ancestry/hashes, source absence, and guard recount pass. The verifier exits zero while explicitly preserving the two pending gates; zero means evidence-consistent, not phase complete.

- [ ] **Step 5: Commit the final automated report only**

```bash
cd '/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS'
git add -- scripts/verify_metering_phase6_demolition.py 'Evlin iOSTests/MeteringPhase6DemolitionLedgerTests.swift' docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-completion.md
git diff --cached --check
git diff --cached
git diff --cached --name-only
git commit -m 'docs: record metering phase 6 pending gates'
```

Do not push, deploy, upload TestFlight, change production flags, query production DB, delete T6, delete T10, or mark the report complete.

## One-Release T6 Gate: Human and Release Work Only

This section is a gate definition, not an executable task in this plan. It remains `PENDING` until a separately approved release workflow performs it.

| Evidence | Required before a later T6 removal plan | Current state |
|---|---|---|
| Released version identifier and immutable source SHAs | exact iOS/Backend release | PENDING |
| Observation interval | one complete released version, start/end UTC | PENDING |
| Eligible protocol-2 device count | real production aggregate, no identities in report | PENDING |
| Legacy callbacks after disabled state | classified and explained | PENDING |
| Earned runtime failures/regressions | zero unexplained failures | PENDING |
| Remaining production consumer inventory | independently reviewed zero | PENDING |
| Removal plan/review | separate reversible change, not this plan | PENDING |

Unit, simulator, local DB, branch age, or a calendar interval without a released version cannot satisfy this gate.

## T10 Fred Approval Gate

This gate stays `PENDING_FRED_APPROVAL`. A future removal plan must link a written artifact in which Fred explicitly approves deletion of the superseded compatibility contract after one compatible version. Silence, acceptance of this plan, automated tests, prior architectural discussion, or approval by another person does not qualify. Until then both compatibility routes remain.

## Automated Completion Boundary

Gate 0 and Tasks 1-12 are locally automatable, including T6 instrumentation, T1-T9 automated evidence, T9 deletion, T10 replacement verification, both simulator runs, six Release target builds, and disposable-DB regression. Local automation may produce only `AUTOMATED DEMOLITION READY`.

The one-release T6 observation, real production telemetry review, feature-flag rollout, release creation, TestFlight, deployment, production DB access, and Fred's T10 approval are outside automation. With T6/T10 pending, Phase 6 remains incomplete and not releasable by design.

## Requirements Trace

| Requirement | Plan coverage |
|---|---|
| C-3 single writer first | Gate 0 and immutable three-commit proof |
| T1-T5 reversible reconciliation | Tasks 2-6 |
| T6 one-version observation only | Tasks 7-8 plus human gate; no deletion task |
| T7/T8 reversible reconciliation | Tasks 9-10 |
| T9 dead path deletion | Task 11 independent demolition + attestation commits |
| T10 Fred approval required | Task 12 and explicit pending gate; no deletion step |
| replacement vectors per item | ledger schema and every T1-T10 task |
| demolition ledger evidence | Tasks 1-12, exact SHAs/hashes/revert commands |
| guard count target | Task 12 named inventory, two cores plus gate state |
| real test entry points | absolute venv, disposable DB runner, literal simulators |
| physical/release/manual truth | pending sections and final non-releasable status |

## Self-Review Checklist

- **Dependency pass:** C-3 precedes all Phase 6 tasks; Phase 3/4/5 completion SHAs are fail-closed inputs.
- **R-16 pass:** T1-T10 appear exactly once; every row has replacement/deletion/vector evidence; T6/T10 cannot be promoted automatically.
- **TDD pass:** every task names RED, minimal implementation or attestation, focused GREEN, affected regression, exact staging, and commit subject.
- **Reversibility pass:** predecessor demolitions retain their SHAs; T9 deletion is isolated from its SHA attestation; pending rows have no fake revert command.
- **Command pass:** Backend uses the absolute virtual-environment runner, DB suites use the guarded script, and iOS uses both installed destinations.
- **Boundary pass:** no push, deploy, TestFlight upload, production DB, production flag change, release, T6 deletion, or T10 deletion is executable here.
