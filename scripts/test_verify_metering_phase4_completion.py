from __future__ import annotations

import copy
import hashlib
import json
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
ATTESTATION = ROOT / ".superpowers/evidence/metering-phase4/report-commit-attestation.json"
REPORT_PATH = "docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md"
VERIFIER_PATH = "scripts/verify_metering_phase4.sh"
RELEASE_SCRIPT_PATH = "scripts/build_verify_six_release_iphoneos.sh"
SUBJECT = "test: add metering phase 4 automated gate"


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def matching_report_commits() -> list[str]:
    rows = git("log", "--format=%H%x09%s", "--", REPORT_PATH).decode().splitlines()
    return [row.split("\t", 1)[0] for row in rows if row.endswith(f"\t{SUBJECT}")]


def committed_bytes(commit: str, path: str) -> bytes:
    return git("show", f"{commit}:{path}")


def committed_blob(commit: str, path: str) -> str:
    return git("rev-parse", f"{commit}:{path}").decode().strip()


def validate(attestation: dict) -> None:
    commits = matching_report_commits()
    assert len(commits) == 1, "canonical Task 17 report commit must be unique"
    report_commit = commits[0]
    assert attestation["report_commit_sha"] == report_commit

    for prefix, path in [
        ("report", REPORT_PATH),
        ("verifier", VERIFIER_PATH),
        ("release_product_script", RELEASE_SCRIPT_PATH),
    ]:
        assert attestation[f"{prefix}_path"] == path
        content = committed_bytes(report_commit, path)
        assert attestation[f"{prefix}_blob_sha"] == committed_blob(report_commit, path)
        assert attestation[f"{prefix}_sha256"] == sha256(content)

    assert attestation["final_command"] == [
        "/bin/bash",
        VERIFIER_PATH,
        "final",
        report_commit,
    ]
    assert attestation["final_exit_code"] == 0
    assert attestation["final_stdout"] == (
        f"final_report_commit={report_commit}\nphysical_status=PENDING\n"
    )
    assert attestation["physical_status"] == "PENDING"
    assert attestation["phase_complete"] is False
    assert attestation["releasable"] is False


def load() -> dict:
    assert ATTESTATION.exists(), "Phase 4 report-commit attestation is missing"
    return json.loads(ATTESTATION.read_text())


def test_committed_phase4_handoff_is_immutable_and_pending() -> None:
    validate(load())


@pytest.mark.parametrize(
    ("field", "replacement"),
    [
        ("report_commit_sha", "0" * 40),
        ("report_sha256", "0" * 64),
        ("verifier_blob_sha", "0" * 40),
        ("release_product_script_sha256", "0" * 64),
        ("final_exit_code", 1),
        ("physical_status", "PASS"),
        ("phase_complete", True),
        ("releasable", True),
    ],
)
def test_tampered_or_promoted_attestation_is_rejected(
    field: str,
    replacement: object,
) -> None:
    value = copy.deepcopy(load())
    value[field] = replacement
    with pytest.raises((AssertionError, KeyError)):
        validate(value)
