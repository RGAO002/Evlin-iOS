# Metering Epoch Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan one task at a time, with a fresh worker and two-level review after each task. Workers operate sequentially in the existing main work directories, may not create worktrees, and may not delegate again.

**Goal:** Add the backend half of Metering Epoch v2: durable epoch provenance, per-device protocol ratcheting, strict sample trust with no five-minute allowance, canonical-day reconciliation, correct multi-device shared-pool fanout, and monotonic per-app command ordering. Keep all existing v1 clients working until each device successfully registers v2.

**Architecture:** The backend advertises a capability but does not infer client readiness. A device remains on v1 until one valid v2 epoch registration commits atomically with its per-device ratchet. Thereafter metadata-free v1 samples are terminal non-counted drops. Accepted v2 samples reference an immutable registered epoch and pass the Phase 1 pure trust function before any row, ledger, command, or notification mutation. Durable lock receipts independently represent device-cap and shared-pool exhaustion, while one device-side `earned_time` source is applied or removed according to the union of those receipts. A database-driven periodic reconciler owns canonical-day bootstrap, stale-epoch retirement, prior-day automatic release, task-bypass expiry, and incomplete shared-pool fanout retry.

**Tech Stack:** FastAPI, Pydantic v2, SQLAlchemy 2 async, PostgreSQL 15+, Alembic, pytest/pytest-asyncio, existing `BigKidStore`, `ActiveLockStore` command wire, APNs silent-wake scheduler, and the Phase 1 Python metering contract. The only iOS repository change in this phase is the byte-identical app-limit wire fixture; production Swift epoch handling belongs to Phase 3 and per-app command application belongs to Phase 4.

## Execution Preflight

Phase 2 must not begin while the preceding beta-agreement migration exists only as an untracked local file. The current working tree contains Fred's unrelated beta-agreement work, and this plan does not own, stage, amend, or commit it.

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
git ls-files \
  alembic/versions/2026_07_11_beta_agreement_acks.py \
  app/db/models/beta_agreement.py \
  app/api/routes/agreement.py
.venv/bin/alembic heads
```

Required before Task 1:

```text
alembic/versions/2026_07_11_beta_agreement_acks.py
app/api/routes/agreement.py
app/db/models/beta_agreement.py
2026_07_11_beta_acks (head)
```

If any path is absent from `git ls-files`, stop. Ask Fred to finish and commit the beta-agreement change first. Do not stage those files into a metering commit and do not create a sibling Alembic head from `2026_07_06_family_tz`.

After the predecessor is committed, record non-mutating recovery pointers:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
git stash create

cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git stash create
```

Save any printed SHAs in the Phase 2 report. `git stash create` must not be followed by `git stash push`, `git reset`, or checkout of unrelated files.

## Global Constraints

- Canonical product behavior is `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/docs/superpowers/specs/2026-07-15-metering-epoch-design.md`, especially Sections 3, 6, 7, 8, 10, 13, and Phase 2.
- The executable reference is the frozen 23-vector contract:
  - backend fixture: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json`
  - iOS fixture: `Evlin iOSTests/Fixtures/metering_epoch_vectors.json`
  - backend evaluator: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_epoch_contract.py`
- Execute sequentially in the existing main work directories. Do not create a worktree, stash away the live tree, reset, or discard unrelated changes.
- Never stage or modify the beta-agreement files, agreement/onboarding Swift files, Xcode user state, debugger data, or top-level iCloud-damaged repositories.
- Every backend DB test runs against a disposable local database created by `scripts/run_limits_db_regression.py`. Never point pytest at Render or Supabase production.
- Backend-first means wire-compatible code and migrations may ship before iOS v2, but this plan does not deploy, push to Render, change Render environment variables, upload TestFlight, or advertise v2 in production. Ask Fred first.
- `metering_epoch_advertised_version` defaults to `1`. Schema and code may be ready while every production device remains on v1.
- A device ratchet is monotonic. Effective protocol is `max(global_advertised_version, device.metering_protocol_version)` so a later environment rollback cannot make a ratcheted device accept unsafe v1 samples.
- No v2 registration may commit before every identity, canonical-day, policy, selection, enforcement-set, and base assertion passes.
- No rejected sample may insert a sample row, mutate an epoch, change a day/device ledger, queue a command, schedule APNs, emit a lock event, or alter a receipt.
- The old `offset + elapsed + 5` formula is removed. Both metadata-bearing v1 and v2 use the Phase 1 upper-bound function with default jitter 30 seconds and hard maximum 60 seconds.
- `offset`, accepted estimate, remaining minutes, callback counts, timestamps, gate state, and retries are mutable epoch state. None is epoch identity.
- A shared-pool receipt and a device-cap receipt are distinct durable causes even though both map to the device's single `earned_time` shield source.
- Manual, task-pause, reflection, block, and per-app `limit` sources are outside earned receipt reconciliation and must never be removed by it.
- App-limit ordering uses an explicit integer `ordering_token`. `updated_at` remains display/debug metadata only.
- New wire fields are additive. Existing fields and endpoints remain decodable by old clients.
- Every task follows red, green, focused refactor, full verification, staged-diff review, then commit.
- Before every commit:

```bash
git diff --cached --check
git diff --cached --stat
git diff --cached
```

The staged diff must contain only that task's files and hunks.

---

### Task 1: Add Epoch, Ratchet, Receipt, Day-Guard, and Ordering Schema

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/alembic/versions/2026_07_16_meter_epoch_v2.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/db/models/earned_time.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/db/models/device.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/db/models/app_limit_rule.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/db/models/__init__.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/account_deletion.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_models.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_models.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_app_limit_rules.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/api/test_account_deletion_endpoint.py`

**Interfaces and schema:**

Add `EarnedTimeMeteringEpoch` with table name exactly:

```python
__tablename__ = "evlin_earned_time_metering_epochs"
```

Required columns:

```text
id UUID primary key
family_id UUID not null -> evlin_families.id
child_profile_id UUID not null -> evlin_child_profiles.id
child_device_id UUID not null -> evlin_devices.id
protocol_version integer not null, exactly 2
usage_date date not null
canonical_timezone varchar(64) not null
policy_revision varchar(128) not null
measurement_selection_digest varchar(64) not null
enforcement_set_id UUID not null -> evlin_child_catalog_list.id
started_at timestamptz not null
registered_at timestamptz not null
base_accepted_minutes integer not null, 0 through 1440
last_raw_threshold_minutes integer not null, 0 through 1440
excluded_while_paused_minutes integer not null, 0 through 1440
status varchar(24) not null: active, paused, exhausted, retired
replacement_reason varchar(40) not null: the seven Phase 1 reasons
last_accepted_sample_at timestamptz nullable
retired_at timestamptz nullable
retire_reason varchar(40) nullable
created_at timestamptz not null
updated_at timestamptz not null
```

Indexes and constraints:

```text
uq_earned_time_metering_epochs_current_device:
  unique child_device_id where retired_at IS NULL

ix_earned_time_metering_epochs_scope_date:
  family_id, child_profile_id, child_device_id, usage_date

ck_earned_time_metering_epochs_digest:
  measurement_selection_digest matches exactly 64 lowercase hex characters

ck_earned_time_metering_epochs_retirement:
  status = retired exactly when retired_at is non-null
```

Do not make the stable key unique: `identity_recovery` and `gate_resume_exact_rebase` may intentionally create a new epoch with the same stable key after retiring the old instance.

Add these columns:

```python
Device.metering_protocol_version: int = 1  # database and ORM default, check 1..2
EarnedTimeSample.epoch_id: UUID | None  # FK to epoch table
EarnedTimeDeviceDay.day_rollover_command_id: UUID | None
EarnedTimeLockCommand.enforcement_set_id: UUID | None  # selected-set receipt target
EarnedTimeLockCommand.released_at: datetime | None
EarnedTimeLockCommand.release_command_id: UUID | None
AppLimitRule.ordering_token: int = 1  # BigInteger, database and ORM default, check >= 1
```

Export `EarnedTimeMeteringEpoch` from `app.db.models`.

Migration identifiers:

```python
revision = "2026_07_16_meter_epoch_v2"
down_revision = "2026_07_11_beta_acks"
```

- [ ] **Step 1: Write failing metadata tests**

In `tests/test_metering_epoch_models.py`, pin:

```python
def test_epoch_table_and_columns():
    assert EarnedTimeMeteringEpoch.__tablename__ == (
        "evlin_earned_time_metering_epochs"
    )
    assert {
        "id",
        "family_id",
        "child_profile_id",
        "child_device_id",
        "protocol_version",
        "usage_date",
        "canonical_timezone",
        "policy_revision",
        "measurement_selection_digest",
        "enforcement_set_id",
        "started_at",
        "registered_at",
        "base_accepted_minutes",
        "last_raw_threshold_minutes",
        "excluded_while_paused_minutes",
        "status",
        "replacement_reason",
        "last_accepted_sample_at",
        "retired_at",
        "retire_reason",
        "created_at",
        "updated_at",
    } == {column.key for column in EarnedTimeMeteringEpoch.__table__.columns}
