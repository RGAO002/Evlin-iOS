# Metering Epoch Phase 3 Automated Evidence

**Status:** AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE

```yaml
status_code: AUTOMATED_PASSED_PHYSICAL_PENDING
phase_complete: false
releasable: false
```

This report records automated evidence only. It does not claim physical-device
completion, release readiness, deployment, or production validation.

## Scope And Immutable Heads

| Item | SHA |
|---|---|
| iOS immutable base | `9e19f4180721cd833c329a99efa168aef8e8aaa0` |
| Backend immutable base | `44c9aa6f94f2ae91ab252c7256bfb754bb130993` |
| iOS automated evidence head | `9083408405f5a05b623d9a71e7bf6ed54d998a33` |
| Backend automated evidence head | `37c391a8acd1b79163f80698c680417d19551579` |

The report cannot recursively embed its own commit SHA or Git blob/SHA-256.
It intentionally has no self-hash field. Task 29 final mode records those values
externally in `.superpowers/evidence/metering-phase3/report-commit-attestation.json`
after this report-only commit exists.

## Test Accounting

Relative to exact named baseline: zero new failures.

Historical debt 36 items tracked separately. The baseline is an exact set of
test identifiers per destination, not a numeric allowance. A new failure, a
substitution, or a resolved row that remains in the baseline fails the gate.

| Destination | Passed | Named historical failures | Skipped | Debt classification |
|---|---:|---:|---:|---|
| iPhone 17 Pro / iOS 26.3.1 | 790 | 36 | 4 | 25 `deinit_family`, 11 `old_fixture` |
| iPad Pro 13-inch (M5) / iOS 26.3.1 | 789 | 35 | 4 | 25 `deinit_family`, 10 `old_fixture` |

The unique historical debt count is 36 because the destination sets overlap.
`deinit_family` is owned by `task_2633a95f`; `old_fixture` and any future
explicit `auth_debt` classification are owned by
`task_phase3_legacy_test_debt_20260719`.

The protected metering family ran separately on both destinations:

| Destination | Protected passed | Proved exception | Skipped |
|---|---:|---:|---:|
| iPhone 17 Pro | 635 | 1 | 0 |
| iPad Pro 13-inch (M5) | 635 | 1 | 0 |

The sole protected exception is
`MeteringAuthoritativeBaseCorrectionTests/testEveryCorrectionBoundaryReopensWithStableIDsAndConverges()`.
Its failure was reproduced in an isolated clone at full baseline commit
`e46ffe15b45825b20ca1a5b687815cbb340b2f24`, dated
`2026-07-18T18:01:53-04:00`, before Task 25. The recorded failure is
`locally active corrected route must remain countable`. Birth-evidence SHA-256:
`18216cae83d676d4dbbb08018b785da963ad3b3a28ef866f49630a296ef371bd`.

The V30 environment-dependent Swift case was executed by the dedicated
cross-stack orchestrator, not waived or baseline-listed.

## Build Evidence

Tests executed with Debug `build-for-testing`; five production Release binaries
were scanned and contained no test seams. This does not claim that Release tests
were executed.

| Product | Bytes | SHA-256 |
|---|---:|---|
| Main app | 50,806,376 | `f81c312d2f054c2f59ef91d635796afe5030181848ab484e0604ca56c36702de` |
| DeviceActivity monitor | 4,225,832 | `800dd9d30c0dbb31e895e1ee342300bacca881ac4a10d6d7ce1898d9ae86affe` |
| DeviceActivity report | 798,096 | `ae9d706d7f342bf31f77586615f60fd66de879044109ded681dfba9f9e72b587` |
| Shield configuration | 168,904 | `2ed2b6838809f54ba8850b4ae0927548e0eacf68396366b0bc86468a093c567e` |
| Push applier | 1,065,632 | `ea5ed9bc7c8911b5264a84a93ba7bfcde2cd7bc120952e98eaaf587eb5cef25c` |
| Debug XCTest executable | 24,704,568 | `33d73a4f0bcbfd6209c45da69c74df216abd77cfdae3d07283b1b694f6c43e01` |

