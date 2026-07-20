from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts/verify_metering_phase5_prerequisites.sh"


def test_prerequisite_verifier_executes_fail_closed_fixture_matrix() -> None:
    result = subprocess.run(
        ["/bin/bash", str(VERIFIER), "--self-test"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "phase5_prerequisite_self_test=PASS" in output