```

Also assert the named constraints/indexes, exact partial-index predicate, UUID FK targets, defaults, and check ranges.

Extend existing model tests to pin:

```python
assert "metering_protocol_version" in Device.__table__.columns
assert "epoch_id" in EarnedTimeSample.__table__.columns
assert "day_rollover_command_id" in EarnedTimeDeviceDay.__table__.columns
assert {"enforcement_set_id", "released_at", "release_command_id"} <= {
    column.key for column in EarnedTimeLockCommand.__table__.columns
}
assert "ordering_token" in AppLimitRule.__table__.columns
```

Add an account-deletion regression that seeds a last-member family with:

```text
one child device and selected set
one earned config/day/device-day
one registered epoch
one sample linked to that epoch
one earned lock receipt
```

Deleting the final account must succeed and leave zero rows in every seeded
earned/epoch table. This test fails before the cascade order is updated.

- [ ] **Step 2: Run the metadata tests and confirm red**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python -m pytest \
  tests/test_metering_epoch_models.py \
  tests/test_earned_time_models.py \
  tests/test_app_limit_rules.py \
  -q
```

Expected: collection or assertions fail only because the new model and columns do not exist.

- [ ] **Step 3: Add the ORM model and additive migration**

Use SQLAlchemy named checks and indexes matching the tests. The migration must:

1. create `evlin_earned_time_metering_epochs`;
2. add the seven columns to existing tables;
3. backfill every existing device protocol to `1`;
4. backfill every existing app-limit rule ordering token to `1`;
5. set non-null/default constraints only after backfill;
6. create indexes and foreign keys;
7. downgrade in exact reverse dependency order.

Do not backfill legacy samples with an epoch ID; provenance cannot be inferred.

Update `_cascade_family` to delete earned rows before catalog lists, devices,
profiles, and the family. The exact dependency order is:

```text
evlin_earned_time_samples
evlin_earned_time_metering_epochs
evlin_earned_time_lock_commands
evlin_earned_time_device_days
evlin_earned_time_days
evlin_earned_time_device_caps
evlin_earned_time_configs
child catalog list members and lists
devices, profiles, family
```

Do not rely on ORM cascades or broad database `CASCADE`; the service already
uses an explicit auditable deletion order.

- [ ] **Step 4: Add a migration round-trip and single-head test**

DB-backed assertions:

```python
assert await scalar(
    "SELECT count(*) FROM information_schema.tables "
    "WHERE table_name = 'evlin_earned_time_metering_epochs'"
) == 1
assert await scalar(
    "SELECT count(*) FROM information_schema.columns "
    "WHERE table_name = 'evlin_devices' "
    "AND column_name = 'metering_protocol_version'"
) == 1
```

The test must run `upgrade head`, downgrade to `2026_07_11_beta_acks`, verify the Phase 2 table/columns are gone and the beta table remains, then upgrade to head again.

Also run:

```bash
.venv/bin/alembic heads
```

Expected exactly:

```text
2026_07_16_meter_epoch_v2 (head)
```

- [ ] **Step 5: Run isolated DB verification**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_models.py \
  tests/test_earned_time_models.py \
  tests/test_app_limit_rules.py \
  tests/api/test_account_deletion_endpoint.py
```

Expected: all selected tests pass and the temporary database is dropped.

- [ ] **Step 6: Commit only schema work**

```bash
git add \
  alembic/versions/2026_07_16_meter_epoch_v2.py \
  app/db/models/earned_time.py \
  app/db/models/device.py \
  app/db/models/app_limit_rule.py \
  app/db/models/__init__.py \
  app/services/account_deletion.py \
  tests/test_metering_epoch_models.py \
  tests/test_earned_time_models.py \
  tests/test_app_limit_rules.py \
  tests/api/test_account_deletion_endpoint.py
git diff --cached --check
git commit -m 'feat: add metering epoch schema'
```

---

### Task 2: Advertise Capability Only When Schema and Policy Identity Are Ready

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/core/settings.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_epoch_readiness.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_policy_identity.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/schemas/bigkid.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/bigkid_child.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/earned_time_service.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/earned_time.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/main.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_readiness.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_policy_identity.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_bigkid_endpoints.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_config.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_lifespan.py`

**Interfaces:**

Settings:

```python
metering_epoch_advertised_version: int = Field(default=1, ge=1, le=2)
```

Policy identity:

```python
@dataclass(frozen=True)
class MeteringPolicyIdentity:
    config_id: UUID
    cap_id: UUID | None

    @property
    def revision(self) -> str:
        return f"{self.config_id}:{self.cap_id if self.cap_id is not None else 'pool'}"


async def current_metering_policy_identity(
    session: AsyncSession,
    *,
    family_id: UUID,
    child_profile_id: UUID,
    child_device_id: UUID,
    usage_date: date,
) -> MeteringPolicyIdentity
```

Readiness:

```python
@dataclass(frozen=True)
class MeteringEpochSchemaReadiness:
    ready: bool
    missing: tuple[str, ...]


async def inspect_metering_epoch_schema(
    session: AsyncSession,
) -> MeteringEpochSchemaReadiness
```

The required-schema list is exact:

```text
table evlin_earned_time_metering_epochs
evlin_devices.metering_protocol_version
evlin_earned_time_samples.epoch_id
evlin_earned_time_device_days.day_rollover_command_id
evlin_earned_time_lock_commands.enforcement_set_id
evlin_earned_time_lock_commands.released_at
evlin_earned_time_lock_commands.release_command_id
evlin_app_limit_rules.ordering_token
```

Child-state wire additions:

```python
class EarnedTimeRuntimeState(BaseModel):
    policy_revision: str
    # existing fields remain unchanged


class ChildStateResponse(BaseModel):
    metering_protocol_version: int = Field(default=1, ge=1, le=2)
    # existing fields remain unchanged
```

The runtime revision is always built from the current active config and current device cap:

```python
revision = f"{config.id}:{cap.id if cap is not None else 'pool'}"
```

Effective advertised protocol:

```python
def effective_metering_protocol_version(device: Device) -> int:
    return max(
        settings.metering_epoch_advertised_version,
        device.metering_protocol_version,
    )
```

`earned_time_config` adds:

```json
{
  "earned_time_config": {
    "policy_revision": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:pool"
  }
}
```

Health adds without removing existing keys:

```json
{
  "status": "healthy",
  "gemini": "configured",
  "metering_epoch": {
    "configured_version": 1,
    "schema_ready": true,
    "missing": []
  }
}
```

- [ ] **Step 1: Add failing unit and route tests**

Pin:

1. settings default is `1`, env value `2` parses, `0` and `3` fail validation;
2. pool-only policy revision is `config UUID:pool`;
3. explicit cap revision is `config UUID:cap UUID`;
4. changing pool config ID or cap ID changes revision;
5. child-state default remains v1;
6. global version 2 advertises 2 to an unratcheted device;
7. a ratcheted device remains 2 when global setting returns to 1;
8. runtime includes the same policy revision as `earned_time_config`;
9. schema readiness reports every missing table/column by stable string;
10. startup with missing Phase 2 schema raises before any background loop starts,
    even while the advertised protocol remains 1;
11. startup with complete schema and configured version 1 reports
    `schema_ready=true` while unratcheted child state remains v1;
12. startup with complete schema and configured version 2 permits registration;
13. pool and cap config commands schedule one post-commit silent wake per target.