Release source SIL excluded `DebugAppGroupMeteringClock` and
`evlin.metering.debugClockNow`; the Debug control SIL contained both symbols.

## Raw Gate Evidence

| Gate | Raw log SHA-256 |
|---|---|
| Backend vector contract | `cd54de04c2a1cc061afc1db9d52270941352baedc7f0e9ba49055b566b9e4e2f` |
| Backend gate resume | `f736db3c0b69c81b64a2fe3e2ce2ff4d48c1ee2df9910813dde344e4754a754e` |
| Backend Phase 3 DB | `b9300cabffaffba7ee230f5f13dde01cbb86fa84369230bd0f2e2dd0a021d451` |
| Cross-stack V30 | `e394f446847970b5bb9070a84225d687d5d6324aeaac6892e6477c14bf19c2ca` |
| Protected iPhone | `89f8d128014156ef9330d9ca6fbb37a0f293dc17ec4bef12cd6c751e9ecca1e2` |
| Protected iPad | `04dffd17b81a67003094e7988fdf46b8175f2d594c7efd5431245ae8ac858423` |
| Legacy iPhone | `e0e8458f61ac5a1b4c88a52195b6818a84bae2ba3bf0c555d053103c0deeb780` |
| Legacy iPad | `31a1f01a1577a9888d07cf128dfa03059a9cdd9c4102b634c90bd4ef4a15efab` |
| Release build | `163a8066ab885720b7dfe529462463ab07554ea9c4ac5acbc9ea9eccd1fe1cc5` |
| Debug test build | `fbb84e27d6f13ff5c8b76b6ad82cfba0c60a5e11ffcae054c5e99477e26427fa` |
| Release source check | `e92cfc69073d405003a887fd11948a0e1de6837c48a9e8062ba87cbca066396a` |
| R-16 structured map | `9946d1965b14b09cbb0aed494b15e69e6c5ddbc2db04646001c964972b2fb613` |
| Authoritative correction disposition | `c581f066ed721b94eea29c078ea9dbfa0b13646fa074118a7beafbd4b7601909` |

The canonical raw-log manifest SHA-256 is
`3bac4172ccc9ba20fd16b36a443f6b3cd103bec0c8a577c7e1aaea578ab412d7`.
The task commit manifest SHA-256 is
`9e74024c119c290ce15fdea3a545ff7bbd098e55db30b8e49902501ede5c6da1`.

## Task Commit Manifest

| Task | Repository | Commit |
|---|---|---|
| 01 | iOS | `f3111669dcedc4ed2dd500c891f52b9ff8818f50` |
| 02 | iOS | `b37c287854828cc8aade85098258c38653a6ed68` |
| 03 | Backend | `87993e3be8b6c4069bd20d6db1b7cdb2ed0cd85a` |
| 04 | iOS | `dcf6bd963ecd0089ef5d1e6e7f0b5aec6a642c2e` |
| 05 | iOS | `32010ce010109b582086b67e3e46ce6288b3c96b` |
| 06 | iOS | `30976066f4e84a3214f0c2a186775c83434a15f6` |
| 07 | Backend | `127be6233db824f7511a61b0e67d0f511a7820f4` |
| 08 | iOS | `2eb2d146361131a0e3842dcc95e5b6ad0f93d439` |
| 09 | iOS | `549de24f541e128b388042d66cadee2c2899aa1e` |
| 10 | iOS | `5d86ef956f1d251d4ee229fc0b37f93751ec2698` |
| 11 | iOS | `e0ee6a2aedaa7f7bd3e6b0c03c3e6eb0912f09ee` |
| 12 | iOS | `83101f45a9d77b6ff9073669f649223d4fe8dab0` |
| 13 | iOS | `e437bc05e2dc83b040ab90e75627815f9bd0acbc` |
| 14 | iOS | `e1046aacbcc4d654aa062db7c1849ce6bfb60257` |
| 15 | iOS | `fcb669d3f8677936646bc753a2cdd0028be65cf8` |
| 16 | iOS | `b11fa4f92e194f5e5a913d94ba2e182bf736a446` |
| 17 | iOS | `04d2beb09feae0a8546963b157c439f71075ba5f` |
| 18 | iOS | `2ec0893caeb0e767882afa221e8d5f1ec679a927` |
| 19 | Backend | `37c391a8acd1b79163f80698c680417d19551579` |
| 20 | iOS | `60a91f8d8656d969ac0f5da3e5efe4fa8ef8bddd` |
| 21 | iOS | `b2eb3a41940c8b166d66fdb0a8918c91a0ffee53` |
| 22 | iOS | `d33218e7ab24e339906b6e786d31ce8b2857b4ae` |
| 23 | iOS | `6194a04816e33116233e6b87d9e935cd4c383065` |
| 23A | iOS | `2ac2e355e00ae6c8291be2aec16388ea56ec70d3` |
| 24 | iOS | `e46ffe15b45825b20ca1a5b687815cbb340b2f24` |
| 25 | iOS | `26fec04d426aa6369e333aef0ede9424e093436f` |
| 26 | iOS | `bef870fa5e372ef1f317a1c0b49b3078cd05fd67` |
| 27 | iOS | `21269f5bb83b5a990decef60402e653fb7d91464` |
| 28 | iOS | `ad1e6394d08b6d95ead893589770f16ea67e586c` |
| 29 | iOS | `2f175713869fc2991046cce9f899d006141e4215` |

