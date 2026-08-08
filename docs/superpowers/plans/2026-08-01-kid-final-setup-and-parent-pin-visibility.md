# Kid final setup step + parent-visible PIN — implementation plan

> **Implementation status (2026-08-01):** The PIN portion of this plan was revised by
> product decision during implementation. FIX-K is now an independent security task,
> not a prerequisite for PIN visibility. The implemented beta contract uses the existing
> child UUID channel for a first write, permits only byte-identical idempotent replay,
> and protects later child-side clear with a per-device PIN lifecycle secret. Child
> endpoints never return the PIN; parent-authenticated APIs remain the only read and
> administrative-clear surface. This note supersedes the older FIX-K prerequisite and
> `ParentPINUploader` sketches below; do not execute those sections verbatim.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the kid's terminal "All set!" text page with a functional final step that captures the screen-time tracking selection and creates the Parent PIN, then make that PIN readable by the parent on their own phone.

**Architecture:** Task 1 is a standalone backend contract fix (an independent pool-birth bug) and lands on its own. Tasks 2–4 add recoverable PIN storage behind the existing backend patterns. Tasks 5–11 build the iOS side bottom-up: pure logic first (recovery, upload payload), then the reused components, then the screen, then the parent view.

**Tech Stack:** Swift/SwiftUI (iOS 17+, `@Observable`-free — this codebase uses `@State`/`@AppStorage`), FamilyControls, CryptoKit; FastAPI + SQLAlchemy 2.0 async + Alembic; pytest-asyncio; XCTest.

## Global Constraints

- **PIN/FIX-K boundary:** FIX-K remains required before broad child-endpoint hardening,
  but it is no longer a prerequisite for this beta PIN feature. The accepted temporary
  risk is overwrite/denial-of-service before the legitimate first write; PIN disclosure
  and device unlock are not possible through this channel. The lifecycle secret closes
  repeated clear-and-overwrite after the legitimate device wins the first write.
- **Execution mode:** inline, one task at a time, one commit per task, a checkpoint for review after every task. Do not batch tasks.
- Backend tests run single-process: `pytest ... -p no:randomly`, one pytest at a time, `EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test`. Never point tests at `ale_db`.
- Never set the system clock. Dates come from `screen_time_clock`, never `date.today()`.
- Copy is sentence case, no emoji. The PIN is always described as "4–8 digits", never "4-digit".
- The PIN is a local edit gate, not a credential. It must never be returned by a child-authed endpoint and never reused for authentication.
- `EarnedTimeStore.saveMeasurementSelection` serialization and persistence semantics are
  **unchanged** by this plan. Task 8 extracts that capture model and replaces only the
  already-dead v1 arming handoff with the existing v2 policy-refresh trigger.
- **Pool-preservation boundary:** this plan must not change metering math, epoch/handoff
  transitions, DAM schedules/events, callback validation, sample acceptance, app-limit
  accounting, or shield convergence. The following production files are protected:
  `DeviceEpochStore.swift`, `EarnedMeteringRecoveryDriver.swift`,
  `MeteringProductionComposition.swift`, `EarnedBudgetArming.swift`,
  `EarnedBudgetScheduler.swift`, and `DeviceActivityMonitorExtension.swift`.
  There are exactly two narrow exceptions: (1) Task 6 may add only
  `ParentPINUploader.clear()` at the already-named `EarnedBudgetArming.swift` identity
  teardown site; (2) Task 8 Step 3b may make
  `MeteringProductionComposition.recoverFromSharedConfiguration` return the documented
  outcome enum and atomically compare its one configuration snapshot with optional
  expected owner/backend inputs. No ordering, state mutation, driver construction or
  recovery logic may change. If any
  other change to these files appears necessary, stop and
  split it into a separately reviewed metering task; do not hide it in this feature.
- **One coordinator only:** onboarding may invoke
  `MeteringProductionComposition.recoverFromSharedConfiguration`; it may not create a new
  scheduler, recovery driver, retry flag, activity name, epoch, route, or direct
  `DeviceActivityCenter.startMonitoring` call. It is a trigger into the existing v2
  coordinator, not a fourth coordinator.
- **Exact diff guard:** after the metering tree is frozen and committed, record the blob
  hashes of the protected files above. Recheck them after every task and before final
  acceptance. Any unexpected hash change is a hard stop, even if tests are green. Task 6
  may refresh only the `EarnedBudgetArming.swift` baseline after proving the exact
  one-call diff. Task 8 may refresh only the `MeteringProductionComposition.swift`
  baseline after proving the exact outcome-only diff described above.
- **Named metering regression gate:** capture the exact failing-test-name baseline before
  Task 1. After Task 1, Task 8, Task 9, and Task 11, rerun the named backend pool suites
  from Task 1 plus these iOS suites in one `xcodebuild` invocation:
  `EarnedBudgetArmingTests`, `EarnedBudgetSchedulerTests`,
  `MeteringProductionIntegrationTests`, `MeteringIdentityCleanupTests`,
  `MeteringV2ActivationTests`, `MeteringEpochDeliveryTests`,
  `MeteringRolloverRecoveryTests`, `AppLimitMeasurementTests`, and
  `AppLimitProductionReorderingTests`. Compare failure-name sets, not totals: no new
  failure is allowed, and any newly green baseline failure is removed from the baseline.
- The v2-only backend fixture debt was resolved before Task 1. On 2026-08-01 the full
  `tests/test_metering*.py` DB regression completed with **274 passed, 0 failed**, and
  the six-suite pool/receipt/registration/sample/reconciler/concurrency gate completed
  with **130 passed, 0 failed**. Historical V30 executable migration tests were removed;
  their pure JSON vectors remain as protocol-history evidence. Preserve these readable
  baselines rather than reintroducing protocol-1 database fixtures.
- Do not commit unless the task's step says to. Never push.

---

### Task 1: `child-all-set` stops reporting success it didn't achieve

Standalone commit. This is an independent pool-birth defect: the endpoint flips `child_onboarding_complete` and commits *before* provisioning the default pool, swallows provisioning errors, and returns `{"ok": true}` regardless. A device can finish onboarding with no pool and no way to notice.

