# Metering Epoch Phase 4 Automated Evidence

**Status:** AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE

status_code: AUTOMATED_PASSED_PHYSICAL_PENDING
phase_complete: false
releasable: false
task16_stale_path_removal_commit: 6dc9181df09ca1a7947e8f1eb4ab97d0e70918a6
ios_head: 6dc9181df09ca1a7947e8f1eb4ab97d0e70918a6
backend_head: bd202058ab3d8ba345fb37db494160165c48aea4
gate_manifest_sha256: d19bd7ed1abf0c90566c945488525a565876cbf29e29ada6a3a47e1145fd1f03
release_products_sha256: 646bedfdf801070eafefd6bde743ead0da9f34fb4e256d3c5b915c5eb985d506
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
`.superpowers/evidence/metering-phase4/gates.tsv`. Physical evidence is not
fabricated by this automated run.
