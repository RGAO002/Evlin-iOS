#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Callable


EXPECTED_IDS = tuple(f"T{index}" for index in range(1, 12))
VALID_STATUSES = {
    "UNATTESTED",
    "REMOVED",
    "PENDING_ONE_RELEASE",
    "PENDING_FRED_APPROVAL",
    "RETAINED_FRED_WAIVER",
}
PENDING_STATUSES = {"PENDING_ONE_RELEASE", "PENDING_FRED_APPROVAL"}
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_DEMOLITION_SUBJECTS = {
    "T1": "refactor: remove earned arm signature churn",
    "T2": "refactor: remove stale raw threshold ceiling",
    "T3": "refactor: remove earned fresh-at-fire gate",
    "T4": "refactor: remove earned backend headroom veto",
    "T5": "feat: validate ratcheted metering samples",
    "T7": "refactor: remove earned counter recovery flags",
    "T8": "refactor: retire duplicate earned activity lifecycle",
    "T9": "refactor: remove dead earned locked token data",
    "T11": "refactor: remove earned plus-five heuristic",
}


class VerificationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise VerificationError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def resolve_repository(name: str, ios_root: Path, backend_root: Path) -> Path:
    if name == "ios":
        return ios_root
    if name == "backend":
        return backend_root
    fail(f"unknown_repository:{name}")


