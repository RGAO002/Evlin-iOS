from __future__ import annotations

import re
import unicodedata
from pathlib import Path


RULEBOOK_PATH = Path("/Users/fred/Desktop/Evlin/LOCK_BEHAVIOR_BOUNDARIES.md")

EXPECTED_T1_T11: tuple[tuple[str, ...], ...] = (
    (
        "T1",
        "armSignature 编码+比较(EarnedBudgetArming makeArmSignature/shouldStartMonitoring/selectionFingerprint 重编码)",
        "churn 元凶",
        "generation replacement key(§6.1,raw-bytes digest)",
        "Phase 3",
    ),
    (
        "T2",
        "stale-ladder 防火墙(raw N > min(pool,cap))",
        "t185 跨账号",
        "epoch 身份匹配 + trust 函数",
        "Phase 3",
    ),
    (
        "T3",
        "fresh-at-fire 门(shouldApplyEarnedShieldFresh)",
        "早期误锁",
        "trust 函数 + epoch gate 状态",
        "Phase 3",
    ),
    (
        "T4",
        "backend headroom veto(600s/5min 窗口)",
        "自锁误杀",
        "trust 函数 + 自锁 CAS revert(§8.5)",
        "Phase 3/5",
    ),
    (
        "T5",
        'R-15 "+5" 容差实现(_sample_is_plausible 的 +5 分支)',
        "G-20 应急补丁",
        "严格上界(elapsed+jitter≤60s)",
        "Phase 2",
    ),
    (
        "T6",
        "BigKidActivityScheduler + evlin.bigkid.chunk + /child/time-consumption 全链",
        "v1 设备总量",
        "earned runtime 权威(§11 五步闸)",
        "Phase 6",
    ),
    (
        "T7",
        "counterRecoveryRequired / pendingUncountedReconciliation 标志族",
        "计数恢复竞态",
        "epoch pause/resume 状态机(§8.3)",
        "Phase 3",
    ),
    (
        "T8",
        "EarnedActivityGeneration 生命周期中与 epoch 重叠的部分(activityLifecycle/breadcrumbs 双轨)",
        "identity 切换",
        "Device Epoch Store(§6.4,身份守卫并入)",
        "Phase 3",
    ),
    (
        "T9",
        "earned.lockedSetTokenData 死路径(双写方皆 nil)",
        "无",
        "无需替代,直接删",
        "任意",
    ),
    (
        "T10",
        '旧 /parent/device/unlock-selected 的"剥全源+自动 override"契约(现标 SUPERSEDED 兼容)',
        "Fix-8/bug#6",
        "纯 manual CTA + 独立 override 动作(§3.6)",
        "兼容一版后,需产品确认",
    ),
    (
        "T11",
        "iOS `EarnedThresholdPlausibility.toleranceMinutes = 5` 整桶容差",
        "re-arm 后早到回调应急补丁",
        "epoch 路由身份 + elapsed/jitter≤60s 严格上界",
        "Phase 3",
    ),
)

EXPECTED_PHASE3: tuple[tuple[str, ...], ...] = (
    (
        "`MeteringCallbackRoute/route tombstone`",
        "T2/T8 callback provenance",
        "stop acknowledged, all references terminal, retention elapsed",
        "V04,V05,V08,V27,V35",
    ),
    (
        "`LegacyCompatibilityMonitorState`",
        "preserves T8 v1 behavior while replacing its storage authority",
        "owner v2 activated and legacy stop acknowledged",
        "V30,V38",
    ),
    (
        "`pendingStart/starting/installed/verified/dualActive/active/pendingStop/stopped`",
        "replaces T8 lifecycle choreography; `dualActive` closes the backend/local ratchet crash window",
        "daemon presence/config or absence acknowledged",
        "V28,V30,V33,V38",
    ),
    (
        "`V2RouteHandoff.preparing/dualV2/cutoverReady/committed`",
        "net-new crash-safe v2-to-v2 replacement without a zero-metering window or stale prior sample loss",
        "prior queue/in-flight barrier closed, replacement active, prior stop acknowledged, overlap samples terminal",
        "V09,V21,V22,V32,V37",
    ),
    (
        "`ActivityInstallClaim 60-second lease`",
        "net-new app/DAM single-start arbitration",
        "one proven monitor-owner process exists",
        "V33",
    ),
    (
        "`futurePlanned/offlinePending`",
        "net-new explicit bounded authorization",
        "registered/activated, retired, or stopped",
        "V24,V27",
    ),
    (
        "`MonitorCoverageState.readyThrough/coverageExhausted`",
        "replaces false repeating coverage",
        "horizon refilled or owner/generation retired",
        "V24,V25,V26",
    ),
    (
        "`registration/activation queue and per-owner protocol ratchet`",
        "replaces direct v1-only dispatch without breaking v1",
        "owner retired after terminal queues",
        "V19,V20,V30,V38",
    ),
    (
        "`BaseCorrectionState.available/used`",
        "net-new bounded 409 correction",
        "registration accepted or correction terminal",
        "V32",
    ),
    (
        "`process-role monitor owner`",
        "net-new capability boundary",
        "physical ownership proof authorizes another role",
        "target/Release/physical evidence",
    ),
    (
        "`resumeBoundaryPending/paused high-water`",
        "replaces T7",
        "first new-route callback discarded or epoch retired",
        "V10,V11,V12,V37",
    ),
    (
        "`0/5/15/60/300 retry schedule`",
        "net-new deterministic recovery policy",
        "all work terminal",
        "V34",
    ),
    (
        "`EarnedShieldEffectEnvelope`",
        "replaces T4 veto",
        "exact release/CAS terminal",
        "V15,V16,P3V01,P3V02,V36",
    ),
    (
        "`EarnedShieldReference` / epoch `shieldReferences`",
        "minimal D#6 authorization reference for the T4 replacement envelope; not an independent veto",
        "exact release, identity cleanup, or reference retention terminally acknowledged",
        "P3V01,P3V02 + T4 demolition vectors",
    ),
    (
        "`IdentityCleanupWork`",
        "replaces T8 detached teardown",
        "every captured acknowledgement durable",
        "V13,V29",
    ),
    (
        "`RolloverEffectsWork`",
        "net-new durable canonical rollover",
        "all exact old/new effects acknowledged",
        "V09,V21,V22,V29",
    ),
    (
        "`EpochSampleWork`",
        "replaces legacy retry/fallback after activation",
        "accepted or terminal disposition",
        "V19,V20,V30,V32",
    ),
)

