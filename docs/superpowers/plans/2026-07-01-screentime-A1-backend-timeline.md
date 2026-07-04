# Screen-Time A1 Backend Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the cross-device unified timeline — a backend `evlin_screen_time_events` table that the kid AND parent apps batch-upload their A0 ring buffers into (plus backend-emitted rows at ingest/command points), and make the device's reported current-restrictions snapshot read enforcement truth instead of the lagging in-memory copy — so the developer (and Claude) can query the whole P/K/backend chain with SQL, no screenshots.

**Architecture:** Backend: one new table + one batch-ingest endpoint (`POST /device/screen-time/events`, idempotent per `(family_id, client_event_id)` with the device embedded in device-uploaded ids, **prod-gated off by default** via `SCREEN_TIME_EVENT_UPLOAD_ENABLED`) + a tiny `screen_time_event_service.emit()` wired at three earned-time points. iOS: a fire-and-forget `ScreenTimeEventUploader` (app target only, **DEBUG builds only**) that hashes ring-buffer lines for deterministic dedupe ids, tracks a watermark (advances only on full success; never skips unattributable lines), and uploads on app foreground; and `CommandPoller.globalEffectiveStateDictionary()` re-pointed from `ActiveLockStore` (in-memory, proven to lag) to `CurrentRestrictionsReader` (App-Group enforcement truth), now including the block list.

**Tech Stack:** FastAPI, SQLAlchemy async, Alembic, asyncpg, pytest(+asyncio, DB-gated); Swift, CryptoKit (SHA-256), URLSession, XCTest.

## Global Constraints

