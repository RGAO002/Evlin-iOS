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

PRODUCTS = (
    "Release-iphoneos/Evlin iOS.app/Evlin iOS",
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor",
    "Release-iphoneos/Evlin iOS.app/Extensions/EvlinDeviceActivityReport.appex/EvlinDeviceActivityReport",
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinShieldConfig.appex/EvlinShieldConfig",
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinPushApplier.appex/EvlinPushApplier",
    "Release-iphoneos/Evlin iOS.app/PlugIns/Evlin iOSTests.xctest/Evlin iOSTests",
)


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
    creates = [f"/fixture/path-{index}" for index in range(52)]
    modifies = [f"/fixture/path-{52 + index}" for index in range(44)]
    modifies += [f"/fixture/path-{index % 96}" for index in range(121)]
    declarations = [f"- Create: `{path}`" for path in creates]
    declarations += [f"- Modify: `{path}`" for path in modifies]
    sections: list[str] = []
    for index, (label, _, subject) in enumerate(TASKS):
        lines = [f"## Task {label}: Fixture", ""]
        if index == 0:
            lines += declarations
            lines += ["xcodebuild fixture" for _ in range(94)]
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
        dirty = subprocess.check_output(["git", "-C", str(repo), "diff", "--binary"])
        (evidence / f"{name}-dirty-diff-before.sha256").write_text(
            hashlib.sha256(dirty).hexdigest() + "  -\n"
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
    lines += ['baseline_failure_archived', 'test_suite=MeteringAuthoritativeBaseCorrectionTests', 'baseline_commit=e46ffe1', 'task24_known_failure_ordinal=27']
    if mode == 'omit-authoritative':
        lines = ['gate=authoritative-correction-disposition', 'passed']
log.parent.mkdir(parents=True, exist_ok=True)
log.write_text('\\n'.join(lines) + '\\n')
if gate == 'release-build' and mode != 'zero-products':
    products = (
        'Release-iphoneos/Evlin iOS.app/Evlin iOS',
        'Release-iphoneos/Evlin iOS.app/PlugIns/EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor',
        'Release-iphoneos/Evlin iOS.app/Extensions/EvlinDeviceActivityReport.appex/EvlinDeviceActivityReport',
        'Release-iphoneos/Evlin iOS.app/PlugIns/EvlinShieldConfig.appex/EvlinShieldConfig',
        'Release-iphoneos/Evlin iOS.app/PlugIns/EvlinPushApplier.appex/EvlinPushApplier',
        'Release-iphoneos/Evlin iOS.app/PlugIns/Evlin iOSTests.xctest/Evlin iOSTests',
    )
    if mode == 'missing-xctest':
        products = products[:-1]
    for relative in products:
        path = Path(evidence_name) / 'DerivedData-Release/Build/Products' / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        data = b'MACHO\\n'
        if mode == 'debug-token' and relative == products[0]:
            data += b'DebugAppGroupMeteringClock\\n'
        path.write_bytes(data)
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
    report_text: str = "physical: pending\nphase_complete: false\nreleasable: false\n",
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
    (ios / "Evlin iOSTests/Fixtures").mkdir(parents=True)
    (ios / "Evlin iOSTests/Fixtures/metering_epoch_phase3_vectors.json").write_text("{}\n")
    (backend / "tests/fixtures").mkdir(parents=True)
    (backend / "tests/fixtures/metering_epoch_vectors.json").write_text("{}\n")
    bases = {"ios": _commit(ios, "fixture ios base"), "backend": _commit(backend, "fixture backend base")}

    ordered = list(TASKS[:-1] if not include_task30 else TASKS)
    if reverse_27_28:
        indexes = {label: index for index, (label, _, _) in enumerate(ordered)}
        ordered[indexes["27"]], ordered[indexes["28"]] = ordered[indexes["28"]], ordered[indexes["27"]]
    shas: dict[str, str] = {}
    for label, repo_name, subject in ordered:
        repo = ios if repo_name == "ios" else backend
        if label == "30":
            report = ios / ".superpowers/sdd/metering-epoch-phase3-report.md"
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text(report_text)
        body = ""
        parent = DEPENDENCIES.get(label)
        if parent and label != omit_trailer:
            body = f"Phase3-Depends-On: {shas[parent]}"
        actual_subject = (subject_override or {}).get(label, subject)
        shas[label] = _commit(repo, actual_subject, body)

    (ios / "tracked-wip.txt").write_text("before\n")
    _commit(ios, "fixture post-task anchor")
    (ios / "tracked-wip.txt").write_text("dirty\n")
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
            "baseline_commit": "e46ffe1",
            "disposition": "baseline_failure_archived",
            "task24_known_failure_ordinal": 27,
        },
        "display_status": "AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE",
        "phase_complete": False,
        "physical": "pending",
        "releasable": False,
        "status_code": "AUTOMATED_PASSED_PHYSICAL_PENDING",
    }


@pytest.mark.parametrize(
    ("fixture_kwargs", "phrase"),
    [
        ({"subject_override": {"28": "wrong subject"}}, "Task 28 subject"),
        ({"reverse_27_28": True}, "reverses same-repository ancestry"),
        ({"omit_trailer": "19"}, "dependency trailer"),
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
        ("missing-xctest", "Evlin iOSTests.xctest"),
        ("debug-token", "DEBUG metering token"),
        ("omit-authoritative", "authoritative-correction disposition"),
    ],
)
def test_artifact_failures_are_rejected(tmp_path: Path, shim_mode: str, phrase: str) -> None:
    root, values = make_fixture(tmp_path)
    (root / "shim-mode").write_text(shim_mode)
    assert_failed(run_verifier(root, values["shim"]), phrase)


def test_untracked_content_change_beneath_same_path_is_rejected(tmp_path: Path) -> None:
    root, values = make_fixture(tmp_path)
    (root / "ios/untracked-wip/inside.txt").write_text("changed without renaming\n")
    assert_failed(run_verifier(root, values["shim"]), "untracked WIP content")


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