_HEADING_PATTERN = re.compile(r"^\s*#{1,6}(?:\s+.*)?\s*$")
_SEPARATOR_CELL_PATTERN = re.compile(r"^:?-{3,}:?$")


def _normalize_cell(cell: str) -> str:
    return unicodedata.normalize("NFC", cell.strip())


def _parse_markdown_row(line: str) -> tuple[str, ...]:
    stripped = line.strip()
    assert stripped.startswith("|") and stripped.endswith("|"), (
        f"malformed Markdown table row: {line!r}"
    )

    cells: list[str] = []
    current: list[str] = []
    escaped = False
    for character in stripped[1:-1]:
        if escaped:
            if character == "|":
                current.append(character)
            else:
                current.extend(("\\", character))
            escaped = False
        elif character == "\\":
            escaped = True
        elif character == "|":
            cells.append(_normalize_cell("".join(current)))
            current = []
        else:
            current.append(character)

    if escaped:
        current.append("\\")
    cells.append(_normalize_cell("".join(current)))
    return tuple(cells)


def parse_table_after_heading(text: str, heading: str) -> tuple[tuple[str, ...], ...]:
    """Return exact non-header Markdown rows; reject duplicate/malformed tables."""
    lines = text.splitlines()
    heading_indexes = [
        index for index, line in enumerate(lines) if line.strip() == heading
    ]
    assert len(heading_indexes) == 1, (
        f"expected exactly one heading {heading!r}, found {len(heading_indexes)}"
    )

    section_start = heading_indexes[0] + 1
    section_end = len(lines)
    for index in range(section_start, len(lines)):
        if _HEADING_PATTERN.fullmatch(lines[index]):
            section_end = index
            break

    table_blocks: list[tuple[str, ...]] = []
    current_block: list[str] = []
    for line in lines[section_start:section_end]:
        if "|" in line:
            current_block.append(line)
        elif current_block:
            table_blocks.append(tuple(current_block))
            current_block = []
    if current_block:
        table_blocks.append(tuple(current_block))

    assert len(table_blocks) == 1, (
        f"expected exactly one Markdown table after {heading!r}, "
        f"found {len(table_blocks)}"
    )

    parsed_rows = tuple(_parse_markdown_row(line) for line in table_blocks[0])
    assert len(parsed_rows) >= 3, f"table after {heading!r} has no data rows"

    header, separator, *data_rows = parsed_rows
    column_count = len(header)
    assert column_count > 0 and all(header), f"table after {heading!r} has an empty header"
    assert len(separator) == column_count and all(
        _SEPARATOR_CELL_PATTERN.fullmatch(cell) for cell in separator
    ), f"table after {heading!r} has a malformed separator"
    assert all(len(row) == column_count for row in data_rows), (
        f"table after {heading!r} has inconsistent column counts"
    )
    assert not any(
        len(row) == column_count
        and all(_SEPARATOR_CELL_PATTERN.fullmatch(cell) for cell in row)
        for row in data_rows
    ), f"table after {heading!r} contains a duplicate separator"
    assert data_rows, f"table after {heading!r} has no data rows"
    return tuple(data_rows)


def main() -> int:
    rulebook = RULEBOOK_PATH.read_text()
    actual_t1_t11 = parse_table_after_heading(
        rulebook,
        "## 11. 机制拆除台账(反臃肿闸,2026-07-15 Fred 提出)",
    )
    assert actual_t1_t11 == EXPECTED_T1_T11, (
        f"T1-T11 dismantling ledger changed:\nexpected {EXPECTED_T1_T11!r}"
        f"\nactual   {actual_t1_t11!r}"
    )

    actual_phase3 = parse_table_after_heading(
        rulebook,
        "### Phase 3 registered safety state",
    )
    assert actual_phase3 == EXPECTED_PHASE3, (
        f"Phase 3 R-16 registration changed:\nexpected {EXPECTED_PHASE3!r}"
        f"\nactual   {actual_phase3!r}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