For scheduler coverage, spy on the request scheduler and assert the command is durable before the sender runs.

- [ ] **Step 2: Run focused tests and confirm red**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python -m pytest \
  tests/test_metering_epoch_readiness.py \
  tests/test_metering_policy_identity.py \
  tests/test_bigkid_endpoints.py \
  tests/test_earned_time_config.py \
  tests/test_metering_epoch_lifespan.py \
  -q
```

Expected: failures name the absent setting, wire fields, helper modules, readiness state, and config wake.

- [ ] **Step 3: Implement policy identity and child-state capability**

Reuse the same active-config and cap lookup semantics as `get_summary`; do not derive revision from mutable minutes or timestamps. Add `policy_revision` to `_earned_time_for_device` and `metering_protocol_version` to the returned state copy.

Pool `0` and cap `0` remain valid response values. Do not change the existing `ge=0` response guards.

- [ ] **Step 4: Make the Phase 2 binary fail closed on incomplete schema**

After migrations and `create_all`, inspect the schema using a real session:

```python
readiness = await inspect_metering_epoch_schema(session)
app.state.metering_epoch_readiness = readiness
if not readiness.ready:
    raise RuntimeError(
        "Metering Epoch Phase 2 schema is incomplete: "
        + ", ".join(readiness.missing)
    )
```

Do not treat `create_all` as an ALTER-table fallback. It cannot add the required
columns, and the new ORM models select those columns even while the wire
advertisement remains v1. Failing the new deploy lets Render retain the
previous working release instead of serving widespread missing-column 500s.

- [ ] **Step 5: Carry policy revision in config delivery and schedule its wake**

Update `_build_earned_time_config_command_payload` to call the policy identity helper and add `policy_revision`.

Update `_insert_earned_time_config_command` to use the currently bound scheduler:

```python
scheduler = get_request_scheduler()
if scheduler is not None:
    scheduler.enqueue(
        apns_token=child.apns_token,
        items=[SilentWakeItem(command_id=cmd.id, nag=False, display="Screen Time")],
    )
```

Change its signature to accept the loaded `child_device: Device`, rather than re-querying or accepting only an ID:

```python
async def _insert_earned_time_config_command(
    db: AsyncSession,
    *,
    family_id: UUID,
    child_device: Device,
    payload: dict[str, Any],
) -> Command
```

Bind `SilentWakeScheduler(background_tasks)` around the entire `put_pool_config` and `put_device_cap` service call, not only code after commands have already been inserted. Add `BackgroundTasks` to the cap route.

`earned_time_config` uses silent wake only. Do not classify it as a lock alert or visible nag.

- [ ] **Step 6: Run focused and DB-backed verification**

```bash
.venv/bin/python -m pytest \
  tests/test_metering_epoch_readiness.py \
  tests/test_metering_policy_identity.py \
  tests/test_metering_epoch_lifespan.py \
  -q

.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_bigkid_endpoints.py \
  tests/test_earned_time_config.py
```

Expected: all selected tests pass.

- [ ] **Step 7: Commit capability/readiness work**

```bash
git add \
  app/core/settings.py \
  app/services/metering_epoch_readiness.py \
  app/services/metering_policy_identity.py \
  app/schemas/bigkid.py \
  app/api/routes/bigkid_child.py \
  app/services/earned_time_service.py \
  app/api/routes/earned_time.py \
  app/main.py \
  tests/test_metering_epoch_readiness.py \
  tests/test_metering_policy_identity.py \
  tests/test_bigkid_endpoints.py \
  tests/test_earned_time_config.py \
  tests/test_metering_epoch_lifespan.py
git diff --cached --check
git commit -m 'feat: advertise metering epoch readiness'
```

---

### Task 3: Register Immutable Epochs and Ratchet Devices

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/schemas/earned_time.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_epoch_registry.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/earned_time.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_registration.py`

**Wire contract:**

```python
class EpochRegistrationReason(str, Enum):
    initial = "initial"
    day_rollover = "day_rollover"
    policy_change = "policy_change"
    selection_change = "selection_change"
    enforcement_set_change = "enforcement_set_change"
    identity_recovery = "identity_recovery"
    gate_resume_exact_rebase = "gate_resume_exact_rebase"


class EpochRegistrationRequest(BaseModel):
    protocol_version: Literal[2]
    epoch_id: UUID
    device_id: UUID
    usage_date: date
    timezone: str
    policy_revision: str = Field(min_length=1, max_length=128)
    measurement_selection_digest: str = Field(
        pattern=r"^[0-9a-f]{64}$"
    )
    enforcement_set_id: UUID
    started_at: datetime
    base_accepted_minutes: int = Field(ge=0, le=1440)
    reason: EpochRegistrationReason


class EpochRegistrationResponse(BaseModel):
    status: Literal["registered", "already_registered"]
    epoch_id: UUID
    metering_protocol_version: Literal[2]
    snapshot: DeviceDaySnapshot


class EpochRegistrationConflictResponse(BaseModel):
    code: Literal["authoritative_base_mismatch"]
    authoritative_snapshot: DeviceDaySnapshot
```

Route:

```text
POST /child/earned-time/epochs
X-Evlin-Child-Device-ID: device UUID
```

Registry interface:

```python
@dataclass(frozen=True)
class EpochRegistrationResult:
    status: Literal["registered", "already_registered"]
    epoch: EarnedTimeMeteringEpoch
    snapshot: DeviceDaySnapshot


class AuthoritativeBaseMismatch(Exception):
    snapshot: DeviceDaySnapshot


async def register_metering_epoch(
    session: AsyncSession,
    store: BigKidStore,
    *,
    child_device: Device,
    request: EpochRegistrationRequest,
    now_utc: datetime | None = None,
) -> EpochRegistrationResult
```

- [ ] **Step 1: Write failing registration tests**

Use fixed UUIDs and an injected UTC instant. Cover:

1. header/body mismatch returns 403 before registry call;
2. missing/non-child device returns 404;
3. first registration is rejected with 503 `metering_v2_not_advertised` while global version is 1;
4. valid registration at global version 2 inserts one epoch and atomically changes `Device.metering_protocol_version` from 1 to 2;
5. exact same request is idempotent and returns `already_registered`;
6. exact same epoch ID after that row has retired returns 409
   `epoch_retired`; registration never reactivates an old ID;
7. same epoch ID with another device/family/profile returns 409 and changes neither scope;
8. same epoch ID with mutated immutable fields returns 409;
9. client date differs from server canonical projection returns 409 `usage_date_mismatch`;
10. timezone differs from authoritative canonical timezone returns 409 `timezone_mismatch`;
11. `started_at` projects to another canonical day or lies in the future returns 409;
12. stale policy revision returns 409 `policy_revision_mismatch`;
13. enforcement set is absent, belongs to another device, is inactive, or is not the device's current selected set: 409;
14. base differs from committed device estimate: top-level HTTP 409 conflict body contains authoritative snapshot, no epoch row, no retirement, no ratchet;
15. declared replacement reason differs from Phase 1 `replacement_reason`: 409;
16. when the periodic reconciler already retired yesterday's epoch, the next
    registration is classified from that latest historical predecessor as
    `day_rollover`, never a second `initial`;
17. explicit `identity_recovery` and `gate_resume_exact_rebase` can replace the same stable key only after the current epoch is retired;
18. `gate_resume_exact_rebase` requires a paused predecessor and an open gate;
19. registration while the accounting gate is closed stores `status="paused"`; open gate stores `active`;
20. concurrent identical registrations produce one row and one ratchet.

The base-conflict assertion must decode this exact top-level shape, not FastAPI's default nested `detail`:

```json
{
  "code": "authoritative_base_mismatch",
  "authoritative_snapshot": {
    "estimated_minutes": 10
  }
}
```

