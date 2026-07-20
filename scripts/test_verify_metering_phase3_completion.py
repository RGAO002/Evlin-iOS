from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts" / "verify_metering_phase3_completion.sh"

TASKS = (
    ("01", "ios", "test: register phase 3 metering safety states"),
    ("02", "ios", "feat: inject shared metering runtime dependencies"),
    ("03", "backend", "feat: add conservative epoch activation protocol"),
    ("04", "ios", "feat: add exact metering epoch wire DTOs"),
    ("05", "ios", "feat: add atomic device epoch store"),
    ("06", "ios", "feat: queue legacy and epoch samples durably"),
    ("07", "backend", "test: extend backend phase 3 vectors"),
    ("08", "ios", "test: mirror phase 3 vectors in Swift"),
    ("09", "ios", "feat: plan immutable dated metering routes"),
    ("10", "ios", "feat: arbitrate and verify dated route installs"),
    ("11", "ios", "feat: activate v2 without breaking legacy metering"),
    ("12", "ios", "feat: authorize earned callbacks by immutable route"),
    ("13", "ios", "fix: replace route on authoritative base correction"),
    ("14", "ios", "feat: persist earned shield effects across processes"),
    ("15", "ios", "feat: retire metering identity atomically"),
    ("16", "ios", "feat: recover canonical rollover effects"),
    ("17", "ios", "feat: resume metering with conservative replacement"),
    ("18", "ios", "feat: wire production metering and V30 encoder"),
    ("19", "backend", "test: verify V30 exact bytes across the stack"),
    ("20", "ios", "feat: surface bounded metering coverage"),
    ("21", "ios", "feat: recover every metering process entry point"),
    ("22", "ios", "refactor: remove earned arm signature churn"),
    ("23", "ios", "refactor: remove stale raw threshold ceiling"),
    ("23A", "ios", "feat: persist trusted terminal shield receipts"),
    ("24", "ios", "refactor: remove earned fresh-at-fire gate"),
    ("25", "ios", "refactor: remove earned backend headroom veto"),
    ("26", "ios", "refactor: remove earned plus-five heuristic"),
    ("27", "ios", "refactor: remove earned counter recovery flags"),
    ("28", "ios", "refactor: retire duplicate earned activity lifecycle"),
    ("29", "ios", "test: add metering phase 3 completion verifier"),
    ("30", "ios", "docs: record metering phase 3 evidence"),
)

DEPENDENCIES = {"03": "02", "04": "03", "07": "06", "08": "07", "19": "18", "20": "19"}

RELEASE_PRODUCTS = (
    "Release-iphoneos/Evlin iOS.app/Evlin iOS",
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor",
    "Release-iphoneos/Evlin iOS.app/Extensions/EvlinDeviceActivityReport.appex/EvlinDeviceActivityReport",
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinShieldConfig.appex/EvlinShieldConfig",
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinPushApplier.appex/EvlinPushApplier",
)
DEBUG_XCTEST_PRODUCT = "Debug-iphonesimulator/Evlin iOS.app/PlugIns/Evlin iOSTests.xctest/Evlin iOSTests"
VOLATILE_TRACKED_TOKENS = ("xcuserdata/", ".xcuserstate", "xcschememanagement.plist")
AUTHORITATIVE_CORRECTION_TEST = (
    "MeteringAuthoritativeBaseCorrectionTests/"
    "testEveryCorrectionBoundaryReopensWithStableIDsAndConverges()"
)


