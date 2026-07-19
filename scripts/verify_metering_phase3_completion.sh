#!/bin/bash
set -euo pipefail

python3 - "$@" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
from pathlib import Path


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

DEPENDENCIES = {
    "03": "02",
    "04": "03",
    "07": "06",
    "08": "07",
    "19": "18",
    "20": "19",
}

PLAN_COUNTS = {
    "headings": 31,
    "commits": 31,
    "create": 54,
    "modify": 169,
    "declarations": 223,
    "unique_paths": 98,
    "xcodebuild": 99,
}

RELEASE_PRODUCTS = (
    "Release-iphoneos/Evlin iOS.app/Evlin iOS",
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor",
    "Release-iphoneos/Evlin iOS.app/Extensions/EvlinDeviceActivityReport.appex/EvlinDeviceActivityReport",
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinShieldConfig.appex/EvlinShieldConfig",
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinPushApplier.appex/EvlinPushApplier",
)
DEBUG_XCTEST_PRODUCT = "Debug-iphoneos/Evlin iOS.app/PlugIns/Evlin iOSTests.xctest/Evlin iOSTests"
VOLATILE_TRACKED_TOKENS = ("xcuserdata/", ".xcuserstate", "xcschememanagement.plist")
AUTHORITATIVE_CORRECTION_TEST = (
    "MeteringAuthoritativeBaseCorrectionTests/"
    "testEveryCorrectionBoundaryReopensWithStableIDsAndConverges()"
)
LEGACY_DEBT_CATEGORIES = {"deinit_family", "old_fixture", "auth_debt"}
PHASE3_EXPLICIT_PROTECTED_SUITES = {
    "ActiveLockStoreTests",
    "AuthServiceTests",
    "BigKidStatePollerTests",
    "DatedRouteInstallerTests",
    "ShieldRecordSourceMigrationTests",
    "ShieldSourceSetTests",
    "TaskPauseShieldMappingTests",
}

GATES = (
    "backend-vector-contract",
    "backend-gate-resume",
    "backend-phase3-db",
    "cross-stack-v30",
    "ios-metering-protected-iphone17pro",
    "ios-metering-protected-ipad-m5",
    "ios-legacy-iphone17pro",
    "ios-legacy-ipad-m5",
    "release-production-build",
    "debug-xctest-build",
    "release-source-check",
    "r16-structured-map",
    "authoritative-correction-disposition",
)


class VerificationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise VerificationError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def run_git(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if check and result.returncode:
        fail(f"git {' '.join(args)} failed in {repo}: {result.stderr.strip()}")
    return result.stdout.strip()


def below(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode not in {"pre-report", "final"}:
    fail("usage: verify_metering_phase3_completion.sh pre-report|final [report-commit]")
if mode == "final" and len(sys.argv) != 3:
    fail("final mode requires exactly one report commit")
if mode == "pre-report" and len(sys.argv) != 2:
    fail("pre-report mode takes no report commit")

test_mode = os.environ.get("METERING_PHASE3_VERIFIER_TEST_MODE") == "1"
fixture_root_value = os.environ.get("METERING_PHASE3_FIXTURE_ROOT")
shim_value = os.environ.get("METERING_PHASE3_COMMAND_SHIM")
test_vars = (
    os.environ.get("METERING_PHASE3_VERIFIER_TEST_MODE"),
    fixture_root_value,
    shim_value,
)

if test_mode:
    if not all(test_vars):
        fail("test mode requires all three verifier fixture variables")
    root = Path(fixture_root_value).resolve()
    if not (root / ".metering-phase3-verifier-fixture").is_file():
        fail("test fixture marker missing")
    ios = root / "ios"
    backend = root / "backend"
    rulebook = root / "rulebook" / "LOCK_BEHAVIOR_BOUNDARIES.md"
    evidence = root / "evidence"
    shim = Path(shim_value).resolve()
    if not below(shim, root):
        fail("test command shim must be below fixture root")
else:
    if any(value is not None for value in test_vars):
        fail("fixture variables are forbidden outside complete test mode")
    root = Path("/Users/fred/Desktop/Evlin")
    ios = Path("/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS")
    backend = Path("/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend")
    rulebook = Path("/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md")
    evidence = ios / ".superpowers/evidence/metering-phase3"
    shim = None

logs = evidence / "logs"
logs.mkdir(parents=True, exist_ok=True)
access_trace = evidence / "verifier-access-trace.txt"
accesses: list[str] = []


def access(path: Path) -> Path:
    resolved = path.resolve()
    if test_mode and not below(resolved, root):
        fail(f"fixture escaped its root: {resolved}")
    accesses.append(str(resolved))
    return resolved


for required in (ios, backend, rulebook, evidence):
    access(required)
    if not required.exists():
        fail(f"required path missing: {required}")

plan = access(ios / "docs/superpowers/plans/2026-07-17-metering-epoch-phase-3.md")
if not plan.is_file():
    fail(f"plan missing: {plan}")


def verify_plan_shape() -> None:
    text = plan.read_text(encoding="utf-8")
    headings = re.findall(r"^## Task (?:[0-9]+|23A):", text, re.MULTILINE)
    commits = re.findall(r"^git commit -m '([^']+)'", text, re.MULTILINE)
    creates = re.findall(r"^- Create: `([^`]+)`", text, re.MULTILINE)
    modifies = re.findall(r"^- Modify: `([^`]+)`", text, re.MULTILINE)
    xcodes = re.findall(r"^xcodebuild ", text, re.MULTILINE)
    actual = {
        "headings": len(headings),
        "commits": len(commits),
        "create": len(creates),
        "modify": len(modifies),
        "declarations": len(creates) + len(modifies),
        "unique_paths": len(set(creates + modifies)),
        "xcodebuild": len(xcodes),
    }
    if actual != PLAN_COUNTS:
        fail(f"plan mechanical counts changed: expected {PLAN_COUNTS}, got {actual}")
    expected_subjects = [subject for _, _, subject in TASKS]
    if commits != expected_subjects:
        fail("plan commit subjects/order do not equal the 31-task manifest")


verify_plan_shape()


def read_base(repo_name: str, repo: Path) -> str:
    path = access(evidence / f"{repo_name}-base-sha.txt")
    if not path.is_file():
        fail(f"missing immutable base file: {path}")
    base = path.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        fail(f"invalid {repo_name} base SHA")
    if subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", base, "HEAD"],
        check=False,
    ).returncode:
        fail(f"{repo_name} base is not an ancestor of HEAD")
    return base


bases = {"ios": read_base("ios", ios), "backend": read_base("backend", backend)}
required_labels = [label for label, _, _ in TASKS if mode == "final" or label != "30"]
selected: dict[str, str] = {}
positions: dict[tuple[str, str], int] = {}

for repo_name, repo in (("ios", ios), ("backend", backend)):
    history = run_git(repo, "rev-list", "--reverse", f"{bases[repo_name]}..HEAD").splitlines()
    positions.update({(repo_name, sha): index for index, sha in enumerate(history)})

for label, repo_name, subject in TASKS:
    if label not in required_labels:
        continue
    repo = ios if repo_name == "ios" else backend
    matches = run_git(
        repo,
        "log",
        "--format=%H%x00%s",
        f"{bases[repo_name]}..HEAD",
    ).splitlines()
    exact = [line.split("\x00", 1)[0] for line in matches if line.split("\x00", 1)[1] == subject]
    if len(exact) != 1:
        fail(f"Task {label} subject must occur exactly once; found {len(exact)}: {subject}")
    selected[label] = exact[0]

if len(set(selected.values())) != len(selected):
    fail("duplicate task SHA in global manifest")

last_position: dict[str, int] = {}
for label, repo_name, _ in TASKS:
    if label not in selected:
        continue
    position = positions.get((repo_name, selected[label]))
    if position is None:
        fail(f"Task {label} commit is outside selected history")
    if position <= last_position.get(repo_name, -1):
        fail(f"Task {label} reverses same-repository ancestry")
    last_position[repo_name] = position

for child, parent in DEPENDENCIES.items():
    if child not in selected:
        continue
    child_repo_name = next(repo for label, repo, _ in TASKS if label == child)
    child_repo = ios if child_repo_name == "ios" else backend
    body = run_git(child_repo, "show", "-s", "--format=%B", selected[child])
    trailer_shas = [
        line.split(":", 1)[1].strip()
        for line in body.splitlines()
        if line.startswith("Phase3-Depends-On:")
    ]
    parent_repo_name = next(repo for label, repo, _ in TASKS if label == parent)
    parent_repo = ios if parent_repo_name == "ios" else backend
    later_parent_tasks = [
        label
        for label, repo_name, _ in TASKS
        if repo_name == parent_repo_name
        and label in selected
        and positions[(parent_repo_name, selected[label])]
        > positions[(parent_repo_name, selected[parent])]
    ]
    next_parent_sha = selected[later_parent_tasks[0]] if later_parent_tasks else None
    valid_trailers: list[str] = []
    for trailer_sha in trailer_shas:
        if not re.fullmatch(r"[0-9a-f]{40}", trailer_sha):
            continue
        if subprocess.run(
            ["git", "-C", str(parent_repo), "cat-file", "-e", f"{trailer_sha}^{{commit}}"],
            check=False,
        ).returncode:
            continue
        if subprocess.run(
            ["git", "-C", str(parent_repo), "merge-base", "--is-ancestor", selected[parent], trailer_sha],
            check=False,
        ).returncode:
            continue
        if next_parent_sha and (
            trailer_sha == next_parent_sha
            or subprocess.run(
                ["git", "-C", str(parent_repo), "merge-base", "--is-ancestor", trailer_sha, next_parent_sha],
                check=False,
            ).returncode
        ):
            continue
        valid_trailers.append(trailer_sha)
    if not valid_trailers:
        fail(
            f"Task {child} requires a Phase3-Depends-On trailer naming Task {parent} "
            "or a reviewed descendant before the next task in that repository"
        )

if mode == "final":
    report_commit = sys.argv[2]
    resolved_report_commit = run_git(ios, "rev-parse", report_commit)
    if resolved_report_commit != selected["30"]:
        fail("final report commit is not the unique Task 30 commit")

manifest_path = evidence / "task-commit-manifest.json"
manifest_path.write_text(
    json.dumps(
        [
            {"task": label, "repository": repo, "subject": subject, "sha": selected[label]}
            for label, repo, subject in TASKS
            if label in selected
        ],
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)


def tracked_semantic_paths(repo: Path) -> list[str]:
    paths: set[str] = set()
    for args in (("diff", "--name-only", "-z"), ("diff", "--cached", "--name-only", "-z")):
        raw = subprocess.check_output(["git", "-C", str(repo), *args])
        paths.update(os.fsdecode(item) for item in raw.split(b"\0") if item)
    return sorted(
        path for path in paths if not any(token in path for token in VOLATILE_TRACKED_TOKENS)
    )


def verify_tracked_blob_baseline(repo_name: str, repo: Path, baseline: Path) -> None:
    try:
        payload = json.loads(baseline.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid {repo_name} tracked WIP blob baseline: {exc}")
    if payload.get("format_version") != 1:
        fail(f"unsupported {repo_name} tracked WIP blob baseline format")
    if tuple(payload.get("volatile_exclusions", ())) != VOLATILE_TRACKED_TOKENS:
        fail(f"{repo_name} tracked WIP volatile exclusions changed")
    rows = payload.get("files")
    if not isinstance(rows, list):
        fail(f"invalid {repo_name} tracked WIP file rows")
    expected: dict[str, str] = {}
    for row in rows:
        if not isinstance(row, dict):
            fail(f"invalid {repo_name} tracked WIP row")
        path = row.get("path")
        blob = row.get("blob_sha")
        reason = row.get("reason")
        if (
            not isinstance(path, str)
            or not path
            or Path(path).is_absolute()
            or ".." in Path(path).parts
            or any(token in path for token in VOLATILE_TRACKED_TOKENS)
            or not isinstance(blob, str)
            or not re.fullmatch(r"[0-9a-f]{40}", blob)
            or not isinstance(reason, str)
            or not reason.strip()
            or path in expected
        ):
            fail(f"invalid {repo_name} tracked WIP row: {row}")
        expected[path] = blob
    current_paths = tracked_semantic_paths(repo)
    if current_paths != sorted(expected):
        fail(f"{repo_name} tracked semantic WIP path set differs from immutable baseline")
    for path, expected_blob in expected.items():
        actual_blob = run_git(repo, "hash-object", "--", path)
        if actual_blob != expected_blob:
            fail(f"{repo_name} tracked semantic WIP content differs from immutable baseline: {path}")
    snapshot = payload.get("snapshot_commit")
    if expected:
        if not isinstance(snapshot, str) or not re.fullmatch(r"[0-9a-f]{40}", snapshot):
            fail(f"{repo_name} tracked WIP recovery snapshot is missing or malformed")
        if subprocess.run(
            ["git", "-C", str(repo), "cat-file", "-e", f"{snapshot}^{{commit}}"],
            check=False,
        ).returncode:
            fail(f"{repo_name} tracked WIP recovery snapshot is unavailable")
        for path, expected_blob in expected.items():
            tree_row = run_git(repo, "ls-tree", snapshot, "--", path)
            parts = tree_row.split()
            if len(parts) < 3 or parts[2] != expected_blob:
                fail(f"{repo_name} recovery snapshot does not contain baseline blob: {path}")
    elif snapshot is not None:
        fail(f"{repo_name} clean tracked WIP baseline must not name a recovery snapshot")


def untracked_manifest(repo: Path) -> bytes:
    raw = subprocess.check_output(
        ["git", "-C", str(repo), "ls-files", "--others", "--exclude-standard", "-z"]
    )
    rows: list[str] = []
    for item in sorted(filter(None, raw.split(b"\0"))):
        relative = os.fsdecode(item)
        if relative.startswith(".superpowers/evidence/metering-phase3/"):
            continue
        path = repo / relative
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            kind = "symlink"
            payload = os.readlink(path).encode()
        elif stat.S_ISREG(info.st_mode):
            kind = "file"
            payload = path.read_bytes()
        else:
            kind = "other"
            payload = b""
        rows.append(
            json.dumps(
                {
                    "kind": kind,
                    "mode": stat.S_IMODE(info.st_mode),
                    "path_bytes_hex": item.hex(),
                    "sha256": sha256_bytes(payload),
                },
                separators=(",", ":"),
                sort_keys=False,
            )
        )
    return (("\n".join(rows) + "\n") if rows else "").encode()


for repo_name, repo in (("ios", ios), ("backend", backend)):
    blob_before = access(evidence / f"{repo_name}-worktree-blob-baseline.json")
    untracked_before = access(evidence / f"{repo_name}-untracked-before.manifest")
    untracked_hash_before = access(evidence / f"{repo_name}-untracked-before.manifest.sha256")
    for path in (blob_before, untracked_before, untracked_hash_before):
        if not path.is_file():
            fail(f"missing immutable workspace baseline: {path}")
    verify_tracked_blob_baseline(repo_name, repo, blob_before)
    current_untracked = untracked_manifest(repo)
    if current_untracked != untracked_before.read_bytes():
        fail(f"{repo_name} untracked WIP content/type/mode differs from immutable baseline")
    recorded_manifest_hash = untracked_hash_before.read_text().split()[0]
    if sha256_file(untracked_before) != recorded_manifest_hash:
        fail(f"{repo_name} untracked baseline manifest hash is wrong")


def read_json_object(path: Path, label: str) -> dict[str, object]:
    access(path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid {label}: {exc}")
    if not isinstance(payload, dict):
        fail(f"invalid {label}: root must be an object")
    return payload


named_baseline_path = ios / "scripts/metering_phase3_named_failure_baseline.json"
birth_evidence_path = ios / "scripts/metering_authoritative_failure_birth_evidence.json"
named_baseline = read_json_object(named_baseline_path, "named failure baseline")
birth_evidence = read_json_object(birth_evidence_path, "authoritative birth evidence")
if named_baseline.get("format_version") != 1:
    fail("unsupported named failure baseline format")

prefixes = named_baseline.get("protected_suite_prefixes")
protected_rows = named_baseline.get("protected_suites")
if (
    not isinstance(prefixes, list)
    or not prefixes
    or any(not isinstance(item, str) or not item for item in prefixes)
    or not isinstance(protected_rows, list)
    or not protected_rows
    or any(not isinstance(item, str) or not item for item in protected_rows)
):
    fail("named failure baseline must name protected suite prefixes and suites")
protected_prefixes = tuple(prefixes)
protected_suites = tuple(sorted(set(protected_rows)))
missing_explicit_suites = PHASE3_EXPLICIT_PROTECTED_SUITES - set(protected_suites)
if missing_explicit_suites:
    fail(
        "Phase 3 protected suite list is incomplete: "
        + ", ".join(sorted(missing_explicit_suites))
    )
test_source_root = ios / "Evlin iOSTests"
discovered_prefixed_suites: set[str] = set()
if test_source_root.is_dir():
    for source in test_source_root.glob("*.swift"):
        source_text = source.read_text(encoding="utf-8")
        discovered_prefixed_suites.update(
            re.findall(r"^final class ((?:DeviceEpoch|Earned|Metering)[A-Za-z0-9_]*Tests)\b", source_text, re.MULTILINE)
        )
missing_prefixed_suites = discovered_prefixed_suites - set(protected_suites)
if missing_prefixed_suites:
    fail(
        "prefixed metering family suite is absent from the protected gate: "
        + ", ".join(sorted(missing_prefixed_suites))
    )


def suite_name(test_identifier: str) -> str:
    return test_identifier.split("/", 1)[0]


def is_protected_test(test_identifier: str) -> bool:
    suite = suite_name(test_identifier)
    return suite in protected_suites or suite.startswith(protected_prefixes)


debt_tasks = named_baseline.get("debt_tasks")
if not isinstance(debt_tasks, dict) or not debt_tasks:
    fail("named failure baseline must define debt tasks")
for task_id, task in debt_tasks.items():
    if (
        not isinstance(task_id, str)
        or not task_id
        or not isinstance(task, dict)
        or not isinstance(task.get("title"), str)
        or not task["title"].strip()
    ):
        fail("invalid named failure debt task")

destinations = named_baseline.get("destinations")
if not isinstance(destinations, dict) or set(destinations) != {"iphone17pro", "ipad_m5"}:
    fail("named failure baseline must define exact iPhone and iPad destinations")
expected_legacy_failures: dict[str, set[str]] = {}
legacy_debt_rows: list[dict[str, str]] = []
for destination, destination_payload in destinations.items():
    if not isinstance(destination_payload, dict) or not isinstance(
        destination_payload.get("failures"), list
    ):
        fail(f"invalid legacy failure rows for {destination}")
    expected: set[str] = set()
    for row in destination_payload["failures"]:
        if not isinstance(row, dict):
            fail(f"invalid legacy failure row for {destination}")
        identifier = row.get("test_identifier")
        category = row.get("category")
        owner = row.get("owner")
        if not isinstance(identifier, str) or not identifier or identifier in expected:
            fail(f"invalid or duplicate legacy failure identifier for {destination}")
        if is_protected_test(identifier):
            fail(f"protected suite cannot enter legacy baseline: {identifier}")
        if category not in LEGACY_DEBT_CATEGORIES:
            fail(f"legacy failure category is missing or invalid: {identifier}")
        if not isinstance(owner, str) or owner not in debt_tasks:
            fail(f"legacy failure debt owner is missing or unknown: {identifier}")
        expected.add(identifier)
        legacy_debt_rows.append(
            {
                "category": category,
                "destination": destination,
                "owner": owner,
                "test_identifier": identifier,
            }
        )
    expected_legacy_failures[destination] = expected

authoritative_exception = named_baseline.get("authoritative_exception")
if not isinstance(authoritative_exception, dict):
    fail("named failure baseline must define the authoritative exception")
if authoritative_exception.get("test_identifier") != AUTHORITATIVE_CORRECTION_TEST:
    fail("only the named authoritative correction test may be exempted")
for field in ("baseline_commit", "failure_text", "test_identifier"):
    if birth_evidence.get(field) != authoritative_exception.get(field):
        fail(f"authoritative birth evidence disagrees on {field}")
if (
    birth_evidence.get("outcome") != "failed"
    or birth_evidence.get("xcodebuild_exit_code") != 65
    or not isinstance(birth_evidence.get("baseline_commit_date"), str)
    or not re.fullmatch(r"[0-9a-f]{40}", str(birth_evidence.get("source_blob", "")))
    or not re.fullmatch(r"[0-9a-f]{64}", str(birth_evidence.get("raw_log_sha256", "")))
    or not re.fullmatch(r"[0-9a-f]{64}", str(birth_evidence.get("xcresult_summary_sha256", "")))
):
    fail("authoritative birth evidence does not prove a failing isolated run")
if authoritative_exception.get("task24_known_failure_ordinal") != 27:
    fail("authoritative exception must retain its Task 24 named-baseline ordinal")
if not test_mode:
    baseline_commit = str(birth_evidence["baseline_commit"])
    if run_git(ios, "rev-parse", baseline_commit) != baseline_commit:
        fail("authoritative birth evidence baseline commit is unavailable")
    if subprocess.run(
        ["git", "-C", str(ios), "merge-base", "--is-ancestor", baseline_commit, selected["25"]],
        check=False,
    ).returncode:
        fail("authoritative failure was not proven before Task 25")
    source_blob = run_git(
        ios,
        "rev-parse",
        f"{baseline_commit}:Evlin iOSTests/MeteringAuthoritativeBaseCorrectionTests.swift",
    )
    if source_blob != birth_evidence["source_blob"]:
        fail("authoritative birth evidence source blob does not match baseline commit")


def gate_command(gate: str) -> tuple[Path, list[str] | str]:
    commands: dict[str, tuple[Path, str]] = {
        "backend-vector-contract": (backend, ".venv/bin/python -m pytest -q tests/test_metering_epoch_vector_contract.py"),
        "backend-gate-resume": (backend, ".venv/bin/python scripts/run_limits_db_regression.py tests/test_target_gate_resume_helpers.py"),
        "backend-phase3-db": (backend, ".venv/bin/python scripts/run_limits_db_regression.py tests/test_metering_epoch_models.py tests/test_metering_epoch_registration.py tests/test_metering_epoch_sample_adapter.py tests/test_metering_epoch_phase2_integration.py tests/test_metering_epoch_lifespan.py tests/test_metering_epoch_phase3_vectors.py"),
        "cross-stack-v30": (backend, "bash scripts/run_metering_v30_cross_stack.sh"),
        "release-production-build": (ios, "DERIVED=\"$PWD/.superpowers/evidence/metering-phase3/DerivedData-Release\"; if [ -e \"$DERIVED\" ]; then mv \"$DERIVED\" \"$DERIVED.previous-$(date +%s)-$$\"; fi; SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -configuration Release -destination 'generic/platform=iOS' -derivedDataPath \"$DERIVED\" CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build"),
        "debug-xctest-build": (ios, "DERIVED=\"$PWD/.superpowers/evidence/metering-phase3/DerivedData-DebugTests\"; if [ -e \"$DERIVED\" ]; then mv \"$DERIVED\" \"$DERIVED.previous-$(date +%s)-$$\"; fi; SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath \"$DERIVED\" CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' build-for-testing"),
        "release-source-check": (ios, "OUT='$PWD/.superpowers/evidence/metering-phase3/release-source.sil'; DEBUG_OUT='$PWD/.superpowers/evidence/metering-phase3/debug-source-control.sil'; SDK=$(xcrun --sdk iphonesimulator --show-sdk-path); xcrun swiftc -emit-sil -parse-as-library -sdk \"$SDK\" -target arm64-apple-ios17.6-simulator 'Evlin iOS/Services/MeteringEpochContract.swift' 'Evlin iOS/Services/MeteringRuntimeInfrastructure.swift' >/dev/null 2>\"$OUT\"; test -s \"$OUT\"; if rg -q 'DebugAppGroupMeteringClock|evlin\\.metering\\.debugClockNow' \"$OUT\"; then exit 1; fi; xcrun swiftc -D DEBUG -emit-sil -parse-as-library -sdk \"$SDK\" -target arm64-apple-ios17.6-simulator 'Evlin iOS/Services/MeteringEpochContract.swift' 'Evlin iOS/Services/MeteringRuntimeInfrastructure.swift' >/dev/null 2>\"$DEBUG_OUT\"; rg -q 'DebugAppGroupMeteringClock' \"$DEBUG_OUT\"; rg -q 'evlin\\.metering\\.debugClockNow' \"$DEBUG_OUT\"; echo release-source-compile-passed"),
        "r16-structured-map": (ios, "python3 scripts/verify_metering_phase3_r16.py"),
        "authoritative-correction-disposition": (ios, "printf '%s\\n' 'baseline_failure_archived' 'test_method=MeteringAuthoritativeBaseCorrectionTests.testEveryCorrectionBoundaryReopensWithStableIDsAndConverges' 'baseline_commit=e46ffe1' 'task24_known_failure_ordinal=27'"),
    }
    return commands[gate]


def archive_existing(path: Path) -> None:
    if not path.exists():
        return
    index = 1
    while True:
        candidate = path.with_name(f"{path.name}.previous-{index}")
        if not candidate.exists():
            path.rename(candidate)
            return
        index += 1


def run_ios_named_gate(gate: str, log: Path) -> subprocess.CompletedProcess[str]:
    protected = gate.startswith("ios-metering-protected-")
    iphone = gate.endswith("iphone17pro")
    destination = (
        "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1"
        if iphone
        else "platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1"
    )
    result_directory = evidence / "xcresults"
    summary_directory = evidence / "named-failures"
    result_directory.mkdir(parents=True, exist_ok=True)
    summary_directory.mkdir(parents=True, exist_ok=True)
    result_bundle = result_directory / f"{gate}.xcresult"
    archive_existing(result_bundle)
    command = [
        "xcodebuild",
        "-project",
        "Evlin iOS.xcodeproj",
        "-scheme",
        "Evlin iOS",
        "-destination",
        destination,
        "IPHONEOS_DEPLOYMENT_TARGET=17.6",
        "TARGETED_DEVICE_FAMILY=1,2",
        "-parallel-testing-enabled",
        "NO",
        "-resultBundlePath",
        str(result_bundle),
    ]
    selector = "-only-testing" if protected else "-skip-testing"
    command.extend(f"{selector}:Evlin iOSTests/{suite}" for suite in protected_suites)
    if protected:
        # This case is executed by the dedicated cross-stack-v30 gate, which
        # supplies the simulator environment and consumes its emitted bytes.
        command.append(
            "-skip-testing:Evlin iOSTests/MeteringV30ProductionEncoderTests/"
            "testWritesCrossStackArtifact"
        )
    if not protected and not iphone:
        command.append("-skip-testing:Evlin iOSTests/ProfileSnapshotTests")
    command.append("test")
    environment = os.environ.copy()
    environment["SENTRY_SKIP_DSYM_UPLOAD"] = "1"
    with log.open("wb") as handle:
        xcode_result = subprocess.run(
            command,
            cwd=ios,
            env=environment,
            stdout=handle,
            stderr=subprocess.STDOUT,
            check=False,
        )
    if xcode_result.returncode not in {0, 65} or not result_bundle.is_dir():
        return subprocess.CompletedProcess(command, xcode_result.returncode or 1)
    summary_result = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(result_bundle),
            "--compact",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if summary_result.returncode:
        with log.open("ab") as handle:
            handle.write(summary_result.stderr.encode())
        return subprocess.CompletedProcess(command, summary_result.returncode)
    try:
        raw_summary = json.loads(summary_result.stdout)
    except json.JSONDecodeError as exc:
        with log.open("ab") as handle:
            handle.write(f"\ninvalid xcresult summary: {exc}\n".encode())
        return subprocess.CompletedProcess(command, 1)
    failures: list[dict[str, str]] = []
    for failure in raw_summary.get("testFailures") or []:
        identifier = str(failure.get("testIdentifierString", ""))
        failure_text = str(failure.get("failureText", ""))
        if re.fullmatch(r"Evlin iOS \([0-9]+\) encountered an error", identifier):
            identifier = "__runner__/early_unexpected_exit"
        if not identifier:
            return subprocess.CompletedProcess(command, 1)
        failures.append({"failure_text": failure_text, "test_identifier": identifier})
    normalized = {
        "failed": int(raw_summary.get("failedTests", len(failures))),
        "failures": failures,
        "passed": int(raw_summary.get("passedTests", 0)),
        "skipped": int(raw_summary.get("skippedTests", 0)),
        "xcodebuild_exit_code": xcode_result.returncode,
    }
    (summary_directory / f"{gate}.json").write_text(
        json.dumps(normalized, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return subprocess.CompletedProcess(command, 0)


for gate in GATES:
    log = logs / f"{gate}.log"
    if test_mode:
        command = [str(shim), gate, str(log), str(ios), str(backend), str(evidence)]
        accesses.append(f"command:{gate}")
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        if result.stdout or result.stderr:
            with log.open("ab") as handle:
                handle.write(result.stdout.encode())
                handle.write(result.stderr.encode())
    elif gate.startswith("ios-metering-protected-") or gate.startswith("ios-legacy-"):
        accesses.append(f"command:{gate}")
        result = run_ios_named_gate(gate, log)
    else:
        cwd, command_text = gate_command(gate)
        accesses.append(f"command:{gate}")
        with log.open("wb") as handle:
            result = subprocess.run(
                ["bash", "-o", "pipefail", "-c", command_text],
                cwd=cwd,
                stdout=handle,
                stderr=subprocess.STDOUT,
                check=False,
            )
    if result.returncode:
        fail(f"gate {gate} failed with exit {result.returncode}; see {log}")
    if not log.is_file() or not log.stat().st_size:
        fail(f"gate {gate} produced an empty raw log")


named_summary_directory = evidence / "named-failures"


def read_named_gate_summary(gate: str) -> set[str]:
    path = access(named_summary_directory / f"{gate}.json")
    payload = read_json_object(path, f"{gate} named failure summary")
    failures = payload.get("failures")
    if (
        not isinstance(failures, list)
        or not isinstance(payload.get("passed"), int)
        or payload["passed"] <= 0
        or not isinstance(payload.get("skipped"), int)
        or payload.get("xcodebuild_exit_code") not in {0, 65}
    ):
        fail(f"invalid or incomplete named failure summary for {gate}")
    if gate.startswith("ios-metering-protected-") and payload["skipped"] != 0:
        fail(f"protected metering gate skipped tests: {gate}")
    identifiers: set[str] = set()
    for row in failures:
        if (
            not isinstance(row, dict)
            or not isinstance(row.get("test_identifier"), str)
            or not row["test_identifier"]
            or not isinstance(row.get("failure_text"), str)
            or row["test_identifier"] in identifiers
        ):
            fail(f"invalid or duplicate failure result for {gate}")
        identifiers.add(row["test_identifier"])
    expected_exit = 65 if identifiers else 0
    if payload["xcodebuild_exit_code"] != expected_exit:
        fail(f"xcodebuild exit and named failures disagree for {gate}")
    return identifiers


protected_gate_results: dict[str, set[str]] = {}
legacy_gate_results: dict[str, set[str]] = {}
for destination, suffix in (("iphone17pro", "iphone17pro"), ("ipad_m5", "ipad-m5")):
    protected_gate = f"ios-metering-protected-{suffix}"
    protected_result = read_named_gate_summary(protected_gate)
    protected_gate_results[destination] = protected_result
    unexpected_protected = protected_result - {AUTHORITATIVE_CORRECTION_TEST}
    if unexpected_protected:
        fail(
            "protected metering failure outside the single proven exception: "
            + ", ".join(sorted(unexpected_protected))
        )
    if AUTHORITATIVE_CORRECTION_TEST not in protected_result:
        fail("authoritative exception is now green and must be removed from the baseline")

    legacy_gate = f"ios-legacy-{suffix}"
    actual_legacy = read_named_gate_summary(legacy_gate)
    legacy_gate_results[destination] = actual_legacy
    protected_in_legacy_result = sorted(item for item in actual_legacy if is_protected_test(item))
    if protected_in_legacy_result:
        fail(
            "protected metering failure appeared in the legacy run: "
            + ", ".join(protected_in_legacy_result)
        )
    expected_legacy = expected_legacy_failures[destination]
    new_failures = actual_legacy - expected_legacy
    if new_failures:
        fail("new failures outside named baseline: " + ", ".join(sorted(new_failures)))
    resolved = expected_legacy - actual_legacy
    if resolved:
        fail("resolved baseline entries must be removed: " + ", ".join(sorted(resolved)))

authoritative_log = (logs / "authoritative-correction-disposition.log").read_text()
for required in (
    "baseline_failure_archived",
    "MeteringAuthoritativeBaseCorrectionTests.testEveryCorrectionBoundaryReopensWithStableIDsAndConverges",
    "baseline_commit=e46ffe1",
    "task24_known_failure_ordinal=27",
):
    if required not in authoritative_log:
        fail(f"authoritative-correction disposition omitted {required}")

derived_products = evidence / "DerivedData-Release/Build/Products"
release_product_paths = [access(derived_products / relative) for relative in RELEASE_PRODUCTS]
if len(release_product_paths) != 5 or len({str(path) for path in release_product_paths}) != 5:
    fail("Release product manifest must contain exactly five unique production products")
for path in release_product_paths:
    if not path.is_file() or not path.stat().st_size:
        fail(f"missing or empty Release product: {path}")
    data = path.read_bytes()
    if test_mode:
        if not data.startswith(b"MACHO"):
            fail(f"fixture Release product is not marked Mach-O: {path}")
    else:
        output = subprocess.check_output(["file", str(path)], text=True)
        if "Mach-O" not in output:
            fail(f"Release product is not Mach-O: {path}: {output.strip()}")
    if b"DebugAppGroupMeteringClock" in data or b"evlin.metering.debugClockNow" in data:
        fail(f"DEBUG metering token present in Release product: {path}")

debug_xctest_path = access(
    evidence / "DerivedData-DebugTests/Build/Products" / DEBUG_XCTEST_PRODUCT
)
if not debug_xctest_path.is_file() or not debug_xctest_path.stat().st_size:
    fail(f"missing or empty Debug XCTest product: {debug_xctest_path}")
if test_mode:
    if not debug_xctest_path.read_bytes().startswith(b"MACHO"):
        fail(f"fixture Debug XCTest product is not marked Mach-O: {debug_xctest_path}")
else:
    output = subprocess.check_output(["file", str(debug_xctest_path)], text=True)
    if "Mach-O" not in output:
        fail(f"Debug XCTest product is not Mach-O: {debug_xctest_path}: {output.strip()}")

fixture_paths = (
    ios / "Evlin iOSTests/Fixtures/metering_epoch_phase3_vectors.json",
    backend / "tests/fixtures/metering_epoch_vectors.json",
)
for fixture in fixture_paths:
    access(fixture)
    if not fixture.is_file() or not fixture.stat().st_size:
        fail(f"missing or empty vector fixture: {fixture}")

target_manifest_path = evidence / "target-membership-manifest.json"
project_path = ios / "Evlin iOS.xcodeproj/project.pbxproj"
if test_mode:
    project_hash = "fixture"
else:
    access(project_path)
    if not project_path.is_file():
        fail("Xcode project is missing for target-membership evidence")
    project_hash = sha256_file(project_path)
target_manifest_path.write_text(
    json.dumps(
        {
            "project_sha256": project_hash,
            "release_products": list(RELEASE_PRODUCTS),
            "debug_xctest_product": DEBUG_XCTEST_PRODUCT,
            "test_build": "Debug build-for-testing",
            "release_verification": "five production Release binaries scanned; no test seams",
            "push_forbidden_sources": [
                "MeteringProductionComposition.swift",
                "MeteringV30ScenarioEncoder.swift",
                "DebugAppGroupMeteringClock",
            ],
        },
        indent=2,
        sort_keys=True,
    )
    + "\n"
)

r16_before = access(evidence / "r16-before.sha256")
if not r16_before.is_file() or not re.fullmatch(r"[0-9a-f]{64}", r16_before.read_text().split()[0]):
    fail("missing or malformed immutable R-16 before hash")
r16_after_path = evidence / "r16-after.sha256"
r16_after_path.write_text(f"{sha256_file(rulebook)}  {rulebook}\n")

raw_hash_lines = []
for path in sorted(logs.glob("*.log")):
    if not path.stat().st_size:
        fail(f"empty raw log: {path}")
    raw_hash_lines.append(f"{sha256_file(path)}  {path.name}")
(evidence / "raw-log-sha256.txt").write_text("\n".join(raw_hash_lines) + "\n")

product_manifest = [
    {"path": relative, "sha256": sha256_file(path), "bytes": path.stat().st_size}
    for relative, path in zip(RELEASE_PRODUCTS, release_product_paths)
]
(evidence / "release-product-manifest.json").write_text(
    json.dumps(product_manifest, indent=2, sort_keys=True) + "\n"
)
(evidence / "debug-test-product-manifest.json").write_text(
    json.dumps(
        {
            "path": DEBUG_XCTEST_PRODUCT,
            "sha256": sha256_file(debug_xctest_path),
            "bytes": debug_xctest_path.stat().st_size,
            "configuration": "Debug",
            "action": "build-for-testing",
        },
        indent=2,
        sort_keys=True,
    )
    + "\n"
)

status_path = evidence / "automated-status.json"
legacy_unique_count = len(set().union(*expected_legacy_failures.values()))
status = {
    "automated": "passed",
    "physical": "pending",
    "releasable": False,
    "status_code": "AUTOMATED_PASSED_PHYSICAL_PENDING",
    "phase_complete": False,
    "display_status": (
        "ZERO NEW FAILURES RELATIVE TO EXACT NAMED BASELINE; "
        f"HISTORICAL DEBT {legacy_unique_count}; PHYSICAL PENDING; NOT RELEASABLE"
    ),
    "authoritative_correction": {
        "disposition": "baseline_failure_archived",
        "baseline_commit": birth_evidence["baseline_commit"],
        "baseline_commit_date": birth_evidence["baseline_commit_date"],
        "task24_known_failure_ordinal": 27,
        "test_method": AUTHORITATIVE_CORRECTION_TEST,
    },
    "build_evidence": {
        "test_build": "Debug build-for-testing",
        "release_verification": "five production Release binaries scanned; no test seams",
    },
    "test_evidence": {
        "claim": "zero new failures relative to exact named baseline",
        "historical_debt_count": legacy_unique_count,
        "historical_debt_tracking": sorted(debt_tasks),
        "metering_exemptions": [AUTHORITATIVE_CORRECTION_TEST],
        "tests_all_green": False,
    },
}
status_path.write_text(json.dumps(status, indent=2, sort_keys=True) + "\n")
if status["physical"] != "pending" or status["releasable"] or status["phase_complete"]:
    fail("verifier must never claim physical pass or releasability")

if mode == "final":
    report = ios / "docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md"
    access(report)
    if not report.is_file():
        fail("final mode requires committed Phase 3 report")
    report_text = report.read_text(encoding="utf-8")
    forbidden = (
        "physical: passed",
        "releasable: true",
        "phase_complete: true",
        "tests all green",
        "all tests pass",
    )
    if any(token in report_text.lower() for token in forbidden):
        fail("report falsely claims a physical pass, completion, or releasability")
    for required in (
        "relative to exact named baseline: zero new failures",
        "historical debt",
        "task_2633a95f",
        "task_phase3_legacy_test_debt_20260719",
        AUTHORITATIVE_CORRECTION_TEST,
        str(birth_evidence["baseline_commit"]),
    ):
        if required.lower() not in report_text.lower():
            fail(f"report omits named-baseline accounting: {required}")
    changed = run_git(ios, "show", "--format=", "--name-only", selected["30"]).splitlines()
    relative_report = str(report.relative_to(ios))
    if relative_report not in changed:
        fail("Task 30 commit does not contain the Phase 3 report")
    report_blob = run_git(ios, "rev-parse", f"{selected['30']}:{relative_report}")
    committed_report = subprocess.check_output(
        ["git", "-C", str(ios), "show", f"{selected['30']}:{relative_report}"]
    )
    attestation = {
        "report_commit": selected["30"],
        "report_blob": report_blob,
        "report_content_sha256": sha256_bytes(committed_report),
        "semantic_status": "AUTOMATED_PASSED_PHYSICAL_PENDING",
    }
    (evidence / "report-commit-attestation.json").write_text(
        json.dumps(attestation, indent=2, sort_keys=True) + "\n"
    )

hash_targets = [
    manifest_path,
    target_manifest_path,
    status_path,
    r16_before,
    r16_after_path,
    evidence / "raw-log-sha256.txt",
    evidence / "release-product-manifest.json",
    evidence / "debug-test-product-manifest.json",
    named_baseline_path,
    birth_evidence_path,
    *(named_summary_directory / f"{gate}.json" for gate in GATES if gate.startswith("ios-")),
    *fixture_paths,
]
for repo_name in ("ios", "backend"):
    hash_targets.extend(
        [
            evidence / f"{repo_name}-base-sha.txt",
            evidence / f"{repo_name}-status-before.txt",
            evidence / f"{repo_name}-worktree-blob-baseline.json",
            evidence / f"{repo_name}-untracked-before.manifest",
            evidence / f"{repo_name}-untracked-before.manifest.sha256",
        ]
    )
for path in hash_targets:
    access(path)
    if not path.is_file():
        fail(f"required evidence artifact missing: {path}")
(evidence / "evidence-artifact-sha256.txt").write_text(
    "\n".join(
        f"{sha256_file(path)}  {path.relative_to(evidence) if below(path, evidence) else path}"
        for path in sorted(hash_targets, key=lambda item: str(item))
    )
    + "\n"
)

access_trace.write_text("\n".join(accesses) + "\n", encoding="utf-8")
if test_mode:
    for line in accesses:
        if line.startswith("command:"):
            continue
        if not below(Path(line), root):
            fail(f"access trace escaped fixture root: {line}")

print(status["display_status"])
PY
