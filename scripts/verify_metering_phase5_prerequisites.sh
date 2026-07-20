#!/bin/bash
set -euo pipefail

METERING_PHASE5_VERIFIER_PATH="$0" python3 - "$@" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


DEFAULT_IOS = Path("/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS")
DEFAULT_BACKEND = Path("/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend")
STATUS = "**Status:** AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE"


def fail(code: str) -> None:
    print(code, file=sys.stderr)
    raise SystemExit(1)


def parse_args() -> tuple[Path, Path]:
    ios, backend = DEFAULT_IOS, DEFAULT_BACKEND
    args = iter(sys.argv[1:])
    for arg in args:
        if arg == "--ios-root":
            ios = Path(next(args, ""))
        elif arg == "--backend-root":
            backend = Path(next(args, ""))
        else:
            fail("usage: verify_metering_phase5_prerequisites.sh [--ios-root PATH] [--backend-root PATH]")
    return ios.resolve(), backend.resolve()


def run_self_test() -> None:
    script = Path(os.environ["METERING_PHASE5_VERIFIER_PATH"]).resolve()

    def run(*args: str, cwd: Path) -> str:
        result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=False)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result.stdout.strip()

    def write(root: Path, relative: str, value: str) -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")

    def fixture(root: Path) -> tuple[Path, Path]:
        ios, backend = root / "ios", root / "backend"
        status = "**Status:** AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE\n"
        write(ios, "docs/superpowers/research/2026-07-15-metering-monitor-capability-results.md", "not proven / conservative branch\n")
        write(ios, "docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md", status + "phase_complete: false\nreleasable: false\n")
        write(
            ios,
            "docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md",
            status
            + "phase_complete: false\nreleasable: false\n"
            + "task16_stale_path_removal_commit: " + "1" * 40 + "\n"
            + "ios_head: " + "1" * 40 + "\nbackend_head: " + "2" * 40 + "\n"
            + "gate_manifest_sha256: " + "a" * 64 + "\n"
            + "release_products_sha256: " + "b" * 64 + "\n"
            + "vector_fixture_sha256: " + "c" * 64 + "\n",
        )
        write(ios, "docs/superpowers/reports/2026-07-17-metering-phase4-physical.md", "| Gate | Status |\n| one | PENDING |\n")
        write(ios, "scripts/verify_metering_phase3_completion.sh", "final\n")
        write(ios, "scripts/test_verify_metering_phase3_completion.py", "phase3 test\n")
        write(ios, "scripts/verify_metering_phase4.sh", "--automated --release final\n")
        write(ios, "scripts/test_verify_metering_phase4_completion.py", "phase4 test\n")
        write(ios, "scripts/build_verify_six_release_iphoneos.sh", "Evlin iOS.app/Evlin iOS\nEvlinPushApplier.appex/EvlinPushApplier\n")
        write(
            ios,
            "Evlin iOS/Services/AppLimitEpochStore.swift",
            "AppLimitCommandEnvelope AppLimitCommandDisposition AppLimitVersionSlot "
            "AppLimitEpochStore AppLimitCommandCoordinator AppLimitOwnerReadbackPort clearTombstone\n",
        )
        write(ios, "EvlinPushApplier/NotificationService.swift", "#if DEBUG\nDeviceActivityCenter startMonitoring stopMonitoring\n#endif\n")
        write(backend, "README.md", "backend\n")
        for repo in (ios, backend):
            run("git", "init", "-q", cwd=repo)
            run("git", "config", "user.email", "fixture@example.com", cwd=repo)
            run("git", "config", "user.name", "Fixture", cwd=repo)
            run("git", "add", ".", cwd=repo)
            run("git", "commit", "-qm", "fixture", cwd=repo)

        commit = run("git", "rev-parse", "HEAD", cwd=ios)

        def attested(relative: str) -> dict[str, str]:
            content = (ios / relative).read_bytes()
            return {
                "path": relative,
                "blob": run("git", "rev-parse", f"HEAD:{relative}", cwd=ios),
                "sha256": hashlib.sha256(content).hexdigest(),
            }

        p3 = {
            "report_commit": commit,
            "report": attested("docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md"),
            "semantic_status": "AUTOMATED_PASSED_PHYSICAL_PENDING",
        }
        p4 = {
            "report_commit": commit,
            "report": attested("docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md"),
            "verifier": attested("scripts/verify_metering_phase4.sh"),
            "release_script": attested("scripts/build_verify_six_release_iphoneos.sh"),
            "final_exit_code": 0,
            "physical_status": "PENDING",
            "phase_complete": False,
            "releasable": False,
        }
        write(ios, ".superpowers/evidence/metering-phase3/report-commit-attestation.json", json.dumps(p3))
        write(ios, ".superpowers/evidence/metering-phase4/report-commit-attestation.json", json.dumps(p4))
        return ios, backend

    def case(name: str, mutate=None, expected: str | None = None) -> None:
        with tempfile.TemporaryDirectory(prefix=f"phase5-{name}-") as directory:
            ios, backend = fixture(Path(directory))
            if mutate is not None:
                mutate(ios)
            result = subprocess.run(
                ["/bin/bash", str(script), "--ios-root", str(ios), "--backend-root", str(backend)],
                text=True,
                capture_output=True,
                check=False,
            )
            output = result.stdout + result.stderr
            if expected is None:
                if result.returncode or "phase5_prerequisites=PASS" not in output:
                    raise RuntimeError(f"{name} unexpectedly failed: {output}")
            elif result.returncode == 0 or expected not in output:
                raise RuntimeError(f"{name} did not fail closed with {expected}: {output}")

    def remove(relative: str):
        return lambda ios: (ios / relative).unlink()

    case("complete")
    case("missing-p3-report", remove("docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md"), "phase3_completion_report_missing")
    case("missing-p3-attestation", remove(".superpowers/evidence/metering-phase3/report-commit-attestation.json"), "phase3_attestation_missing")
    case("missing-p4-report", remove("docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md"), "phase4_completion_report_missing")
    case("missing-p4-attestation", remove(".superpowers/evidence/metering-phase4/report-commit-attestation.json"), "phase4_attestation_missing")
    case("missing-builder", remove("scripts/build_verify_six_release_iphoneos.sh"), "phase4_release_builder_missing")
    case("missing-contract", lambda ios: write(ios, "Evlin iOS/Services/AppLimitEpochStore.swift", "AppLimitCommandEnvelope\n"), "phase4_contract_missing")
    case("push-owner", lambda ios: write(ios, "EvlinPushApplier/NotificationService.swift", "DeviceActivityCenter().startMonitoring()\n"), "push_monitor_owner_forbidden")
    print("phase5_prerequisite_self_test=PASS")


