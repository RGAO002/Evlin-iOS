# Metering Epoch Phase 5 Automated Evidence

**Status:** AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE

status_code: AUTOMATED_PASSED_PHYSICAL_PENDING
phase_complete: false
releasable: false
ios_head: 95fa8edf3d9a61abc8850ba6222afb6cdd69d23f
backend_head: 39450008fcdb283f01e526f4c4c042a461168a8a
phase4_report_commit: 35a4d966f652cfee98d8ab87fac957b72f83b89b
gate_run_id: 20260720T205012Z-95fa8ed
gate_manifest_sha256: 024f3ccc74b5b26ca2b8550339d826d816179b8a9a779530cfad7a3f04c6fc17
release_products_sha256: 46b57965a76c1a08dbde7acd0df0fb90f5a3b41c54426555bfd27753ca9824d5
vector_fixture_sha256: cbc9161a7a47d773e691a5033bcbd62e16a9a6e24e35c0db40fbf55ee7c55c6b

Simulator tests ran using Debug products. The fixed production products were
built and scanned separately using Release. This report does not claim that
Release XCTest ran.

| Gate | Required evidence | Status |
|---|---|---|
| G-17 five bypasses | canonical helper plus durable command/wake rows | AUTOMATED PASS |
| G-18 newest delivery | P5V01-P5V05 plus tombstones | AUTOMATED PASS |
| G-18 owner readback | exact owner receipt before ack | AUTOMATED PASS |
| G-19 persistence/readback | P5V06-P5V07 monotonic policy owner | AUTOMATED PASS |
| Multi-device fanout | P5V08-P5V11 A/B receipts and attribution | AUTOMATED PASS |
| Force-killed set/clear physical | App Group capture and owner ack | PENDING |
| Force-killed config physical | policy bytes and owner activation ack | PENDING |
| DEBUG one-minute per-app threshold | real-use shield only | PENDING |
| Two-device attribution smoke | distinct own-cap bars | PENDING |
| TestFlight overnight | two devices across canonical midnight | PENDING |
| Physical 17.6 minimum floor | install, callback, stop, horizon | PENDING |

Raw logs and immutable hashes are archived under
.superpowers/evidence/metering-phase5/runs/20260720T205012Z-95fa8ed/. A failed rerun creates a
new directory and cannot overwrite this successful run.