## 本阶段拆除清单 + 向量证据

| R-16 item | Removed production mechanism | Authoritative replacement | Vector / production evidence | Result |
|---|---|---|---|---|
| T1 | scalar arm signature churn | six-field generation + eight dated routes | V01/V02/V03/V06/V07/V24 + real-installer 121 reconciliation log | AUTOMATED PASS |
| T2 | raw pool/cap stale-ladder ceiling | immutable route provenance + tombstone | V04/V05/V08/V13/V27 + T2 log | AUTOMATED PASS |
| T3 | fresh-at-fire shield gate | strict callback trust + shield envelope | V04/V05/V10/V12/P3V01 + T3 log | AUTOMATED PASS |
| Phase 3 T4 | backend headroom veto | local effect envelope + exact CAS release | V15/V16/P3V01/P3V02/V36 + T4 log | AUTOMATED PASS |
| T5 | backend `_sample_is_plausible` `+5` branch | Phase 2 strict canonical/accounting validation | Phase 2 report + backend tests | PHASE 2 PASS |
| T11 | iOS device plus-five heuristic | 30-second default / 60-second maximum jitter | V04/V05/V19/V30 + T11 log | AUTOMATED PASS |
| T7 | counter-recovery flags | paused high-water + conservative replacement + one boundary discard | V06/V10/V11/V12/V37 + T7 log | AUTOMATED PASS |
| T8 | dual activity lifecycle implementation | Device Epoch Store + LegacyCompatibilityMonitorState | V01/V08/V09/V13/V21/V22/V28/V38 + T8 log | AUTOMATED PASS |

R-16 rulebook hash changed from
`3be460546198107f5c4a4cfab1e06f7bbec07a3b07252e4eb1e34396203455fc`
to `c0ae054794ca344c71b5497496f148cb7e4087b89c605ec5e60157e6b601ceba`.
The structured verifier confirmed the registered replacements and required
vector sets.

## Physical-Device Pending Gate

| Gate | Required evidence | Status |
|---|---|---|
| Earned threshold | 6-7 minute earned threshold, force-kill delivery, no duplicate attribution | PENDING |
| Per-app DEBUG | DEBUG one-minute per-app threshold and shield transition | PENDING |
| Two-device | two distinct physical devices; usage attributed only to reporting device | PENDING |
| TestFlight overnight | eight-date horizon, force-quit overnight callback/rollover/refill, no churn, capacity result | PENDING |
| Minimum floor | physical iOS/iPadOS 17.6 start/callback/replacement/stop/day-boundary ownership | PENDING |

No simulator result, report, local SDK inspection, or elapsed time may promote
these rows. Phase 3 therefore remains incomplete and not releasable.