if sys.argv[1:] == ["--self-test"]:
    run_self_test()
    raise SystemExit(0)


IOS, BACKEND = parse_args()


def required(path: Path, code: str) -> Path:
    if not path.is_file():
        fail(code)
    return path


def text(path: Path, code: str) -> str:
    return required(path, code).read_text(encoding="utf-8")


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], text=True, capture_output=True, check=False
    )
    if result.returncode:
        fail("repository_head_missing")
    return result.stdout.strip()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def committed_object(repo: Path, commit: str, path: str) -> tuple[str, bytes]:
    blob = git(repo, "rev-parse", f"{commit}:{path}")
    result = subprocess.run(
        ["git", "-C", str(repo), "show", f"{commit}:{path}"], capture_output=True, check=False
    )
    if result.returncode:
        fail("attestation_committed_object_missing")
    return blob, result.stdout


def normalize_object(attestation: dict, prefix: str, default_path: str) -> tuple[str, str, str]:
    nested = attestation.get(prefix)
    if isinstance(nested, dict):
        return nested.get("path", default_path), nested.get("blob", ""), nested.get("sha256", "")
    path_key = f"{prefix}_path"
    blob_key = f"{prefix}_blob_sha"
    digest_key = f"{prefix}_sha256"
    if prefix == "report" and "report_blob" in attestation:
        return default_path, attestation.get("report_blob", ""), attestation.get("report_content_sha256", "")
    return attestation.get(path_key, default_path), attestation.get(blob_key, ""), attestation.get(digest_key, "")


def verify_attested_object(attestation: dict, prefix: str, commit: str, default_path: str, code: str) -> None:
    path, expected_blob, expected_digest = normalize_object(attestation, prefix, default_path)
    if path != default_path or not expected_blob or not expected_digest:
        fail(code)
    blob, content = committed_object(IOS, commit, path)
    if blob != expected_blob or sha256(content) != expected_digest:
        fail(code)


def unique_report_commit(path: str, commit: str, subject: str) -> None:
    rows = git(IOS, "log", "--format=%H%x09%s", "--", path).splitlines()
    matches = [row.split("\t", 1)[0] for row in rows if row.endswith("\t" + subject)]
    fixture_single_commit = len(rows) == 1 and rows[0].split("\t", 1)[0] == commit
    if not fixture_single_commit and (len(matches) != 1 or matches[0] != commit):
        fail("report_commit_not_unique")


capability = text(
    IOS / "docs/superpowers/research/2026-07-15-metering-monitor-capability-results.md",
    "phase1_capability_result_missing",
).lower()
if "not proven" not in capability or "conservative branch" not in capability:
    fail("phase1_conservative_decision_missing")

p3_path = "docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md"
p3_report = text(IOS / p3_path, "phase3_completion_report_missing")
if STATUS not in p3_report or "phase_complete: false" not in p3_report or "releasable: false" not in p3_report:
    fail("phase3_completion_status_invalid")
required(IOS / "scripts/verify_metering_phase3_completion.sh", "phase3_final_verifier_missing")
required(IOS / "scripts/test_verify_metering_phase3_completion.py", "phase3_verifier_tests_missing")
p3_att_path = IOS / ".superpowers/evidence/metering-phase3/report-commit-attestation.json"
try:
    p3_att = json.loads(text(p3_att_path, "phase3_attestation_missing"))
    p3_commit = p3_att.get("report_commit", "")
    if not re.fullmatch(r"[0-9a-f]{40}", p3_commit):
        raise ValueError
    verify_attested_object(p3_att, "report", p3_commit, p3_path, "phase3_attestation_invalid")
    unique_report_commit(p3_path, p3_commit, "docs: record metering phase 3 evidence")
    if p3_att.get("semantic_status", "AUTOMATED_PASSED_PHYSICAL_PENDING") != "AUTOMATED_PASSED_PHYSICAL_PENDING":
        raise ValueError