def require_commit(repo: Path, value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA_PATTERN.fullmatch(value):
        fail(f"malformed_SHA:{label}")
    if git(repo, "cat-file", "-e", f"{value}^{{commit}}", check=False).returncode != 0:
        fail(f"commit_not_found:{label}:{value}")
    return value


def production_files(repo: Path) -> list[Path]:
    result: list[Path] = []
    excluded_parts = {
        ".git", ".superpowers", ".worktrees", "docs", "scripts", "Evlin iOSTests",
        "tests", "__pycache__", "DerivedData",
    }
    for root, directories, filenames in os.walk(repo):
        root_path = Path(root)
        directories[:] = [name for name in directories if name not in excluded_parts]
        if any(part in excluded_parts for part in root_path.relative_to(repo).parts):
            continue
        for filename in filenames:
            path = root_path / filename
            if path.suffix in {".swift", ".py"}:
                result.append(path)
    return result


def validate_ledger(
    payload: Any,
    *,
    ios_root: Path,
    backend_root: Path,
    allow_unattested: bool,
    final: bool,
) -> None:
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        fail("invalid_schema_version")
    rows = payload.get("demolitions")
    if not isinstance(rows, list):
        fail("demolitions_must_be_array")
    ids = [row.get("id") if isinstance(row, dict) else None for row in rows]
    if len(ids) != len(set(ids)):
        fail("duplicate_T_id")
    missing = sorted(set(EXPECTED_IDS) - set(ids))
    extra = sorted(set(ids) - set(EXPECTED_IDS), key=str)
    if missing or extra:
        fail(f"missing_or_unknown_T_ids:missing={missing}:extra={extra}")

    for row in rows:
        if not isinstance(row, dict):
            fail("demolition_row_must_be_object")
        row_id = row["id"]
        status = row.get("status")
        if status not in VALID_STATUSES:
            fail(f"unknown_status:{row_id}:{status}")
        if status == "RETAINED_FRED_WAIVER":
            fail(f"waiver_not_permitted:{row_id}")
        if row_id == "T6" and status == "REMOVED":
            fail("T6_requires_one_release")
        if row_id == "T10" and status == "REMOVED" and not row.get("fred_approval"):
            fail("T10_requires_Fred_written_approval")

        demolition = row.get("demolition_commit")
        revert_command = row.get("revert_command")
        if status in PENDING_STATUSES:
            if demolition is not None or revert_command is not None:
                fail(f"pending_row_carries_demolition_SHA:{row_id}")
        if status == "UNATTESTED":
            if final or not allow_unattested:
                fail(f"unattested_row:{row_id}")
            continue
        if status != "REMOVED":
            continue

        if not isinstance(row.get("vectors"), list) or not row["vectors"]:
            fail(f"missing_vector:{row_id}")
        if not all(isinstance(value, str) and value for value in row["vectors"]):
            fail(f"invalid_vector:{row_id}")
        replacements = row.get("replacement_commits")
        if not isinstance(replacements, list) or not replacements:
            fail(f"missing_replacement_commit:{row_id}")
        if not isinstance(demolition, dict):
            fail(f"missing_demolition_commit:{row_id}")
        demolition_repo = resolve_repository(
            demolition.get("repository"), ios_root, backend_root
        )
        demolition_sha = require_commit(
            demolition_repo, demolition.get("sha"), f"{row_id}.demolition"
        )
        expected_subject = EXPECTED_DEMOLITION_SUBJECTS.get(row_id)
        actual_subject = git(demolition_repo, "show", "-s", "--format=%s", demolition_sha).stdout.strip()
        if expected_subject is not None and actual_subject != expected_subject:
            fail(f"wrong_demolition_subject:{row_id}:{actual_subject}")
        if not isinstance(revert_command, str) or not revert_command:
            fail(f"missing_revert_command:{row_id}")
        if demolition_sha not in revert_command:
            fail(f"revert_SHA_mismatch:{row_id}")

        for index, replacement in enumerate(replacements):
            if not isinstance(replacement, dict):
                fail(f"replacement_commit_malformed:{row_id}:{index}")
            replacement_repo = resolve_repository(
                replacement.get("repository"), ios_root, backend_root
            )
            replacement_sha = require_commit(
                replacement_repo,
                replacement.get("sha"),
                f"{row_id}.replacement.{index}",
            )
            if replacement_repo == demolition_repo:
                result = git(
                    demolition_repo,
                    "merge-base", "--is-ancestor", replacement_sha, demolition_sha,
                    check=False,
                )
                if result.returncode != 0 or replacement_sha == demolition_sha:
                    fail(f"replacement_commit_after_demolition:{row_id}")

        evidence = row.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            fail(f"subject_only_evidence:{row_id}")
        for index, entry in enumerate(evidence):
            if not isinstance(entry, dict):
                fail(f"evidence_entry_malformed:{row_id}:{index}")
            raw_path = entry.get("path")
            expected_hash = entry.get("sha256")
            if not isinstance(raw_path, str) or not Path(raw_path).is_absolute():
                fail(f"evidence_path_not_absolute:{row_id}:{index}")
            if not isinstance(expected_hash, str) or not HASH_PATTERN.fullmatch(expected_hash):
                fail(f"evidence_hash_malformed:{row_id}:{index}")
            evidence_path = Path(raw_path)
            if not evidence_path.is_file() or sha256(evidence_path) != expected_hash:
                fail(f"wrong_evidence_hash:{row_id}:{index}")

        forbidden = row.get("forbidden_symbols")
        if not isinstance(forbidden, list):
            fail(f"forbidden_symbols_malformed:{row_id}")
        repository = demolition_repo
        for symbol in forbidden:
            if not isinstance(symbol, str) or not symbol:
                fail(f"forbidden_symbol_malformed:{row_id}")
            for path in production_files(repository):
                if symbol in path.read_text(errors="ignore"):
                    fail(f"forbidden_symbol_present:{row_id}:{symbol}:{path}")


def _git_commit(repo: Path, subject: str, filename: str) -> str:
    (repo / filename).write_text(subject)
    git(repo, "add", filename)
    git(
        repo,
        "-c", "user.name=Phase Six",
        "-c", "user.email=phase6@example.invalid",
        "commit", "-m", subject,
    )
    return git(repo, "rev-parse", "HEAD").stdout.strip()


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="phase6-verifier-") as raw:
        root = Path(raw)
        ios = root / "ios"
        backend = root / "backend"
        ios.mkdir()
        backend.mkdir()
        for repo in (ios, backend):
            git(repo, "init")
        replacement = _git_commit(ios, "replacement", "replacement.txt")
        demolition = _git_commit(
            ios, EXPECTED_DEMOLITION_SUBJECTS["T1"], "demolition.txt"
        )
        evidence = root / "evidence.log"
        evidence.write_text("green\n")

        def base_payload() -> dict[str, Any]:
            rows = []
            for row_id in EXPECTED_IDS:
                status = "UNATTESTED"
                if row_id == "T6":
                    status = "PENDING_ONE_RELEASE"
                elif row_id == "T10":
                    status = "PENDING_FRED_APPROVAL"
                rows.append({
                    "id": row_id,
                    "status": status,
                    "legacy_mechanism": row_id,
                    "replacement": ["replacement"],
                    "deletion_criterion": "green",
                    "replacement_commits": [],
                    "vectors": [],
                    "evidence": [],
                    "demolition_commit": None,
                    "revert_command": None,
                    "forbidden_symbols": [],
                    "release_observation": None,
                    "fred_approval": None,
                })
            return {"schema_version": 1, "demolitions": rows}

        def removed_t1() -> dict[str, Any]:
            payload = base_payload()
            row = payload["demolitions"][0]
            row.update({
                "status": "REMOVED",
                "replacement_commits": [{"repository": "ios", "sha": replacement}],
                "vectors": ["V01"],
                "evidence": [{"path": str(evidence), "sha256": sha256(evidence)}],
                "demolition_commit": {"repository": "ios", "sha": demolition},
                "revert_command": f"git -C {ios} revert {demolition}",
            })
            return payload

        def expect_failure(
            name: str,
            payload: dict[str, Any],
            expected: str,
            *,
            final: bool = False,
        ) -> None:
            try:
                validate_ledger(
                    payload,
                    ios_root=ios,
                    backend_root=backend,
                    allow_unattested=not final,
                    final=final,
                )
            except VerificationError as error:
                if expected not in str(error):
                    fail(f"self_test_wrong_error:{name}:{error}")
            else:
                fail(f"self_test_expected_failure:{name}")

        valid = removed_t1()
        validate_ledger(valid, ios_root=ios, backend_root=backend, allow_unattested=True, final=False)

        duplicate = copy.deepcopy(valid)
        duplicate["demolitions"].append(copy.deepcopy(duplicate["demolitions"][0]))
        expect_failure("duplicate", duplicate, "duplicate_T_id")
        missing = copy.deepcopy(valid)
        missing["demolitions"].pop()
        expect_failure("missing", missing, "missing_or_unknown_T_ids")
        unknown = copy.deepcopy(valid)
        unknown["demolitions"][1]["status"] = "MAGIC"
        expect_failure("unknown-status", unknown, "unknown_status")
        malformed = copy.deepcopy(valid)
        malformed["demolitions"][0]["demolition_commit"]["sha"] = "abc"
        expect_failure("malformed-sha", malformed, "malformed_SHA")
        subject_only = copy.deepcopy(valid)
        subject_only["demolitions"][0]["evidence"] = []
        expect_failure("subject-only", subject_only, "subject_only_evidence")
        wrong_hash = copy.deepcopy(valid)
        wrong_hash["demolitions"][0]["evidence"][0]["sha256"] = "0" * 64
        expect_failure("wrong-hash", wrong_hash, "wrong_evidence_hash")
        missing_revert = copy.deepcopy(valid)
        missing_revert["demolitions"][0]["revert_command"] = None
        expect_failure("missing-revert", missing_revert, "missing_revert_command")
        wrong_revert = copy.deepcopy(valid)
        wrong_revert["demolitions"][0]["revert_command"] = "git revert " + "0" * 40
        expect_failure("wrong-revert", wrong_revert, "revert_SHA_mismatch")
        no_vector = copy.deepcopy(valid)
        no_vector["demolitions"][0]["vectors"] = []
        expect_failure("missing-vector", no_vector, "missing_vector")

        ignored_worktree_file = (
            ios / ".worktrees" / "stale" / "Evlin iOS" / "Services" / "Forbidden.swift"
        )
        ignored_worktree_file.parent.mkdir(parents=True)
        ignored_worktree_file.write_text("let oldGuard = true\n")
        ignored_worktree = copy.deepcopy(valid)
        ignored_worktree["demolitions"][0]["forbidden_symbols"] = ["oldGuard"]
        validate_ledger(
            ignored_worktree,
            ios_root=ios,
            backend_root=backend,
            allow_unattested=True,
            final=False,
        )

        forbidden_file = ios / "Evlin iOS" / "Services" / "Forbidden.swift"
        forbidden_file.parent.mkdir(parents=True)
        forbidden_file.write_text("let oldGuard = true\n")
        forbidden = copy.deepcopy(valid)
        forbidden["demolitions"][0]["forbidden_symbols"] = ["oldGuard"]
        expect_failure("forbidden", forbidden, "forbidden_symbol_present")
        forbidden_file.unlink()

        later = _git_commit(ios, "later replacement", "later.txt")
        replacement_after = copy.deepcopy(valid)
        replacement_after["demolitions"][0]["replacement_commits"][0]["sha"] = later
        expect_failure(
            "replacement-after", replacement_after, "replacement_commit_after_demolition"
        )

        outside = root / "outside"
        outside.mkdir()
        git(outside, "init")
        outside_sha = _git_commit(outside, "outside", "outside.txt")
        git(ios, "fetch", str(outside), outside_sha)
        outside_payload = copy.deepcopy(valid)
        outside_payload["demolitions"][0]["replacement_commits"][0]["sha"] = outside_sha
        expect_failure("outside-ancestry", outside_payload, "replacement_commit_after_demolition")

        t6 = copy.deepcopy(valid)
        t6["demolitions"][5]["status"] = "REMOVED"
        expect_failure("t6", t6, "T6_requires_one_release")
        t10 = copy.deepcopy(valid)
        t10["demolitions"][9]["status"] = "REMOVED"
        expect_failure("t10", t10, "T10_requires_Fred_written_approval")
        pending_sha = copy.deepcopy(valid)
        pending_sha["demolitions"][5]["demolition_commit"] = {
            "repository": "ios", "sha": demolition
        }
        expect_failure("pending-sha", pending_sha, "pending_row_carries_demolition_SHA")
        expect_failure("final-unattested", valid, "unattested_row", final=True)

    print("phase6_demolition_self_test_passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ios-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument(
        "--backend-root",
        type=Path,
        default=Path("/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend"),
    )
    parser.add_argument(
        "--ledger",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json",
    )
    parser.add_argument("--allow-unattested", action="store_true")
    parser.add_argument("--final", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.self_test:
            run_self_test()
            return 0
        if args.allow_unattested == args.final:
            fail("choose_exactly_one_mode")
        payload = json.loads(args.ledger.read_text())
        validate_ledger(
            payload,
            ios_root=args.ios_root.resolve(),
            backend_root=args.backend_root.resolve(),
            allow_unattested=args.allow_unattested,
            final=args.final,
        )
        print("phase6_demolition_ledger_valid")
        return 0
    except (VerificationError, OSError, json.JSONDecodeError) as error:
        print(f"VerificationError: {error}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