- Backend repo: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend` (Tasks 1–3). iOS repo: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS` (Tasks 4–5).
- Table name (verbatim): `evlin_screen_time_events`. Endpoint path (verbatim): `/device/screen-time/events`. Auth header (verbatim): `X-Evlin-Device-ID` (must equal `body.device_id`; the endpoint accepts **both** parent- and child-mode devices).
- **Production gate (review decision 2026-07-01): device-header self-attestation is DEBUG-ONLY trust — never on by default in production.** Backend: `settings.screen_time_event_upload_enabled` (env `SCREEN_TIME_EVENT_UPLOAD_ENABLED`, **default `False`**) — the endpoint returns 403 when off; enable only in the local `.env`, do NOT set it on Render. iOS: the uploader body is compiled out with `#if DEBUG` — Release/TestFlight builds never upload.
- Idempotency scope (verbatim): unique `(family_id, client_event_id)`, where device-uploaded ids **embed the uploading device**: `client_event_id = "line:<deviceID>:<sha256hex(line)>"` — two devices emitting byte-identical lines must NOT dedupe each other (the whole point of this table is the cross-device chain). Backend-emitted rows use `backend:<uuid4>`.
- iOS watermark key (verbatim): `evlin.screentime.uploadedThroughHash` — stores the **bare** sha256 hex of the last uploaded line (device-independent, so it's computed before attribution). Kill-switch key: `evlin.screentime.uploadDisabled` (standard defaults). **Watermark advances ONLY when every POST of the pending window succeeded. If no device identity is resolvable, return WITHOUT advancing** — never silently drop unattributable diagnostics (identity-missing events are exactly the ones we need); the ring-buffer cap + server dedupe make rescans safe.
- `ScreenTimeEventUploader.swift` is a member of the **`Evlin iOS` app target ONLY** — never the extension (the extension only writes the ring buffer; A0 constraint).
- Backend DB tests require `EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test` (they skip without it). Run iOS tests with `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 17' test` filtered via `-only-testing:`.
- Commits include ONLY the files named in each task. Never stage `project.pbxproj` churn beyond target-membership additions, `xcuserstate`, or `.DS_Store`. **Do NOT push either repo** — the user controls pushes (backend push auto-deploys to Render).
- Scope notes: the uploader ships whatever is in the ring buffer — kid-extension events flow through today; new **in-app** emission points (parent app limit-change/lock taps, kid app sample/command points) are NOT added in this plan (parent actions are already visible via the backend `command_emit`/`sample` rows; more in-app emitters land with the Tier-2 fixes that touch those paths). Backend emission at cascade/exhaustion-mark points likewise lands with the Tier-2 fixes that modify them.

---

## File Structure

**Backend (Evlin-Backend):**
- **Create** `app/db/models/screen_time_event.py` — `ScreenTimeEventRow` ORM model.
- **Modify** `app/db/models/__init__.py` — register the model.
- **Create** `alembic/versions/2026_07_01_screen_time_events.py` — create-table migration.
- **Create** `app/schemas/screen_time_events.py` — request/response schemas.
- **Create** `app/api/routes/screen_time_events.py` — batch-ingest route.
- **Modify** `app/main.py` — register the router.
- **Create** `app/services/screen_time_event_service.py` — backend emitter.
- **Modify** `app/services/earned_time_service.py` — emit at 3 points (ingest, pool-exhausted lock command, config command).
- **Create** `tests/test_screen_time_events_api.py` — endpoint + emitter regression tests (DB-gated).

**iOS (Evlin-iOS):**
- **Modify** `Evlin iOS/Services/ScreenTimeEventLog.swift` — add `readLines()` (raw-line access for hashing).
- **Create** `Evlin iOS/Services/ScreenTimeEventUploader.swift` — batch uploader (app target only).
- **Create** `Evlin iOSTests/ScreenTimeEventUploaderTests.swift` — pure-helper tests.
- **Modify** `Evlin iOS/Evlin_iOSApp.swift` — trigger upload on scenePhase `.active`.
- **Modify** `Evlin iOS/Models/CommandModels.swift` — `AckEffectiveState` gains `blocks`.
- **Modify** `Evlin iOS/Services/CommandPoller.swift` — snapshot reads enforcement truth.
- **Create** `Evlin iOSTests/CommandPollerEffectiveStateTests.swift` — snapshot-truth tests.

---

## Task 1: Backend — `ScreenTimeEventRow` model + migration

**Files:**
- Create: `app/db/models/screen_time_event.py`
- Modify: `app/db/models/__init__.py`
- Create: `alembic/versions/2026_07_01_screen_time_events.py`
- Test: `tests/test_screen_time_events_api.py` (first test only)

**Interfaces:**
- Consumes: `app.db.base.Base`; FK targets `evlin_families.id`, `evlin_devices.id`.
- Produces: `ScreenTimeEventRow` with columns `id, family_id, device_id (nullable), ts, emitter, day_key, kind, source, app, reason, nums (JSONB), transition (JSONB), policy_gen, corr_id, client_event_id, created_at`; unique index `uq_screen_time_events_idempotency (family_id, client_event_id)`; query index `ix_screen_time_events_family_ts (family_id, ts)`. Tasks 2–3 import it as `from app.db.models.screen_time_event import ScreenTimeEventRow`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_screen_time_events_api.py`:

```python
"""A1 regressions: screen_time_events model, batch-ingest endpoint, backend emitter."""
from __future__ import annotations

import os
from datetime import datetime, timezone as _tz
from uuid import uuid4

import pytest
from sqlalchemy import select

pytestmark = [
    pytest.mark.asyncio,
    pytest.mark.skipif(
        not os.getenv("EVLIN_TEST_DATABASE_URL"),
        reason="EVLIN_TEST_DATABASE_URL not set; local Postgres required",
    ),
]

from app.db.models import Device, DeviceMode, Family
from app.db.models.screen_time_event import ScreenTimeEventRow


async def _make_family_device(session, mode=DeviceMode.child):
    fam = Family()
    session.add(fam)
    await session.flush()
    device = Device(family_id=fam.id, mode=mode, label="Test Device")
    session.add(device)
    await session.flush()
    return fam, device


async def test_model_insert_roundtrip(session):
    fam, device = await _make_family_device(session)
    session.add(ScreenTimeEventRow(
        family_id=fam.id,
        device_id=device.id,
        ts=datetime(2026, 7, 1, 20, 55, tzinfo=_tz.utc),
        emitter="kid_extension",
        day_key="2026-07-01@America/New_York",
        kind="lock",
        source="earnedPool",
        app="device-wide",
        reason="pool_exhausted",
        nums={"remaining": 0, "poolTotal": 60},
        client_event_id=f"line:{uuid4().hex}",
    ))
    await session.flush()
    row = (await session.execute(select(ScreenTimeEventRow))).scalar_one()
    assert row.emitter == "kid_extension"
    assert row.nums["poolTotal"] == 60
    assert row.device_id == device.id
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_screen_time_events_api.py -v
```
Expected: FAIL with `ModuleNotFoundError`/`ImportError: cannot import name 'ScreenTimeEventRow'`.
(Precondition: `colima start` + `docker start evlin-pg` if Postgres isn't running; the `ale_test` database already exists.)

- [ ] **Step 3: Write the model**

Create `app/db/models/screen_time_event.py`:

```python
"""ScreenTimeEventRow — cross-device screen-time observability timeline (A1).

Dev/debug telemetry, NOT enforcement data: the kid + parent apps batch-upload
their App-Group `ScreenTimeEvent` ring buffers here, and backend code appends
its own rows at ingest/command points, so one SQL query shows the unified
P / K / backend chain. Idempotent per (family_id, client_event_id) so batch
re-uploads never duplicate. Mirrors the Swift `ScreenTimeEvent` schema
(spec: docs/superpowers/specs/2026-07-01-timelimit-stability-design.md Part A).
"""
from __future__ import annotations

import uuid
from datetime import datetime
from typing import Optional

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class ScreenTimeEventRow(Base):
    __tablename__ = "evlin_screen_time_events"
    __table_args__ = (
        # Idempotency: re-uploading the same client event is a no-op.
        Index(
            "uq_screen_time_events_idempotency",
            "family_id",
            "client_event_id",
            unique=True,
        ),
        # The main query path: one family's timeline in ts order.
        Index("ix_screen_time_events_family_ts", "family_id", "ts"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    family_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("evlin_families.id", name="fk_screen_time_events_family_id"),
        nullable=False,
    )
    device_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("evlin_devices.id", name="fk_screen_time_events_device_id"),
        nullable=True,  # backend-emitted rows have no device
        index=True,
    )
    ts: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    emitter: Mapped[str] = mapped_column(String(16), nullable=False)
    day_key: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    source: Mapped[Optional[str]] = mapped_column(String(16), nullable=True)
    app: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    reason: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    nums: Mapped[Optional[dict]] = mapped_column(JSONB, nullable=True)
    transition: Mapped[Optional[dict]] = mapped_column(JSONB, nullable=True)
    policy_gen: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    corr_id: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    client_event_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
```

- [ ] **Step 4: Register the model**

In `app/db/models/__init__.py`, add the import next to the other model imports (match the file's existing style — e.g. right after the `EarnedTime*` import block):

```python
from app.db.models.screen_time_event import ScreenTimeEventRow
```

and add `"ScreenTimeEventRow",` to the `__all__` list (e.g. after `"EarnedTimeLockCommand",`).

- [ ] **Step 5: Write the migration**

Create `alembic/versions/2026_07_01_screen_time_events.py`:

```python
"""A1: create evlin_screen_time_events (cross-device observability timeline).

Revision ID: 2026_07_01_screen_time_events
Revises: 2026_06_24_app_limit_usage
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "2026_07_01_screen_time_events"
down_revision: Union[str, Sequence[str], None] = "2026_06_24_app_limit_usage"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "evlin_screen_time_events",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "family_id",
            UUID(as_uuid=True),
            sa.ForeignKey("evlin_families.id", name="fk_screen_time_events_family_id"),
            nullable=False,
        ),
        sa.Column(
            "device_id",
            UUID(as_uuid=True),
            sa.ForeignKey("evlin_devices.id", name="fk_screen_time_events_device_id"),
            nullable=True,
        ),
        sa.Column("ts", sa.DateTime(timezone=True), nullable=False),
        sa.Column("emitter", sa.String(16), nullable=False),
        sa.Column("day_key", sa.String(64), nullable=True),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("source", sa.String(16), nullable=True),
        sa.Column("app", sa.String(255), nullable=True),
        sa.Column("reason", sa.String(64), nullable=True),
        sa.Column("nums", JSONB, nullable=True),
        sa.Column("transition", JSONB, nullable=True),
        sa.Column("policy_gen", sa.Integer, nullable=True),
        sa.Column("corr_id", sa.String(64), nullable=True),
        sa.Column("client_event_id", sa.String(128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )
    op.create_index(
        "uq_screen_time_events_idempotency",
        "evlin_screen_time_events",
        ["family_id", "client_event_id"],
        unique=True,
    )
    op.create_index(
        "ix_screen_time_events_family_ts",
        "evlin_screen_time_events",
        ["family_id", "ts"],
    )
    op.create_index(
        "ix_evlin_screen_time_events_device_id",
        "evlin_screen_time_events",
        ["device_id"],
    )


def downgrade() -> None:
    op.drop_table("evlin_screen_time_events")
```

- [ ] **Step 6: Run test to verify it passes, and apply the migration to the dev DB**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_screen_time_events_api.py -v
```
Expected: `test_model_insert_roundtrip PASSED` (the test fixture uses `create_all`, so it passes without the migration; the migration is for the dev/prod DBs).

```bash
alembic upgrade head
docker exec evlin-pg psql -U ale_user -d ale_db -c "\d evlin_screen_time_events" | head -8
```
Expected: `alembic` logs `Running upgrade 2026_06_24_app_limit_usage -> 2026_07_01_screen_time_events`; `\d` shows the table.

- [ ] **Step 7: Commit**

```bash
git add app/db/models/screen_time_event.py app/db/models/__init__.py \
        alembic/versions/2026_07_01_screen_time_events.py \
        tests/test_screen_time_events_api.py
git commit -m "feat(a1): evlin_screen_time_events table for cross-device timeline"
```

---

## Task 2: Backend — batch-ingest endpoint

**Files:**
- Create: `app/schemas/screen_time_events.py`
- Create: `app/api/routes/screen_time_events.py`
- Modify: `app/core/settings.py` (add the upload-enabled flag)
- Modify: `.env` (local only: `SCREEN_TIME_EVENT_UPLOAD_ENABLED=true`; `.env` is gitignored — do NOT commit it, do NOT set the var on Render)
- Modify: `app/main.py` (router registration, after the existing `include_router` block ~line 411)
- Test: `tests/test_screen_time_events_api.py` (append)

**Interfaces:**
- Consumes: `ScreenTimeEventRow` (Task 1); `Device` model; `get_async_session`; `app.core.settings.settings`.
- Produces: `settings.screen_time_event_upload_enabled: bool` (default `False`); `POST /device/screen-time/events` accepting `{"device_id": UUID, "events": [ScreenTimeEventIn, …]}` (≤200 events/batch) with header `X-Evlin-Device-ID == body.device_id`, any registered device (parent or child mode); returns `{"accepted": int, "duplicates": int}`; `403` when the flag is off. Task 4's iOS uploader POSTs exactly this shape.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_screen_time_events_api.py`:

```python
@pytest.fixture(autouse=True)
def _enable_screen_time_upload(monkeypatch):
    """The endpoint is prod-gated OFF by default; tests opt in explicitly."""
    from app.core import settings as settings_mod
    monkeypatch.setattr(
        settings_mod.settings, "screen_time_event_upload_enabled", True
    )


def _event(i: int, *, kind: str = "lock") -> dict:
    return {
        "ts": f"2026-07-01T20:5{i}:00Z",
        "emitter": "kid_extension",
        "day_key": "2026-07-01@America/New_York",
        "kind": kind,
        "source": "earnedPool",
        "app": "device-wide",
        "reason": "pool_exhausted",
        "nums": {"remaining": 0},
        "client_event_id": f"line:dev-1:{'ab' * 20}{i:02d}",
    }


async def test_upload_disabled_by_default_403(client, session, monkeypatch):
    from app.core import settings as settings_mod
    monkeypatch.setattr(
        settings_mod.settings, "screen_time_event_upload_enabled", False
    )
    fam, device = await _make_family_device(session)
    await session.commit()
    resp = await client.post(
        "/device/screen-time/events",
        json={"device_id": str(device.id), "events": [_event(1)]},
        headers={"X-Evlin-Device-ID": str(device.id)},
    )
    assert resp.status_code == 403


async def test_batch_upload_inserts_rows(client, session):
    fam, device = await _make_family_device(session)
    await session.commit()
    resp = await client.post(
        "/device/screen-time/events",
        json={"device_id": str(device.id), "events": [_event(1), _event(2)]},
        headers={"X-Evlin-Device-ID": str(device.id)},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"accepted": 2, "duplicates": 0}
    rows = (await session.execute(select(ScreenTimeEventRow))).scalars().all()
    assert len(rows) == 2
    assert {r.family_id for r in rows} == {fam.id}


async def test_repost_is_idempotent(client, session):
    fam, device = await _make_family_device(session)
    await session.commit()
    batch = {"device_id": str(device.id), "events": [_event(1), _event(2)]}
    headers = {"X-Evlin-Device-ID": str(device.id)}
    assert (await client.post("/device/screen-time/events", json=batch, headers=headers)).status_code == 200
    resp = await client.post("/device/screen-time/events", json=batch, headers=headers)
    assert resp.json() == {"accepted": 0, "duplicates": 2}
    rows = (await session.execute(select(ScreenTimeEventRow))).scalars().all()
    assert len(rows) == 2


async def test_duplicate_within_one_batch_inserted_once(client, session):
    fam, device = await _make_family_device(session)
    await session.commit()
    resp = await client.post(
        "/device/screen-time/events",
        json={"device_id": str(device.id), "events": [_event(1), _event(1)]},
        headers={"X-Evlin-Device-ID": str(device.id)},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"accepted": 1, "duplicates": 1}


async def test_parent_device_can_upload(client, session):
    fam, device = await _make_family_device(session, mode=DeviceMode.parent)
    await session.commit()
    body = {"device_id": str(device.id), "events": [dict(_event(3), emitter="parent_app")]}
    resp = await client.post(
        "/device/screen-time/events",
        json=body,
        headers={"X-Evlin-Device-ID": str(device.id)},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["accepted"] == 1


async def test_header_mismatch_403(client, session):
    fam, device = await _make_family_device(session)
    await session.commit()
    resp = await client.post(
        "/device/screen-time/events",
        json={"device_id": str(device.id), "events": [_event(1)]},
        headers={"X-Evlin-Device-ID": str(uuid4())},
    )
    assert resp.status_code == 403


async def test_unknown_device_404(client):
    ghost = str(uuid4())
    resp = await client.post(
        "/device/screen-time/events",
        json={"device_id": ghost, "events": [_event(1)]},
        headers={"X-Evlin-Device-ID": ghost},
    )
    assert resp.status_code == 404
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_screen_time_events_api.py -v
```
Expected: the new tests FAIL with `404` (route not registered yet); `test_model_insert_roundtrip` still passes.

- [ ] **Step 3a: Add the production gate flag**

In `app/core/settings.py`, inside `class Settings`, add next to the other feature flags (e.g. near `agent_enabled`):

```python
    # A1 screen-time observability upload. Device-header self-attestation is
    # DEBUG-only trust, so this is OFF by default — enable in local .env only;
    # never set on Render (review decision 2026-07-01).
    screen_time_event_upload_enabled: bool = False
```

Append to the local `.env` (gitignored — never committed, never mirrored to Render):

```bash
SCREEN_TIME_EVENT_UPLOAD_ENABLED=true
```

- [ ] **Step 3: Write the schemas**

Create `app/schemas/screen_time_events.py`:

```python
"""Schemas for the A1 screen-time event batch upload."""
from __future__ import annotations

from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


class ScreenTimeEventIn(BaseModel):
    ts: datetime
    emitter: str = Field(pattern="^(parent_app|kid_app|kid_extension)$")
    day_key: Optional[str] = Field(default=None, max_length=64)
    kind: str = Field(max_length=16)
    source: Optional[str] = Field(default=None, max_length=16)
    app: Optional[str] = Field(default=None, max_length=255)
    reason: Optional[str] = Field(default=None, max_length=64)
    nums: Optional[dict] = None
    transition: Optional[dict] = None
    policy_gen: Optional[int] = None
    corr_id: Optional[str] = Field(default=None, max_length=64)
    client_event_id: str = Field(min_length=8, max_length=128)


class ScreenTimeEventBatch(BaseModel):
    device_id: UUID
    events: list[ScreenTimeEventIn] = Field(max_length=200)


class BatchIngestResponse(BaseModel):
    accepted: int
    duplicates: int
```

- [ ] **Step 4: Write the route**

Create `app/api/routes/screen_time_events.py`:

```python
"""A1 — screen-time observability event upload (dev/debug telemetry).

POST /device/screen-time/events — kid AND parent apps batch-upload their
App-Group ScreenTimeEvent ring buffers. Idempotent per
(family_id, client_event_id): re-uploads and overlapping batches are no-ops.

Auth: X-Evlin-Device-ID header must equal body.device_id; the device row
provides family scoping (same device-header trust model as
POST /child/earned-time/sample). Both device modes are accepted — the parent
app emits parent_app events.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.settings import settings
from app.db.engine import get_async_session
from app.db.models.device import Device
from app.db.models.screen_time_event import ScreenTimeEventRow
from app.schemas.screen_time_events import BatchIngestResponse, ScreenTimeEventBatch

router = APIRouter(tags=["Screen-Time Events"])


@router.post("/device/screen-time/events", response_model=BatchIngestResponse)
async def upload_screen_time_events(
    body: ScreenTimeEventBatch,
    x_evlin_device_id: UUID = Header(alias="X-Evlin-Device-ID"),
    session: AsyncSession = Depends(get_async_session),
) -> BatchIngestResponse:
    # Prod gate: device-header self-attestation is DEBUG-only trust.
    if not settings.screen_time_event_upload_enabled:
        raise HTTPException(status_code=403, detail="screen-time event upload disabled")

    if x_evlin_device_id != body.device_id:
        raise HTTPException(status_code=403, detail="device context mismatch")

    device = await session.get(Device, body.device_id)
    if device is None:
        raise HTTPException(status_code=404, detail="device not found")

    if not body.events:
        return BatchIngestResponse(accepted=0, duplicates=0)

    # In-batch dedupe first: Postgres raises "cannot affect row a second time"
    # if one INSERT contains the same conflict key twice.
    seen: set[str] = set()
    rows: list[dict] = []
    for e in body.events:
        if e.client_event_id in seen:
            continue
        seen.add(e.client_event_id)
        rows.append(
            {
                "family_id": device.family_id,
                "device_id": device.id,
                "ts": e.ts,
                "emitter": e.emitter,
                "day_key": e.day_key,
                "kind": e.kind,
                "source": e.source,
                "app": e.app,
                "reason": e.reason,
                "nums": e.nums,
                "transition": e.transition,
                "policy_gen": e.policy_gen,
                "corr_id": e.corr_id,
                "client_event_id": e.client_event_id,
            }
        )

    stmt = (
        pg_insert(ScreenTimeEventRow)
        .values(rows)
        .on_conflict_do_nothing(index_elements=["family_id", "client_event_id"])
    )
    result = await session.execute(stmt)
    await session.commit()
    accepted = result.rowcount or 0
    return BatchIngestResponse(accepted=accepted, duplicates=len(body.events) - accepted)
```

- [ ] **Step 5: Register the router**

In `app/main.py`, add next to the other route imports (match the file's existing import style):

```python
from app.api.routes.screen_time_events import router as screen_time_events_router
```

and after the existing `include_router` block (after ~line 411, `app_alias_routes.router`):

```python
app.include_router(screen_time_events_router, prefix=settings.api_prefix)
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_screen_time_events_api.py -v
```
Expected: all 8 tests PASS (incl. `test_upload_disabled_by_default_403`).

- [ ] **Step 7: Commit**

```bash
git add app/schemas/screen_time_events.py app/api/routes/screen_time_events.py \
        app/core/settings.py app/main.py tests/test_screen_time_events_api.py
git commit -m "feat(a1): POST /device/screen-time/events batch ingest (idempotent, prod-gated off)"
```
(`.env` is gitignored — the `SCREEN_TIME_EVENT_UPLOAD_ENABLED=true` line stays local.)

---

## Task 3: Backend — emitter service wired at 3 earned-time points

**Files:**
- Create: `app/services/screen_time_event_service.py`
- Modify: `app/services/earned_time_service.py` (3 insertion points, exact anchors below)
- Test: `tests/test_screen_time_events_api.py` (append)

**Interfaces:**
- Consumes: `ScreenTimeEventRow` (Task 1).
- Produces: `async def emit(session, *, family_id, kind, device_id=None, day_key=None, source=None, app=None, reason=None, nums=None, corr_id=None) -> None` — adds one `emitter="backend"` row to the session (no flush/commit; rides the caller's transaction). Later Tier-2 work calls this from cascade/exhaustion paths.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_screen_time_events_api.py`:

```python
from datetime import date
from types import SimpleNamespace

from app.db.models.child_profile import ChildProfile
from app.db.models.earned_time import EarnedTimeConfig
from app.services import earned_time_service as ets


async def test_backend_emits_sample_event_on_ingest(client, session):
    fam = Family()
    session.add(fam)
    await session.flush()
    profile = ChildProfile(family_id=fam.id, display_name="Test Child")
    session.add(profile)
    await session.flush()
    device = Device(family_id=fam.id, mode=DeviceMode.child,
                    label="Kid iPhone", child_profile_id=profile.id)
    session.add(device)
    await session.flush()
    session.add(EarnedTimeConfig(
        family_id=fam.id, child_profile_id=profile.id,
        effective_date=date(2026, 6, 23), daily_pool_minutes=60,
        timezone="America/New_York", enabled=True,
    ))
    await session.commit()

    resp = await client.post(
        "/child/earned-time/sample",
        json={
            "device_id": str(device.id),
            "usage_date": "2026-06-23",
            "timezone": "America/New_York",
            "activity_name": "evlin.earned.budget",
            "event_name": "evlin.earned.t30",
            "threshold_minutes": 30,
            "estimated_minutes": 30,
            "observed_at": "2026-06-23T15:04:00Z",
            "client_sample_id": f"earned:{device.id}:2026-06-23:t30",
        },
        headers={"X-Evlin-Child-Device-ID": str(device.id)},
    )
    assert resp.status_code == 200, resp.text

    rows = (
        await session.execute(
            select(ScreenTimeEventRow).where(ScreenTimeEventRow.kind == "sample")
        )
    ).scalars().all()
    assert len(rows) == 1
    assert rows[0].emitter == "backend"
    assert rows[0].device_id == device.id
    assert rows[0].nums["remaining"] == 30  # 60 pool - 30 used
    assert rows[0].day_key == "2026-06-23@America/New_York"


async def test_backend_emits_auto_lock_command_event(monkeypatch, session):
    """Point 2: `_maybe_queue_auto_lock` emits a backend command timeline row.

    Keep this focused on the A1 insertion point: selected-set discovery and
    `queue_app_control` already have their own suites, so patch them to force
    the branch immediately after `device_day_row.selected_lock_command_id = cmd.id`.
    """
    fam, device = await _make_family_device(session)
    command_id = uuid4()

    async def fake_load_selected_set(*args, **kwargs):
        return SimpleNamespace(list_id=uuid4(), executable_tokens_count=1)

    async def fake_ensure_selected_set(*args, **kwargs):
        return SimpleNamespace(list_id=uuid4(), executable_tokens_count=1)

    async def fake_queue_app_control(*args, **kwargs):
        return SimpleNamespace(id=command_id)

    monkeypatch.setattr(ets, "load_selected_set", fake_load_selected_set)
    monkeypatch.setattr(ets, "ensure_selected_set", fake_ensure_selected_set)
    monkeypatch.setattr(ets, "queue_app_control", fake_queue_app_control)

    device_day = SimpleNamespace(selected_lock_command_id=None, cap_exhausted_at=None)
    warning = await ets._maybe_queue_auto_lock(
        session,
        child_device=device,
        device_day_row=device_day,
        child_day_state="available",
        max_estimated=61,
        effective_cap=60,
        now_utc=datetime(2026, 7, 1, 20, 55, tzinfo=_tz.utc),
    )
    await session.flush()

    assert warning is None
    assert device_day.selected_lock_command_id == command_id
    rows = (
        await session.execute(
            select(ScreenTimeEventRow).where(
                ScreenTimeEventRow.kind == "command_emit",
                ScreenTimeEventRow.reason == "pool_exhausted_lock",
            )
        )
    ).scalars().all()
    assert len(rows) == 1
    assert rows[0].emitter == "backend"
    assert rows[0].family_id == fam.id
    assert rows[0].device_id == device.id
    assert rows[0].source == "earnedPool"
    assert rows[0].corr_id == str(command_id)
    assert rows[0].nums == {"used": 61, "cap": 60}


async def test_backend_emits_config_command_event(session):
    """Point 3: `_insert_earned_time_config_command` emits a backend command row."""
    fam, device = await _make_family_device(session)
    cmd = await ets._insert_earned_time_config_command(
        session,
        family_id=fam.id,
        child_device_id=device.id,
        payload={"action": "earned_time_config"},
    )
    await session.flush()

    rows = (
        await session.execute(
            select(ScreenTimeEventRow).where(
                ScreenTimeEventRow.kind == "command_emit",
                ScreenTimeEventRow.reason == "config_change",
            )
        )
    ).scalars().all()
    assert len(rows) == 1
    assert rows[0].emitter == "backend"
    assert rows[0].family_id == fam.id
    assert rows[0].device_id == device.id
    assert rows[0].source == "earnedPool"
    assert rows[0].corr_id == str(cmd.id)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest \
    tests/test_screen_time_events_api.py::test_backend_emits_sample_event_on_ingest \
    tests/test_screen_time_events_api.py::test_backend_emits_auto_lock_command_event \
    tests/test_screen_time_events_api.py::test_backend_emits_config_command_event \
    -v
```
Expected: all three FAIL at `assert len(rows) == 1` (0 rows — nothing emits yet).

- [ ] **Step 3: Write the emitter service**

Create `app/services/screen_time_event_service.py`:

```python
"""Backend emitter for the A1 screen-time observability timeline.

Appends `emitter="backend"` rows to evlin_screen_time_events on the caller's
session/transaction. Observability must never break the caller: this only
`session.add()`s — no flush, no commit, no exceptions expected. Keep calls
cheap and unconditional (the table is the debug timeline; volume is low).
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models.screen_time_event import ScreenTimeEventRow


async def emit(
    session: AsyncSession,
    *,
    family_id: uuid.UUID,
    kind: str,
    device_id: Optional[uuid.UUID] = None,
    day_key: Optional[str] = None,
    source: Optional[str] = None,
    app: Optional[str] = None,
    reason: Optional[str] = None,
    nums: Optional[dict] = None,
    corr_id: Optional[str] = None,
) -> None:
    session.add(
        ScreenTimeEventRow(
            family_id=family_id,
            device_id=device_id,
            ts=datetime.now(timezone.utc),
            emitter="backend",
            day_key=day_key,
            kind=kind,
            source=source,
            app=app,
            reason=reason,
            nums=nums,
            corr_id=corr_id,
            client_event_id=f"backend:{uuid.uuid4()}",
        )
    )
```

- [ ] **Step 4: Wire the 3 emission points in `app/services/earned_time_service.py`**

Add the import at the top of the file, next to the other `app.services` imports:

```python
from app.services import screen_time_event_service
```

**Point 1 — ingest (kind=`sample`).** Find the lines (~365):

```python
    child_day_row.remaining_minutes = remaining
    child_day_row.state = new_state
    await db.flush()
```

Insert immediately after `await db.flush()`:

```python
    await screen_time_event_service.emit(
        db,
        family_id=family_id,
        device_id=child_device_id,
        kind="sample",
        source="earnedPool",
        day_key=f"{usage_date.isoformat()}@{body.timezone}",
        reason=f"ingest:{new_state}",
        nums={
            "used": total_used,
            "poolTotal": pool,
            "remaining": remaining,
            "rounded": body.estimated_minutes,
        },
    )
```

**Point 2 — pool-exhausted lock command (kind=`command_emit`).** This is inside `_maybe_queue_auto_lock(db, *, child_device: Device, device_day_row, child_day_state, max_estimated, effective_cap, now_utc)` (~line 97) — note it has **no** `family_id`/`child_device_id` locals, only `child_device`. Find (~190):

```python
    # Record the command id on the device-day (idempotency)
    device_day_row.selected_lock_command_id = cmd.id  # type: ignore[assignment]
```

Insert immediately after that line:

```python
    await screen_time_event_service.emit(
        db,
        family_id=child_device.family_id,
        device_id=child_device.id,
        kind="command_emit",
        source="earnedPool",
        reason="pool_exhausted_lock",
        nums={"used": max_estimated, "cap": effective_cap},
        corr_id=str(cmd.id),
    )
```

**Point 3 — config command (kind=`command_emit`).** In `_insert_earned_time_config_command(db, *, family_id: UUID, child_device_id: UUID, payload: Dict[str, Any])` (~line 1039) — here `family_id` / `child_device_id` ARE the keyword parameters. Insert after `await db.flush()` and before `return cmd`:

```python
    await screen_time_event_service.emit(
        db,
        family_id=family_id,
        device_id=child_device_id,
        kind="command_emit",
        source="earnedPool",
        reason="config_change",
        corr_id=str(cmd.id),
    )
```

- [ ] **Step 5: Run the full backend suite**

```bash
EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test \
  python -m pytest tests/test_screen_time_events_api.py tests/test_earned_time_remaining_recompute.py -v
```
Expected: all PASS (the emitter must not break existing earned-time flows). Then run the whole suite once: `python -m pytest -q` — expected: no new failures vs. the pre-task baseline.

- [ ] **Step 6: Commit**

```bash
git add app/services/screen_time_event_service.py app/services/earned_time_service.py \
        tests/test_screen_time_events_api.py
git commit -m "feat(a1): backend emitter wired at ingest + lock/config command points"
```

---

## Task 4: iOS — `ScreenTimeEventUploader` + foreground trigger

**Files:**
- Modify: `Evlin iOS/Services/ScreenTimeEventLog.swift` (add `readLines`)
- Create: `Evlin iOS/Services/ScreenTimeEventUploader.swift` (**app target only**)
- Modify: `Evlin iOS/Evlin_iOSApp.swift` (scenePhase `.active`, ~line 96)
- Test: `Evlin iOSTests/ScreenTimeEventUploaderTests.swift`

**Interfaces:**
- Consumes: `ScreenTimeEventLog.readLines(from:)` (added here), `ScreenTimeEvent.from(jsonLine:)`, `DeviceIdentity.parentKey`/`.childKey`, `APIClient.currentBaseURL: String`.
- Produces: `enum ScreenTimeEventUploader` with pure helpers `lineHash(_:) -> String` (bare sha256 hex; watermark currency), `clientEventID(deviceID:line:) -> String` (`"line:<deviceID>:<hash>"`), `pendingLines(all:lastUploadedHash:) -> [String]`, `deviceID(for:parentID:childID:) -> String?`, `groupedPayloads(lines:parentID:childID:) -> [String: [[String: Any]]]`, `makeRequest(baseURL:deviceID:events:) throws -> URLRequest`, and entry point `static func uploadPending() async` (DEBUG-only body).

- [ ] **Step 1: Add raw-line access to the ring buffer**

In `Evlin iOS/Services/ScreenTimeEventLog.swift`, after the `read(from:)` function add:

```swift
    /// Raw JSONL lines (oldest → newest). The A1 uploader hashes these for
    /// deterministic client_event_ids, so it needs the exact stored strings.
    static func readLines() -> [String] {
        guard let d = shared else { return [] }
        return readLines(from: d)
    }

    static func readLines(from defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }
```

- [ ] **Step 2: Write the failing tests**

Create `Evlin iOSTests/ScreenTimeEventUploaderTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class ScreenTimeEventUploaderTests: XCTestCase {

    private func line(ts: String, emitter: ScreenTimeEvent.Emitter = .kidExtension) -> String {
        ScreenTimeEvent(
            ts: ts, emitter: emitter, deviceID: nil,
            dayKey: "2026-07-01@America/New_York",
            kind: .lock, source: .earnedPool, app: "device-wide",
            reason: "pool_exhausted", nums: nil, transition: nil,
            policyGen: nil, corrID: nil
        ).jsonLine()
    }

    // 1) same line → same hash; different line → different hash; 64-hex, no prefix
    func test_lineHash_deterministic() {
        let l = line(ts: "2026-07-01T20:55:00Z")
        XCTAssertEqual(ScreenTimeEventUploader.lineHash(l), ScreenTimeEventUploader.lineHash(l))
        XCTAssertNotEqual(ScreenTimeEventUploader.lineHash(l),
                          ScreenTimeEventUploader.lineHash(line(ts: "2026-07-01T20:56:00Z")))
        XCTAssertEqual(ScreenTimeEventUploader.lineHash(l).count, 64)
    }

    // 1b) client_event_id embeds the uploading device — identical lines from two
    //     devices must NOT collide (cross-device dedupe would eat one device's chain)
    func test_clientEventID_embedsDevice() {
        let l = line(ts: "2026-07-01T20:55:00Z")
        let idA = ScreenTimeEventUploader.clientEventID(deviceID: "DEV-A", line: l)
        let idB = ScreenTimeEventUploader.clientEventID(deviceID: "DEV-B", line: l)
        XCTAssertNotEqual(idA, idB)
        XCTAssertEqual(idA, "line:DEV-A:" + ScreenTimeEventUploader.lineHash(l))
        XCTAssertLessThanOrEqual(idA.count, 128)  // backend column limit
    }

    // 2) no watermark → everything pending
    func test_pendingLines_noWatermark_returnsAll() {
        let all = [line(ts: "T1"), line(ts: "T2")]
        XCTAssertEqual(ScreenTimeEventUploader.pendingLines(all: all, lastUploadedHash: nil), all)
    }

    // 3) watermark in buffer → only lines after it
    func test_pendingLines_afterWatermark() {
        let a = line(ts: "T1"), b = line(ts: "T2"), c = line(ts: "T3")
        let mark = ScreenTimeEventUploader.lineHash(b)
        XCTAssertEqual(ScreenTimeEventUploader.pendingLines(all: [a, b, c], lastUploadedHash: mark), [c])
    }

    // 4) watermark rotated out of the capped buffer → re-upload all (server dedupes)
    func test_pendingLines_rotatedWatermark_returnsAll() {
        let all = [line(ts: "T5"), line(ts: "T6")]
        XCTAssertEqual(
            ScreenTimeEventUploader.pendingLines(all: all, lastUploadedHash: "0123deadbeef"), all)
    }

    // 5) emitter → device id attribution
    func test_deviceID_mapping() {
        XCTAssertEqual(ScreenTimeEventUploader.deviceID(for: .parentApp, parentID: "P", childID: "C"), "P")
        XCTAssertEqual(ScreenTimeEventUploader.deviceID(for: .kidApp, parentID: "P", childID: "C"), "C")
        XCTAssertEqual(ScreenTimeEventUploader.deviceID(for: .kidExtension, parentID: "P", childID: "C"), "C")
        XCTAssertNil(ScreenTimeEventUploader.deviceID(for: .kidExtension, parentID: "P", childID: nil))
        XCTAssertNil(ScreenTimeEventUploader.deviceID(for: .backend, parentID: "P", childID: "C"))
    }

    // 6) grouping: kid + parent events split into per-device payloads; snake_case keys
    func test_groupedPayloads_groupsByEmitterAndBuildsPayload() {
        let kid = line(ts: "2026-07-01T20:55:00Z", emitter: .kidExtension)
        let parent = line(ts: "2026-07-01T20:56:00Z", emitter: .parentApp)
        let groups = ScreenTimeEventUploader.groupedPayloads(
            lines: [kid, parent], parentID: "P-ID", childID: "C-ID")
        XCTAssertEqual(Set(groups.keys), ["P-ID", "C-ID"])
        let payload = groups["C-ID"]![0]
        XCTAssertEqual(payload["emitter"] as? String, "kid_extension")
        XCTAssertEqual(payload["kind"] as? String, "lock")
        XCTAssertEqual(payload["source"] as? String, "earnedPool")
        XCTAssertEqual(payload["day_key"] as? String, "2026-07-01@America/New_York")
        XCTAssertEqual(payload["client_event_id"] as? String,
                       ScreenTimeEventUploader.clientEventID(deviceID: "C-ID", line: kid))
    }

    // 7) unattributable lines are skipped, not crashed on
    func test_groupedPayloads_skipsUnattributable() {
        let kid = line(ts: "T1", emitter: .kidExtension)
        let groups = ScreenTimeEventUploader.groupedPayloads(
            lines: [kid, "not json"], parentID: nil, childID: nil)
        XCTAssertTrue(groups.isEmpty)
    }

    // 8) request shape: path, header == body device_id
    func test_makeRequest_shape() throws {
        let req = try ScreenTimeEventUploader.makeRequest(
            baseURL: URL(string: "http://localhost:8000/api/v1")!,
            deviceID: "DEV-1",
            events: [["kind": "lock", "client_event_id": "line:x"]])
        XCTAssertEqual(req.url?.path, "/api/v1/device/screen-time/events")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Evlin-Device-ID"), "DEV-1")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(body["device_id"] as? String, "DEV-1")
        XCTAssertEqual((body["events"] as? [[String: Any]])?.count, 1)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS"
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Evlin iOSTests/ScreenTimeEventUploaderTests" test 2>&1 | tail -5
```
Expected: BUILD FAILED — `cannot find 'ScreenTimeEventUploader' in scope`.

- [ ] **Step 4: Write the uploader**

Create `Evlin iOS/Services/ScreenTimeEventUploader.swift` (File Inspector → Target Membership: **`Evlin iOS` only**; with Xcode 16 synchronized groups the file lands in the app target automatically — just verify the extension box is UNCHECKED):

```swift
import CryptoKit
import Foundation

/// A1 — batch-uploads the App-Group `ScreenTimeEvent` ring buffer to the
/// backend unified timeline (`POST /device/screen-time/events`), so the
/// cross-device P/K/backend chain is queryable server-side with SQL.
///
/// Design:
///   - Watermark = bare SHA-256 hex of the last successfully uploaded
///     ring-buffer line (`evlin.screentime.uploadedThroughHash`, App-Group
///     defaults) — device-independent, computed before attribution. Lines
///     after it are pending. If the watermark line rotated out of the capped
///     buffer, the whole buffer is re-sent — the backend dedupes on
///     client_event_id, so that is safe.
///   - client_event_id = "line:<deviceID>:<lineHash>" — embeds the uploading
///     device so byte-identical lines from two devices never dedupe each
///     other (review decision 2026-07-01).
///   - Events are attributed by emitter: parent_app → parent device id,
///     kid_app/kid_extension → child device id (a dev phone can hold both
///     identities; each group is its own POST). If NO identity is resolvable,
///     the watermark does NOT advance — identity-missing periods are exactly
///     what we need to diagnose, so those lines wait for identity to appear.
///   - Fire-and-forget: on any failure the watermark stays put and the next
///     foreground retries. Never throws, never blocks UI.
///   - DEBUG builds only: the body is compiled out for Release/TestFlight
///     (device-header self-attestation is debug-only trust).
///
/// Membership: `Evlin iOS` app target ONLY (the extension just writes the
/// ring buffer; uploading from the extension's tight budget is forbidden).
enum ScreenTimeEventUploader {

    static let watermarkKey = "evlin.screentime.uploadedThroughHash"
    static let disableKey = "evlin.screentime.uploadDisabled"
    static let batchLimit = 200

    // MARK: - Pure helpers (unit-tested)

    /// Bare SHA-256 hex of a ring-buffer line (watermark currency).
    static func lineHash(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Server dedupe id: embeds the uploading device so identical lines from
    /// different devices stay distinct rows. "line:" + 36 + ":" + 64 = 106 ≤ 128.
    static func clientEventID(deviceID: String, line: String) -> String {
        "line:\(deviceID):\(lineHash(line))"
    }

    /// Lines strictly after the watermark line; the whole buffer when the
    /// watermark is missing or rotated out (server-side dedupe makes that safe).
    static func pendingLines(all: [String], lastUploadedHash: String?) -> [String] {
        guard let h = lastUploadedHash, !h.isEmpty,
              let idx = all.lastIndex(where: { lineHash($0) == h })
        else { return all }
        return Array(all[(idx + 1)...])
    }

    /// The device id an event is attributed to (nil = unattributable, skip).
    static func deviceID(
        for emitter: ScreenTimeEvent.Emitter,
        parentID: String?,
        childID: String?
    ) -> String? {
        switch emitter {
        case .parentApp: return parentID
        case .kidApp, .kidExtension: return childID
        case .backend: return nil
        }
    }

    /// Decode + group pending lines into per-device upload payloads
    /// (backend `ScreenTimeEventIn` shape, snake_case keys). Undecodable or
    /// unattributable lines are skipped.
    static func groupedPayloads(
        lines: [String],
        parentID: String?,
        childID: String?
    ) -> [String: [[String: Any]]] {
        var groups: [String: [[String: Any]]] = [:]
        for l in lines {
            guard let e = ScreenTimeEvent.from(jsonLine: l),
                  let dev = deviceID(for: e.emitter, parentID: parentID, childID: childID)
            else { continue }
            var payload: [String: Any] = [
                "ts": e.ts,
                "emitter": e.emitter.rawValue,
                "kind": e.kind.rawValue,
                "client_event_id": clientEventID(deviceID: dev, line: l),
            ]
            payload["day_key"] = e.dayKey
            payload["source"] = e.source?.rawValue
            payload["app"] = e.app
            payload["reason"] = e.reason
            payload["policy_gen"] = e.policyGen
            payload["corr_id"] = e.corrID
            if let nums = e.nums,
               let data = try? JSONEncoder().encode(nums),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payload["nums"] = dict
            }
            if let tr = e.transition,
               let data = try? JSONEncoder().encode(tr),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payload["transition"] = dict
            }
            groups[dev, default: []].append(payload)
        }
        return groups
    }

    static func makeRequest(
        baseURL: URL,
        deviceID: String,
        events: [[String: Any]]
    ) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("device/screen-time/events"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceID, forHTTPHeaderField: "X-Evlin-Device-ID")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceID,
            "events": events,
        ])
        return req
    }

    // MARK: - Entry point (app foreground)

    /// Upload everything past the watermark. Safe to call often; no-ops fast.
    /// DEBUG builds only — Release compiles to a no-op (prod gate, review
    /// decision 2026-07-01; the backend endpoint is also off by default).
    static func uploadPending() async {
        #if DEBUG
        let std = UserDefaults.standard
        guard !std.bool(forKey: disableKey) else { return }
        guard let d = UserDefaults(suiteName: ScreenTimeEventLog.suiteName) else { return }

        let all = ScreenTimeEventLog.readLines(from: d)
        let pending = pendingLines(all: all, lastUploadedHash: d.string(forKey: watermarkKey))
        guard !pending.isEmpty else { return }
        guard let base = URL(string: APIClient.currentBaseURL) else { return }

        let groups = groupedPayloads(
            lines: pending,
            parentID: std.string(forKey: DeviceIdentity.parentKey),
            childID: std.string(forKey: DeviceIdentity.childKey)
        )
        guard !groups.isEmpty else {
            // No resolvable device identity: do NOT advance the watermark.
            // Identity-missing stretches are exactly what we need to diagnose —
            // the lines stay pending and upload once identity is restored.
            // (Ring-buffer cap + server dedupe keep the rescan cheap and safe.)
            return
        }

        var allOK = true
        for (dev, events) in groups {
            var start = 0
            while start < events.count {
                let chunk = Array(events[start..<min(start + batchLimit, events.count)])
                start += batchLimit
                guard let req = try? makeRequest(baseURL: base, deviceID: dev, events: chunk) else {
                    allOK = false
                    continue
                }
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200...299).contains(code) { allOK = false }
                } catch {
                    allOK = false
                }
            }
        }
        // Advance ONLY when every POST of the pending window succeeded.
        if allOK, let last = pending.last {
            d.set(lineHash(last), forKey: watermarkKey)
        }
        #endif
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `TEST SUCCEEDED`, all 9 tests pass.

- [ ] **Step 6: Trigger on app foreground**

In `Evlin iOS/Evlin_iOSApp.swift`, inside the `.onChange(of: scenePhase)` handler's `case .active:` branch (~line 96), append after the existing statements in that case:

```swift
                        Task { await ScreenTimeEventUploader.uploadPending() }
```

- [ ] **Step 7: Build the app target to verify the wiring compiles**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add "Evlin iOS/Services/ScreenTimeEventLog.swift" \
        "Evlin iOS/Services/ScreenTimeEventUploader.swift" \
        "Evlin iOS/Evlin_iOSApp.swift" \
        "Evlin iOSTests/ScreenTimeEventUploaderTests.swift"
git commit -m "feat(a1): ScreenTimeEventUploader — foreground batch upload to backend timeline"
```
(If Xcode changed `project.pbxproj` only to add the new files to targets, stage it too; never stage unrelated pbxproj churn.)

---

## Task 5: iOS — current-restrictions snapshot reads enforcement truth (B.1-A1)

**Files:**
- Modify: `Evlin iOS/Models/CommandModels.swift` (`AckEffectiveState`, ~line 137)
- Modify: `Evlin iOS/Services/CommandPoller.swift` (`globalEffectiveStateDictionary`, ~line 532)
- Test: `Evlin iOSTests/CommandPollerEffectiveStateTests.swift`

**Why:** `globalEffectiveStateDictionary()` currently reads `ActiveLockStore.shared.allCurrent()` — the **in-memory** copy we proved lags enforcement truth (device test 2026-07-01: truth had 2 earnedTime shields, in-memory had 0). The heartbeat/ack snapshot the backend stores in `Device.last_effective_state` was therefore wrong exactly when it mattered. Repoint it at the persisted App-Group records (`CurrentRestrictionsReader`) and include the block list, per spec Part B.1. Backend needs no change: `_normalize_effective_state_covers` (`child_device.py:2651`) passes unknown keys through (`{**state, ...}`).

**Interfaces:**
- Consumes: `CurrentRestrictionsReader.persistedShields(from:)` / `.persistedBlocks(from:)` / `.suiteName` (A0.5); `ShieldRecord`, `BlockRecord`.
- Produces: `AckEffectiveState` gains `let blocks: [BlockEntry]?` (`BlockEntry = {bundleID, displayName}`, optional for back-compat). `CommandPoller.globalEffectiveStateDictionary(defaults:) -> [String: Any]?` (sync, injectable); the existing `async` signature stays as a thin wrapper so heartbeat/ack call sites don't change.

- [ ] **Step 1: Write the failing test**

Create `Evlin iOSTests/CommandPollerEffectiveStateTests.swift`. The persisted shape `CurrentRestrictionsReader.decodeDict` expects is a JSON-encoded `[String: Record]` dictionary with `.iso8601` dates (`ShieldRecord` keyed by `recordKey`, `BlockRecord` by `bundleID`); both records are memberwise-constructible with empty token sets:

```swift
import XCTest
@testable import Evlin_iOS

final class CommandPollerEffectiveStateTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "test.effstate.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func makeShield() -> ShieldRecord {
        ShieldRecord(
            recordKey: "savedList:L1",
            tier: .savedList,
            targetKey: "L1",
            displayName: "Locked Set",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_780_000_000),
            expiresAt: nil,
            originalRequest: "test",
            targetChildID: UUID(),
            sources: [.earnedTime]
        )
    }

    private func makeBlock() -> BlockRecord {
        BlockRecord(
            bundleID: "com.game.x",
            displayName: "Game X",
            blockedAt: Date(timeIntervalSince1970: 1_780_000_000),
            lastCommandID: UUID(),
            originalRequest: "test",
            targetChildID: UUID()
        )
    }

    private func seed(shields: [ShieldRecord], blocks: [BlockRecord]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let shieldDict = Dictionary(uniqueKeysWithValues: shields.map { ($0.recordKey, $0) })
        let blockDict = Dictionary(uniqueKeysWithValues: blocks.map { ($0.bundleID, $0) })
        defaults.set(try! enc.encode(shieldDict), forKey: CurrentRestrictionsReader.shieldsKey)
        defaults.set(try! enc.encode(blockDict), forKey: CurrentRestrictionsReader.blocksKey)
    }

    // 1) snapshot reflects the PERSISTED records (enforcement truth)
    func test_snapshot_readsPersistedTruth() throws {
        seed(shields: [makeShield()], blocks: [makeBlock()])
        let dict = try XCTUnwrap(
            CommandPoller.globalEffectiveStateDictionary(defaults: defaults))
        XCTAssertEqual(dict["isBlocked"] as? Bool, true)
        let covers = try XCTUnwrap(dict["shieldsCovering"] as? [[String: Any]])
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(covers[0]["recordKey"] as? String, "savedList:L1")
        XCTAssertEqual((covers[0]["sources"] as? [String]), ["earnedTime"])
        let blocks = try XCTUnwrap(dict["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks[0]["bundleID"] as? String, "com.game.x")
        XCTAssertEqual(blocks[0]["displayName"] as? String, "Game X")
    }

    // 2) empty truth → empty snapshot (not nil)
    func test_snapshot_emptyTruth() throws {
        let dict = try XCTUnwrap(
            CommandPoller.globalEffectiveStateDictionary(defaults: defaults))
        XCTAssertEqual(dict["isBlocked"] as? Bool, false)
        XCTAssertEqual((dict["shieldsCovering"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((dict["blocks"] as? [[String: Any]])?.count, 0)
    }
}
```

Sanity note: `CurrentRestrictionsReader.decodeDict(_:key:from:)` decodes a `[String: T]` dictionary with an `.iso8601`-date `JSONDecoder` — if compilation shows the persisted encoding differs (e.g. `Data` vs string payload), match whatever `CurrentRestrictionsReader.persistedShields(from:)` actually reads; the reader, not this test, is the contract.

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Evlin iOSTests/CommandPollerEffectiveStateTests" test 2>&1 | tail -5
```
Expected: BUILD FAILED — no `globalEffectiveStateDictionary(defaults:)` overload / no `blocks` key.

- [ ] **Step 3: Add `blocks` to `AckEffectiveState`**

`AckEffectiveState` currently has NO explicit initializer — it relies on the implicit memberwise init, and there are 7 other construction sites (`ActionExecutor.swift:507,519,918,960`, `EffectiveStateWireTests.swift:143`, `ReceiptCopyTests.swift:22,51`). Adding a stored `let` without a default would break them all, so add the field **plus an explicit init with a defaulted `blocks:` parameter** (same back-compat pattern `ShieldCover` already uses).

In `Evlin iOS/Models/CommandModels.swift`, replace the three stored properties at the bottom of `AckEffectiveState` (~lines 164–166):

```swift
    let isBlocked: Bool
    let shieldsCovering: [ShieldCover]
    let possibleSavedListCoverage: Bool  // indeterminate — honest "May still be…" line
```

with:

```swift
    struct BlockEntry: Codable, Sendable, Equatable {
        let bundleID: String
        let displayName: String
    }

    let isBlocked: Bool
    let shieldsCovering: [ShieldCover]
    let possibleSavedListCoverage: Bool  // indeterminate — honest "May still be…" line
    /// Full per-app block list (B.1-A1). Optional for back-compat with old
    /// binaries whose payloads only carried `isBlocked`.
    let blocks: [BlockEntry]?

    // Explicit init with a defaulted `blocks:` so the 7 pre-B.1 construction
    // sites (ActionExecutor + tests) compile unchanged — same pattern as
    // ShieldCover's back-compat init above.
    init(
        isBlocked: Bool,
        shieldsCovering: [ShieldCover],
        possibleSavedListCoverage: Bool,
        blocks: [BlockEntry]? = nil
    ) {
        self.isBlocked = isBlocked
        self.shieldsCovering = shieldsCovering
        self.possibleSavedListCoverage = possibleSavedListCoverage
        self.blocks = blocks
    }
```

- [ ] **Step 4: Repoint the snapshot at enforcement truth**

In `Evlin iOS/Services/CommandPoller.swift`, replace the body of `static func globalEffectiveStateDictionary() async -> [String: Any]?` (~line 532) with a thin wrapper + a sync injectable implementation:

```swift
    /// Enforcement-truth snapshot: reads the PERSISTED App-Group shield/block
    /// records (what the extension actually wrote and iOS enforces) — NOT the
    /// in-memory ActiveLockStore copy, which lags when the extension locks
    /// while this app is suspended (proven divergence, 2026-07-01).
    static func globalEffectiveStateDictionary() async -> [String: Any]? {
        globalEffectiveStateDictionary(
            defaults: UserDefaults(suiteName: CurrentRestrictionsReader.suiteName))
    }

    static func globalEffectiveStateDictionary(defaults: UserDefaults?) -> [String: Any]? {
        guard let d = defaults else { return nil }
        let shields = CurrentRestrictionsReader.persistedShields(from: d)
        let blocks = CurrentRestrictionsReader.persistedBlocks(from: d)
        let covers = shields
            .sorted { lhs, rhs in
                if lhs.displayName == rhs.displayName {
                    return lhs.recordKey < rhs.recordKey
                }
                return lhs.displayName < rhs.displayName
            }
            .map {
                AckEffectiveState.ShieldCover(
                    displayName: $0.displayName,
                    expiresAtISO: $0.expiresAt.map { ISO8601DateFormatter().string(from: $0) },
                    tier: $0.tier.rawValue,
                    recordKey: $0.recordKey,
                    targetKey: $0.targetKey,
                    sources: $0.sources.map { $0.rawValue }.sorted()
                )
            }
        let snapshot = AckEffectiveState(
            isBlocked: !blocks.isEmpty,
            shieldsCovering: covers,
            possibleSavedListCoverage: false,
            blocks: blocks
                .sorted { $0.bundleID < $1.bundleID }
                .map { .init(bundleID: $0.bundleID, displayName: $0.displayName) }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
```

(Keep the argument order of `AckEffectiveState.init` matching its declaration; if other `AckEffectiveState(` call sites exist, they compile unchanged thanks to the defaulted `blocks:` parameter.)

- [ ] **Step 5: Run the new tests + the A0/Tier-1 suites (no regressions)**

```bash
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"Evlin iOSTests/CommandPollerEffectiveStateTests" \
  -only-testing:"Evlin iOSTests/CurrentRestrictionsReaderTests" \
  -only-testing:"Evlin iOSTests/DeviceIdentityTests" \
  -only-testing:"Evlin iOSTests/ScreenTimeEventUploaderTests" test 2>&1 | tail -5
```
Expected: `TEST SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add "Evlin iOS/Models/CommandModels.swift" \
        "Evlin iOS/Services/CommandPoller.swift" \
        "Evlin iOSTests/CommandPollerEffectiveStateTests.swift"
git commit -m "fix(b1-a1): heartbeat/ack snapshot reads App-Group enforcement truth + block list"
```

---

## End-to-end verification (manual, with the user)

1. Backend up: `colima start && cd Evlin-Backend && ./dev.sh` (migration applies on start).
2. Cmd+R the app onto the parent phone (Backend URL → `http://192.168.1.175:8000/api/v1`).
3. Trigger any screen-time event (or reuse the existing ring buffer), background → foreground the app.
4. **Claude-side query (the whole point of A1):**

```bash
docker exec evlin-pg psql -U ale_user -d ale_db -c \
 "SELECT to_char(ts, 'MM-DD HH24:MI:SS') t, emitter, kind, source, reason,
         nums->>'remaining' rem, day_key
  FROM evlin_screen_time_events ORDER BY ts DESC LIMIT 30;"
```

Expected: device-uploaded rows (`kid_extension`/`parent_app`) interleaved with `backend` rows on one timeline. 5. Check the snapshot: `SELECT last_effective_state FROM evlin_devices WHERE id='<kid-device-id>';` shows `shieldsCovering` + `blocks` matching the phone's debug screen "enforcement truth" section.