def _named_failure_baseline() -> dict[str, object]:
    return {
        "format_version": 1,
        "protected_suite_prefixes": ["DeviceEpoch", "Earned", "Metering"],
        "protected_suites": [
            "ActiveLockStoreTests",
            "AuthServiceTests",
            "BigKidStatePollerTests",
            "DatedRouteInstallerTests",
            "DeviceEpochStoreTests",
            "EarnedSampleReporterResponseTests",
            "MeteringAuthoritativeBaseCorrectionTests",
            "ShieldRecordSourceMigrationTests",
            "ShieldSourceSetTests",
            "TaskPauseShieldMappingTests",
        ],
        "authoritative_exception": {
            "baseline_commit": "e46ffe15b45825b20ca1a5b687815cbb340b2f24",
            "failure_text": "failed - locally active corrected route must remain countable",
            "test_identifier": AUTHORITATIVE_CORRECTION_TEST,
            "task24_known_failure_ordinal": 27,
        },
        "debt_tasks": {
            "task_2633a95f": {"title": "MainActor deinit crash family"},
            "task_phase3_legacy_test_debt_20260719": {
                "title": "Retire pre-existing iOS fixture and auth test debt"
            },
        },
        "destinations": {
            "iphone17pro": {
                "failures": [
                    {
                        "category": "deinit_family",
                        "owner": "task_2633a95f",
                        "test_identifier": "LegacyDeinitTests/testCrash()",
                    },
                    {
                        "category": "old_fixture",
                        "owner": "task_phase3_legacy_test_debt_20260719",
                        "test_identifier": "OldFixtureTests/testStale()",
                    },
                ]
            },
            "ipad_m5": {
                "failures": [
                    {
                        "category": "auth_debt",
                        "owner": "task_phase3_legacy_test_debt_20260719",
                        "test_identifier": "AuthDebtTests/testExpired()",
                    },
                    {
                        "category": "deinit_family",
                        "owner": "task_2633a95f",
                        "test_identifier": "LegacyDeinitTests/testCrash()",
                    },
                ]
            },
        },
    }


def _authoritative_birth_evidence() -> dict[str, object]:
    return {
        "baseline_commit": "e46ffe15b45825b20ca1a5b687815cbb340b2f24",
        "baseline_commit_date": "2026-07-18T18:01:53-04:00",
        "failure_text": "failed - locally active corrected route must remain countable",
        "raw_log_sha256": "1" * 64,
        "outcome": "failed",
        "source_blob": "2" * 40,
        "test_identifier": AUTHORITATIVE_CORRECTION_TEST,
        "xcresult_summary_sha256": "3" * 64,
        "xcodebuild_exit_code": 65,
    }


def _git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def _commit(repo: Path, subject: str, body: str = "") -> str:
    marker = repo / "history.txt"
    with marker.open("a", encoding="utf-8") as handle:
        handle.write(subject + "\n")
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
    command = ["git", "-C", str(repo), "commit", "-q", "-m", subject]
    if body:
        command += ["-m", body]
    subprocess.run(command, check=True)
    return _git(repo, "rev-parse", "HEAD")


def _plan_text() -> str:
    creates = [f"/fixture/path-{index}" for index in range(54)]
    modifies = [f"/fixture/path-{54 + index}" for index in range(44)]
    modifies += [f"/fixture/path-{index % 98}" for index in range(125)]
    declarations = [f"- Create: `{path}`" for path in creates]
    declarations += [f"- Modify: `{path}`" for path in modifies]
    sections: list[str] = []
    for index, (label, _, subject) in enumerate(TASKS):
        lines = [f"## Task {label}: Fixture", ""]
        if index == 0:
            lines += declarations
            lines += ["xcodebuild fixture" for _ in range(99)]
        lines += ["", f"git commit -m '{subject}'", ""]
        sections.append("\n".join(lines))
    return "\n".join(sections)


def _untracked_manifest(repo: Path) -> bytes:
    raw = subprocess.check_output(
        ["git", "-C", str(repo), "ls-files", "--others", "--exclude-standard", "-z"]
    )
    rows = []
    for item in sorted(filter(None, raw.split(b"\0"))):
        path = repo / os.fsdecode(item)
        info = path.lstat()
        payload = path.read_bytes()
        rows.append(
            json.dumps(
                {
                    "kind": "file",
                    "mode": stat.S_IMODE(info.st_mode),
                    "path_bytes_hex": item.hex(),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                },
                separators=(",", ":"),
            )
        )
    return (("\n".join(rows) + "\n") if rows else "").encode()