**Files:**
- Modify: `../Evlin-Backend/app/api/routes/family.py:860-892` (`child_all_set`), `:894-906` (`_auto_provision_default_pool` early return), `:956` (the helper's internal `commit`)
- Test: `../Evlin-Backend/tests/test_default_pool_provisioning.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `POST /family/onboarding/child-all-set` returns `{"all_set": true, "default_pool_ready": true}` on success, non-2xx on any failure. Task 9 consumes this shape via `APIClient.markChildAllSet`.

- [x] **Step 1: Write the failing tests**

Append to `../Evlin-Backend/tests/test_default_pool_provisioning.py` inside `class TestDefaultPoolProvisioning`:

```python
    async def test_success_response_reports_pool_ready(self, client, session):
        fam, profile, device = await _setup_family(session)
        await session.commit()

        resp = await client.post(
            "/family/onboarding/child-all-set",
            json={"child_device_id": str(device.id)},
        )
        assert resp.status_code == 200
        assert resp.json() == {"all_set": True, "default_pool_ready": True}

    async def test_provisioning_failure_does_not_mark_onboarding_complete(
        self, client, session, monkeypatch
    ):
        """The flag is the parent's release signal AND the device's 'stop asking'
        signal. Setting it when the pool is missing strands the kid with no pool
        and no retry."""
        fam, profile, device = await _setup_family(session)
        await session.commit()

        import app.api.routes.family as family_routes

        async def boom(*args, **kwargs):
            raise RuntimeError("pool provisioning exploded")

        monkeypatch.setattr(family_routes, "_auto_provision_default_pool", boom)

        resp = await client.post(
            "/family/onboarding/child-all-set",
            json={"child_device_id": str(device.id)},
        )
        assert resp.status_code == 503

        await session.refresh(device)
        assert device.child_onboarding_complete is False

    async def test_retry_after_failure_reuses_existing_pool_and_sets_flag(
        self, client, session
    ):
        """Convergence: a device that already has a pool (from a partially
        succeeded earlier attempt) must complete on retry, not double-provision."""
        fam, profile, device = await _setup_family(session)
        await _make_config(
            session, family_id=fam.id, child_profile_id=profile.id, pool_minutes=90
        )
        await session.commit()

        resp = await client.post(
            "/family/onboarding/child-all-set",
            json={"child_device_id": str(device.id)},
        )
        assert resp.status_code == 200
        assert resp.json() == {"all_set": True, "default_pool_ready": True}

        configs = await _active_configs(
            session, family_id=fam.id, child_profile_id=profile.id
        )
        assert len(configs) == 1
        assert configs[0].daily_pool_minutes == 90

        await session.refresh(device)
        assert device.child_onboarding_complete is True

    async def test_device_without_child_profile_is_a_failure_not_a_noop(
        self, client, session
    ):
        """A device with no profile can never earn time. Reporting it as fully
        set up is the same lie as a swallowed provisioning error."""
        fam, profile, device = await _setup_family(session)
        device.child_profile_id = None
        await session.commit()

        resp = await client.post(
            "/family/onboarding/child-all-set",
            json={"child_device_id": str(device.id)},
        )
        assert resp.status_code == 409

        await session.refresh(device)
        assert device.child_onboarding_complete is False
```

Then fix the two existing assertions that pin the old response shape — in
`test_onboarding_complete_with_no_config_creates_default_pool` replace
`assert resp.json() == {"ok": True}` with
`assert resp.json() == {"all_set": True, "default_pool_ready": True}`.
`test_onboarding_complete_with_existing_config_untouched` only asserts
`resp.status_code == 200`; leave it.

- [x] **Step 2: Run tests to verify they fail**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test .venv/bin/python -m pytest tests/test_default_pool_provisioning.py -p no:randomly -q
```

Expected: 4 new tests FAIL (the response-shape ones on `KeyError`/assertion, the failure ones because the flag is already committed and the endpoint returns 200), plus 1 pre-existing test failing on the changed shape.

- [x] **Step 3: Rewrite the endpoint body**

In `../Evlin-Backend/app/api/routes/family.py`, replace the body of `child_all_set` from `child.child_onboarding_complete = True` through `return {"ok": True}` with:

```python
    # Order is load-bearing. Flipping the completion flag first is what made a
    # later pool failure invisible AND unrecoverable: the parent's waiting
    # screen releases, and the device never asks again because it already
    # "succeeded". Provision (or confirm) the pool first, and only then record
    # completion — in one transaction, so a failure leaves nothing half-done.
    try:
        await _auto_provision_default_pool(
            session, child=child, background_tasks=background_tasks
        )
    except _MissingChildProfile:
        raise HTTPException(409, "child_profile_required")
    except Exception:
        logger.exception(
            "auto-provision default pool failed for child_device_id={}",
            req.child_device_id,
        )
        raise HTTPException(503, "default_pool_unavailable")

    child.child_onboarding_complete = True
    await session.commit()
    return {"all_set": True, "default_pool_ready": True}
```

Delete the now-dangling `child.child_onboarding_complete = True` / `await session.commit()` pair that preceded the old `try` block, so the flag is written exactly once.

- [x] **Step 4: Make the missing-profile path raise instead of no-op**

Above `_auto_provision_default_pool` in the same file, add:

```python
class _MissingChildProfile(Exception):
    """A child device with no profile can never earn time; `child-all-set`
    turns this into a 409 rather than reporting a device as fully set up."""
```

In `_auto_provision_default_pool`, replace the `if child.child_profile_id is None:` early-return block with:

```python
    if child.child_profile_id is None:
        logger.info(
            "auto-provision default pool: child_device_id={} has no child_profile_id",
            child.id,
        )
        raise _MissingChildProfile
```

Then delete the `await session.commit()` at the end of `_auto_provision_default_pool`
(`family.py:956`, after the `screen_time_event_service.emit(...)` call). With it in
place the pool and its timeline event are already durable before the caller decides
anything, so "pool first, then the flag" would still be two transactions and a crash
between them would leave the same silent split. The endpoint now owns the single commit.

**This changes an existing concurrency test's expected value, and the new value is the
invariant we want.** `test_concurrent_parent_config_wins_over_default_provisioning`
records `(child.child_onboarding_complete, db.in_transaction())` on entry to
provisioning (`:223-225`) and asserts `onboarding_state == [(True, False)]` (`:300`) —
that is, "flag already set, already committed", the exact split being fixed. Update it:

```python
        # Was [(True, False)]: the flag was set and committed BEFORE the pool
        # was provisioned, which is what let a provisioning failure vanish.
        # Provisioning now runs first, inside the endpoint's single open
        # transaction, so the flag is still false and the session still open.
        assert onboarding_state == [(False, True)]
```

Holding the profile advisory lock for the whole endpoint rather than releasing it at the
helper's commit also lengthens the window a concurrent parent write contends with. That
is intended — atomicity is the point — but it is a real behaviour change to lock
ordering, so Step 6 runs the wider regression rather than this file alone.

- [x] **Step 5: Prove the two writes land or fail together**

Append to `../Evlin-Backend/tests/test_default_pool_provisioning.py`:

```python
    async def test_flag_failure_rolls_back_the_pool_too(
        self, client, session, monkeypatch
    ):
        """One transaction, or the split we just fixed comes back in the other
        direction: a pool that exists while the device is still 'incomplete'."""
        fam, profile, device = await _setup_family(session)
        await session.commit()

        import app.api.routes.family as family_routes

        original = family_routes.child_all_set.__wrapped__ if hasattr(
            family_routes.child_all_set, "__wrapped__"
        ) else None
        _ = original  # documented no-op: we patch the commit, not the handler

        real_commit = type(session).commit
        calls = {"n": 0}

        async def failing_commit(self):
            calls["n"] += 1
            raise RuntimeError("commit exploded")

        monkeypatch.setattr(type(session), "commit", failing_commit)
        try:
            resp = await client.post(
                "/family/onboarding/child-all-set",
                json={"child_device_id": str(device.id)},
            )
        finally:
            monkeypatch.setattr(type(session), "commit", real_commit)

        assert resp.status_code >= 500
        await session.rollback()

        configs = await _active_configs(
            session, family_id=fam.id, child_profile_id=profile.id
        )
        assert configs == []
        await session.refresh(device)
        assert device.child_onboarding_complete is False
```

- [x] **Step 6: Run the wider regression, not just this file**

The commit boundary moved and the profile advisory lock is now held for the whole
endpoint, so receipts, registration, samples, the day reconciler and lock concurrency are
all in scope. Run them **named and in one process** — a `-k` keyword filter silently
selects whatever happens to match, and "about 54 known failures" is a number, not a
gate:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test .venv/bin/python -m pytest \
  tests/test_default_pool_provisioning.py \
  tests/test_earned_time_lock_receipts.py \
  tests/test_metering_epoch_registration.py \
  tests/test_metering_epoch_sample_adapter.py \
  tests/test_metering_day_reconciler.py \
  tests/test_earned_time_profile_lock_concurrency.py \
  -p no:randomly -q
```

`test_earned_time_profile_lock_concurrency.py` is the one that matters most: it exercises
exactly the lock the endpoint now holds longer.

**Readable baseline established 2026-08-01:** the exact six-suite command above completed
with **130 passed, 0 failed**. The wider single-process command
`scripts/run_limits_db_regression.py tests/test_metering*.py` completed with
**274 passed, 0 failed**. The former protocol-1 fixture debt (at least 109 failures) has
been removed rather than baselined. Capture the exact command again immediately before
Task 1 and require zero failures; compare names as well as totals.

- [x] **Step 7: Commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git add app/api/routes/family.py tests/test_default_pool_provisioning.py && git commit -m "fix(onboarding): don't report all-set when the default pool wasn't created"
```

---

### Task 2: `Device.parent_pin` + `parent_pin_status` columns

**Files:**
- Modify: `../Evlin-Backend/app/db/models/device.py`
- Create: `../Evlin-Backend/alembic/versions/2026_08_01_device_parent_pin.py`

**Interfaces:**
- Produces: `Device.parent_pin: str | None`, `Device.parent_pin_status: ParentPINStatus` (default `not_set`), and `class ParentPINStatus(str, enum.Enum)` with members `not_set`, `pending_sync`, `available`, `unrecoverable`. Tasks 3, 4 and the lifecycle step consume these.

- [x] **Step 1: Add the enum and columns**

In `../Evlin-Backend/app/db/models/device.py`, next to `class DeviceMode`:

```python
class ParentPINStatus(str, enum.Enum):
    """A nullable value alone cannot distinguish "never set" from "set on the
    device but not uploaded yet" from "hash could not be recovered". The parent
    UI renders off this, never off value presence."""
    not_set = "not_set"
    pending_sync = "pending_sync"
    available = "available"
    unrecoverable = "unrecoverable"
```

Inside `class Device`, after the `apns_token` column:

```python
    parent_pin: Mapped[Optional[str]] = mapped_column(String(8), nullable=True)
    parent_pin_status: Mapped[ParentPINStatus] = mapped_column(
        SAEnum(ParentPINStatus, name="parent_pin_status"),
        nullable=False,
        default=ParentPINStatus.not_set,
        server_default=ParentPINStatus.not_set.value,
    )
```

Add `Enum as SAEnum` to the existing `from sqlalchemy import ...` line if it is not already imported.

- [x] **Step 2: Find the current migration head**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && .venv/bin/alembic heads
```

Expected: exactly one head. Use that revision id as `down_revision` in the next step. If two heads print, stop and write a merge revision first — `alembic upgrade head` fails with multiple heads.

- [x] **Step 3: Write the migration**

Create `../Evlin-Backend/alembic/versions/2026_08_01_device_parent_pin.py`:

```python
"""store the parent PIN and its sync status on the device row

Revision ID: 2026_08_01_device_parent_pin
Revises: <paste the head printed in Step 2>
Create Date: 2026-08-01
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "2026_08_01_device_parent_pin"
down_revision: Union[str, Sequence[str], None] = "<paste the head printed in Step 2>"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_STATUS = sa.Enum(
    "not_set", "pending_sync", "available", "unrecoverable",
    name="parent_pin_status",
)


def upgrade() -> None:
    _STATUS.create(op.get_bind(), checkfirst=True)
    op.add_column("evlin_devices", sa.Column("parent_pin", sa.String(length=8), nullable=True))
    op.add_column(
        "evlin_devices",
        sa.Column("parent_pin_status", _STATUS, nullable=False, server_default="not_set"),
    )
    # Existing rows genuinely have no uploaded PIN. `not_set` is the honest
    # value; the kid device corrects it to pending_sync/available/unrecoverable
    # once the recovery migration runs.


def downgrade() -> None:
    op.drop_column("evlin_devices", "parent_pin_status")
    op.drop_column("evlin_devices", "parent_pin")
    _STATUS.drop(op.get_bind(), checkfirst=True)
```

- [x] **Step 4: Verify the migration applies and reverses**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test .venv/bin/python -m pytest tests/test_default_pool_provisioning.py -p no:randomly -q
```

Expected: PASS (the test harness builds the schema from metadata, so this proves the model change is coherent).

- [ ] **Step 5: Commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git add app/db/models/device.py alembic/versions/2026_08_01_device_parent_pin.py && git commit -m "feat(pin): add parent_pin and parent_pin_status to the device row"
```

---

### Task 3: `PUT /child/device/parent-pin` (built on FIX-K, not merely sequenced after it)

**Blocked by FIX-K (#68) — hard, not advisory.** A recoverable PIN must never travel over
a surface where the caller names its own device. Sequencing this task after FIX-K but
still deriving identity from `child_device_id` in the body would ship the exact hole
FIX-K exists to close: anyone holding a device UUID could overwrite that device's PIN, or
read whether one exists. Do not start this task until FIX-K has landed and provides the
dependency below.

**Prerequisite contract (from FIX-K):** an authenticated dependency that resolves the
calling child device from a verified credential and raises 401 when it is missing,
malformed, or unknown:

```python
async def get_current_child_device(...) -> Device
```

Use FIX-K's actual name, module, and header format if they differ from this sketch — the
non-negotiable part is that **the device identity comes from the verified credential and
from nothing the caller can assert**. If FIX-K did not ship such a dependency, stop and
raise it rather than falling back to a body/header UUID.

**Files:**
- Modify: `../Evlin-Backend/app/api/routes/bigkid_child.py`
- Test: `../Evlin-Backend/tests/api/test_child_parent_pin.py` (create)

**Interfaces:**
- Consumes: `Device.parent_pin`, `Device.parent_pin_status`, `ParentPINStatus` (Task 2); `get_current_child_device` (FIX-K).
- Produces: `PUT /child/device/parent-pin` accepting `{pin, status}` — **no device id in the body** — → `{"parent_pin_status": "<status>"}`; `GET /child/device/parent-pin-status` with **no query parameters** → `{"parent_pin_status": "<status>"}` (status only, never the value).

- [ ] **Step 1: Write the failing tests**

Create `../Evlin-Backend/tests/api/test_child_parent_pin.py`:

```python
"""The PIN is a local edit gate the parent set on the kid's phone. This surface
stores it so the parent can read it back on their own phone — and must never
hand it back to the child surface it arrived on, nor let one device write
another's."""
import pytest

from app.db.models.device import ParentPINStatus

pytestmark = pytest.mark.asyncio


async def test_upload_stores_value_and_marks_available(
    client, session, device_a, creds_a
):
    resp = await client.put(
        "/child/device/parent-pin",
        json={"pin": "48267", "status": "available"},
        headers=creds_a,
    )
    assert resp.status_code == 200
    assert resp.json() == {"parent_pin_status": "available"}

    await session.refresh(device_a)
    assert device_a.parent_pin == "48267"
    assert device_a.parent_pin_status == ParentPINStatus.available


async def test_upload_is_idempotent(client, session, device_a, creds_a):
    body = {"pin": "1234", "status": "available"}
    first = await client.put("/child/device/parent-pin", json=body, headers=creds_a)
    second = await client.put("/child/device/parent-pin", json=body, headers=creds_a)
    assert first.status_code == 200
    assert second.status_code == 200

    await session.refresh(device_a)
    assert device_a.parent_pin == "1234"


@pytest.mark.parametrize("bad", ["123", "123456789", "12a4", "", "  12"])
async def test_non_digit_or_wrong_length_is_422(client, creds_a, bad):
    """String(8) bounds the column, not the format."""
    resp = await client.put(
        "/child/device/parent-pin",
        json={"pin": bad, "status": "available"},
        headers=creds_a,
    )
    assert resp.status_code == 422


async def test_unrecoverable_status_accepts_no_value(
    client, session, device_a, creds_a
):
    resp = await client.put(
        "/child/device/parent-pin",
        json={"pin": None, "status": "unrecoverable"},
        headers=creds_a,
    )
    assert resp.status_code == 200

    await session.refresh(device_a)
    assert device_a.parent_pin is None
    assert device_a.parent_pin_status == ParentPINStatus.unrecoverable


async def test_available_without_a_value_is_rejected(client, creds_a):
    resp = await client.put(
        "/child/device/parent-pin",
        json={"pin": None, "status": "available"},
        headers=creds_a,
    )
    assert resp.status_code == 422


async def test_status_read_never_returns_the_value(
    client, session, device_a, creds_a
):
    device_a.parent_pin = "4826"
    device_a.parent_pin_status = ParentPINStatus.available
    await session.commit()

    resp = await client.get("/child/device/parent-pin-status", headers=creds_a)
    assert resp.status_code == 200
    assert resp.json() == {"parent_pin_status": "available"}
    assert "4826" not in resp.text


async def test_missing_credential_is_401(client):
    resp = await client.put(
        "/child/device/parent-pin", json={"pin": "1234", "status": "available"}
    )
    assert resp.status_code == 401


async def test_invalid_credential_is_401(client, bad_creds):
    resp = await client.put(
        "/child/device/parent-pin",
        json={"pin": "1234", "status": "available"},
        headers=bad_creds,
    )
    assert resp.status_code == 401


async def test_a_device_cannot_write_another_devices_pin(
    client, session, device_a, device_b, creds_a
):
    """The whole reason this task waits for FIX-K. With identity taken from the
    body, holding any device UUID was enough to overwrite that device's PIN."""
    await client.put(
        "/child/device/parent-pin",
        json={"pin": "1111", "status": "available"},
        headers=creds_a,
    )

    await session.refresh(device_a)
    await session.refresh(device_b)
    assert device_a.parent_pin == "1111"
    assert device_b.parent_pin is None
    assert device_b.parent_pin_status == ParentPINStatus.not_set


async def test_status_read_is_scoped_to_the_calling_device(
    client, session, device_a, device_b, creds_b
):
    device_a.parent_pin = "4826"
    device_a.parent_pin_status = ParentPINStatus.available
    await session.commit()

    resp = await client.get("/child/device/parent-pin-status", headers=creds_b)
    assert resp.status_code == 200
    assert resp.json() == {"parent_pin_status": "not_set"}
```

Add the fixtures to the same file. `_credential_headers` wraps whatever header format
FIX-K defined — write it once here so the tests above stay format-agnostic:

```python
import pytest_asyncio

from tests.test_default_pool_provisioning import _setup_family


def _credential_headers(device):
    """Build the authenticated child-device headers FIX-K expects. Adjust the
    header name/format to match FIX-K; every test above goes through here."""
    from app.api.deps.child_auth import child_credential_headers_for_test

    return child_credential_headers_for_test(device)


@pytest_asyncio.fixture
async def device_a(session):
    _fam, _profile, device = await _setup_family(session)
    await session.commit()
    return device


@pytest_asyncio.fixture
async def device_b(session):
    _fam, _profile, device = await _setup_family(session)
    await session.commit()
    return device


@pytest_asyncio.fixture
def creds_a(device_a):
    return _credential_headers(device_a)


@pytest_asyncio.fixture
def creds_b(device_b):
    return _credential_headers(device_b)


@pytest_asyncio.fixture
def bad_creds():
    return {"Authorization": "x-child-id-v1 not-a-real-credential"}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test .venv/bin/python -m pytest tests/api/test_child_parent_pin.py -p no:randomly -q
```

Expected: all FAIL with 404 (routes do not exist).

- [ ] **Step 3: Implement the routes**

Append to `../Evlin-Backend/app/api/routes/bigkid_child.py`:

```python
class ParentPINUploadRequest(BaseModel):
    # NO device id. Identity comes from the verified credential — a caller that
    # can name its own device can overwrite any device's PIN.
    #
    # `String(8)` bounds the column; this bounds the format. Without it a
    # non-numeric or over-long PIN reaches the DB and fails as a 500.
    pin: str | None = Field(default=None, pattern=r"^[0-9]{4,8}$")
    status: ParentPINStatus

    @model_validator(mode="after")
    def _value_matches_status(self) -> "ParentPINUploadRequest":
        if self.status == ParentPINStatus.available and not self.pin:
            raise ValueError("status=available requires a pin")
        if self.status != ParentPINStatus.available and self.pin:
            raise ValueError("only status=available may carry a pin")
        return self


@router.put("/child/device/parent-pin", summary="Kid device uploads the parent PIN")
async def put_parent_pin(
    req: ParentPINUploadRequest,
    device: Device = Depends(get_current_child_device),
    session: AsyncSession = Depends(get_async_session),
) -> dict:
    device.parent_pin = req.pin
    device.parent_pin_status = req.status
    await session.commit()
    return {"parent_pin_status": device.parent_pin_status.value}


@router.get(
    "/child/device/parent-pin-status",
    summary="Kid device asks whether the backend already holds its PIN",
)
async def get_parent_pin_status(
    device: Device = Depends(get_current_child_device),
) -> dict:
    """Status only, scoped to the calling device. The kid device needs this to
    decide whether the one-time recovery sweep should run; it must never be
    able to read a value back, its own or anyone's."""
    return {"parent_pin_status": device.parent_pin_status.value}
```

Add `ParentPINStatus` to the existing `from app.db.models.device import Device` line, import `get_current_child_device` from wherever FIX-K put it, and ensure `Field` and `model_validator` are imported from `pydantic`. Note there is no `family_device_exists` call and no 404 path: an unknown or unpaired device fails at the credential dependency as a 401, before this code runs.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test .venv/bin/python -m pytest tests/api/test_child_parent_pin.py -p no:randomly -q
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git add app/api/routes/bigkid_child.py tests/api/test_child_parent_pin.py && git commit -m "feat(pin): kid device uploads the parent PIN, child surface reads status only"
```

---

### Task 4: Parent read path + lifecycle clearing

**Files:**
- Modify: `../Evlin-Backend/app/schemas/profile.py:32-45` (`EnrolledDeviceDTO`), `../Evlin-Backend/app/api/routes/profile.py:89-95` (`_enrolled_device_dto`), `:416-418` (device removal)
- Test: `../Evlin-Backend/tests/api/test_profile_endpoints.py`

**Interfaces:**
- Consumes: `Device.parent_pin`, `Device.parent_pin_status` (Task 2).
- Produces: `EnrolledDeviceDTO.parent_pin: str | None` and `EnrolledDeviceDTO.parent_pin_status: str`. Task 11 renders off `parent_pin_status`.

- [ ] **Step 1: Write the failing tests**

Append to `../Evlin-Backend/tests/api/test_profile_endpoints.py`, reusing that file's
existing `_seed_family` and `_auth_overrides` helpers (the same setup its current unpair
test at `:300` uses):

```python
async def test_unpair_clears_the_parent_pin(client, session):
    """Device removal is a soft delete — the row survives with `unpaired_at`
    set. Without explicit clearing, a stale PIN outlives the pairing it
    belonged to and would show on a parent's device list forever."""
    from app.db.models.device import ParentPINStatus

    acc, family = await _seed_family(session)
    child = ChildProfile(
        family_id=family.id,
        display_name="PIN Kid",
        avatar_kind="emoji",
        avatar_value="🧒",
        avatar_color="#2E7D32",
    )
    session.add(child)
    await session.flush()
    device = Device(
        family_id=family.id,
        mode=DeviceMode.child,
        label="Kid iPhone",
        child_profile_id=child.id,
        parent_pin="4826",
        parent_pin_status=ParentPINStatus.available,
    )
    session.add(device)
    await session.flush()
    _auth_overrides(app, acc, family)

    removed = await client.delete(f"/family/children/{child.id}/devices/{device.id}")
    assert removed.status_code == 200, removed.text

    await session.refresh(device)
    assert device.parent_pin is None
    assert device.parent_pin_status == ParentPINStatus.not_set
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test .venv/bin/python -m pytest tests/api/test_profile_endpoints.py::test_unpair_clears_the_parent_pin -p no:randomly -q
```

Expected: FAIL — the PIN survives removal.

- [ ] **Step 3: Expose the fields and clear them on unpair**

In `../Evlin-Backend/app/schemas/profile.py`, inside `EnrolledDeviceDTO`:

```python
    parent_pin_status: str = "not_set"
    # Parent-authed reads only. The child surface returns status alone.
    parent_pin: str | None = None
```

In `../Evlin-Backend/app/api/routes/profile.py`, in the `EnrolledDeviceDTO(...)` construction, add:

```python
        parent_pin_status=d.parent_pin_status.value, parent_pin=d.parent_pin,
```

In the same file, in `remove_child_device`, next to `device.apns_token = None`:

```python
    device.parent_pin = None
    device.parent_pin_status = ParentPINStatus.not_set
```

Import `ParentPINStatus` alongside the existing `Device, DeviceMode` import.

- [ ] **Step 4: Clear on cross-family re-pair**

In `../Evlin-Backend/app/api/routes/family_v2.py`, in the join-commit `restore` branch where the existing device row is refreshed (the block that sets `device.label`, `device.platform`, `device.os_version`), add:

```python
    # A device re-pairing into a different family must not carry the previous
    # family's PIN. The identitySwitch branch already re-homes the row; the PIN
    # has to be re-established by the new parent.
    if device.family_id != invite.family_id:
        device.parent_pin = None
        device.parent_pin_status = ParentPINStatus.not_set
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && EVLIN_TEST_DATABASE_URL=postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test .venv/bin/python -m pytest tests/api/test_profile_endpoints.py tests/api/test_family_v2_flow.py -p no:randomly -q
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && git add app/schemas/profile.py app/api/routes/profile.py app/api/routes/family_v2.py tests/api/test_profile_endpoints.py && git commit -m "feat(pin): expose the PIN to the parent read path and clear it when pairing ends"
```

---

### Task 5: PIN recovery from the stored hash

Pure logic, no UI. `EvlinPINStore` keeps only `salt || sha256(salt || pin)`, so an already-set PIN has to be recovered by exhaustive search over its own small keyspace before it can ever be uploaded.

**Files:**
- Modify: `Evlin iOS/Services/EvlinPINStore.swift`
- Create: `Evlin iOS/Services/ParentPINRecovery.swift`
- Test: `Evlin iOSTests/ParentPINRecoveryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `EvlinPINStore.recoveryMaterial() -> (salt: Data, digest: Data)?` (Release-available; the existing `debugStoredBlob()` is `#if DEBUG`).
  - `struct ParentPINRecovery` with `struct Cursor: Codable, Equatable { var length: Int; var next: Int }`, `enum Outcome: Equatable { case found(String); case exhausted; case budgetSpent(Cursor) }`, and
    `static func sweep(salt: Data, digest: Data, from: Cursor, budget: Int, maxLength: Int) -> Outcome`.
  - `static let startCursor = Cursor(length: 4, next: 0)` and `static let autoMaxLength = 6`.

- [ ] **Step 1: Write the failing tests**

Create `Evlin iOSTests/ParentPINRecoveryTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class ParentPINRecoveryTests: XCTestCase {

    private func material(for pin: String) -> (salt: Data, digest: Data) {
        let store = EvlinPINStore(account: "evlin.test.\(UUID().uuidString)")
        try! store.setPIN(pin)
        return store.recoveryMaterial()!
    }

    func testFindsAFourDigitPIN() {
        let m = material(for: "4826")
        let outcome = ParentPINRecovery.sweep(
            salt: m.salt, digest: m.digest,
            from: ParentPINRecovery.startCursor, budget: 100_000, maxLength: 6
        )
        XCTAssertEqual(outcome, .found("4826"))
    }

    func testFindsAFiveDigitPIN() {
        let m = material(for: "48267")
        let outcome = ParentPINRecovery.sweep(
            salt: m.salt, digest: m.digest,
            from: ParentPINRecovery.startCursor, budget: 200_000, maxLength: 6
        )
        XCTAssertEqual(outcome, .found("48267"))
    }

    func testLeadingZeroPINIsNotLost() {
        // "0042" and 42 are different PINs. An integer-formatted sweep that
        // drops leading zeros silently fails to find a third of real PINs.
        let m = material(for: "0042")
        let outcome = ParentPINRecovery.sweep(
            salt: m.salt, digest: m.digest,
            from: ParentPINRecovery.startCursor, budget: 100_000, maxLength: 6
        )
        XCTAssertEqual(outcome, .found("0042"))
    }

    func testCorruptedDigestExhaustsRatherThanMatching() {
        var m = material(for: "1234")
        m.digest[0] = m.digest[0] ^ 0xFF
        let outcome = ParentPINRecovery.sweep(
            salt: m.salt, digest: m.digest,
            from: ParentPINRecovery.startCursor, budget: 5_000_000, maxLength: 4
        )
        XCTAssertEqual(outcome, .exhausted)
    }

    func testBudgetStopsAndResumesInsteadOfRestarting() {
        // A partial sweep must never be re-run from zero: without a resumable
        // cursor an 8-digit device would restart every foreground and never
        // finish.
        let m = material(for: "9999")
        let first = ParentPINRecovery.sweep(
            salt: m.salt, digest: m.digest,
            from: ParentPINRecovery.startCursor, budget: 10, maxLength: 4
        )
        guard case .budgetSpent(let cursor) = first else {
            return XCTFail("expected budgetSpent, got \(first)")
        }
        XCTAssertEqual(cursor, ParentPINRecovery.Cursor(length: 4, next: 10))

        let second = ParentPINRecovery.sweep(
            salt: m.salt, digest: m.digest,
            from: cursor, budget: 100_000, maxLength: 4
        )
        XCTAssertEqual(second, .found("9999"))
    }

    func testDoesNotSearchPastMaxLength() {
        let m = material(for: "1234567")   // 7 digits, beyond the auto ceiling
        let outcome = ParentPINRecovery.sweep(
            salt: m.salt, digest: m.digest,
            from: ParentPINRecovery.startCursor, budget: 5_000_000,
            maxLength: ParentPINRecovery.autoMaxLength
        )
        XCTAssertEqual(outcome, .exhausted)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ParentPINRecoveryTests' 2>&1 | tail -20
```

Expected: build FAILS — `ParentPINRecovery` and `recoveryMaterial()` do not exist.

- [ ] **Step 3: Add the Release-available accessor**

In `Evlin iOS/Services/EvlinPINStore.swift`, after `clear()`:

```swift
    /// Salt + digest for the one-time recovery sweep (`ParentPINRecovery`).
    /// Separate from `debugStoredBlob()`, which is `#if DEBUG` and therefore
    /// unavailable in the shipping build that has to run the migration.
    func recoveryMaterial() -> (salt: Data, digest: Data)? {
        guard let blob = readBlob(), blob.count > saltLength else { return nil }
        return (Data(blob.prefix(saltLength)), Data(blob.suffix(from: saltLength)))
    }

    /// Hash under this store's scheme, for recovery candidate testing.
    static func digest(salt: Data, candidate: String) -> Data {
        hash(salt: salt, pin: candidate)
    }
```

- [ ] **Step 4: Write the recovery type**

Create `Evlin iOS/Services/ParentPINRecovery.swift`:

```swift
import Foundation

/// Recovers an already-set Evlin Parent PIN from its own salted digest so it
/// can be uploaded for the parent to read back.
///
/// This is the app recovering its own data, not an attack: the store holds the
/// salt and the digest, and the keyspace is 4–8 ASCII digits. It exists because
/// `EvlinPINStore` deliberately never persisted the plaintext, and a parent who
/// forgot the PIN currently cannot open Parent Controls or uninstall Evlin.
///
/// Cost is not uniform — 4 digits is 10^4 hashes, 8 digits is 1.1×10^8 — so the
/// sweep is budgeted and resumable rather than one blocking pass.
enum ParentPINRecovery {

    struct Cursor: Codable, Equatable {
        var length: Int
        var next: Int
    }

    enum Outcome: Equatable {
        case found(String)
        case exhausted
        case budgetSpent(Cursor)
    }

    static let startCursor = Cursor(length: 4, next: 0)

    /// Lengths swept automatically. 7–8 digits stay off until a real-device
    /// benchmark says a full sweep finishes at acceptable time and power.
    static let autoMaxLength = 6

    static func sweep(
        salt: Data,
        digest: Data,
        from cursor: Cursor,
        budget: Int,
        maxLength: Int
    ) -> Outcome {
        var length = cursor.length
        var index = cursor.next
        var spent = 0

        while length <= maxLength {
            let space = pow10(length)
            while index < space {
                if spent >= budget {
                    return .budgetSpent(Cursor(length: length, next: index))
                }
                let candidate = format(index, width: length)
                if EvlinPINStore.digest(salt: salt, candidate: candidate) == digest {
                    return .found(candidate)
                }
                index += 1
                spent += 1
            }
            length += 1
            index = 0
        }
        return .exhausted
    }

    /// Zero-padded so "0042" is tested as itself. Formatting as a bare integer
    /// would skip every PIN with a leading zero.
    private static func format(_ value: Int, width: Int) -> String {
        let digits = String(value)
        if digits.count >= width { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }

    private static func pow10(_ n: Int) -> Int {
        var result = 1
        for _ in 0..<n { result *= 10 }
        return result
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ParentPINRecoveryTests' 2>&1 | grep -E "Test Case.*(passed|failed)|TEST" | tail -12
```

Expected: 6 passed, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && git add "Evlin iOS/Services/ParentPINRecovery.swift" "Evlin iOS/Services/EvlinPINStore.swift" "Evlin iOSTests/ParentPINRecoveryTests.swift" && git commit -m "feat(pin): recover an already-set PIN from its own salted digest"
```

---

### Task 6: Durable PIN upload payload + client call

**Files:**
- Create: `Evlin iOS/Services/ParentPINUploader.swift`
- Test: `Evlin iOSTests/ParentPINUploaderTests.swift`

**Interfaces:**
- Consumes: `ParentPINRecovery.Outcome` (Task 5); `PUT /child/device/parent-pin` (Task 3).
- Produces:
  - `struct PendingParentPIN: Codable, Equatable { let childDeviceID: UUID; let pin: String?; let status: String }`
  - `enum ParentPINUploader` with `static func save(_:)`, `static func pending() -> PendingParentPIN?`, `static func clear()`, `static func flush(baseURL:perform:) async -> Bool`.

- [ ] **Step 1: Write the failing tests**

Create `Evlin iOSTests/ParentPINUploaderTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class ParentPINUploaderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ParentPINUploader.clear()
    }

    override func tearDown() {
        ParentPINUploader.clear()
        super.tearDown()
    }

    func testSavedPayloadSurvivesUntilAcked() {
        // The plaintext exists for exactly one instant — right after the gate
        // creates it. If the app dies before the POST lands and nothing durable
        // held it, the parent can never see that PIN.
        let payload = PendingParentPIN(
            childDeviceID: UUID(), pin: "4826", status: "available"
        )
        ParentPINUploader.save(payload)
        XCTAssertEqual(ParentPINUploader.pending(), payload)
    }

    func testFlushClearsOnSuccess() async {
        let payload = PendingParentPIN(
            childDeviceID: UUID(), pin: "4826", status: "available"
        )
        ParentPINUploader.save(payload)

        let ok = await ParentPINUploader.flush(baseURL: "https://example.test") { _ in true }

        XCTAssertTrue(ok)
        XCTAssertNil(ParentPINUploader.pending())
    }

    func testFlushKeepsPayloadOnFailure() async {
        let payload = PendingParentPIN(
            childDeviceID: UUID(), pin: "4826", status: "available"
        )
        ParentPINUploader.save(payload)

        let ok = await ParentPINUploader.flush(baseURL: "https://example.test") { _ in false }

        XCTAssertFalse(ok)
        XCTAssertEqual(ParentPINUploader.pending(), payload)
    }

    func testFlushWithNothingPendingIsASuccessfulNoOp() async {
        let ok = await ParentPINUploader.flush(baseURL: "https://example.test") { _ in
            XCTFail("must not perform a request with nothing pending")
            return false
        }
        XCTAssertTrue(ok)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ParentPINUploaderTests' 2>&1 | tail -20
```

Expected: build FAILS — `ParentPINUploader` does not exist.

- [ ] **Step 3: Implement the uploader**

Create `Evlin iOS/Services/ParentPINUploader.swift`:

```swift
import Foundation

struct PendingParentPIN: Codable, Equatable {
    let childDeviceID: UUID
    /// nil when `status` is `unrecoverable` — there is no value to send.
    let pin: String?
    let status: String
}

/// Holds a created-but-not-yet-uploaded Parent PIN in the App Group container
/// until the backend acks it.
///
/// The plaintext is recoverable for exactly one instant — the moment
/// `EvlinPINGateView` creates it — because the store keeps only a salted digest
/// afterwards. Without a durable payload, an app kill between "PIN created" and
/// "upload succeeded" leaves a PIN the parent can never read.
enum ParentPINUploader {

    private static let key = "evlin.parentPIN.pendingUpload"
    private static let suiteName = "group.com.evlin.ios"

    /// No `?? .standard` fallback. `EvlinPINStore` can afford one because it
    /// stores a salted digest; this holds PLAINTEXT, and silently writing it to
    /// the app-wide defaults when the App Group is unavailable would put it
    /// somewhere the teardown paths below never clear.
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func save(_ payload: PendingParentPIN) {
        guard let defaults, let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
    }

    static func pending() -> PendingParentPIN? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingParentPIN.self, from: data)
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }

    /// Uploads whatever is pending. `perform` is injected so the retry policy is
    /// unit-tested without the network; passing nil uses the real POST against
    /// `baseURL` (a default closure can't reference another parameter, and
    /// silently falling back to a different base URL than the caller asked for
    /// would be a trap).
    @discardableResult
    static func flush(
        baseURL: String,
        perform: ((PendingParentPIN) async -> Bool)? = nil
    ) async -> Bool {
        guard let payload = pending() else { return true }
        let send = perform ?? { await post(baseURL: baseURL, payload: $0) }
        guard await send(payload) else { return false }
        clear()
        return true
    }

    static func post(baseURL: String, payload: PendingParentPIN) async -> Bool {
        guard let url = URL(string: "\(baseURL)/child/device/parent-pin") else { return false }
        // Identity travels in the credential, never in the body. `childDeviceID`
        // on the payload is local bookkeeping only — which device this pending
        // upload belongs to — and is deliberately not sent.
        guard let auth = ChildDeviceCredentialStore.authorizationHeader() else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(auth.value, forHTTPHeaderField: auth.field)
        req.timeoutInterval = 12
        var body: [String: Any] = ["status": payload.status]
        body["pin"] = payload.pin as Any
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
```

`ChildDeviceCredentialStore` is FIX-K's client-side counterpart: it holds the credential
issued by the Pairing v2 join commit (`device_credential` in the commit response) and
renders it as `(field: String, value: String)`. Use FIX-K's actual type and accessor if
they differ. If no credential is stored, `post` returns false and the payload stays
pending — never fall back to sending a bare device id.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ParentPINUploaderTests' 2>&1 | grep -E "Test Case.*(passed|failed)|TEST" | tail -10
```

Expected: 4 passed, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Clear the pending plaintext wherever the identity ends**

A pending payload holds a PIN in the clear. If the device signs out, is unpaired, or
switches identity before the upload lands, that plaintext must not survive to be
uploaded against the *next* identity. Add `ParentPINUploader.clear()` beside the existing
`EvlinPINStore.shared.clear()` call in each teardown.

**Add one line per site; do not restructure the teardown.** `EarnedBudgetArming` is one
of the files the architecture review named as an identity-transition hazard, and a PIN
cleanup is not a reason to touch that state machine. If the call cannot be added without
reorganising surrounding logic, stop and raise it.

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && grep -rn "EvlinPINStore.shared.clear()" "Evlin iOS"
```

Expected today: `Evlin iOS/Services/Auth/AuthService.swift:286` (sign-out teardown) and
`Evlin iOS/Views/Child/BigKid/BigKidRootView.swift:326`. Add the call at each site. Also
add it to the identity-switch teardown in
`Evlin iOS/Services/EarnedBudgetArming.swift` — inside `mirrorChildIdentity`, in the
branch that runs when the owner actually changes (next to
`readinessStore.clearUsageStateForIdentityChange()`), so a PIN created under the old
owner is never uploaded under the new one.

- [ ] **Step 6: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && git add "Evlin iOS/Services/ParentPINUploader.swift" "Evlin iOSTests/ParentPINUploaderTests.swift" "Evlin iOS/Services/Auth/AuthService.swift" "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift" "Evlin iOS/Services/EarnedBudgetArming.swift" && git commit -m "feat(pin): hold a created PIN durably until the backend acks it"
```

---

### Task 7: `EvlinPINGateView` reports the created PIN

**Files:**
- Modify: `Evlin iOS/Views/Settings/EvlinPINGateView.swift:9-33` (properties/copy), `:159` (create path)
- Test: manual — the three existing call sites must still compile unchanged.

**Interfaces:**
- Consumes: nothing.
- Produces: `EvlinPINGateView.onPINCreated: (String) -> Void` (defaults to `{ _ in }`), fired **only** on the first-run create path. Task 9 passes a closure here.

- [ ] **Step 1: Add the callback and copy**

In `Evlin iOS/Views/Settings/EvlinPINGateView.swift`, after `let onCancel: () -> Void`:

```swift
    /// Fired ONLY when a PIN was just created, carrying the plaintext.
    /// `onUnlocked` cannot carry it: it is also the verify-path callback, and
    /// the three unlock call sites must never receive a PIN. The plaintext is
    /// unrecoverable the moment `setPIN` returns — the store keeps only
    /// `salt || sha256(salt || pin)` — so this is the single opportunity to
    /// hand it to the uploader.
    var onPINCreated: (String) -> Void = { _ in }
```

Change `subtitle` to:

```swift
    private var subtitle: String {
        isFirstRun
            ? "4–8 digits. Your child can't change managed apps without it."
            : "to manage settings on this phone"
    }
```

Change the create-path title to disambiguate it from the iOS Screen Time passcode set one step earlier:

```swift
    private var title: String {
        if !isFirstRun { return "Enter parent PIN" }
        return phase == .enter ? "Create your Evlin Parent PIN" : "Confirm PIN"
    }
```

- [ ] **Step 2: Fire it on the create path only**

In `submit()`, replace `do { try store.setPIN(pin); onUnlocked() }` with:

```swift
            do {
                let created = pin
                try store.setPIN(created)
                onPINCreated(created)
                onUnlocked()
            }
```

- [ ] **Step 3: Verify the existing call sites still compile**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build 2>&1 | grep -E "error:|warning: unused" | head -10
```

Expected: no `error:` lines. `HomeSettingsSheet.swift:406`, `:427` and `BigKidRootView.swift:272` do not pass `onPINCreated` and must keep working on the default.

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && git add "Evlin iOS/Views/Settings/EvlinPINGateView.swift" && git commit -m "feat(pin): surface the created PIN from the gate without touching the unlock path"
```

---

### Task 8: Extract the tracking capture into a shared model

Focused extraction. `ScreenTimeCaptureView` owns both the capture logic and the home-card
chrome; the onboarding step needs the logic with different chrome. Selection defaults,
serialization and persistence must not change. The only behaviour change is explicit:
both entry points invoke the existing v2 policy refresh instead of the retired
`armIfReady()` arming half.

**Files:**
- Create: `Evlin iOS/Services/TrackingSelectionCapture.swift`, `Evlin iOS/Services/MeteringPolicyRefresh.swift`
- Modify: `Evlin iOS/Services/MeteringProductionComposition.swift:104-113` (return an outcome instead of `Void`), `Evlin iOS/Views/Child/BigKid/ScreenTimeCaptureView.swift:27-31` (state), `:118-152` (`openPicker`/`saveIfReady`)
- Test: `Evlin iOSTests/TrackingSelectionCaptureTests.swift`, `Evlin iOSTests/MeteringPolicyRefreshTests.swift`

**Two deliberate behaviour changes, called out because the rest of the task is a pure
move:**

1. `recoverFromSharedConfiguration` currently returns `Void` and **silently returns**
   when `sharedConfiguration()` is nil — App Group unavailable, or the `baseURL`/owner
   keys missing or malformed (`MeteringProductionComposition.swift:113`, `:466-473`).
   A caller cannot distinguish "reconciled" from "did nothing", so any success flag built
   on "it didn't throw" is a lie in exactly the case that matters: a device whose identity
   mirror is not set up. It gains a return value; no logic changes.
2. `ScreenTimeCaptureView` (the App Controls / re-pick entry) gets the same v2 hand-off
   the new onboarding step gets. Leaving it on the dead `armIfReady()` would mean the
   same user action — picking tracked apps — arms immediately in onboarding and waits up
   to a poll interval everywhere else, with the file's own comment still claiming
   immediacy in both.

**Interfaces:**
- Consumes: `EarnedTimeStore.shared.saveMeasurementSelection(_:)`, `EarnedBudgetArming.armIfReady()`.
- Produces: `@MainActor final class TrackingSelectionCapture: ObservableObject` with `@Published var selection: FamilyActivitySelection`, `@Published private(set) var state: State` where `enum State: Equatable { case idle, needsSelection, notAuthorized, saved }`, `func requestPicker(authorized: Bool) -> Bool`, `func commit()`.

- [ ] **Step 1: Write the failing tests**

Create `Evlin iOSTests/TrackingSelectionCaptureTests.swift`:

```swift
import FamilyControls
import XCTest
@testable import Evlin_iOS

@MainActor
final class TrackingSelectionCaptureTests: XCTestCase {

    func testEmptySelectionIsRejectedRatherThanSavedAsNothing() {
        // Saving an empty selection arms a ladder that measures nothing, which
        // presents as "the bar never moves" with no error anywhere.
        let capture = TrackingSelectionCapture()
        capture.selection = FamilyActivitySelection()
        capture.commit()
        XCTAssertEqual(capture.state, .needsSelection)
    }

    func testUnauthorizedRequestDoesNotOpenThePicker() {
        let capture = TrackingSelectionCapture()
        XCTAssertFalse(capture.requestPicker(authorized: false))
        XCTAssertEqual(capture.state, .notAuthorized)
    }

    func testAuthorizedRequestClearsPriorComplaints() {
        let capture = TrackingSelectionCapture()
        _ = capture.requestPicker(authorized: false)
        XCTAssertTrue(capture.requestPicker(authorized: true))
        XCTAssertEqual(capture.state, .idle)
    }

    func testDefaultSelectionIncludesEntireCategories() {
        // The earned-time ladder measures whole categories; a selection built
        // without this flag silently measures a narrower set than the parent
        // believes they picked.
        let capture = TrackingSelectionCapture()
        XCTAssertTrue(capture.selection.includeEntireCategory)
    }

    func testValidSelectionRunsTheV2RecoveryExactlyOnce() async {
        // THE test for this task. The old call site "armed" with
        // EarnedBudgetArming.armIfReady(), which on a v2-only build returns
        // early at canInstallLegacyLadder and arms nothing. If someone deletes
        // the hand-off, this must go red — a negative-only test would not.
        let capture = TrackingSelectionCapture(isSelectionEmpty: { false })

        var recoveries = 0
        await capture.commit(then: { recoveries += 1 })

        XCTAssertEqual(capture.state, .saved)
        XCTAssertEqual(recoveries, 1)
    }

    func testEmptySelectionDoesNotRunRecovery() async {
        let capture = TrackingSelectionCapture(isSelectionEmpty: { true })

        var recoveries = 0
        await capture.commit(then: { recoveries += 1 })

        XCTAssertEqual(capture.state, .needsSelection)
        XCTAssertEqual(recoveries, 0)
    }
}
```

Also create `Evlin iOSTests/MeteringPolicyRefreshTests.swift` — the RED that a missing
App Group configuration must not read as success:

```swift
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringRecoveryOutcomeTests: XCTestCase {

    func testMissingSharedConfigurationIsNotSuccess() async throws {
        // The failure this guards: the App Group owner/baseURL are unset, the
        // composition returns without throwing, and a caller that only checks
        // "did it throw" reports a fully set-up device that armed nothing.
        let suite = "group.com.evlin.ios"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let savedBase = defaults.string(forKey: MeteringProductionComposition.baseURLKey)
        let savedOwner = defaults.string(forKey: MeteringProductionComposition.ownerKey)
        defaults.removeObject(forKey: MeteringProductionComposition.baseURLKey)
        defaults.removeObject(forKey: MeteringProductionComposition.ownerKey)
        defer {
            if let savedBase {
                defaults.set(savedBase, forKey: MeteringProductionComposition.baseURLKey)
            }
            if let savedOwner {
                defaults.set(savedOwner, forKey: MeteringProductionComposition.ownerKey)
            }
        }

        let outcome = try await MeteringProductionComposition
            .recoverFromSharedConfiguration(role: .app)

        XCTAssertEqual(outcome, .skippedMissingConfiguration)
        XCTAssertNotEqual(outcome, .attempted)
    }

    func testExpectedOwnerMismatchIsNotAttempted() async throws {
        let suite = "group.com.evlin.ios"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let savedBase = defaults.string(forKey: MeteringProductionComposition.baseURLKey)
        let savedOwner = defaults.string(forKey: MeteringProductionComposition.ownerKey)
        let configuredOwner = UUID()
        let baseURL = URL(string: "http://127.0.0.1:8000")!
        defaults.set(baseURL.absoluteString, forKey: MeteringProductionComposition.baseURLKey)
        defaults.set(configuredOwner.uuidString, forKey: MeteringProductionComposition.ownerKey)
        defer {
            if let savedBase { defaults.set(savedBase, forKey: MeteringProductionComposition.baseURLKey) }
            else { defaults.removeObject(forKey: MeteringProductionComposition.baseURLKey) }
            if let savedOwner { defaults.set(savedOwner, forKey: MeteringProductionComposition.ownerKey) }
            else { defaults.removeObject(forKey: MeteringProductionComposition.ownerKey) }
        }

        let outcome = try await MeteringProductionComposition
            .recoverFromSharedConfiguration(
                role: .app,
                expectedOwner: UUID(),
                expectedBaseURL: baseURL
            )

        XCTAssertEqual(outcome, .skippedConfigurationMismatch)
    }
}
```

`baseURLKey` and `ownerKey` must be at least `internal` for this test to compile; they
are already referenced by `OnboardingCoordinator.swift:1090`, so no visibility change
should be needed — confirm with
`grep -n "baseURLKey\|ownerKey" "Evlin iOS/Services/MeteringProductionComposition.swift"`.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/TrackingSelectionCaptureTests' -only-testing:'Evlin iOSTests/MeteringRecoveryOutcomeTests' 2>&1 | tail -20
```

Expected: build FAILS — `TrackingSelectionCapture` does not exist.

- [ ] **Step 3: Write the model**

Create `Evlin iOS/Services/TrackingSelectionCapture.swift`:

```swift
import FamilyControls
import Foundation

/// The all-category measurement selection the earned-time ladder counts
/// against. Extracted verbatim from `ScreenTimeCaptureView` so onboarding and
/// the home card share one implementation instead of drifting apart.
@MainActor
final class TrackingSelectionCapture: ObservableObject {

    enum State: Equatable {
        case idle
        case needsSelection
        case notAuthorized
        case saved
    }

    @Published var selection = FamilyActivitySelection(includeEntireCategory: true)
    @Published private(set) var state: State = .idle

    /// Test seam. `ApplicationToken` and `ActivityCategoryToken` are opaque and
    /// can only be minted by the real picker, so a unit test cannot build a
    /// non-empty selection. Without this injection the "valid selection arms
    /// v2" path would be untestable — and an untested hand-off is how the
    /// dead `armIfReady()` call survived in the first place.
    private let overrideIsSelectionEmpty: (() -> Bool)?

    init(isSelectionEmpty: (() -> Bool)? = nil) {
        self.overrideIsSelectionEmpty = isSelectionEmpty
    }

    private var selectionIsEmpty: Bool {
        if let overrideIsSelectionEmpty { return overrideIsSelectionEmpty() }
        return selection.applicationTokens.isEmpty
            && selection.categoryTokens.isEmpty
            && selection.webDomainTokens.isEmpty
    }

    /// Returns true when the picker may be presented. Checking first avoids a
    /// crash on a device where Screen Time was never authorized.
    func requestPicker(authorized: Bool) -> Bool {
        guard authorized else {
            state = .notAuthorized
            return false
        }
        state = .idle
        return true
    }

    /// Persists the selection. It does NOT arm — see `commit(then:)`.
    ///
    /// The old call site followed the save with `EarnedBudgetArming.armIfReady()`
    /// under a comment promising immediate arming. That promise is dead: on a
    /// v2-only build `armIfReady` reaches
    /// `EarnedBudgetScheduler.canInstallLegacyLadder`, which now returns false
    /// unconditionally, and returns early with "skipped v2-metering-selected".
    /// (It is not a pure no-op — `reconcileIdentityTransition()` and
    /// `recoverInterruptedTransition()` run before that guard — but nothing is
    /// ever armed by it.) Arming a v2 route is
    /// `MeteringProductionComposition.recoverFromSharedConfiguration`, which the
    /// caller supplies.
    func commit() {
        guard !selectionIsEmpty else {
            state = .needsSelection
            return
        }
        EarnedTimeStore.shared.saveMeasurementSelection(selection)
        EarnedBudgetArming.armIfReady()   // identity/transition reconciliation only
        state = .saved
    }

    /// Save, then hand off to the caller's v2 recovery. Kept as a separate entry
    /// point so the arming path is explicit at every call site rather than
    /// hidden inside a "save" that silently does nothing.
    func commit(then recoverV2: @escaping () async -> Void) async {
        commit()
        guard state == .saved else { return }
        await recoverV2()
    }
}
```

- [ ] **Step 3b: Make the production recovery say whether it did anything**

In `Evlin iOS/Services/MeteringProductionComposition.swift`, add the outcome type above
`recoverFromSharedConfiguration`:

```swift
/// Whether a reconcile actually ran. `recoverFromSharedConfiguration` returns
/// early — without throwing — when the App Group is unavailable or the shared
/// `baseURL`/owner keys are missing or malformed. Callers that gate a user-facing
/// "setup complete" on it cannot tell that apart from success unless it is said
/// out loud, and "no error therefore armed" is precisely the false-success shape
/// this whole feature is trying not to reproduce.
enum MeteringRecoveryOutcome: Equatable {
    case attempted
    case skippedMissingConfiguration
    case skippedConfigurationMismatch
}
```

Change the signature, classify the missing-configuration exit, and compare the same
configuration snapshot with optional expected owner/backend inputs (no recovery logic
or state mutation changes):

```swift
    @MainActor
    @discardableResult
    static func recoverFromSharedConfiguration(
        role: MeteringProcessRole,
        runtime: EarnedTimeRuntime? = nil,
        usageCountingAllowed: Bool? = nil,
        expectedOwner: UUID? = nil,
        expectedBaseURL: URL? = nil,
        store: DeviceEpochStore = .shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        transport: any MeteringHTTPTransport = URLSession.shared
    ) async throws -> MeteringRecoveryOutcome {
        guard let configuration = sharedConfiguration() else {
            return .skippedMissingConfiguration
        }
        if let expectedOwner, configuration.owner != expectedOwner {
            return .skippedConfigurationMismatch
        }
        if let expectedBaseURL {
            let slashes = CharacterSet(charactersIn: "/")
            guard configuration.baseURL.absoluteString.trimmingCharacters(in: slashes)
                    == expectedBaseURL.absoluteString.trimmingCharacters(in: slashes)
            else { return .skippedConfigurationMismatch }
        }
```

and `return .attempted` at the end of the function body. `@discardableResult` keeps the
three existing call sites (`CommandPoller.swift:1269`, `BigKidStatePoller.swift:105`,
`OnboardingCoordinator.swift:1121`) compiling untouched.

- [ ] **Step 3c: One refresh helper, used by both entry points**

Create `Evlin iOS/Services/MeteringPolicyRefresh.swift`:

```swift
import Foundation

/// Fetch current policy, then reconcile the v2 horizon. The single place that
/// pairing, onboarding's final step and the App Controls re-pick all call, so
/// "the user chose what to track" means the same thing everywhere instead of
/// arming immediately on one screen and waiting for the next poll on another.
///
/// Not a coordinator: it owns no state and makes no decisions. It is the two
/// existing calls, in the existing order, in one place.
enum MeteringPolicyRefresh {

    @MainActor
    static func now(childDeviceID: UUID, baseURL: URL) async -> MeteringRecoveryOutcome? {
        do {
            let state = try await BigKidAPIClient(
                baseURL: baseURL, childId: childDeviceID
            ).fetchState()
            return try await MeteringProductionComposition.recoverFromSharedConfiguration(
                role: .app,
                runtime: state.earnedTimeRuntime,
                usageCountingAllowed: state.effectiveUsageCountingAllowed,
                expectedOwner: childDeviceID,
                expectedBaseURL: baseURL
            )
        } catch {
            MeteringFlightRecorder.emitError(
                site: "meteringPolicyRefresh",
                error: error,
                detail: MeteringFlightRecorder.detail([
                    ("device", childDeviceID.uuidString)
                ])
            )
            return nil   // threw: neither attempted nor cleanly skipped
        }
    }
}
```

- [ ] **Step 4: Point the existing view at the model**

In `Evlin iOS/Views/Child/BigKid/ScreenTimeCaptureView.swift`, replace the four `@State` properties (`selection`, `isSaved`, `notAuthorized`, `selectionRequired`) with:

```swift
    @StateObject private var capture = TrackingSelectionCapture()
```

Replace `openPicker()` and `saveIfReady()` with:

```swift
    private func openPicker() {
        let approved = AuthorizationCenter.shared.authorizationStatus == .approved
        pickerShown = capture.requestPicker(authorized: approved)
    }

    private func saveIfReady() {
        Task {
            // Same v2 hand-off the onboarding step uses. Previously this called
            // `EarnedBudgetArming.armIfReady()` under a comment promising
            // immediate arming; on a v2-only build that returns early at
            // canInstallLegacyLadder and nothing is ever armed here.
            await capture.commit(then: {
                guard let raw = UserDefaults.standard
                        .string(forKey: DeviceIdentity.childKey),
                      let childID = UUID(uuidString: raw),
                      let baseURL = URL(string: APIClient.currentBaseURL) else { return }
                _ = await MeteringPolicyRefresh.now(childDeviceID: childID, baseURL: baseURL)
            })
            guard capture.state == .saved else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onDone() }
        }
    }
```

Delete the stale `// Arm immediately…` comment block that sat above the old
`EarnedBudgetArming.armIfReady()` call — it describes behaviour this build has not had
since the v2-only cutover.

Update the view body's references: `isSaved` → `capture.state == .saved`, `notAuthorized` → `capture.state == .notAuthorized`, `selectionRequired` → `capture.state == .needsSelection`, and `$selection` → `$capture.selection`. The `withAnimation` wrapper around the saved flag moves onto the `capture.state` read; keep the same 0.3s ease-out on the card by wrapping the `commit()` call:

```swift
        withAnimation(.easeOut(duration: 0.3)) { capture.commit() }
```

- [ ] **Step 5: Run tests and build to verify nothing changed**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/TrackingSelectionCaptureTests' -only-testing:'Evlin iOSTests/MeteringRecoveryOutcomeTests' -only-testing:'Evlin iOSTests/EarnedBudgetArmingTests' 2>&1 | grep -E "Test Case.*(passed|failed)|TEST" | tail -16
```

Expected: all pass, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && git add "Evlin iOS/Services/TrackingSelectionCapture.swift" "Evlin iOS/Services/MeteringPolicyRefresh.swift" "Evlin iOS/Services/MeteringProductionComposition.swift" "Evlin iOS/Views/Child/BigKid/ScreenTimeCaptureView.swift" "Evlin iOSTests/TrackingSelectionCaptureTests.swift" "Evlin iOSTests/MeteringPolicyRefreshTests.swift" && git commit -m "fix(tracking): refresh the existing v2 policy after selection"
```

---

### Task 9: `ChildFinalSetupStep` replaces the "All set!" page

**Files:**
- Create: `Evlin iOS/Views/Onboarding/Child/V2/ChildFinalSetupStep.swift`
- Modify: `Evlin iOS/Views/Onboarding/OnboardingCoordinator.swift:73-74` (step cases), `:893-907` (`childSafetyLock` wiring), `:581-598` (`childReady` case)
- Delete: `Evlin iOS/Views/Onboarding/Child/ChildReadyStep.swift`
- Test: `Evlin iOSTests/ChildFinalSetupStepTests.swift`

**Interfaces:**
- Consumes: `TrackingSelectionCapture` (Task 8), `EvlinPINGateView.onPINCreated` (Task 7), `ParentPINUploader` (Task 6), `APIClient.markChildAllSet(childDeviceID:) -> Bool`.
- Produces: `ChildFinalSetupStep(childDeviceID:familyID:kidName:onEnter:onSingleDeviceContinue:onBack:)`, plus the pure gate `ChildFinalSetupStep.canFinish(trackingDone:pinDone:) -> Bool` used by tests.

- [ ] **Step 1: Write the failing tests**

Create `Evlin iOSTests/ChildFinalSetupStepTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class ChildFinalSetupStepTests: XCTestCase {

    func testFinishStaysLockedUntilBothCardsAreDone() {
        // Skipping either card is exactly how a kid ends up with no measurement
        // selection, or opens Parent Controls first and sets their own PIN.
        XCTAssertFalse(ChildFinalSetupStep.canFinish(trackingDone: false, pinDone: false))
        XCTAssertFalse(ChildFinalSetupStep.canFinish(trackingDone: true, pinDone: false))
        XCTAssertFalse(ChildFinalSetupStep.canFinish(trackingDone: false, pinDone: true))
        XCTAssertTrue(ChildFinalSetupStep.canFinish(trackingDone: true, pinDone: true))
    }

    func testFinishPersistsIdentifiersBeforeReportingAllSet() async {
        // Evlin_iOSApp.onChange(of: onboardingComplete) reads these keys
        // synchronously to start the CommandPoller. Reversing the order races
        // the poller against missing pairing keys and leaves it stopped.
        let deviceID = UUID()
        let familyID = UUID()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "evlin.childDeviceID")
        defaults.removeObject(forKey: "evlin.familyID")

        var seenDeviceKeyAtAllSet: String?
        var order: [String] = []
        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: deviceID,
            familyID: familyID,
            markAllSet: { _ in
                order.append("all-set")
                seenDeviceKeyAtAllSet = defaults.string(forKey: "evlin.childDeviceID")
                return true
            },
            recoverV2: {
                order.append("recover-v2")
                return true
            }
        )

        XCTAssertTrue(done)
        XCTAssertEqual(order, ["all-set", "recover-v2"])
        XCTAssertEqual(seenDeviceKeyAtAllSet, deviceID.uuidString)
        XCTAssertEqual(defaults.string(forKey: "evlin.familyID"), familyID.uuidString)
    }

    func testFinishFailsWhenAllSetFails() async {
        // markChildAllSet is what provisions the default pool. Leaving the step
        // on a failure is the difference between "retry" and "a kid with no
        // pool and a parent stuck on waiting".
        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: UUID(),
            familyID: UUID(),
            markAllSet: { _ in false },
            recoverV2: {
                XCTFail("recovery must not run when all-set failed")
                return true
            }
        )
        XCTAssertFalse(done)
    }

    func testFinishFailsWhenV2RecoveryDidNotRun() async {
        // This is the load-bearing completion invariant. Deleting the recovery
        // call, swallowing a missing App Group identity, or turning it back
        // into best-effort must make this test red.
        var recoveryCalls = 0
        let done = await ChildFinalSetupStep.runFinish(
            childDeviceID: UUID(),
            familyID: UUID(),
            markAllSet: { _ in true },
            recoverV2: {
                recoveryCalls += 1
                return false
            }
        )

        XCTAssertFalse(done)
        XCTAssertEqual(recoveryCalls, 1)
    }

}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ChildFinalSetupStepTests' 2>&1 | tail -20
```

Expected: build FAILS — `ChildFinalSetupStep` does not exist.

- [ ] **Step 3: Write the step**

Create `Evlin iOS/Views/Onboarding/Child/V2/ChildFinalSetupStep.swift`:

```swift
import FamilyControls
import SwiftUI

/// The kid's last onboarding screen. It replaces the old "All set!" notice,
/// which was pure text occupying the slot where the two things Evlin actually
/// needs — a measurement selection and a Parent PIN — should be captured.
struct ChildFinalSetupStep: View {

    let childDeviceID: UUID?
    let familyID: UUID?
    var kidName: String = ""
    let onEnter: () -> Void
    /// Single Device Mode: hand control back instead of flipping the flag, so
    /// the coordinator can switch this same phone to the parent payoff phase.
    var onSingleDeviceContinue: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    @EnvironmentObject var apiClient: APIClient
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    @StateObject private var capture = TrackingSelectionCapture()
    @State private var pickerShown = false
    @State private var pinGateShown = false
    @State private var pinDone = false
    @State private var pinError: String?
    @State private var finishing = false
    @State private var finishError: String?

    private var trackingDone: Bool { capture.state == .saved }

    /// Pure gate so the rule is testable without the view.
    static func canFinish(trackingDone: Bool, pinDone: Bool) -> Bool {
        trackingDone && pinDone
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "6 · Final setup",
            stepIndex: 11,
            stepTotal: childTotal,
            title: "Two quick things and you're done",
            subtitle: "Both are needed before Evlin can start.",
            content: {
                VStack(spacing: Spacing.lg) {
                    trackingCard
                    pinCard
                    if let finishError {
                        Text(finishError)
                            .onboardingV2BodyXS()
                            .foregroundStyle(OnboardingV2Theme.Palette.error)
                    }
                }
            },
            footer: {
                OnboardingV2PrimaryButton(
                    finishing ? "Finishing…" : "Finish setup",
                    role: .child
                ) {
                    Task { await finish() }
                }
                .disabled(!Self.canFinish(trackingDone: trackingDone, pinDone: pinDone) || finishing)
                .opacity(Self.canFinish(trackingDone: trackingDone, pinDone: pinDone) ? 1 : 0.5)

                if !Self.canFinish(trackingDone: trackingDone, pinDone: pinDone) {
                    Text("Finish unlocks when both are done")
                        .onboardingV2BodyXS()
                }
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
        .familyActivityPicker(isPresented: $pickerShown, selection: $capture.selection)
        .onChange(of: pickerShown) { _, isOpen in
            guard !isOpen else { return }
            Task {
                // Save, then arm through the ONE v2 path the rest of the app
                // uses. `EarnedBudgetArming.armIfReady()` cannot do this on a
                // v2-only build — it returns early at canInstallLegacyLadder —
                // and inventing a second arming coordinator here is exactly the
                // overlap the architecture review flagged as a root cause.
                //
                // Best-effort on purpose: the pool may not exist yet (it is
                // created by markChildAllSet at Finish), so "no route yet" is a
                // legitimate outcome here. The gating reconcile is in finish().
                await capture.commit(then: {
                    _ = await recoverMeteringV2(site: "onboarding.finalSetup.recoverV2.postSelection")
                })
            }
        }
        .fullScreenCover(isPresented: $pinGateShown) {
            EvlinPINGateView(
                store: .shared,
                onUnlocked: { pinGateShown = false },
                onCancel: { pinGateShown = false },
                onPINCreated: { pin in
                    guard let deviceID = childDeviceID else {
                        pinError = "This phone isn't paired yet. Go back and pair again."
                        return
                    }
                    // Durable BEFORE the request: the plaintext is gone from the
                    // store the instant setPIN returns.
                    ParentPINUploader.save(
                        PendingParentPIN(childDeviceID: deviceID, pin: pin, status: "available")
                    )
                    Task { await uploadPIN() }
                }
            )
        }
    }

    @ViewBuilder
    private var trackingCard: some View {
        OnboardingV2Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("SCREEN-TIME TRACKING").onboardingV2BodyXS()
                Text(trackingDone ? "Tracking enabled" : "Turn on tracking")
                    .font(OnboardingV2Theme.Typography.bodyStrong)
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                Text("Tap below and choose All Apps & Categories so Evlin can count screen time and award earned minutes.")
                    .onboardingV2BodyXS()
                if capture.state == .needsSelection {
                    Text("Choose All Apps & Categories before continuing.")
                        .onboardingV2BodyXS()
                        .foregroundStyle(OnboardingV2Theme.Palette.error)
                }
                if capture.state == .notAuthorized {
                    Text("Screen Time isn't authorized yet. Go back and finish the Screen Time step first.")
                        .onboardingV2BodyXS()
                        .foregroundStyle(OnboardingV2Theme.Palette.error)
                }
                if !trackingDone {
                    OnboardingV2SecondaryButton("Select All Apps & Categories") {
                        let approved = AuthorizationCenter.shared.authorizationStatus == .approved
                        pickerShown = capture.requestPicker(authorized: approved)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pinCard: some View {
        OnboardingV2Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("PARENT PIN").onboardingV2BodyXS()
                Text(pinDone ? "PIN created" : "Hand the phone to your parent")
                    .font(OnboardingV2Theme.Typography.bodyStrong)
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                Text("A parent creates a 4–8 digit PIN that locks Parent Controls on this phone.")
                    .onboardingV2BodyXS()
                if let pinError {
                    Text(pinError)
                        .onboardingV2BodyXS()
                        .foregroundStyle(OnboardingV2Theme.Palette.error)
                }
                if !pinDone {
                    OnboardingV2SecondaryButton(
                        pinError == nil ? "Create Parent PIN" : "Retry"
                    ) {
                        pinError = nil
                        if ParentPINUploader.pending() != nil {
                            Task { await uploadPIN() }   // created, upload never landed
                        } else {
                            pinGateShown = true
                        }
                    }
                }
            }
        }
    }

    /// The card is "done" only once the backend acked. Letting the kid past on
    /// a local write alone leaves a PIN the parent can never read.
    private func uploadPIN() async {
        if await ParentPINUploader.flush(baseURL: apiClient.baseURL) {
            pinDone = true
            pinError = nil
        } else {
            pinError = "Couldn't save the PIN. Retry"
        }
    }

    /// Fetch current policy and reconcile the v2 horizon — the same call the
    /// state poller and `KidJoinMeteringBootstrap` make. Reused deliberately:
    /// a second arming path would be a fourth coordinator on top of the three
    /// the review already blamed for the wedge surface.
    ///
    /// Returns whether the reconcile ran. That is **not** the same as "a route
    /// is active": install and verify are asynchronous and finish after this
    /// returns. The device-side route/install/readback/ack checks belong to
    /// acceptance, and this screen must not claim them.
    @discardableResult
    private func recoverMeteringV2(site: String) async -> Bool {
        guard let deviceID = childDeviceID,
              let baseURL = URL(string: apiClient.baseURL) else { return false }

        // The composition reads the App Group configuration once and compares
        // that same snapshot with this expected owner/backend. A separate view-
        // level preflight would leave a TOCTOU window where identity A's runtime
        // could be planned under owner B after a concurrent identity switch.
        let outcome = await MeteringPolicyRefresh.now(
            childDeviceID: deviceID, baseURL: baseURL
        )
        guard outcome == .attempted else {
            MeteringFlightRecorder.emit(
                kind: .meteringError,
                site: site,
                verdict: "recovery_not_attempted",
                detail: MeteringFlightRecorder.detail([
                    ("device", deviceID.uuidString),
                    ("outcome", String(describing: outcome))
                ])
            )
            return false
        }
        return true
    }

    private func finish() async {
        finishing = true
        defer { finishing = false }
        finishError = nil
        let ok = await Self.runFinish(
            childDeviceID: childDeviceID,
            familyID: familyID,
            markAllSet: { id in await apiClient.markChildAllSet(childDeviceID: id) },
            recoverV2: {
                await recoverMeteringV2(
                    site: "onboarding.finalSetup.recoverV2.postAllSet"
                )
            }
        )
        guard ok else {
            finishError = "Couldn't finish setup. Retry"
            return
        }
        if let cont = onSingleDeviceContinue {
            cont()
        } else {
            onboardingComplete = true
            onEnter()
        }
    }

    /// Persist ids, then report all-set. Order is load-bearing: the app's
    /// `onChange(of: onboardingComplete)` reads those keys synchronously to
    /// start the CommandPoller, and `markChildAllSet` is what provisions the
    /// default pool — a false return must keep the kid on this screen.
    static func runFinish(
        childDeviceID: UUID?,
        familyID: UUID?,
        markAllSet: (UUID) async -> Bool,
        recoverV2: () async -> Bool
    ) async -> Bool {
        if let id = childDeviceID {
            UserDefaults.standard.set(id.uuidString, forKey: "evlin.childDeviceID")
        }
        if let fid = familyID {
            UserDefaults.standard.set(fid.uuidString, forKey: "evlin.familyID")
        }
        guard let id = childDeviceID,
              await markAllSet(id)
        else { return false }

        // The pool only exists after all-set. This recovery is part of the
        // tested completion transaction: if it did not actually run, the kid
        // stays here and can retry instead of leaving onboarding unmetered.
        return await recoverV2()
    }
}
```

- [ ] **Step 4: Wire it into the coordinator and delete the old page**

In `Evlin iOS/Views/Onboarding/OnboardingCoordinator.swift`:

1. In the v2 step enum, add `case childFinalSetup` after `case childSafetyLock`.
2. Change the `childSafetyLock` case's `onContinue` from `{ step = .childReady }` to `{ step = .childFinalSetup }`, and update its copy arguments so the two passcodes are distinguishable — title `"Set the iOS Screen Time Passcode"` and a body opening with `"This is the iOS Screen Time passcode — different from the Evlin Parent PIN you'll create next."`
3. Add the new case to the switch:

```swift
            case .childFinalSetup:
                ChildFinalSetupStep(
                    childDeviceID: childDeviceID,
                    familyID: familyID,
                    kidName: kidName,
                    onEnter: {},
                    onSingleDeviceContinue: singleDevice ? {
                        SingleDeviceSession.shared.stage = .done
                        appMode = "parent"
                        onboardingComplete = true
                    } : nil,
                    onBack: { step = .childSafetyLock }
                )
```

4. Delete the `case .childReady:` block and the `childReady` enum case, then delete the file:

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && git rm "Evlin iOS/Views/Onboarding/Child/ChildReadyStep.swift"
```

5. Confirm nothing still references it:

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && grep -rn "ChildReadyStep\|childReady" "Evlin iOS" "Evlin iOSTests" | grep -v "childReadiness"
```

Expected: no output. If the v1 flow still routes to `childReady`, keep the v1 enum case and its screen — only the **v2** chain moves — and re-run this grep restricted to the v2 files.

- [ ] **Step 5: Run tests and build**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ChildFinalSetupStepTests' 2>&1 | grep -E "Test Case.*(passed|failed)|TEST" | tail -10
```

Expected: 4 passed, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && git add -A "Evlin iOS/Views/Onboarding" "Evlin iOSTests/ChildFinalSetupStepTests.swift" && git commit -m "feat(onboarding): replace the kid's All-set notice with a functional final step"
```

---

### Task 10: Run the recovery migration on foreground

**Files:**
- Create: `Evlin iOS/Services/ParentPINBackfill.swift`
- Modify: `Evlin iOS/Evlin_iOSApp.swift` (foreground hook — find it with the grep in Step 3)
- Test: `Evlin iOSTests/ParentPINBackfillTests.swift`

**Interfaces:**
- Consumes: `ParentPINRecovery` (Task 5), `ParentPINUploader` (Task 6), `EvlinPINStore.recoveryMaterial()`.
- Produces: `enum ParentPINBackfill` with `static func step(material:cursor:budget:) -> ParentPINRecovery.Outcome` and `static func runIfNeeded(childDeviceID:store:backendHasPIN:) async`.

- [ ] **Step 1: Write the failing tests**

Create `Evlin iOSTests/ParentPINBackfillTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class ParentPINBackfillTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ParentPINBackfill.resetCursor()
        ParentPINUploader.clear()
    }

    override func tearDown() {
        ParentPINBackfill.resetCursor()
        ParentPINUploader.clear()
        super.tearDown()
    }

    func testDoesNothingWhenNoPINIsSet() async {
        let store = EvlinPINStore(account: "evlin.test.\(UUID().uuidString)")
        await ParentPINBackfill.runIfNeeded(
            childDeviceID: UUID(), store: store, backendHasPIN: { false }
        )
        XCTAssertNil(ParentPINUploader.pending())
    }

    func testDoesNothingWhenBackendAlreadyHasThePIN() async {
        // Re-sweeping a device the backend already knows about burns battery
        // for nothing.
        let store = EvlinPINStore(account: "evlin.test.\(UUID().uuidString)")
        try! store.setPIN("4826")
        await ParentPINBackfill.runIfNeeded(
            childDeviceID: UUID(), store: store, backendHasPIN: { true }
        )
        XCTAssertNil(ParentPINUploader.pending())
    }

    func testRecoveredPINIsQueuedForUpload() async {
        let store = EvlinPINStore(account: "evlin.test.\(UUID().uuidString)")
        try! store.setPIN("4826")
        let deviceID = UUID()

        await ParentPINBackfill.runIfNeeded(
            childDeviceID: deviceID, store: store, backendHasPIN: { false }
        )

        XCTAssertEqual(
            ParentPINUploader.pending(),
            PendingParentPIN(childDeviceID: deviceID, pin: "4826", status: "available")
        )
    }

    func testCursorAdvancesAcrossCallsInsteadOfRestarting() {
        let store = EvlinPINStore(account: "evlin.test.\(UUID().uuidString)")
        try! store.setPIN("9999")
        let material = store.recoveryMaterial()!

        let first = ParentPINBackfill.step(
            material: material, cursor: ParentPINRecovery.startCursor, budget: 10
        )
        guard case .budgetSpent(let cursor) = first else {
            return XCTFail("expected budgetSpent, got \(first)")
        }
        let second = ParentPINBackfill.step(material: material, cursor: cursor, budget: 100_000)
        XCTAssertEqual(second, .found("9999"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ParentPINBackfillTests' 2>&1 | tail -20
```

Expected: build FAILS — `ParentPINBackfill` does not exist.

- [ ] **Step 3: Write the backfill**

Create `Evlin iOS/Services/ParentPINBackfill.swift`:

```swift
import Foundation

/// One-time migration that makes an already-set Parent PIN visible to the
/// parent. It is deliberately narrow: main app, foreground, paired, and only
/// when the backend does not already hold a PIN for this device. It is not a
/// capability — no extension may call it, and it is never exposed as an API.
enum ParentPINBackfill {

    private static let cursorKey = "evlin.parentPIN.recoveryCursor"
    private static let suiteName = "group.com.evlin.ios"

    /// Hashes per foreground pass. Sized so a full 6-digit sweep finishes in a
    /// handful of sessions without a visible stall.
    static let budgetPerPass = 250_000

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func resetCursor() {
        defaults.removeObject(forKey: cursorKey)
    }

    private static func loadCursor() -> ParentPINRecovery.Cursor {
        guard let data = defaults.data(forKey: cursorKey),
              let cursor = try? JSONDecoder().decode(ParentPINRecovery.Cursor.self, from: data)
        else { return ParentPINRecovery.startCursor }
        return cursor
    }

    private static func saveCursor(_ cursor: ParentPINRecovery.Cursor) {
        guard let data = try? JSONEncoder().encode(cursor) else { return }
        defaults.set(data, forKey: cursorKey)
    }

    static func step(
        material: (salt: Data, digest: Data),
        cursor: ParentPINRecovery.Cursor,
        budget: Int
    ) -> ParentPINRecovery.Outcome {
        ParentPINRecovery.sweep(
            salt: material.salt,
            digest: material.digest,
            from: cursor,
            budget: budget,
            maxLength: ParentPINRecovery.autoMaxLength
        )
    }

    static func runIfNeeded(
        childDeviceID: UUID,
        store: EvlinPINStore = .shared,
        backendHasPIN: () async -> Bool
    ) async {
        guard store.isSet(), let material = store.recoveryMaterial() else { return }
        guard await backendHasPIN() == false else { return }

        let outcome = await Task.detached(priority: .utility) {
            step(material: material, cursor: loadCursor(), budget: budgetPerPass)
        }.value

        switch outcome {
        case .found(let pin):
            ParentPINUploader.save(
                PendingParentPIN(childDeviceID: childDeviceID, pin: pin, status: "available")
            )
            resetCursor()
        case .budgetSpent(let cursor):
            saveCursor(cursor)
        case .exhausted:
            // Report honestly rather than leaving the parent staring at a row
            // that never resolves.
            ParentPINUploader.save(
                PendingParentPIN(childDeviceID: childDeviceID, pin: nil, status: "unrecoverable")
            )
            resetCursor()
        }
    }
}
```

- [ ] **Step 4: Call it from the app's foreground path**

Find the existing foreground hook:

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && grep -n "scenePhase\|case .active" "Evlin iOS/Evlin_iOSApp.swift" | head -8
```

In the `.active` branch, after the existing pairing/arming calls, add:

```swift
                    // Existing installs kept only a salted digest, so a PIN set
                    // before this build has to be recovered before the parent
                    // can ever see it. Also flushes a PIN created during
                    // onboarding whose upload never landed.
                    if let raw = UserDefaults.standard.string(forKey: "evlin.childDeviceID"),
                       let childID = UUID(uuidString: raw) {
                        Task {
                            await ParentPINUploader.flush(baseURL: APIClient.currentBaseURL)
                            await ParentPINBackfill.runIfNeeded(
                                childDeviceID: childID,
                                backendHasPIN: {
                                    await ParentPINStatusClient.hasPIN(
                                        baseURL: APIClient.currentBaseURL,
                                        childDeviceID: childID
                                    )
                                }
                            )
                        }
                    }
```

Add the status client to the bottom of `Evlin iOS/Services/ParentPINUploader.swift`:

```swift
/// Status-only read. The child surface never returns the value, so this can
/// answer "has my PIN already been uploaded?" without exposing it.
enum ParentPINStatusClient {
    static func hasPIN(baseURL: String, childDeviceID: UUID) async -> Bool {
        guard var comps = URLComponents(string: "\(baseURL)/child/device/parent-pin-status")
        else { return false }
        comps.queryItems = [URLQueryItem(name: "child_device_id", value: childDeviceID.uuidString)]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["parent_pin_status"] as? String
        else { return false }
        return status == "available" || status == "unrecoverable"
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ParentPINBackfillTests' 2>&1 | grep -E "Test Case.*(passed|failed)|TEST" | tail -10
```

Expected: 4 passed, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Benchmark before enabling 7–8 digits**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ParentPINRecoveryTests' 2>&1 | grep "seconds" | tail -6
```

Record the per-test durations. `autoMaxLength` stays at 6 unless a real-device run shows a full 8-digit sweep (1.1×10⁸ hashes) completing within a few foreground passes at acceptable power. Do not raise it on simulator numbers.

- [ ] **Step 7: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && git add "Evlin iOS/Services/ParentPINBackfill.swift" "Evlin iOS/Services/ParentPINUploader.swift" "Evlin iOS/Evlin_iOSApp.swift" "Evlin iOSTests/ParentPINBackfillTests.swift" && git commit -m "feat(pin): recover and upload pre-existing PINs on foreground"
```

---

### Task 11: Parent device detail shows the PIN

**Files:**
- Modify: `Evlin iOS/Views/Home/HomeSettingsSheet.swift:1272-1318` (`deviceDetailMenu`), `Evlin iOS/Models/ProfileMockData.swift` (`EnrolledDeviceDTO` decoding)
- Test: `Evlin iOSTests/ParentPINRowTests.swift`

**Interfaces:**
- Consumes: `EnrolledDeviceDTO.parent_pin_status`, `.parent_pin` (Task 4).
- Produces: `enum ParentPINRow { static func display(status:pin:kidName:) -> (title: String, subtitle: String, value: String?) }`.

- [ ] **Step 1: Write the failing tests**

Create `Evlin iOSTests/ParentPINRowTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class ParentPINRowTests: XCTestCase {

    func testAvailableShowsTheValue() {
        let row = ParentPINRow.display(status: "available", pin: "48267", kidName: "Maya")
        XCTAssertEqual(row.value, "48267")
    }

    func testNotSetTellsTheParentWhereToCreateIt() {
        let row = ParentPINRow.display(status: "not_set", pin: nil, kidName: "Maya")
        XCTAssertNil(row.value)
        XCTAssertEqual(row.subtitle, "Create it in Parent Controls on Maya's phone.")
    }

    func testPendingSyncDoesNotClaimAValue() {
        // The row must not imply the PIN is knowable yet — the kid's phone has
        // not uploaded it.
        let row = ParentPINRow.display(status: "pending_sync", pin: nil, kidName: "Maya")
        XCTAssertNil(row.value)
        XCTAssertEqual(row.subtitle, "Will appear when Maya's phone syncs.")
    }

    func testUnrecoverableIsHonestRatherThanBlank() {
        let row = ParentPINRow.display(status: "unrecoverable", pin: nil, kidName: "Maya")
        XCTAssertNil(row.value)
        XCTAssertEqual(row.title, "Set on device — value not recoverable")
        XCTAssertEqual(row.subtitle, "Ask Maya to reset it in Parent Controls.")
    }

    func testAvailableWithoutAValueDegradesToPending() {
        // Trusting the status over a missing value keeps the UI from rendering
        // an empty monospaced box that looks like a bug.
        let row = ParentPINRow.display(status: "available", pin: nil, kidName: "Maya")
        XCTAssertNil(row.value)
        XCTAssertEqual(row.subtitle, "Will appear when Maya's phone syncs.")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ParentPINRowTests' 2>&1 | tail -20
```

Expected: build FAILS — `ParentPINRow` does not exist.

- [ ] **Step 3: Write the row model**

Create `Evlin iOS/Views/Home/ParentPINRow.swift`:

```swift
import Foundation

/// Copy for the parent-facing Parent PIN row. Rendering is driven by the
/// status, never by value presence: a missing value can mean "never set",
/// "not uploaded yet", or "not recoverable", and those read very differently
/// to a parent trying to get into Parent Controls.
enum ParentPINRow {

    static func display(
        status: String,
        pin: String?,
        kidName: String
    ) -> (title: String, subtitle: String, value: String?) {
        let kid = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = kid.isEmpty ? "your child" : kid

        switch status {
        case "available":
            guard let pin, !pin.isEmpty else {
                return ("Parent PIN", "Will appear when \(who)'s phone syncs.", nil)
            }
            return ("Parent PIN", "Set during setup on \(who)'s phone.", pin)
        case "pending_sync":
            return ("Parent PIN", "Will appear when \(who)'s phone syncs.", nil)
        case "unrecoverable":
            return ("Set on device — value not recoverable",
                    "Ask \(who) to reset it in Parent Controls.", nil)
        default:
            return ("Not set", "Create it in Parent Controls on \(who)'s phone.", nil)
        }
    }
}
```

- [ ] **Step 4: Add the fields to the DTO and render the section**

In `Evlin iOS/Models/ProfileMockData.swift`, add to the `EnrolledDeviceDTO` declaration:

```swift
    let parent_pin_status: String?
    let parent_pin: String?
```

In `Evlin iOS/Views/Home/HomeSettingsSheet.swift`, inside `deviceDetailMenu`, replace the whole `Section("Device Inventory") { … }` block (both rows are `Not wired` placeholders with `disabled: true` — dead UI) with:

```swift
            Section("Security") {
                let row = ParentPINRow.display(
                    status: device.parent_pin_status ?? "not_set",
                    pin: device.parent_pin,
                    kidName: child.display_name
                )
                settingsRow(
                    title: row.title,
                    subtitle: row.subtitle,
                    systemImage: "lock",
                    value: row.value.map { pinRevealed ? $0 : String(repeating: "•", count: $0.count) },
                    accent: .evSecondary
                )
                if row.value != nil {
                    Button(pinRevealed ? "Hide PIN" : "Show PIN") {
                        pinRevealed.toggle()
                    }
                }
            }
```

Add `@State private var pinRevealed = false` next to the other `@State` properties on the sheet.

- [ ] **Step 5: Run tests and build**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && xcodebuild test -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'Evlin iOSTests/ParentPINRowTests' 2>&1 | grep -E "Test Case.*(passed|failed)|TEST" | tail -10
```

Expected: 5 passed, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS" && git add "Evlin iOS/Views/Home/ParentPINRow.swift" "Evlin iOS/Views/Home/HomeSettingsSheet.swift" "Evlin iOS/Models/ProfileMockData.swift" "Evlin iOSTests/ParentPINRowTests.swift" && git commit -m "feat(pin): show the parent PIN on device detail and drop the dead inventory rows"
```

---

## Device acceptance (after Task 11)

Run on real hardware, not simulator. Each check is a separate observation — record what you saw, not what you expected.

1. **Clean onboarding.** Pair a fresh kid device. The last screen is "Two quick things and you're done"; Finish is disabled until both cards complete. Complete both, tap Finish, land in the kid app.
2. **The device is actually metering — a config row proves nothing.** A pool in the
   database only says the parent's side of the contract exists. Before believing the
   feature works, confirm on the device (metering diagnostics screen / black box) that
   all six hold:
   - local protocol selection is `v2` (not `v1` or `v2Pending`),
   - the current dated route lifecycle is `active`,
   - its install phase is `active` (not `planned` / `pendingStart`),
   - the daemon readback matches exactly (no `durableReadbackMismatch`),
   - the activation was acked by the backend,
   - and after opening a counted app for 6 minutes, real samples land — the
     device-day used minutes advance, not just per-app.

   If any of the first five is false, stop: the screen is reporting success the device
   cannot deliver, which is the precise failure shape this whole plan exists to avoid
   re-creating.
3. **The pool exists.** Query the child's config rows and confirm exactly one active row at 120 minutes — this proves `markChildAllSet` landed and the new contract provisioned:
   ```bash
   cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend && .venv/bin/python -c "
   import asyncio, asyncpg
   async def main():
       c = await asyncpg.connect('postgresql://ale_user:ale_pass@localhost:5433/ale_db')
       for r in await c.fetch('select p.display_name, cfg.daily_pool_minutes, cfg.enabled, cfg.superseded_at from evlin_earned_time_configs cfg join evlin_child_profiles p on p.id=cfg.child_profile_id order by cfg.created_at desc limit 5'):
           print(dict(r))
       await c.close()
   asyncio.run(main())"
   ```
4. **Restored device with a pool it already had.** This is the case the plan's earlier
   draft would have broken. Re-pair a device whose profile already has an active pool
   (so `child-all-set` provisions nothing and issues no config command), pick a tracking
   selection during the final step, and finish. Re-run every check in step 2. A route
   that is still `planned` here means the post-finish v2 reconcile did not take, and the
   kid is metering nothing while the screen says "done".
5. **PIN appears on the parent phone.** Open Settings → the kid → that device. The Security row shows the masked PIN; Show PIN reveals the digits the parent just typed.
6. **Backfill on an existing install.** On a device that already had a PIN before this build: update, open the kid app once, foreground it, then check the parent phone — the row moves from "Not set" to the real value.
7. **Failure is honest.** Stop the backend, create a PIN on a fresh kid device: the card shows "Couldn't save the PIN. Retry" and Finish stays disabled. Restart the backend, tap Retry, and it completes.

## Notes for the implementer

- Task 1 ships alone. It fixes a defect that exists today regardless of this feature, and keeping it in its own commit is what lets a later regression be attributed to one change rather than to "the onboarding rewrite".
- Task 8's extraction must not change the home card's UI, picker defaults, saved selection
  bytes, or validation. Its one deliberate runtime change is that both the home card and
  onboarding use `commit(then:)` to trigger the same v2 policy refresh; neither may call a
  private scheduler or wait silently for the next poll.
- **Arming is `MeteringProductionComposition.recoverFromSharedConfiguration`, and nothing else.** `EarnedBudgetArming.armIfReady()` still runs identity reconciliation, but on a v2-only build its arming half returns early at `EarnedBudgetScheduler.canInstallLegacyLadder` and never installs anything. Do not "fix" that by re-enabling the legacy ladder, and do not add a third arming path — reuse the one the state poller and `KidJoinMeteringBootstrap` already call.
- **A saved selection is not an armed route, and a pool row is not a metering device.** Every claim of success in this plan is checked against device state, not against the database. Step 2 of the acceptance list is the gate.
- `EvlinPINStore.shared` uses the App Group container, so a simulator rebuild keeps the PIN. Use a fresh `EvlinPINStore(account:)` in tests (as the tests above do) rather than clearing the shared one.