- [ ] **Step 2: Run and confirm red**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_registration.py
```

Expected: failures are due to missing schema DTOs, route, and registry.

- [ ] **Step 3: Implement registry validation under a device row lock**

Start with:

```python
device = (
    await session.execute(
        select(Device)
        .where(Device.id == child_device.id)
        .with_for_update()
    )
).scalar_one()
```

Validation order:

1. global version 2 permits a device's first v2 registration; an already
   ratcheted device may register replacement epochs even if the global setting
   has been rolled back to 1;
2. epoch ID reuse/cross-scope check;
3. canonical timezone and date;
4. current policy revision;
5. current selected-set/enforcement-set identity;
6. authoritative committed base;
7. replacement reason;
8. gate-derived initial status.

Choose the replacement predecessor as the current unreleased epoch when one
exists; otherwise use the most recently registered historical epoch for the
device. With no history, only `initial` is valid. Construct the predecessor and
request `EpochKey` values and call Phase 1 `replacement_reason`. This preserves
`day_rollover`/policy/selection classification after the periodic reconciler
has already retired the old row. A new epoch with unchanged key is legal only
for the two explicit recovery reasons, and
`gate_resume_exact_rebase` additionally requires a paused predecessor plus an
open accounting gate.

Retire the old current row and insert the new row in the same transaction. Set:

```python
device.metering_protocol_version = 2
```

only after all validation passes.

Registration does not arm a monitor, count usage, queue locks, or schedule APNs.

- [ ] **Step 4: Return an actionable base conflict**

Catch `AuthoritativeBaseMismatch` in the route and return:

```python
return JSONResponse(
    status_code=409,
    content=jsonable_encoder(
        EpochRegistrationConflictResponse(
            code="authoritative_base_mismatch",
            authoritative_snapshot=exc.snapshot,
        )
    ),
)
```

Do not insert, retire, or ratchet on this branch. The future iOS client will create a new corrected epoch ID; it never edits an existing epoch.

- [ ] **Step 5: Run focused plus frozen protocol-vector tests**

```bash
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_registration.py

.venv/bin/python -m pytest \
  tests/test_metering_epoch_vector_contract.py \
  -q
```

Expected: all pass, including V19 and V20.

- [ ] **Step 6: Commit registration and ratchet**

```bash
git add \
  app/schemas/earned_time.py \
  app/services/metering_epoch_registry.py \
  app/api/routes/earned_time.py \
  tests/test_metering_epoch_registration.py
git diff --cached --check
git commit -m 'feat: register metering epochs'
```

---

### Task 4: Replace Sample Trust With the v1/v2 Ratcheted Adapter

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_epoch_contract.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/schemas/earned_time.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/earned_time.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/earned_time_service.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_vector_contract.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_sample.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_sample_adapter.py`

**Interfaces:**

Add optional fields:

```python
class SampleIngestRequest(BaseModel):
    protocol_version: Literal[2] | None = None
    epoch_id: UUID | None = None
    # every existing field remains
```

Extract the physical upper bound from `callback_verdict`:

```python
def physical_threshold_is_trustworthy(
    *,
    base_accepted_minutes: int,
    adjusted_estimate_minutes: int,
    started_at: datetime,
    callback_at: datetime,
    jitter_seconds: int = DEFAULT_JITTER_SECONDS,
) -> bool
```

Both `callback_verdict` and metadata-bearing legacy validation call this function. There is one formula:

```text
delta >= 0
delta * 60 <= elapsed_seconds + clamp(jitter_seconds, 0, 60)
```

Namespace parser:

```python
def earned_v2_event_namespace(
    *,
    activity_name: str,
    event_name: str,
    threshold_minutes: int,
) -> str | None:
    """Return 'evlin.earned.v2' only for generated earned activity plus exact tN."""
```

Legal inputs:

```text
activity_name = evlin.earned.budget followed by a dot and a valid UUID
event_name = evlin.earned.t followed by the exact threshold_minutes integer
```

The activity UUID is a generation identifier, not the epoch ID. Epoch identity is checked independently from `body.epoch_id`.

Change ingestion:

```python
async def ingest_sample(
    db: AsyncSession,
    child_device: Device,
    body: SampleIngestRequest,
    *,
    epoch_id: UUID | None = None,
) -> DeviceDaySnapshot
```

Persist `epoch_id` on accepted v2 sample rows; keep it null for legacy.

- [ ] **Step 1: Reverse the old five-minute tolerance tests**

The legacy case that currently accepts `t5` immediately after arm must become:

```python
def test_metadata_legacy_immediate_t5_is_rejected():
    assert physical_threshold_is_trustworthy(
        base_accepted_minutes=0,
        adjusted_estimate_minutes=5,
        started_at=datetime(2026, 7, 16, 12, 0, tzinfo=timezone.utc),
        callback_at=datetime(2026, 7, 16, 12, 0, tzinfo=timezone.utc),
    ) is False


def test_metadata_legacy_t5_after_five_minutes_is_accepted():
    assert physical_threshold_is_trustworthy(
        base_accepted_minutes=0,
        adjusted_estimate_minutes=5,
        started_at=datetime(2026, 7, 16, 12, 0, tzinfo=timezone.utc),
        callback_at=datetime(2026, 7, 16, 12, 5, tzinfo=timezone.utc),
    ) is True
```

Add a source guard:

```python
source = Path("app/api/routes/earned_time.py").read_text()
assert "+ 5" not in source
assert "maximum_trusted" not in source
```

- [ ] **Step 2: Add failing ratchet/side-effect matrix tests**

Cover:

| Device state | Request | Result |
|---|---|---|
| v1 | no generation metadata | existing compatibility behavior |
| v1 | both legacy generation fields | strict upper bound, no five-minute allowance |
| v1 | one legacy generation field only | `counted=false`, `warning=invalid_generation_metadata` |
| v1 | protocol 2 plus epoch ID | v2 validation |
| v1 | only one of protocol 2 / epoch ID | `counted=false`, `warning=invalid_protocol_metadata` |
| v2 ratcheted | metadata-free v1 | HTTP 200, `counted=false`, `warning=legacy_after_v2` |
| v2 ratcheted | valid active epoch | accepted only after trust and gate |

For every rejected row, snapshot before and after and assert:

```python
assert sample_count_after == sample_count_before
assert epoch_bytes_after == epoch_bytes_before
assert child_day_bytes_after == child_day_bytes_before
assert device_day_bytes_after == device_day_bytes_before
assert command_count_after == command_count_before
assert lock_receipt_count_after == lock_receipt_count_before
assert scheduled_wakes == []
```

V2 rejection cases:

```text
unknown epoch -> stale_epoch
retired epoch -> stale_epoch
wrong device owner -> owner_mismatch
wrong canonical date -> usage_date_mismatch
wrong policy revision -> policy_revision_mismatch
bad activity/event pair -> event_namespace_mismatch
negative adjusted delta -> implausible_threshold
too-early threshold -> implausible_threshold
```

Gate cases:

```text
trustworthy + gate closed:
  counted=false, warning=accounting_paused
  no sample/ledger/command mutation
  epoch status becomes paused
  last_raw_threshold_minutes advances monotonically
  excluded_while_paused_minutes advances by raw delta

gate reopened on paused epoch:
  counted=false, warning=gate_resume_rebase_required
  old epoch remains paused
  no ledger mutation
```

- [ ] **Step 3: Run and confirm red**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_earned_time_sample.py \
  tests/test_metering_epoch_sample_adapter.py

.venv/bin/python -m pytest \
  tests/test_metering_epoch_vector_contract.py \
  -q