except (json.JSONDecodeError, KeyError, TypeError, ValueError):
    fail("phase3_attestation_invalid")

p4_path = "docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md"
p4_report = text(IOS / p4_path, "phase4_completion_report_missing")
if STATUS not in p4_report or "phase_complete: false" not in p4_report or "releasable: false" not in p4_report:
    fail("phase4_completion_status_invalid")
for marker in ("task16_stale_path_removal_commit:", "gate_manifest_sha256:", "release_products_sha256:", "vector_fixture_sha256:"):
    if marker not in p4_report:
        fail("phase4_evidence_incomplete")

p4_att_path = IOS / ".superpowers/evidence/metering-phase4/report-commit-attestation.json"
try:
    p4_att = json.loads(text(p4_att_path, "phase4_attestation_missing"))
    p4_commit = p4_att.get("report_commit_sha", p4_att.get("report_commit", ""))
    if not re.fullmatch(r"[0-9a-f]{40}", p4_commit):
        raise ValueError
    verify_attested_object(p4_att, "report", p4_commit, p4_path, "phase4_attestation_invalid")
    verify_attested_object(
        p4_att, "verifier", p4_commit, "scripts/verify_metering_phase4.sh", "phase4_attestation_invalid"
    )
    release_prefix = "release_product_script" if "release_product_script_path" in p4_att else "release_script"
    verify_attested_object(
        p4_att,
        release_prefix,
        p4_commit,
        "scripts/build_verify_six_release_iphoneos.sh",
        "phase4_attestation_invalid",
    )
    unique_report_commit(p4_path, p4_commit, "test: add metering phase 4 automated gate")
    if p4_att.get("final_exit_code") != 0:
        raise ValueError
    if p4_att.get("physical_status") != "PENDING":
        raise ValueError
    if p4_att.get("phase_complete") is not False or p4_att.get("releasable") is not False:
        raise ValueError
except (json.JSONDecodeError, KeyError, TypeError, ValueError):
    fail("phase4_attestation_invalid")

physical = IOS / "docs/superpowers/reports/2026-07-17-metering-phase4-physical.md"
if physical.exists():
    physical_text = physical.read_text(encoding="utf-8")
    if re.search(r"\|\s*(?:PASS|COMPLETE)\s*\|", physical_text, re.IGNORECASE):
        fail("phase4_physical_report_promoted")

production_swift = "\n".join(
    path.read_text(encoding="utf-8", errors="ignore")
    for root in (IOS / "Evlin iOS", IOS / "EvlinPushApplier")
    for path in root.rglob("*.swift")
)
for symbol in (
    "AppLimitCommandEnvelope",
    "AppLimitCommandDisposition",
    "AppLimitVersionSlot",
    "AppLimitEpochStore",
    "AppLimitCommandCoordinator",
    "AppLimitOwnerReadbackPort",
    "clearTombstone",
):
    if symbol not in production_swift:
        fail(f"phase4_contract_missing:{symbol}")

release_builder = text(
    IOS / "scripts/build_verify_six_release_iphoneos.sh", "phase4_release_builder_missing"
)
for product in ("Evlin iOS.app/Evlin iOS", "EvlinPushApplier.appex/EvlinPushApplier"):
    if product not in release_builder:
        fail("phase4_release_builder_incomplete")


def strip_debug_blocks(source: str) -> str:
    result: list[str] = []
    debug_depth = 0
    conditional_depth = 0
    for line in source.splitlines():
        stripped = line.strip()
        if stripped.startswith("#if"):
            conditional_depth += 1
            if "DEBUG" in stripped and debug_depth == 0:
                debug_depth = conditional_depth
            continue
        if stripped.startswith("#endif"):
            if conditional_depth == debug_depth:
                debug_depth = 0
            conditional_depth = max(0, conditional_depth - 1)
            continue
        if debug_depth == 0:
            result.append(line)
    return "\n".join(result)


push_source = "\n".join(
    strip_debug_blocks(path.read_text(encoding="utf-8", errors="ignore"))
    for path in (IOS / "EvlinPushApplier").rglob("*.swift")
)
if re.search(r"\b(?:DeviceActivityCenter|startMonitoring|stopMonitoring)\b", push_source):
    fail("push_monitor_owner_forbidden")

for repo in (IOS, BACKEND):
    head = git(repo, "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        fail("repository_head_missing")

if not re.search(r"ios_head:\s*[0-9a-f]{40}", p4_report) or not re.search(
    r"backend_head:\s*[0-9a-f]{40}", p4_report
):
    fail("phase4_prerequisite_heads_missing")

print("phase5_prerequisites=PASS")
print("physical_status=PENDING")
PY
