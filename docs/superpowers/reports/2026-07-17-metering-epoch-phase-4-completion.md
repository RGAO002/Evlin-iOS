# Metering Epoch Phase 4 Automated Evidence

**Status:** AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE

status_code: AUTOMATED_PASSED_PHYSICAL_PENDING
phase_complete: false
releasable: false
task16_stale_path_removal_commit: 6dc9181df09ca1a7947e8f1eb4ab97d0e70918a6
ios_head: b49aee1f90474a940cc0da392f3f644d79d3e1dd
backend_head: da06fba46ffc1ed240bae7a571b72a6c50ecf239
gate_manifest_sha256: 61d9dd6661f3bca4248337cfdd312edd69a3066ba66d7cab184549701effdd46
release_products_sha256: c07534b67890de69daca0564e09e6a0e4968c0e550889621da16aab1c32c61b5
vector_fixture_sha256: c565b8fc43b2964a59827e1f9883c60e7d87f97d6a9d07357145d5f50699b32a

Tests ran using Debug simulator products. Five unsigned production products were
built using Release; the XCTest executable was built separately using Debug
build-for-testing. This report does not claim that Release tests ran.

| Gate | Required physical evidence | Status |
|---|---|---|
| P4-DEVICE-1 | One-minute app-limit callback and shield | PENDING |
| P4-DEVICE-2 | Pause, force-quit, resume replacement | PENDING |
| P4-DEVICE-3 | New clear followed by delayed old set | PENDING |
| P4-DEVICE-4 | Two-device attribution | PENDING |

Automated gate details, command exit codes, runtimes, and raw-log hashes are in
`.superpowers/evidence/metering-phase4/runs/20260721T012742Z-b49aee1/gates.tsv`. Physical evidence is not
fabricated by this automated run.