```

Expected: old immediate-t5 assertion fails and the new adapter cases fail because the route still uses `_sample_is_plausible`.

- [ ] **Step 4: Implement protocol disposition before any gate or ledger call**

Order in `ingest_earned_time_sample`:

1. header/body identity;
2. load and lock the device;
3. determine complete protocol metadata shape;
4. call Phase 1 `protocol_disposition`;
5. terminal-drop ratcheted v1;
6. validate v1 or v2 physical/identity provenance;
7. evaluate accounting gate;
8. call ledger ingestion only for accepted, open-gate input;
9. commit;
10. return.

Do not call `usage_counting_allowed` before terminal protocol/identity rejection if doing so can hydrate or mutate process state for an invalid owner.

- [ ] **Step 5: Implement paused audit without accounting**

Under the epoch row lock:

```python
raw = max(epoch.last_raw_threshold_minutes, body.threshold_minutes)
ignored = max(0, raw - epoch.last_raw_threshold_minutes)
epoch.last_raw_threshold_minutes = raw
epoch.excluded_while_paused_minutes = min(
    1440,
    epoch.excluded_while_paused_minutes + ignored,
)
epoch.status = "paused"
```

This is the only rejected/non-counted branch allowed to mutate an epoch, and only after owner/date/policy/namespace/physical trust succeeds. It still must not write samples or ledgers.

- [ ] **Step 6: Persist accepted v2 provenance**

For accepted v2:

```python
result = await earned_time_service.ingest_sample(
    db=session,
    child_device=device,
    body=body,
    epoch_id=epoch.id,
)
epoch.last_raw_threshold_minutes = max(
    epoch.last_raw_threshold_minutes,
    body.threshold_minutes,
)
epoch.last_accepted_sample_at = body.observed_at
epoch.status = (
    "exhausted"
    if result.remaining_minutes == 0 or (
        result.cap_minutes is not None
        and result.estimated_minutes >= result.cap_minutes
    )
    else "active"
)
```

The ledger's accepted value remains monotonic within `(device, canonical usage_date)` and never uses a prior date as baseline.

- [ ] **Step 7: Run focused, vector, and legacy regression**

```bash
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_earned_time_sample.py \
  tests/test_metering_epoch_sample_adapter.py

.venv/bin/python -m pytest \
  tests/test_metering_epoch_vector_contract.py \
  -q
```

Expected: all pass; V04, V05, V08, V13, V19, and V20 remain green.

- [ ] **Step 8: Commit sample adapter**

```bash
git add \
  app/services/metering_epoch_contract.py \
  app/schemas/earned_time.py \
  app/api/routes/earned_time.py \
  app/services/earned_time_service.py \
  tests/test_metering_epoch_vector_contract.py \
  tests/test_earned_time_sample.py \
  tests/test_metering_epoch_sample_adapter.py
git diff --cached --check
git commit -m 'feat: validate ratcheted metering samples'
```

---

### Task 5: Make Device-Cap and Shared-Pool Locks Durable and Independently Reconciled

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/earned_time_lock_reconciler.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/earned_time_service.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/earned_time.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_auto_lock.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_lock_receipts.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_time_config.py`

**Interfaces:**

```python
class EarnedLockTrigger(str, Enum):
    device_cap_exhausted = "device_cap_exhausted"
    shared_pool_exhausted = "shared_pool_exhausted"


@dataclass(frozen=True)
class EarnedLockReconcileResult:
    shield_command_ids: tuple[UUID, ...]
    release_command_ids: tuple[UUID, ...]
    active_receipt_ids: tuple[UUID, ...]
    warnings_by_device: Mapping[UUID, str]


async def reconcile_earned_lock_receipts(
    session: AsyncSession,
    *,
    family_id: UUID,
    child_profile_id: UUID,
    usage_date: date,
    now_utc: datetime,
) -> EarnedLockReconcileResult


async def release_earned_lock_receipts_for_day(
    session: AsyncSession,
    *,
    family_id: UUID,
    child_profile_id: UUID,
    usage_date: date,
    now_utc: datetime,
) -> EarnedLockReconcileResult
```

Receipt key:

```python
def earned_receipt_key(
    *,
    family_id: UUID,
    child_profile_id: UUID,
    child_device_id: UUID,
    usage_date: date,
    trigger: EarnedLockTrigger,
) -> str:
    return (
        f"earned:v2:{family_id}:{child_profile_id}:{usage_date}:"
        f"{trigger.value}:{child_device_id}"
    )
```

Receipt semantics:

```text
trigger=device_cap_exhausted:
  desired only for that device when own estimate >= effective own cap

trigger=shared_pool_exhausted:
  desired for every enrolled child device when child used >= daily pool

day state override_unlocked:
  neither trigger is desired for the rest of that canonical day
```

Each active receipt stores the exact `enforcement_set_id` that its shield
command targeted. One `earned_time` source on one selected-set record is the
union of every unreleased receipt for the same
`(child_device_id, enforcement_set_id)` across usage dates. The date-specific
reconciler changes only the target date's receipts, then checks that
cross-date, same-record union before deciding whether a physical unshield is
legal:

Only rows whose idempotency key starts with `earned:v2:` are receipt state.
Legacy/debug rows in `evlin_earned_time_lock_commands` are ignored. Every new
v2 receipt has non-null `enforcement_set_id`, and all active v2 receipts for
one device must converge to that device's current selected-set ID.

```text
zero -> one active receipt: queue shield and store command on receipt
one -> two active receipts: do not queue duplicate shield; second receipt reuses active command ID
two -> one active receipt: release only the obsolete receipt; do not unshield device
one -> zero active receipts: queue one unshield with unlock_sources=["earned_time"]
```

`release_earned_lock_receipts_for_day` is a deliberate day-close operation. It
marks every unreleased receipt for that usage date released without consulting
the prior day's exhausted ledger, then applies the same cross-date source-union
decision. Therefore a new-day active receipt prevents an old-day release from
incorrectly removing `earned_time` from that same selected-set record.

When a desired receipt's current selected-set ID differs from its stored
`enforcement_set_id`, first release the old record by its stored ID, then apply
the source to the new record and update the receipt. Never guess the release
target from the device's latest selection.

`EarnedTimeDeviceDay.selected_lock_command_id` remains a compatibility mirror:

```text
any active earned receipt -> current shield command ID
no active earned receipt -> null
```

- [ ] **Step 1: Write failing attributed receipt tests**

Cover the frozen vector semantics with real rows/commands:

1. V14: A accepts five minutes; only A ledger changes, no lock receipt;
2. V15: A reaches own cap; exactly one A `device_cap_exhausted` receipt and one A shield, B untouched;
3. V16: shared pool reaches zero; A and B each get distinct `shared_pool_exhausted` receipts and child-targeted commands;
4. each receipt names device, `lock_source="earned_time"`, trigger, usage date, and command ID;
5. B missing selected set does not prevent A from locking, but `auto_lock_fanout_at` remains null and B warning is stable;
6. retry after B selection becomes executable creates only B's missing receipt/command and then sets `auto_lock_fanout_at`;
7. duplicate sample/reconcile produces no duplicate command;
8. active cap receipt followed by shared exhaustion adds a shared receipt without a second A shield command;
9. raising A cap while shared pool remains exhausted releases cap receipt but sends no unshield;
10. restoring shared headroom while A cap remains exhausted releases shared receipt but sends no unshield;
11. removing the final active receipt queues exactly one earned-only unshield and clears the compatibility mirror;
12. manual and task-pause sources are not included in `unlock_sources`;
13. day override releases all earned receipts across siblings, queues exactly
    one earned-only marker/unshield command per enrolled device, and suppresses
    reactivation that day;
14. an override with no pre-existing day row bootstraps the real active
    config's pool and canonical timezone, never the current 1440/UTC sentinel;
15. an override with no active receipt still queues one marker-bearing command
    per device so the foreground executor/NSE persists
    `earned.overridden.<usage_date>`;
16. each override command retains
    `earned_override_usage_date`, `unlock_sources=["earned_time"]`, and optional
    selected-set identity; receipt integration must not replace it with a plain
    unshield;
17. explicit prior-day release ignores the old exhausted ledger;
18. prior-day release does not unshield when a current-day earned receipt is
    already active for the same device;
19. release uses the receipt's stored enforcement-set ID even if the device's
    current selected set changed;
20. retargeting a still-desired receipt releases the old selected-set record
    and applies the new one exactly once;
21. legacy lock-log rows without the `earned:v2:` prefix or enforcement set do
    not count as active receipts;
22. `_maybe_queue_auto_lock` no longer exists or has any caller; there is one
    earned automatic-lock writer;
23. concurrent reconciliation produces one row per idempotency key.

Assertions must inspect target identity, not only counts:

```python
assert receipt.child_device_id == device_a.id
assert receipt.trigger == "device_cap_exhausted"
assert receipt.lock_source == "earned_time"
assert receipt.enforcement_set_id == device_a_list.id
assert command.target_device_id == device_a.id
assert command.payload["target"]["list_id"] == str(device_a_list.id)
```

- [ ] **Step 2: Run and confirm red**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_earned_time_auto_lock.py \
  tests/test_earned_time_lock_receipts.py \
  tests/test_earned_time_config.py