def _write_baselines(root: Path, ios: Path, backend: Path, bases: dict[str, str]) -> None:
    evidence = root / "evidence"
    evidence.mkdir()
    for name, repo in (("ios", ios), ("backend", backend)):
        (evidence / f"{name}-base-sha.txt").write_text(bases[name] + "\n")
        (evidence / f"{name}-status-before.txt").write_text("fixture status\n")
        raw_paths = subprocess.check_output(
            ["git", "-C", str(repo), "diff", "--name-only", "-z"]
        )
        paths = sorted(
            os.fsdecode(raw)
            for raw in raw_paths.split(b"\0")
            if raw and not any(token in os.fsdecode(raw) for token in VOLATILE_TRACKED_TOKENS)
        )
        snapshot = _git(repo, "stash", "create") or None
        files = [
            {
                "blob_sha": _git(repo, "hash-object", "--", path),
                "path": path,
                "reason": "fixture approved WIP",
            }
            for path in paths
        ]
        (evidence / f"{name}-worktree-blob-baseline.json").write_text(
            json.dumps(
                {
                    "files": files,
                    "format_version": 1,
                    "snapshot_commit": snapshot,
                    "volatile_exclusions": list(VOLATILE_TRACKED_TOKENS),
                },
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )
        manifest = _untracked_manifest(repo)
        manifest_path = evidence / f"{name}-untracked-before.manifest"
        manifest_path.write_bytes(manifest)
        (evidence / f"{name}-untracked-before.manifest.sha256").write_text(
            hashlib.sha256(manifest).hexdigest() + f"  {manifest_path}\n"
        )


def _write_shim(root: Path) -> Path:
    shim = root / "shim.py"
    shim.write_text(
        """#!/usr/bin/env python3
import json
import sys
from pathlib import Path

gate, log_name, ios_name, backend_name, evidence_name = sys.argv[1:]
root = Path(evidence_name).parent
mode = (root / 'shim-mode').read_text().strip() if (root / 'shim-mode').exists() else ''
log = Path(log_name)
if mode == f'empty:{gate}':
    log.write_bytes(b'')
    raise SystemExit(0)
lines = [f'gate={gate}', 'passed']
if gate == 'authoritative-correction-disposition':
    lines += ['baseline_failure_archived', 'test_method=MeteringAuthoritativeBaseCorrectionTests.testEveryCorrectionBoundaryReopensWithStableIDsAndConverges', 'baseline_commit=e46ffe1', 'task24_known_failure_ordinal=27']
    if mode == 'omit-authoritative':
        lines = ['gate=authoritative-correction-disposition', 'passed']
log.parent.mkdir(parents=True, exist_ok=True)
log.write_text('\\n'.join(lines) + '\\n')
if gate in {'ios-metering-protected-iphone17pro', 'ios-metering-protected-ipad-m5'}:
    failures = [{
        'test_identifier': 'MeteringAuthoritativeBaseCorrectionTests/testEveryCorrectionBoundaryReopensWithStableIDsAndConverges()',
        'failure_text': 'failed - locally active corrected route must remain countable',
    }]
    if mode == 'protected-regression':
        failures.append({
            'test_identifier': 'MeteringEpochWireTests/testUnexpectedRegression()',
            'failure_text': 'new protected failure',
        })
    if mode == 'authoritative-green':
        failures = []
    summary = {
        'failures': failures,
        'passed': 50,
        'skipped': 1 if mode == 'protected-skipped' else 0,
        'xcodebuild_exit_code': 65 if failures else 0,
    }
    path = Path(evidence_name) / 'named-failures' / f'{gate}.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(summary, sort_keys=True) + '\\n')
if gate in {'ios-legacy-iphone17pro', 'ios-legacy-ipad-m5'}:
    if gate.endswith('iphone17pro'):
        failures = [
            {'test_identifier': 'LegacyDeinitTests/testCrash()', 'failure_text': 'Test crashed with signal abrt.'},
            {'test_identifier': 'OldFixtureTests/testStale()', 'failure_text': 'stale fixture'},
        ]
    else:
        failures = [
            {'test_identifier': 'AuthDebtTests/testExpired()', 'failure_text': 'expired auth fixture'},
            {'test_identifier': 'LegacyDeinitTests/testCrash()', 'failure_text': 'Test crashed with signal abrt.'},
        ]
    if mode in {'unexpected-legacy', 'swapped-legacy'}:
        failures.append({'test_identifier': 'NewRegressionTests/testNewFailure()', 'failure_text': 'new failure'})
    if mode in {'resolved-legacy', 'swapped-legacy'}:
        failures = failures[1:]
    summary = {
        'failures': failures,
        'passed': 100,
        'skipped': 0,
        'xcodebuild_exit_code': 65 if failures else 0,
    }
    path = Path(evidence_name) / 'named-failures' / f'{gate}.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(summary, sort_keys=True) + '\\n')
if gate == 'release-production-build' and mode != 'zero-products':
    products = (
        'Release-iphoneos/Evlin iOS.app/Evlin iOS',
        'Release-iphoneos/Evlin iOS.app/PlugIns/EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor',
        'Release-iphoneos/Evlin iOS.app/Extensions/EvlinDeviceActivityReport.appex/EvlinDeviceActivityReport',
        'Release-iphoneos/Evlin iOS.app/PlugIns/EvlinShieldConfig.appex/EvlinShieldConfig',
        'Release-iphoneos/Evlin iOS.app/PlugIns/EvlinPushApplier.appex/EvlinPushApplier',
    )
    for relative in products:
        path = Path(evidence_name) / 'DerivedData-Release/Build/Products' / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        data = b'MACHO\\n'
        if mode == 'debug-token' and relative == products[0]:
            data += b'DebugAppGroupMeteringClock\\n'
        path.write_bytes(data)
if gate == 'debug-xctest-build' and mode != 'missing-debug-xctest':
    path = Path(evidence_name) / 'DerivedData-DebugTests/Build/Products/Debug-iphonesimulator/Evlin iOS.app/PlugIns/Evlin iOSTests.xctest/Evlin iOSTests'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'MACHO\\nDEBUG TEST PRODUCT\\n')
""",
        encoding="utf-8",
    )
    shim.chmod(0o755)
    return shim


def make_fixture(
    tmp_path: Path,
    *,
    include_task30: bool = False,
    subject_override: dict[str, str] | None = None,
    reverse_27_28: bool = False,
    omit_trailer: str | None = None,
    reviewed_dependency_head: str | None = None,
    report_text: str = (
        "physical: pending\nphase_complete: false\nreleasable: false\n"
        "Relative to exact named baseline: zero new failures. Historical debt is tracked by "
        "task_2633a95f and task_phase3_legacy_test_debt_20260719.\n"
        "MeteringAuthoritativeBaseCorrectionTests/"
        "testEveryCorrectionBoundaryReopensWithStableIDsAndConverges() was reproduced at "
        "e46ffe15b45825b20ca1a5b687815cbb340b2f24.\n"
    ),
    named_baseline_mutation: str | None = None,
) -> tuple[Path, dict[str, str]]:
    root = tmp_path / "fixture"
    root.mkdir(parents=True)
    (root / ".metering-phase3-verifier-fixture").write_text("fixture\n")
    ios = root / "ios"
    backend = root / "backend"
    for repo in (ios, backend):
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        _git(repo, "config", "user.email", "fixture@example.com")
        _git(repo, "config", "user.name", "Fixture")
    (ios / "docs/superpowers/plans").mkdir(parents=True)
    (ios / "docs/superpowers/plans/2026-07-17-metering-epoch-phase-3.md").write_text(_plan_text())
    (ios / "scripts").mkdir(parents=True)
    named_baseline = _named_failure_baseline()
    if named_baseline_mutation == "protected-in-legacy":
        named_baseline["destinations"]["iphone17pro"]["failures"].append(
            {
                "category": "old_fixture",
                "owner": "task_phase3_legacy_test_debt_20260719",
                "test_identifier": "MeteringEpochWireTests/testMustNeverBeWaived()",
            }
        )
    elif named_baseline_mutation == "missing-owner":
        del named_baseline["destinations"]["iphone17pro"]["failures"][0]["owner"]
    (ios / "scripts/metering_phase3_named_failure_baseline.json").write_text(
        json.dumps(named_baseline, indent=2, sort_keys=True) + "\n"
    )
    birth_evidence = _authoritative_birth_evidence()
    if named_baseline_mutation == "bad-birth-evidence":
        birth_evidence["outcome"] = "passed"
    (ios / "scripts/metering_authoritative_failure_birth_evidence.json").write_text(
        json.dumps(birth_evidence, indent=2, sort_keys=True) + "\n"
    )
    (ios / "Evlin iOSTests/Fixtures").mkdir(parents=True)
    (ios / "Evlin iOSTests/Fixtures/metering_epoch_phase3_vectors.json").write_text("{}\n")
    (backend / "tests/fixtures").mkdir(parents=True)
    (backend / "tests/fixtures/metering_epoch_vectors.json").write_text("{}\n")
    volatile = ios / "Evlin iOS.xcodeproj/xcuserdata/fred.xcuserdatad/UserInterfaceState.xcuserstate"
    volatile.parent.mkdir(parents=True)
    volatile.write_text("committed fixture state\n")
    bases = {"ios": _commit(ios, "fixture ios base"), "backend": _commit(backend, "fixture backend base")}

    ordered = list(TASKS[:-1] if not include_task30 else TASKS)
    if reverse_27_28:
        indexes = {label: index for index, (label, _, _) in enumerate(ordered)}
        ordered[indexes["27"]], ordered[indexes["28"]] = ordered[indexes["28"]], ordered[indexes["27"]]
    shas: dict[str, str] = {}
    dependency_heads: dict[str, str] = {}
    for label, repo_name, subject in ordered:
        repo = ios if repo_name == "ios" else backend
        if label == "30":
            report = ios / "docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md"
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text(report_text)
        body = ""
        parent = DEPENDENCIES.get(label)
        if parent and label != omit_trailer:
            body = f"Phase3-Depends-On: {dependency_heads.get(parent, shas[parent])}"
        actual_subject = (subject_override or {}).get(label, subject)
        shas[label] = _commit(repo, actual_subject, body)
        if label == reviewed_dependency_head:
            dependency_heads[label] = _commit(repo, f"fix: close Task {label} review findings")

    (ios / "tracked-wip.txt").write_text("before\n")
    _commit(ios, "fixture post-task anchor")
    (ios / "tracked-wip.txt").write_text("dirty\n")
    volatile.write_text("volatile fixture state\n")
    (ios / "untracked-wip/inside.txt").parent.mkdir()
    (ios / "untracked-wip/inside.txt").write_text("preserve me\n")
    (backend / "untracked-backend.txt").write_text("preserve me\n")

    (root / "rulebook").mkdir()
    (root / "rulebook/LOCK_BEHAVIOR_BOUNDARIES.md").write_text("# fixture rulebook\nV01 V38 T1 T11\n")
    _write_baselines(root, ios, backend, bases)
    (root / "evidence/r16-before.sha256").write_text("0" * 64 + "  rulebook\n")
    shim = _write_shim(root)
    return root, {"shim": str(shim), **shas}


def run_verifier(root: Path, shim: str, mode: str = "pre-report", commit: str | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        METERING_PHASE3_VERIFIER_TEST_MODE="1",
        METERING_PHASE3_FIXTURE_ROOT=str(root),
        METERING_PHASE3_COMMAND_SHIM=shim,
    )
    command = [str(VERIFIER), mode]
    if commit:
        command.append(commit)
    return subprocess.run(command, env=env, text=True, capture_output=True, check=False)


def assert_failed(result: subprocess.CompletedProcess[str], phrase: str) -> None:
    assert result.returncode != 0
    assert phrase.lower() in (result.stdout + result.stderr).lower()


def test_pre_report_fixture_passes_without_touching_real_paths(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    result = run_verifier(root, values["shim"])
    assert result.returncode == 0, result.stdout + result.stderr
    trace = (root / "evidence/verifier-access-trace.txt").read_text().splitlines()
    assert trace
    assert all(line.startswith("command:") or Path(line).is_relative_to(root) for line in trace)
    status = json.loads((root / "evidence/automated-status.json").read_text())
    assert status == {
        "automated": "passed",
        "authoritative_correction": {
            "baseline_commit": "e46ffe15b45825b20ca1a5b687815cbb340b2f24",
            "baseline_commit_date": "2026-07-18T18:01:53-04:00",
            "disposition": "baseline_failure_archived",
            "task24_known_failure_ordinal": 27,
            "test_method": AUTHORITATIVE_CORRECTION_TEST,
        },
        "build_evidence": {
            "release_verification": "five production Release binaries scanned; no test seams",
            "test_build": "Debug build-for-testing",
        },
        "display_status": (
            "ZERO NEW FAILURES RELATIVE TO EXACT NAMED BASELINE; "
            "HISTORICAL DEBT 3; PHYSICAL PENDING; NOT RELEASABLE"
        ),
        "phase_complete": False,
        "physical": "pending",
        "releasable": False,
        "status_code": "AUTOMATED_PASSED_PHYSICAL_PENDING",
        "test_evidence": {
            "claim": "zero new failures relative to exact named baseline",
            "historical_debt_count": 3,
            "historical_debt_tracking": [
                "task_2633a95f",
                "task_phase3_legacy_test_debt_20260719",
            ],
            "metering_exemptions": [AUTHORITATIVE_CORRECTION_TEST],
            "tests_all_green": False,
        },
    }


def test_real_gate_shells_are_fail_closed_and_expand_source_paths() -> None:
    source = VERIFIER.read_text()
    assert '["bash", "-euo", "pipefail", "-c", command_text]' in source
    assert 'OUT=\\"$PWD/.superpowers/evidence/metering-phase3/release-source.sil\\"' in source
    assert 'DEBUG_OUT=\\"$PWD/.superpowers/evidence/metering-phase3/debug-source-control.sil\\"' in source
    assert 'python3 scripts/verify_metering_phase3_r16.py && echo r16-structured-map-passed' in source


def test_named_ios_gates_use_the_fresh_dedicated_debug_test_product() -> None:
    source = VERIFIER.read_text()
    gates_text = source[source.index("GATES = (") : source.index("\n\n\nclass VerificationError")]
    assert gates_text.index('"debug-xctest-build"') < gates_text.index(
        '"ios-metering-protected-iphone17pro"'
    )
    named_gate_text = source[
        source.index("def run_ios_named_gate") : source.index("\n\nfor gate in GATES:")
    ]
    assert '"-derivedDataPath"' in named_gate_text
    assert 'str(evidence / "DerivedData-DebugTests")' in named_gate_text
    assert 'command.append("test-without-building")' in named_gate_text
    assert 'command.append("test")' not in named_gate_text
    debug_command = source[
        source.index('"debug-xctest-build":') : source.index('\n        "release-source-check":')
    ]
    assert "CODE_SIGNING_ALLOWED=NO" not in debug_command
    assert "COPYFILE_DISABLE=1" in debug_command


def test_pre_report_ignores_noncanonical_manual_log_artifacts(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    manual_log = root / "evidence/logs/r16-structured-map.manual.log"
    manual_log.parent.mkdir(parents=True, exist_ok=True)
    manual_log.write_bytes(b"")
    result = run_verifier(root, values["shim"])
    assert result.returncode == 0, result.stdout + result.stderr
    hashes = (root / "evidence/raw-log-sha256.txt").read_text()
    assert "r16-structured-map.manual.log" not in hashes


def test_dependency_trailer_accepts_reviewed_descendant_of_task_subject(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path, reviewed_dependency_head="07")
    result = run_verifier(root, values["shim"])
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize(
    ("fixture_kwargs", "phrase"),
    [
        ({"subject_override": {"28": "wrong subject"}}, "Task 28 subject"),
        ({"reverse_27_28": True}, "reverses same-repository ancestry"),
        ({"omit_trailer": "19"}, "Phase3-Depends-On trailer"),
    ],
)
def test_history_failures_are_rejected(tmp_path: Path, fixture_kwargs: dict[str, object], phrase: str) -> None:
    root, values = make_fixture(tmp_path, **fixture_kwargs)
    assert_failed(run_verifier(root, values["shim"]), phrase)


def test_duplicate_subject_is_rejected(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    _commit(root / "ios", "refactor: retire duplicate earned activity lifecycle")
    assert_failed(run_verifier(root, values["shim"]), "found 2")


def test_non_ancestor_base_is_rejected(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    other = root / "other"
    subprocess.run(["git", "init", "-q", str(other)], check=True)
    _git(other, "config", "user.email", "fixture@example.com")
    _git(other, "config", "user.name", "Fixture")
    foreign = _commit(other, "foreign")
    (root / "evidence/ios-base-sha.txt").write_text(foreign + "\n")
    assert_failed(run_verifier(root, values["shim"]), "not an ancestor")


@pytest.mark.parametrize(
    ("shim_mode", "phrase"),
    [
        ("empty:backend-vector-contract", "empty raw log"),
        ("zero-products", "missing or empty Release product"),
        ("missing-debug-xctest", "Evlin iOSTests.xctest"),
        ("debug-token", "DEBUG metering token"),
        ("omit-authoritative", "authoritative-correction disposition"),
    ],
)
def test_artifact_failures_are_rejected(tmp_path: Path, shim_mode: str, phrase: str) -> None:
    root, values = make_fixture(tmp_path)
    (root / "shim-mode").write_text(shim_mode)
    assert_failed(run_verifier(root, values["shim"]), phrase)


@pytest.mark.parametrize(
    ("shim_mode", "phrase"),
    [
        ("unexpected-legacy", "new failures outside named baseline"),
        ("resolved-legacy", "resolved baseline entries must be removed"),
        ("swapped-legacy", "new failures outside named baseline"),
        ("protected-regression", "protected metering failure"),
        ("protected-skipped", "protected metering gate skipped tests"),
        ("authoritative-green", "authoritative exception is now green"),
    ],
)
def test_named_failure_set_gate_rejects_drift(
    tmp_path: Path, shim_mode: str, phrase: str
) -> None:
    root, values = make_fixture(tmp_path)
    (root / "shim-mode").write_text(shim_mode)
    assert_failed(run_verifier(root, values["shim"]), phrase)


@pytest.mark.parametrize(
    ("mutation", "phrase"),
    [
        ("protected-in-legacy", "protected suite cannot enter legacy baseline"),
        ("missing-owner", "legacy failure debt owner"),
        ("bad-birth-evidence", "authoritative birth evidence"),
    ],
)
def test_named_failure_baseline_rejects_toothless_accounting(
    tmp_path: Path, mutation: str, phrase: str
) -> None:
    root, values = make_fixture(tmp_path, named_baseline_mutation=mutation)
    assert_failed(run_verifier(root, values["shim"]), phrase)


def test_untracked_content_change_beneath_same_path_is_rejected(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    (root / "ios/untracked-wip/inside.txt").write_text("changed without renaming\n")
    assert_failed(run_verifier(root, values["shim"]), "untracked WIP content")


def test_tracked_worktree_blob_change_is_rejected(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    (root / "ios/tracked-wip.txt").write_text("content drift\n")
    assert_failed(run_verifier(root, values["shim"]), "tracked semantic WIP")


def test_volatile_xcode_user_state_is_not_semantic_wip(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    volatile = root / "ios/Evlin iOS.xcodeproj/xcuserdata/fred.xcuserdatad/UserInterfaceState.xcuserstate"
    volatile.write_text("Xcode changed this again\n")
    result = run_verifier(root, values["shim"])
    assert result.returncode == 0, result.stdout + result.stderr


def test_invalid_tracked_wip_snapshot_is_rejected(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    baseline = root / "evidence/ios-worktree-blob-baseline.json"
    payload = json.loads(baseline.read_text())
    payload["snapshot_commit"] = "0" * 40
    baseline.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    assert_failed(run_verifier(root, values["shim"]), "recovery snapshot")


def test_wrong_baseline_manifest_hash_is_rejected(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    (root / "evidence/ios-untracked-before.manifest.sha256").write_text("0" * 64 + "  manifest\n")
    assert_failed(run_verifier(root, values["shim"]), "manifest hash is wrong")


def test_plan_mechanical_count_change_is_rejected(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    plan = root / "ios/docs/superpowers/plans/2026-07-17-metering-epoch-phase-3.md"
    plan.write_text(plan.read_text().replace("xcodebuild fixture\n", "", 1))
    assert_failed(run_verifier(root, values["shim"]), "mechanical counts changed")


def test_final_requires_task30_and_rejects_physical_pass(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path / "missing")
    assert_failed(run_verifier(root, values["shim"], "final", values["29"]), "Task 30 subject")

    root, values = make_fixture(
        tmp_path / "physical",
        include_task30=True,
        report_text="physical: passed\nphase_complete: false\nreleasable: false\n",
    )
    assert_failed(run_verifier(root, values["shim"], "final", values["30"]), "falsely claims")


def test_final_writes_idempotent_external_attestation(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path, include_task30=True)
    first = run_verifier(root, values["shim"], "final", values["30"])
    assert first.returncode == 0, first.stdout + first.stderr
    attestation = (root / "evidence/report-commit-attestation.json").read_bytes()
    second = run_verifier(root, values["shim"], "final", values["30"])
    assert second.returncode == 0, second.stdout + second.stderr
    assert (root / "evidence/report-commit-attestation.json").read_bytes() == attestation


def test_test_mode_requires_marker_and_rejects_escape(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    (root / ".metering-phase3-verifier-fixture").unlink()
    assert_failed(run_verifier(root, values["shim"]), "marker missing")