```

Expected: shared fanout and source-union cases fail because `_maybe_queue_auto_lock` only targets the reporting device and uses one compatibility guard.

- [ ] **Step 3: Implement receipt reconciliation under profile/day serialization**

Acquire:

```python
await session.execute(
    text("SELECT pg_advisory_xact_lock(hashtext(:key))"),
    {"key": f"earned-lock:{child_profile_id}:{usage_date.isoformat()}"},
)
```

Then lock the child-day, all device-days, and existing receipts. Compute desired receipts entirely from durable rows. Do not use process-local state as an idempotency guard.

When a desired receipt does not exist, insert it with the stable idempotency key. When it exists with `released_at` set and becomes desired again, reopen the same row by clearing release fields and assigning the new/current shield command. The row is a durable current-day receipt, not an immutable command history.

If selection is missing/tokenless:

- set exhaustion timestamps as appropriate;
- return `selected_set_missing` or `selected_set_tokenless`;
- leave receipt inactive with no command;
- do not mark shared fanout complete.

- [ ] **Step 4: Replace `_maybe_queue_auto_lock` with the reconciler**

After ledger recomputation in `ingest_sample`, call:

```python
lock_result = await reconcile_earned_lock_receipts(
    db,
    family_id=family_id,
    child_profile_id=child_profile_id,
    usage_date=usage_date,
    now_utc=now_utc,
)
```

Return the reporting device's warning, if any, in `DeviceDaySnapshot.warning`.

Add `BackgroundTasks` to the sample route and bind `SilentWakeScheduler` around the complete ingestion transaction. Commands must be committed before FastAPI runs scheduled wake tasks.

- [ ] **Step 5: Route config changes and override through the same source-union logic**

For effective-today pool/cap edits:

1. persist policy and config command;
2. recompute current desired receipts using the new policy;
3. queue only the source-union delta.

Replace bespoke `selected_lock_command_id` clearing/unshield decisions in pool/cap raise paths with the reconciler.

Delete `_maybe_queue_auto_lock` after all call sites move. Add a source guard
asserting the symbol is absent so a future edit cannot silently restore the
second writer.

In `apply_override`, bootstrap a missing row from the active
`EarnedTimeConfig` for that date: real `daily_pool_minutes`, real canonical
timezone, `used_minutes=0`, and `remaining_minutes=daily_pool_minutes`. Remove
the 1440/UTC sentinel.

In `queue_earned_override_releases`, mark current-day receipts released, but
retain the existing `queue_earned_override_release` wire contract. Queue exactly
one marker-bearing command per enrolled device even when no receipt existed or
the selected-set ID is absent. Link the command to any receipt released for
that device. The receipt service decides source-union state; the override
helper owns the mandatory day marker and must remain in the same transaction
as `EarnedTimeDay.state="override_unlocked"`.

When shared exhaustion ceases to be desired, clear
`EarnedTimeDay.auto_lock_fanout_at`. Set it only when every currently enrolled
device has an active shared-pool receipt backed by an executable selected set.

- [ ] **Step 6: Run receipt, config, override, and vector verification**

```bash
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_earned_time_auto_lock.py \
  tests/test_earned_time_lock_receipts.py \
  tests/test_earned_time_config.py \
  tests/test_earned_time_policy_summary.py

.venv/bin/python -m pytest \
  tests/test_metering_epoch_vector_contract.py \
  -q
```

Expected: all pass; V14, V15, and V16 attributed observations match device and enforcement-set identity.

- [ ] **Step 7: Commit lock receipt/fanout work**

```bash
git add \
  app/services/earned_time_lock_reconciler.py \
  app/services/earned_time_service.py \
  app/api/routes/earned_time.py \
  tests/test_earned_time_auto_lock.py \
  tests/test_earned_time_lock_receipts.py \
  tests/test_earned_time_config.py
git diff --cached --check
git commit -m 'fix: reconcile earned lock receipts'
```

---

### Task 6: Reconcile Canonical Day, Task Bypass, Epoch Retirement, and Fanout Periodically

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/metering_day_reconciler.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/bigkid_task_persistence.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/main.py`
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_day_reconciler.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_task_lock_service.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_task_gated_lock_routes.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_lifespan.py`

**Interfaces:**

```python
@dataclass(frozen=True)
class MeteringDayReconcileResult:
    child_profile_id: UUID
    usage_date: date
    bootstrapped_device_ids: tuple[UUID, ...]
    retired_epoch_ids: tuple[UUID, ...]
    rollover_command_ids: tuple[UUID, ...]
    expired_bypass_task_ids: tuple[UUID, ...]
    lock_result: EarnedLockReconcileResult


async def reconcile_profile_canonical_day(
    session: AsyncSession,
    store: BigKidStore,
    *,
    child_profile_id: UUID,
    now_utc: datetime,
) -> MeteringDayReconcileResult


async def run_metering_day_reconciliation_once(
    session_factory,
    store: BigKidStore,
    *,
    now_utc: datetime | None = None,
    sender=None,
) -> tuple[MeteringDayReconcileResult, ...]
```

Task persistence helper:

```python
async def expire_prior_day_task_bypasses(
    session: AsyncSession,
    store: BigKidStore,
    *,
    child_device_id: UUID,
    canonical_usage_date: date,
    canonical_timezone: str,
) -> tuple[UUID, ...]
```

For an approved bypass whose `responded_at` canonical date is before today:

```python
task.bypass.status = BypassStatus.withdrawn
task.status = TaskStatus.todo
task.phase = TaskPhase.input
```

An approved legacy payload with `responded_at=None` has no provable day scope;
treat it as stale and withdraw it on the next reconciliation rather than
allowing a permanent bypass.

Persist the full updated `task_json`, hydrate the in-memory store, then call `reconcile_task_lock`.

- [ ] **Step 1: Add failing virtual-clock and concurrency tests**

Use injected `now_utc`; no `date.today()`, sleeps, or wall clock.

Cover:

1. first write of a canonical day bootstraps one `EarnedTimeDay` from active config and one `EarnedTimeDeviceDay` per enrolled child device;
2. child day starts with `used=0`, `remaining=daily_pool`, `state=available`, canonical timezone;
3. device day starts with `estimated=0`, current cap/fallback pool, canonical timezone;
4. old-date epoch is retired once with `retire_reason=day_rollover`;
5. timezone or policy revision mismatch retires current epoch once with the matching reason;
6. prior-day earned receipts release; manual/task-pause receipts/sources remain untouched;
7. exactly one `earned_time_config` command per device/day is queued and its ID is stored in `day_rollover_command_id`;
8. repeated runs and two concurrent workers do not duplicate day rows, config commands, receipt transitions, or task commands;
9. approved task bypass remains effective on its responded canonical date;
10. D+1 changes bypass to withdrawn, task to todo/input, persists JSON, and re-applies task pause when Daily Screen Time is enabled;
11. an approved bypass with no `responded_at` is withdrawn instead of lasting
    forever;
12. reflection still keeps accounting paused independently;
13. incomplete shared fanout from Task 5 is retried;
14. device timezone `Asia/Tokyo`, canonical timezone `America/New_York`: Tokyo midnight does nothing; New York midnight reconciles exactly once;
15. canonical timezone changes while device timezone stays fixed: old epoch retires, old bypass/override markers do not migrate, and the new projected date is used;
16. a future-only config does not bootstrap today's day or send today's
    command;
17. two unsuperseded configs on different effective dates resolve the latest
    row effective on or before canonical today exactly once;
18. worker commits before `CollectedSilentWakeScheduler.drain`;
19. cancellation cleanly stops the loop.

- [ ] **Step 2: Run and confirm red**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_day_reconciler.py \
  tests/test_task_lock_service.py \
  tests/test_task_gated_lock_routes.py

.venv/bin/python -m pytest tests/test_metering_epoch_lifespan.py -q
```

Expected: failures identify the missing reconciler, bypass expiry, loop, and day guard.

- [ ] **Step 3: Bootstrap with durable upsert and lock guards**

Query distinct child profiles that have an enabled, unsuperseded earned-time
config. For each profile:

1. resolve canonical timezone with
   `screen_time_clock.canonical_timezone_for_child`;
2. project `today` from injected `now_utc`;
3. resolve exactly one active config with `_load_active_config(..., as_of=today)`;
4. skip a profile that has only future-dated configs;
5. acquire the profile/date advisory transaction lock;
6. upsert child-day with `ON CONFLICT DO NOTHING`;
7. lock/read it;
8. enumerate currently enrolled child devices;
9. upsert each device-day with `ON CONFLICT DO NOTHING`;
10. lock/read device-days.

Process-local `BigKidStore` is hydrated input for task state only; it is never a once-per-day guard.

- [ ] **Step 4: Retire stale epochs and queue one day-state command**

Retire an active epoch when any of these differ from current authority:

```text
usage_date
canonical_timezone
policy_revision
```

Do not create a new epoch on behalf of the client. Phase 3 owns registration. Queue an `earned_time_config` command so the child learns the new day/policy and can register.

Use `day_rollover_command_id` as the durable per-device/day command guard. If the referenced command is absent due to rollback/data repair, clear the stale guard and recreate once.

- [ ] **Step 5: Expire bypasses and reconcile automatic lock state**

For every device:

```python
expired = await expire_prior_day_task_bypasses(
    session,
    store,
    child_device_id=device.id,
    canonical_usage_date=today,
    canonical_timezone=config.timezone,
)
await reconcile_task_lock(
    session,
    store,
    child_device_id=device.id,
    usage_date=today,
    now_utc=now_utc,
)
```

Call `release_earned_lock_receipts_for_day` for every prior canonical date that
still has an unreleased receipt, then call `reconcile_earned_lock_receipts` for
the current day to retry incomplete cap/shared fanout. Do not infer old-day
release by re-evaluating the old exhausted ledger. Do not remove manual,
reflection, block, task-pause, or limit sources.

- [ ] **Step 6: Add the 60-second background loop**

In `app/main.py`:

```python
_METERING_DAY_RECONCILE_INTERVAL_SECONDS = 60


async def _metering_day_reconcile_loop() -> None:
    while True:
        try:
            await run_metering_day_reconciliation_once(
                get_session_factory(),
                get_store(),
            )
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("metering day reconciliation failed")
        await asyncio.sleep(_METERING_DAY_RECONCILE_INTERVAL_SECONDS)
```

`run_metering_day_reconciliation_once` must:

1. create `CollectedSilentWakeScheduler`;
2. bind it while mutating/queueing;
3. commit each successful transaction;
4. call `await scheduler.drain(sender=sender)` only after commit.

Start the task in lifespan and explicitly cancel/await it on shutdown.

- [ ] **Step 7: Run day, task, vector, and lifespan tests**

```bash
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_day_reconciler.py \
  tests/test_task_lock_service.py \
  tests/test_task_gated_lock_routes.py

.venv/bin/python -m pytest \
  tests/test_metering_epoch_vector_contract.py \
  tests/test_metering_epoch_lifespan.py \
  -q
```

Expected: all pass; V09, V11, V12, V21, and V22 remain green.

**Lock-protocol completion gate:** Any change to the earned-profile advisory
lock or its row-lock ordering/strength must rerun all lock-related suites in
one disposable PostgreSQL invocation. Separate green runs do not satisfy this
gate:

```bash
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_earned_time_lock_receipts.py \
  tests/test_metering_epoch_registration.py \
  tests/test_earned_time_sample.py \
  tests/test_metering_day_reconciler.py
```

- [ ] **Step 8: Commit canonical-day reconciler**

```bash
git add \
  app/services/metering_day_reconciler.py \
  app/services/bigkid_task_persistence.py \
  app/main.py \
  tests/test_metering_day_reconciler.py \
  tests/test_task_lock_service.py \
  tests/test_task_gated_lock_routes.py \
  tests/test_metering_epoch_lifespan.py
git diff --cached --check
git commit -m 'feat: reconcile canonical metering day'
```

---

### Task 7: Version Every Per-App Set and Clear Command

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/child_device.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_app_limit_delivery.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_app_limit_wire_contract.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/api/test_app_limits_endpoint.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/app_limit_wire.json`
- Modify: `Evlin iOSTests/Fixtures/app_limit_wire.json`

**Wire and response additions:**

```python
class AppLimitRuleResponse(BaseModel):
    ordering_token: int


class AppLimitRuleUpdateResponse(BaseModel):
    ordering_token: int
```

Nested command fields:

```json
{
  "limit": {
    "ordering_token": 2
  },
  "clear": {
    "ordering_token": 3
  }
}
```

Helper:

```python
def advance_app_limit_ordering(rule: AppLimitRule) -> int:
    rule.ordering_token += 1
    return rule.ordering_token
```

The helper may only run after the route holds the same child `Device` row lock used for app-limit write serialization.

Emission rules:

```text
new active rule: token 1, set_limit carries 1
repeat POST/update that emits set: increment then emit
PATCH active -> disabled: increment then emit clear_limit
PATCH disabled -> active: increment then emit set_limit
DELETE: lock device, increment, disable, emit clear_limit
PATCH with no enforcement change: do not increment and do not emit
```

- [ ] **Step 1: Update the canonical fixture first and make both contract tests red**

Add concrete values:

```json
"ordering_token": 2
```

to `set_limit.limit`, and:

```json
"ordering_token": 3
```

to `clear_limit.clear`.

Copy exact bytes between repositories; do not independently reformat.

Run:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_app_limit_wire_contract.py

cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/AppLimitWireContractTests
```

Expected: backend emission fails because `ordering_token` is missing. Existing Swift decode remains compatible because unknown nested fields are ignored in Phase 2.

- [ ] **Step 2: Add failing endpoint/concurrency tests**

Cover:

1. create emits token 1;
2. budget edit emits token 2;
3. window/timezone edit emits next token;
4. rapid two edits serialize and emit distinct increasing tokens;
5. active-to-disabled PATCH emits `clear_limit` with the next token;
6. disabled-to-active emits `set_limit` with the next token;
7. DELETE takes `_lock_child_alias_scope` before mutation and emits next-token clear;
8. no-op/display-only edit keeps token and emits no command;
9. response/list output includes current token;
10. delivery order `set 2`, `set 1`, `clear 3`, `set 2`, `clear 3` matches V23's newest-wins contract;
11. `updated_at` equality under rapid writes does not affect token ordering.

The backend does not persist the device-side tombstone in this task. Phase 4 consumes and enforces the token on iOS.

- [ ] **Step 3: Run and confirm red**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_app_limit_delivery.py \
  tests/test_app_limit_wire_contract.py \
  tests/api/test_app_limits_endpoint.py
```

Expected: token, PATCH-disable clear, and delete-serialization assertions fail.

- [ ] **Step 4: Implement serialized token advancement**

Ensure POST, PATCH, and DELETE all acquire `_lock_child_alias_scope` before loading the final mutable rule state.

For POST, resolve whether the active unique-key rule already exists while that
device lock is held. A newly inserted rule keeps its database default token
`1`; a repeat POST that reuses an existing rule advances once before emitting
the replacement `set_limit`. Do not infer "new" from timestamps after the
upsert.

Change both existing payload helpers without removing or renaming any current
wire field:

- in `_limit_payload_for_rule(rule: AppLimitRule, used_today_minutes: int = 0)`,
  insert `"ordering_token": rule.ordering_token` immediately after `rule_id`;
- in `_clear_payload_for_rule(rule: AppLimitRule, *, reason: str)`, insert
  `"ordering_token": rule.ordering_token` immediately after `rule_id`.

PATCH must distinguish:

```python
should_emit_clear_limit = currently_active and not will_be_active
```

If true, advance once and queue `clear_limit` with reason `parent_disabled`.

DELETE currently loads/disables without `_lock_child_alias_scope`; fix that race before incrementing.

- [ ] **Step 5: Verify wire parity and ordering**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_app_limit_delivery.py \
  tests/test_app_limit_wire_contract.py \
  tests/api/test_app_limits_endpoint.py

.venv/bin/python -m pytest \
  tests/test_metering_epoch_vector_contract.py \
  -q

cmp \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/app_limit_wire.json \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/'Evlin iOSTests/Fixtures/app_limit_wire.json'

cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/AppLimitWireContractTests
```

Expected: all pass; `cmp` is silent and exits 0; V23 stays green.

- [ ] **Step 6: Commit backend then iOS fixture separately**

Backend:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
git add \
  app/api/routes/child_device.py \
  tests/test_app_limit_delivery.py \
  tests/test_app_limit_wire_contract.py \
  tests/api/test_app_limits_endpoint.py \
  tests/fixtures/app_limit_wire.json
git diff --cached --check
git commit -m 'feat: version app limit commands'
```

iOS fixture only:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add 'Evlin iOSTests/Fixtures/app_limit_wire.json'
git diff --cached --check
git commit -m 'test: pin app limit ordering token'
```

Do not stage `APIClient.swift`, onboarding, agreement, Xcode user-state, or debugger files.

---

### Task 8: Prove Integrated Phase 2 Behavior and Record a Rollout Gate

**Files:**
- Create: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_metering_epoch_phase2_integration.py`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/scripts/run_limits_db_regression.py`
- Create: `.superpowers/sdd/metering-epoch-phase2-report.md`

**Integrated scenario:**

Use one family, one child profile, two child devices A/B, two executable selected sets, pool 15, A cap 10, B cap 15, fixed canonical timezone `America/New_York`, and fixed timestamps.

The scenario must prove:

1. backend default advertises v1 and old sample still works before ratchet;
2. configured v2 permits A and B registration with separate epoch IDs;
3. immediate A t5 is rejected with zero effects;
4. physically valid A t5 counts once;
5. A device-day becomes 5, B remains 0, child used becomes 5;
6. A reaches cap 10 and only A receives a cap receipt/shield;
7. B contributes 5, shared pool reaches 15, and both A/B receive shared receipts;
8. A does not get a duplicate shield when shared receipt joins its active cap receipt;
9. every command target, selected-set ID, trigger, receipt, and epoch attribution is exact;
10. an old v1 sample after ratchet is terminal `legacy_after_v2`;
11. raising A cap releases only cap cause while shared cause keeps A locked;
12. override releases final earned causes on both devices but does not remove manual/task sources;
13. canonical D+1 retires both epochs, resets ledgers, expires task bypass, queues one config command/device, and can run twice without duplication;
14. Tokyo device-local midnight does not cause New York canonical rollover;
15. rapid app-limit set/clear commands carry increasing ordering tokens.

- [ ] **Step 1: Add the failing integration test**

Write one readable scenario plus narrowly named helper assertions. Do not mock SQLAlchemy, the lock reconciler, registry, sample adapter, command insertions, or periodic reconciler. Mock only APNs sender transport and use a real disposable Postgres database.

Assert exact attribution:

```python
assert {
    (
        row.child_device_id,
        row.trigger,
        row.lock_source,
        row.command_id,
    )
    for row in receipts
} == expected_receipts
```

- [ ] **Step 2: Add new Phase 2 tests to the disposable DB runner**

Append:

```python
"tests/test_metering_epoch_models.py",
"tests/test_metering_epoch_registration.py",
"tests/test_metering_epoch_sample_adapter.py",
"tests/test_earned_time_lock_receipts.py",
"tests/test_metering_day_reconciler.py",
"tests/test_metering_epoch_phase2_integration.py",
```

Keep the local-host and database-name safety checks unchanged.

- [ ] **Step 3: Run all Phase 2 backend gates**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend

.venv/bin/python -m pytest \
  tests/test_metering_epoch_vector_contract.py \
  tests/test_metering_epoch_readiness.py \
  tests/test_metering_policy_identity.py \
  -q

.venv/bin/python scripts/run_limits_db_regression.py

.venv/bin/alembic heads
```

Expected:

```text
all pure contract/readiness tests pass
all disposable limits DB regression tests pass
2026_07_16_meter_epoch_v2 (head)
```

- [ ] **Step 4: Run targeted existing backend regressions**

```bash
.venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_earned_time_sample.py \
  tests/test_earned_time_auto_lock.py \
  tests/test_earned_time_config.py \
  tests/test_earned_time_policy_summary.py \
  tests/test_task_lock_service.py \
  tests/test_task_gated_lock_routes.py \
  tests/test_app_limit_delivery.py \
  tests/test_app_limit_wire_contract.py \
  tests/api/test_app_limits_endpoint.py \
  tests/test_effective_state_sources.py
```

Expected: all selected tests pass. Any failure is investigated; do not relabel a new failure as historical without a pre-task baseline.

- [ ] **Step 5: Run iOS fixture compatibility**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
cmp \
  'Evlin iOSTests/Fixtures/metering_epoch_vectors.json' \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/metering_epoch_vectors.json

cmp \
  'Evlin iOSTests/Fixtures/app_limit_wire.json' \
  /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/fixtures/app_limit_wire.json

xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/MeteringEpochVectorCoverageTests \
  -only-testing:Evlin\ iOSTests/AppLimitWireContractTests
```

Expected: both `cmp` commands exit 0 and both selected XCTest suites pass.

- [ ] **Step 6: Review migration and rollout behavior without deploying**

With a disposable database:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
METERING_EPOCH_ADVERTISED_VERSION=1 \
  .venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_readiness.py \
  tests/test_bigkid_endpoints.py

METERING_EPOCH_ADVERTISED_VERSION=2 \
  .venv/bin/python scripts/run_limits_db_regression.py \
  tests/test_metering_epoch_readiness.py \
  tests/test_metering_epoch_registration.py
```

Confirm:

```text
version 1: schema ready but child state advertises 1 to unratcheted devices
version 2: schema ready and first v2 registration is allowed
ratcheted device: remains effective v2 if global setting returns to 1
```

Do not set `METERING_EPOCH_ADVERTISED_VERSION=2` on Render in this task.

- [ ] **Step 7: Write the completion report**

Create `.superpowers/sdd/metering-epoch-phase2-report.md` with:

```text
backend start/end commit
iOS start/end commit
recovery pointer SHAs
each task commit
exact test commands and counts
single Alembic head evidence
23-vector parity evidence
app-limit wire byte-parity evidence
known pre-existing failures, each backed by pre-task baseline
schema readiness result
configured protocol remains 1
no Render deployment
no TestFlight upload
no production data mutation
```

Also record the later rollout order, without executing it:

```text
1. merge backend code and migration
2. deploy backend with advertised version 1
3. verify /health says schema_ready true
4. ship Phase 3 iOS with v2 support but no device can ratchet while server advertises 1
5. ask Fred for explicit approval
6. set advertised version 2
7. monitor registration conflicts, terminal v1 drops, fanout receipts, and command acknowledgements
```

- [ ] **Step 8: Commit integration test, runner, and report**

Backend:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
git add \
  tests/test_metering_epoch_phase2_integration.py \
  scripts/run_limits_db_regression.py
git diff --cached --check
git commit -m 'test: prove metering epoch phase 2'
```

iOS report:

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
git add .superpowers/sdd/metering-epoch-phase2-report.md
git diff --cached --check
git commit -m 'docs: report metering epoch phase 2'
```

---

## Phase 2 Completion Gate

Phase 2 is complete only when all statements are backed by test output in the report:

- one Alembic head exists and the Phase 2 migration round-trips over the committed beta predecessor;
- `/child/state` remains v1 by default and exposes matching policy revision/config identity;
- first successful registration is the only per-device v2 ratchet;
- metadata-free v1 is counted before ratchet and terminally dropped after ratchet;
- immediate t5 is rejected and delayed physically possible t5 is accepted;
- rejected samples have zero ledger, row, command, receipt, APNs, and shield effects;
- device A usage never advances device B's device-day estimate;
- A cap locks only A;
- shared exhaustion creates independent durable A/B receipts and converges partial delivery;
- removing one automatic cause never unshields while another remains;
- canonical D+1 bootstraps zeroed rows, retires stale epochs, expires task bypass, re-reconciles task locks, and queues one state command/device;
- canonical timezone, not device timezone, owns rollover;
- every emitted per-app set and clear carries a strictly increasing integer ordering token;
- both shared fixture pairs are byte-identical;
- no production Swift epoch adapter, Render deployment, TestFlight upload, environment flip, or production DB repair occurred.

No physical-device action is required for Phase 2. Device implementation and physical metering gates resume in Phase 3.
