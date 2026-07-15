# Metering Epoch Phase 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the independently releasable display and Profile-button guardrails: device bars show own-cap usage only, the child-wide CTA changes only `manual`, and automatic lock reasons/actions are visible without overloading that CTA.

**Architecture:** Keep the existing child-wide manual endpoints and reconciliation machinery unchanged. Fix the pure device-bar projection, add a pure automatic-lock notice/action projection, and make the dedicated earned-time override endpoint complete: the same transaction writes the override and queues an earned-source-only unshield carrying canonical `usage_date` for every enrolled child device. Both foreground and NSE command paths validate and persist the child-local day override before removing the earned source, so a later extension callback cannot immediately re-lock. Then wire that dedicated action into `ProfileView`. The manual CTA never calls the override endpoint and never removes automatic sources.

**Tech Stack:** Swift with the current Xcode 26 toolchain (project language mode `SWIFT_VERSION=5.0`), SwiftUI, XCTest, FastAPI, SQLAlchemy, pytest, iOS/iPadOS 17.6 minimum deployment target.

## Global Constraints

- Canonical behavior is `docs/superpowers/specs/2026-07-15-metering-epoch-design.md` Sections 3.2, 3.6, and Phase 0.
- Execute sequentially in the existing main work directories. Do not create a worktree, stash, reset, or discard unrelated beta-agreement changes.
- Before Task 1, record recovery pointers without changing the worktree:

```bash
git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS stash create
git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend stash create
```

- `Evlin iOS/Services/APIClient.swift` already contains an unrelated agreement hunk. Stage only the new `usage_date` hunk with `git add -p`; never stage the whole file.
- The Profile CTA calls only `/parent/child/lock-selected` and `/parent/child/unlock-selected`. It never calls the legacy single-device unlock endpoint.
- Manual Lock/Unlock must not mutate task suppression, exhaustion override, pool/day/device ledgers, accepted estimates, offsets, epochs, arm state, or automatic sources.
- `POST /parent/earned-time/unlock-override` is the only Phase 0 automatic action. It sets the day override and queues `unlock_sources=["earned_time"]` plus `target.earned_override_usage_date=<canonical usage_date>` for every enrolled device. A known Locked-set ID is carried; without one the command is marker-only and never guesses an ID. It must never remove `manual` or `task_pause`.
- The override endpoint accepts only the child's current canonical usage date. A stale parent snapshot receives `409 stale_usage_date` before any row or command mutation.
- App and NSE execution validate the optional override date, require it to equal the current canonical usage date derived from the persisted runtime timezone, and write `earned.overridden.<usage_date>` before removing `.earnedTime`. They never fall back to `TimeZone.current`; a missing runtime timezone fails closed. The NSE additionally rechecks that the App Group device identity still matches the command target immediately before mutation. Invalid/stale/wrong-identity metadata fails closed; an absent field preserves legacy/config-raise release behavior.
- Rollout order is backend wire support first, then the iOS build on both parent and child devices. The optional field is decode-compatible with old clients, but an old child cannot provide the day-marker guarantee and must not be counted as Phase 0 acceptance evidence.
- Device row label is `min(shared remaining, own cap remaining)`; device row bar is `own cap remaining / own cap` and never consumes a sibling's minutes.
- Do not add a nested card inside the summary card. The automatic reason/action is one compact inline status row below the manual CTA.
- No production metering scheduler, generation, callback, sample-ingest, or usage-ledger math changes belong in this phase. Backend production changes are limited to completing the existing override transaction and carrying its date metadata; iOS production changes are limited to persisting that marker before the existing source-aware unshield.
- Every commit must pass `git diff --cached --check`, and staged diffs must contain only the task's files/hunks.

---

### Task 1: Make Device Bars Own-Cap-Only

**Files:**
- Modify: `Evlin iOS/Services/EarnedDisplayFormatters.swift:65-130`
- Test: `Evlin iOSTests/EarnedDisplayTests.swift:96-220`

**Interfaces:**
- Consumes: `remainingToCapMinutes`, `capMinutes`, optional shared-pool values already supplied by `ProfileView.deviceRemainingFraction(for:)`.
- Produces: unchanged signature `EarnedDisplayFormatters.deviceRemainingFraction(remainingToCapMinutes:capMinutes:overallRemainingMinutes:dailyPoolMinutes:) -> Double` with corrected D-12 semantics.

- [ ] **Step 1: Replace the clamped-bar assertions with own-cap assertions**

Update the existing device tests so labels remain shared-pool-clamped but bars do not:

```swift
func test_deviceRemaining_sharedPoolEmptyChangesLabelButNotOwnCapBar() {
    XCTAssertEqual(
        EarnedDisplayFormatters.deviceRemainingLabel(
            remainingToCapMinutes: 60,
            overallRemainingMinutes: 0,
            fallbackOverallLabel: "Time's up for today"
        ),
        "Time's up for today"
    )
    XCTAssertEqual(
        EarnedDisplayFormatters.deviceRemainingFraction(
            remainingToCapMinutes: 60,
            capMinutes: 65,
            overallRemainingMinutes: 0,
            dailyPoolMinutes: 120
        ),
        60.0 / 65.0,
        accuracy: 0.001
    )
}

func test_deviceRemaining_sharedPoolClampsLabelButUnusedDeviceBarStaysFull() {
    XCTAssertEqual(
        EarnedDisplayFormatters.deviceRemainingLabel(
            remainingToCapMinutes: 120,
            overallRemainingMinutes: 35,
            fallbackOverallLabel: "35m left"
        ),
        "35 mins left"
    )
    XCTAssertEqual(
        EarnedDisplayFormatters.deviceRemainingFraction(
            remainingToCapMinutes: 120,
            capMinutes: 120,
            overallRemainingMinutes: 35,
            dailyPoolMinutes: 120
        ),
        1.0,
        accuracy: 0.001
    )
}

func test_deviceRemaining_ownUsageStillShrinksOwnCapBar() {
    XCTAssertEqual(
        EarnedDisplayFormatters.deviceRemainingFraction(
            remainingToCapMinutes: 35,
            capMinutes: 60,
            overallRemainingMinutes: 50,
            dailyPoolMinutes: 120
        ),
        35.0 / 60.0,
        accuracy: 0.001
    )
}
```

Keep the existing missing-device fallback test: when there is no device row, the formatter may fall back to the shared-pool fraction because no own-cap projection exists.

- [ ] **Step 2: Run the focused test and verify the two changed assertions fail**

Run:

```bash
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/EarnedDisplayTests
```

Expected: FAIL because the current formatter returns `0` when shared remaining is zero and `35/120` for an unused 120-minute device under a 35-minute shared remainder.

- [ ] **Step 3: Correct only the bar projection**

Replace `deviceRemainingFraction` with:

```swift
/// Device-row progress is own-cap-only. Shared remaining may clamp the row's
/// label, but a sibling's usage must never shrink this device's bar.
static func deviceRemainingFraction(
    remainingToCapMinutes: Int?,
    capMinutes: Int?,
    overallRemainingMinutes: Int?,
    dailyPoolMinutes: Int?
) -> Double {
    guard let remainingToCapMinutes else {
        return remainingFraction(
            remainingMinutes: overallRemainingMinutes,
            dailyPoolMinutes: dailyPoolMinutes
        )
    }

    return remainingFraction(
        remainingMinutes: remainingToCapMinutes,
        dailyPoolMinutes: capMinutes ?? dailyPoolMinutes
    )
}
```

Do not change `deviceRemainingLabel`; its shared-pool clamp is intentional.

- [ ] **Step 4: Run focused display tests**

Run the Step 2 command again.

Expected: `EarnedDisplayTests` PASS.

- [ ] **Step 5: Commit the isolated formatter change**

```bash
git diff -- 'Evlin iOS/Services/EarnedDisplayFormatters.swift' 'Evlin iOSTests/EarnedDisplayTests.swift'
git add 'Evlin iOS/Services/EarnedDisplayFormatters.swift' 'Evlin iOSTests/EarnedDisplayTests.swift'
git diff --cached --check
git commit -m 'fix: keep device cap bars device-local'
```

---

### Task 2: Project Automatic Lock Reasons Separately From Manual State

**Files:**
- Create: `Evlin iOS/Models/AutomaticLockNotice.swift`
- Create: `Evlin iOSTests/AutomaticLockNoticeTests.swift`

**Interfaces:**
- Consumes: flattened wire `covering_sources`, earned summary `state/override_active/usage_date`.
- Produces:
  - `AutomaticLockNotice.make(coveringSources:exhausted:overrideActive:usageDate:) -> AutomaticLockNotice?`
  - `AutomaticLockNoticeAction.overrideEarnedTime(usageDate:)`
  - `AutomaticLockActionRunner.run(action:childProfileID:unlockOverride:) async throws`

- [ ] **Step 1: Write the projection and action-routing tests**

Create `AutomaticLockNoticeTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

@MainActor
final class AutomaticLockNoticeTests: XCTestCase {
    func test_manualOnly_hasNoAutomaticNotice() {
        XCTAssertNil(AutomaticLockNotice.make(
            coveringSources: ["manual"],
            exhausted: false,
            overrideActive: false,
            usageDate: nil
        ))
    }

    func test_exhausted_hasSeparateOverrideAction_evenBeforeLockReceiptArrives() {
        XCTAssertEqual(
            AutomaticLockNotice.make(
                coveringSources: [],
                exhausted: true,
                overrideActive: false,
                usageDate: "2026-07-15"
            ),
            AutomaticLockNotice(
                kind: .earnedTime,
                systemImage: "hourglass.bottomhalf.filled",
                message: "Screen time is used up for today.",
                actionTitle: "Override today",
                action: .overrideEarnedTime(usageDate: "2026-07-15")
            )
        )
    }

    func test_automaticSourceAliases_mapWithoutAffectingManualState() {
        XCTAssertEqual(
            AutomaticLockNotice.make(
                coveringSources: ["manual", "task_pause"],
                exhausted: false,
                overrideActive: false,
                usageDate: nil
            )?.kind,
            .taskPause
        )
        XCTAssertEqual(
            AutomaticLockNotice.make(
                coveringSources: ["earnedTime", "earned_pool", "device_cap"],
                exhausted: false,
                overrideActive: false,
                usageDate: nil
            )?.kind,
            .earnedTime
        )

        XCTAssertEqual(
            AutomaticLockNotice.make(
                coveringSources: ["task_pause"],
                exhausted: false,
                overrideActive: false,
                usageDate: nil
            )?.message,
            "Today's tasks are keeping apps locked. Review tasks below."
        )
    }

    func test_overrideAlreadyActive_hasNoSecondAction() {
        let notice = AutomaticLockNotice.make(
            coveringSources: ["earned_time"],
            exhausted: true,
            overrideActive: true,
            usageDate: "2026-07-15"
        )
        XCTAssertEqual(notice?.message, "Screen time override is applying.")
        XCTAssertNil(notice?.action)
    }

    func test_completeCoveringSources_preservesPriorStateUntilEveryDeviceReplies() {
        XCTAssertNil(AutomaticLockNotice.completeCoveringSources(
            expectedDeviceCount: 2,
            coveringSources: [["earned_time"], nil]
        ))
        XCTAssertEqual(
            AutomaticLockNotice.completeCoveringSources(
                expectedDeviceCount: 2,
                coveringSources: [["manual"], ["task_pause"]]
            ),
            ["manual", "task_pause"]
        )
    }

    func test_actionRunner_callsOnlyDedicatedOverrideClosure() async throws {
        let childID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let spy = OverrideCallSpy()

        try await AutomaticLockActionRunner.run(
            action: .overrideEarnedTime(usageDate: "2026-07-15"),
            childProfileID: childID
        ) { id, usageDate in
            await spy.record(id: id, usageDate: usageDate)
        }

        let calls = await spy.calls
        XCTAssertEqual(calls, [.init(childID: childID, usageDate: "2026-07-15")])
    }
}

private actor OverrideCallSpy {
    struct Call: Equatable { let childID: UUID; let usageDate: String }
    private(set) var calls: [Call] = []
    func record(id: UUID, usageDate: String) {
        calls.append(.init(childID: id, usageDate: usageDate))
    }
}
```

- [ ] **Step 2: Run the new test and verify it fails to compile**

```bash
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/AutomaticLockNoticeTests
```

Expected: FAIL with `Cannot find 'AutomaticLockNotice' in scope`.

- [ ] **Step 3: Add the pure notice and dedicated action router**

Create `AutomaticLockNotice.swift`:

```swift
import Foundation

nonisolated enum AutomaticLockNoticeAction: Equatable, Sendable {
    case overrideEarnedTime(usageDate: String)
}

nonisolated struct AutomaticLockNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case earnedTime
        case taskPause
    }

    let kind: Kind
    let systemImage: String
    let message: String
    let actionTitle: String?
    let action: AutomaticLockNoticeAction?

    static func make(
        coveringSources: [String],
        exhausted: Bool,
        overrideActive: Bool,
        usageDate: String?
    ) -> AutomaticLockNotice? {
        let sources = Set(coveringSources.map(normalize))

        let earnedSources: Set<String> = [
            "earnedtime", "earnedpool", "devicepool", "devicecap"
        ]
        if exhausted || !sources.isDisjoint(with: earnedSources) {
            if overrideActive {
                return .init(
                    kind: .earnedTime,
                    systemImage: "hourglass.bottomhalf.filled",
                    message: "Screen time override is applying.",
                    actionTitle: nil,
                    action: nil
                )
            }
            let action = usageDate.map(AutomaticLockNoticeAction.overrideEarnedTime)
            return .init(
                kind: .earnedTime,
                systemImage: "hourglass.bottomhalf.filled",
                message: exhausted
                    ? "Screen time is used up for today."
                    : "A screen time limit is keeping apps locked.",
                actionTitle: action == nil ? nil : "Override today",
                action: action
            )
        }

        if sources.contains("taskpause") {
            return .init(
                kind: .taskPause,
                systemImage: "checklist",
                message: "Today's tasks are keeping apps locked. Review tasks below.",
                actionTitle: nil,
                action: nil
            )
        }

        return nil
    }

    static func completeCoveringSources(
        expectedDeviceCount: Int,
        coveringSources: [[String]?]
    ) -> [String]? {
        guard expectedDeviceCount > 0,
              coveringSources.count == expectedDeviceCount,
              coveringSources.allSatisfy({ $0 != nil })
        else { return nil }
        return coveringSources.compactMap { $0 }.flatMap { $0 }
    }

    private static func normalize(_ source: String) -> String {
        source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}

@MainActor
enum AutomaticLockActionRunner {
    static func run(
        action: AutomaticLockNoticeAction,
        childProfileID: UUID,
        unlockOverride: (UUID, String) async throws -> Void
    ) async throws {
        switch action {
        case .overrideEarnedTime(let usageDate):
            try await unlockOverride(childProfileID, usageDate)
        }
    }
}
```

This projection is intentionally scoped to selected-set automatic provenance:
`earnedTime` and `taskPause`. The backend selected-set lock-state endpoint
deliberately does not treat all-app reflection records or exact-app limit
records as selected-set covers. Reflection already replaces `summaryCard` with
`ParentReflectionStatusCard`; per-app status remains on the device/App Limits
surface. Do not infer either from a missing/`manual` selected-set source.

- [ ] **Step 4: Run the new tests**

Run the Step 2 command again.

Expected: `AutomaticLockNoticeTests` PASS.

- [ ] **Step 5: Commit the pure model**

```bash
git add 'Evlin iOS/Models/AutomaticLockNotice.swift' 'Evlin iOSTests/AutomaticLockNoticeTests.swift'
git diff --cached --check
git commit -m 'feat: separate automatic lock presentation'
```

---

### Task 3: Make the Dedicated Override Actually Release Earned Locks

**Files:**
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/app_control_execution.py:276-310,418-552`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/services/earned_time_service.py:1863-1895`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/api/routes/earned_time.py:313-350`
- Modify: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/app/schemas/earned_time.py:208-225`
- Test: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_earned_override.py`

**Interfaces:**

```python
async def queue_earned_override_release(
    session: AsyncSession,
    *,
    family_id: UUID,
    child: Device,
    usage_date: date,
    list_id: UUID | None,
) -> Command

async def queue_earned_override_releases(
    db: AsyncSession,
    *,
    family_id: UUID,
    child_profile_id: UUID,
    usage_date: date,
) -> list[UUID]

async def unlock_override(
    db: AsyncSession,
    *,
    family_id: UUID,
    body: UnlockOverrideRequest,
    now_utc: datetime | None = None,
) -> UnlockOverrideResponse
```

The helper resolves every `Device(mode=child)` owned by the family/profile,
loads that device's selected set, and queues one saved-list `unshield` per
device with exactly `unlock_sources=["earned_time"]`; every command target also
carries `earned_override_usage_date=usage_date.isoformat()`. Missing
selected-set identity produces a marker-only command with `list_id=None`, not a
skip and not a guessed identity. The route binds the existing request-scoped
`SilentWakeScheduler`, applies the override, queues releases, and commits once.
Before any mutation, the service resolves the child's current date through
`screen_time_clock.child_today`; a request for any other day returns
`409 stale_usage_date`.

- [ ] **Step 1: Write failing multi-device and source-isolation tests**

Freeze this test module at a deterministic instant whose canonical New York day
is `2026-06-23`, then add the release tests:

```python
@pytest.fixture(autouse=True)
def _freeze_override_clock(monkeypatch):
    frozen = datetime(2026, 6, 23, 16, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "app.services.screen_time_clock.now_utc",
        lambda: frozen,
    )


async def test_unlock_override_queues_earned_only_release_for_every_device(
    session, client, monkeypatch
):
    family, profile, first = await _seed_family(session)
    first.apns_token = "token-first"
    second = Device(
        family_id=family.id,
        mode=DeviceMode.child,
        label="Kid iPad",
        child_profile_id=profile.id,
        apns_token="token-second",
    )
    session.add(second)
    await session.flush()
    lists = {
        first.id: await _seed_locked_set(
            session, family_id=family.id, child_device_id=first.id
        ),
        second.id: await _seed_locked_set(
            session, family_id=family.id, child_device_id=second.id
        ),
    }
    usage_date = date(2026, 6, 23)
    await _seed_exhausted_day(
        session,
        family_id=family.id,
        child_profile_id=profile.id,
        usage_date=usage_date,
    )
    await session.commit()

    scheduled: list[tuple[str | None, list]] = []

    class SpyScheduler:
        def __init__(self, background_tasks):
            self.background_tasks = background_tasks

        def enqueue(self, *, apns_token, items):
            scheduled.append((apns_token, items))

    monkeypatch.setattr(
        "app.api.routes.earned_time.SilentWakeScheduler", SpyScheduler
    )

    async with _authed_client(client, family_id=family.id) as c:
        response = await c.post(
            "/parent/earned-time/unlock-override",
            json={
                "child_profile_id": str(profile.id),
                "usage_date": str(usage_date),
            },
        )

    assert response.status_code == 200, response.text
    assert response.json()["state"] == "override_unlocked"
    commands = (
        await session.execute(
            select(Command).where(
                Command.target_device_id.in_([first.id, second.id])
            )
        )
    ).scalars().all()
    releases = [c for c in commands if c.payload.get("action") == "unshield"]
    assert {c.target_device_id for c in releases} == {first.id, second.id}
    assert len(releases) == 2
    for command in releases:
        assert command.payload["tier"] == "savedList"
        assert command.payload["unlock_sources"] == ["earned_time"]
        assert command.payload["target"]["unlock_sources"] == ["earned_time"]
        assert command.payload["target"]["earned_override_usage_date"] == str(
            usage_date
        )
        assert command.payload["target"]["list_id"] == str(
            lists[command.target_device_id].id
        )
        assert "manual" not in command.payload["unlock_sources"]
        assert "task_pause" not in command.payload["unlock_sources"]
    assert len(scheduled) == 2
    assert {token for token, _ in scheduled} == {"token-first", "token-second"}
    assert all(len(items) == 1 for _, items in scheduled)


async def test_unlock_override_missing_selected_set_still_sets_override(
    session, client, monkeypatch
):
    family, profile, device = await _seed_family(session)
    device.apns_token = "token-marker-only"
    usage_date = date(2026, 6, 23)
    await _seed_exhausted_day(
        session,
        family_id=family.id,
        child_profile_id=profile.id,
        usage_date=usage_date,
    )
    await session.commit()

    scheduled = []

    class SpyScheduler:
        def __init__(self, background_tasks):
            self.background_tasks = background_tasks

        def enqueue(self, *, apns_token, items):
            scheduled.append((apns_token, items))

    monkeypatch.setattr(
        "app.api.routes.earned_time.SilentWakeScheduler", SpyScheduler
    )

    async with _authed_client(client, family_id=family.id) as c:
        response = await c.post(
            "/parent/earned-time/unlock-override",
            json={
                "child_profile_id": str(profile.id),
                "usage_date": str(usage_date),
            },
        )

    assert response.status_code == 200, response.text
    assert response.json()["state"] == "override_unlocked"
    day = (
        await session.execute(
            select(EarnedTimeDay).where(
                EarnedTimeDay.family_id == family.id,
                EarnedTimeDay.child_profile_id == profile.id,
                EarnedTimeDay.usage_date == usage_date,
            )
        )
    ).scalar_one()
    assert day.exhaustion_override_at is not None
    commands = (await session.execute(select(Command))).scalars().all()
    releases = [c for c in commands if c.payload.get("action") == "unshield"]
    assert len(releases) == 1
    marker = releases[0]
    assert marker.target_device_id == device.id
    assert marker.payload["unlock_sources"] == ["earned_time"]
    assert marker.payload["target"]["unlock_sources"] == ["earned_time"]
    assert marker.payload["target"]["earned_override_usage_date"] == str(usage_date)
    assert marker.payload["target"]["list_id"] is None
    assert len(scheduled) == 1
    assert scheduled[0][0] == "token-marker-only"


async def test_unlock_override_rejects_stale_canonical_day_before_mutation(
    session, client
):
    family, profile, device = await _seed_family(session)
    stale_date = date(2026, 6, 22)
    await _seed_exhausted_day(
        session,
        family_id=family.id,
        child_profile_id=profile.id,
        usage_date=stale_date,
    )
    await session.commit()

    async with _authed_client(client, family_id=family.id) as c:
        response = await c.post(
            "/parent/earned-time/unlock-override",
            json={
                "child_profile_id": str(profile.id),
                "usage_date": str(stale_date),
            },
        )

    assert response.status_code == 409, response.text
    assert response.json()["detail"] == "stale_usage_date"
    await session.rollback()
    day = (
        await session.execute(
            select(EarnedTimeDay).where(
                EarnedTimeDay.family_id == family.id,
                EarnedTimeDay.child_profile_id == profile.id,
                EarnedTimeDay.usage_date == stale_date,
            )
        )
    ).scalar_one()
    assert day.state == "exhausted"
    assert day.exhaustion_override_at is None
    assert (await session.execute(select(Command))).scalars().all() == []
```

The first test seeds one exhausted child profile with two child devices and a
Locked set for each. After `POST /parent/earned-time/unlock-override`, assert:

- the day is `override_unlocked` with `exhaustion_override_at` set;
- exactly two new commands exist, one per device;
- every command has `action="unshield"`, `tier="savedList"`, and the correct device-local `list_id`;
- top-level and target `unlock_sources` are exactly `["earned_time"]`;
- target `earned_override_usage_date` is the request's canonical date;
- neither command contains `manual` or `task_pause`;
- command delivery was enrolled through the request scheduler (spy the scheduler enqueue), so force-killed devices have the existing NSE path available.

The second test seeds no selected set, expects HTTP 200 and the override row,
and asserts one marker-only command with `list_id=None`; this ensures a device
that gains a selection later that day still knows not to self-lock. The third
test proves a delayed parent snapshot cannot override yesterday or enqueue a
command that could unlock today's earned source.

- [ ] **Step 2: Run the tests and verify the release assertion fails**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
EVLIN_TEST_DATABASE_URL='postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test' \
  .venv/bin/pytest \
  tests/test_earned_override.py::test_unlock_override_queues_earned_only_release_for_every_device \
  tests/test_earned_override.py::test_unlock_override_missing_selected_set_still_sets_override \
  tests/test_earned_override.py::test_unlock_override_rejects_stale_canonical_day_before_mutation \
  -q
```

Expected: the release tests fail because the endpoint currently changes only
`EarnedTimeDay` and queues no unshield command; the stale-day test fails because
the endpoint currently accepts historical dates.

- [ ] **Step 3: Add the earned-only release helper**

In `app_control_execution.py`, add `date` to the datetime import and add
this specialized, wire-compatible command helper. It deliberately avoids
`_load_list` so a marker-only command can be delivered without inventing a
list identity:

```python
async def queue_earned_override_release(
    session: AsyncSession,
    *,
    family_id: UUID,
    child: Device,
    usage_date: date,
    list_id: UUID | None,
) -> Command:
    target = _base_target(
        child=child,
        target_type="list",
        display="Locked set",
        original_request="override today's screen time",
        force_downgrade=False,
        list_name="Locked set",
        list_id=list_id,
    )
    target["default_lock_group"] = True
    target["unlock_sources"] = ["earned_time"]
    target["earned_override_usage_date"] = usage_date.isoformat()
    payload = _payload(
        action="unshield",
        tier="savedList",
        target=target,
        duration_minutes=None,
    )
    payload["unlock_sources"] = ["earned_time"]
    command = await _insert_command(
        session,
        family_id=family_id,
        child=child,
        payload=payload,
    )
    _schedule_silent_wake(child, [command])
    return command
```

This helper is for explicit exhaustion override only. Do not call it from
policy-raise or manual-unlock paths.

Then import it beside `queue_app_control` and add this profile fanout helper
to `earned_time_service.py`:

```python
async def queue_earned_override_releases(
    db: AsyncSession,
    *,
    family_id: UUID,
    child_profile_id: UUID,
    usage_date: date,
) -> list[UUID]:
    devices = (
        await db.execute(
            select(Device)
            .where(
                Device.family_id == family_id,
                Device.child_profile_id == child_profile_id,
                Device.mode == DeviceMode.child,
            )
            .order_by(Device.id)
        )
    ).scalars().all()

    command_ids: list[UUID] = []
    for dev in devices:
        preview = await load_selected_set(
            db,
            family_id=family_id,
            child_device_id=dev.id,
        )
        command = await queue_earned_override_release(
            db,
            family_id=family_id,
            child=dev,
            usage_date=usage_date,
            list_id=preview.list_id if preview is not None else None,
        )
        command_ids.append(command.id)
    return command_ids
```

Then call it from `unlock_override` immediately after `apply_override`:

```python
day_row = await apply_override(
    db,
    family_id=family_id,
    child_profile_id=child_profile_id,
    usage_date_=usage_date_,
)
await queue_earned_override_releases(
    db,
    family_id=family_id,
    child_profile_id=child_profile_id,
    usage_date=usage_date_,
)
```

Before that call, add the canonical-day guard at the start of
`unlock_override`. The injectable instant is for deterministic service tests;
the route omits it and uses the clock authority:

```python
instant = now_utc or screen_time_clock.now_utc()
canonical_today = await screen_time_clock.child_today(
    db,
    child_profile_id,
    instant=instant,
)
if usage_date_ != canonical_today:
    raise HTTPException(status_code=409, detail="stale_usage_date")
```

This guard must execute before `apply_override`, device fanout, or any flush.
Update `UnlockOverrideResponse`'s schema comment: the response informs the
parent UI, while child-local suppression is written only by the app/NSE command
executor. The parent process cannot write a child's App Group.

Do not clear or rewrite manual/task records, task suppression, device-day
usage, estimates, or offsets. The marker-only payload has `list_id=None`;
never substitute a sibling list or a generated UUID.

- [ ] **Step 4: Bind delivery around the complete override transaction**

Add `background_tasks: BackgroundTasks` to `post_unlock_override`, then replace
the existing service call/commit with:

```python
with bind_request_scheduler(SilentWakeScheduler(background_tasks)):
    result = await earned_time_service.unlock_override(
        session,
        family_id=family_id,
        body=body,
    )
await session.commit()
return result
```

Authorization remains before the scheduler/service call. Do not reuse the
legacy `/parent/device/unlock-selected` route: that route removes multiple
sources and would violate the new manual-only CTA contract.

- [ ] **Step 5: Run the complete override suite**

```bash
EVLIN_TEST_DATABASE_URL='postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test' \
  .venv/bin/pytest tests/test_earned_override.py -q
```

Expected: all override tests pass, including existing ownership/day-scope
coverage and the two new release tests. Repeating the endpoint may enqueue an
additional idempotent earned-only unshield command; it must never broaden the
source list or rewrite metering data.

- [ ] **Step 6: Commit the backend change only**

```bash
git add app/services/app_control_execution.py \
        app/services/earned_time_service.py \
        app/api/routes/earned_time.py \
        app/schemas/earned_time.py \
        tests/test_earned_override.py
git diff --cached --check
git commit -m 'fix: release earned locks through override action'
```

---

### Task 4: Persist Override Metadata Before App/NSE Unshield

**Files:**
- Modify: `Evlin iOS/Models/CommandModels.swift:68-125`
- Create: `Evlin iOS/Models/NSECommandWireModels.swift`
- Modify: `Evlin iOS/Services/APIClient.swift:416-495`
- Modify: `Evlin iOS/Services/CommandPoller.swift:370-410`
- Modify: `Evlin iOS/Services/ActiveLockStore.swift:894-980`
- Modify: `Evlin iOS/Services/EarnedTimeStore.swift:857-872,1416-1425`
- Modify: `Evlin iOS/Services/ActionExecutor.swift:165-210,1049-1080`
- Modify: `EvlinPushApplier/NotificationService.swift:110-145,330-500`
- Modify: `Evlin iOS.xcodeproj/project.pbxproj`
- Test: `Evlin iOSTests/CommandProvenanceTests.swift`
- Test: `Evlin iOSTests/NSEUnshieldTests.swift`
- Test: `Evlin iOSTests/OverrideSuppressionTests.swift`

**Interfaces:**

```swift
// Optional wire metadata. Absent means an ordinary earned release, not an override.
CommandTarget.earnedOverrideUsageDate: String?

nonisolated enum EarnedOverrideCommandApplier {
    enum Outcome: Equatable, Sendable {
        case absent
        case applied(String)
        case invalid
    }

    static func applyIfPresent(
        _ command: LockCommand,
        currentUsageDate: String?,
        store: EarnedTimeStore
    ) -> Outcome
}

nonisolated enum NSECommandWireDecoder {
    static func decode(_ data: Data) throws -> LockCommand
}
```

The metadata is valid only when the command is saved-list `.unshield`,
`unlockSources == ["earned_time"]`, the value is canonical `yyyy-MM-dd`, and
it exactly equals the child's current canonical usage date.
That current date comes from a new strict store projection that returns `nil`
when `runtimeTimezoneIdentifier` is absent/invalid; it never uses the process
timezone fallback in `currentPolicyDateContext`.
When present and valid, both executors synchronously persist the App Group flag
before removing `.earnedTime`. A valid command with no list ID is marker-only
and confirms after persistence. When absent, existing policy-raise unshields
are unchanged. When present but invalid, execution fails before either
mutation. For the NSE path, `targetChildID`, the device ID used to fetch the
command, and the App Group's current device ID must all match immediately before
the marker write.

- [ ] **Step 1: Write failing wire, ordering, legacy, and fail-closed tests**

In `CommandProvenanceTests`, extend `pollJSON` with an optional target field and
pin the app poll path:

```swift
func test_overrideUsageDate_survivesPollDTOAndLockCommandMapping() throws {
    let dto = try decode(pollJSON(
        unlockSources: ["earned_time"],
        earnedOverrideUsageDate: "2026-07-15"
    ))
    let command = CommandPoller.lockCommand(from: dto)
    XCTAssertEqual(command.target.earnedOverrideUsageDate, "2026-07-15")
}

func test_absentOverrideUsageDate_staysNilForPolicyRaiseCompatibility() throws {
    let dto = try decode(pollJSON(unlockSources: ["earned_time"]))
    XCTAssertNil(CommandPoller.lockCommand(from: dto).target.earnedOverrideUsageDate)
}
```

Add the parameter to the helper and append it inside the target object:

```swift
private func pollJSON(
    topLevelLockSource: String? = nil,
    targetLockSource: String? = nil,
    unlockSources: [String]? = nil,
    earnedOverrideUsageDate: String? = nil
) -> Data {
    var topLevel = ""
    if let source = topLevelLockSource {
        topLevel = #","lock_source":"\#(source)""#
    }
    if let unlockSources {
        let values = unlockSources.map { #""\#($0)""# }.joined(separator: ",")
        topLevel += #","unlock_sources":[\#(values)]"#
    }

    var targetExtra = ""
    if let source = targetLockSource {
        targetExtra += #","lock_source":"\#(source)""#
    }
    if let earnedOverrideUsageDate {
        targetExtra += #","earned_override_usage_date":"\#(earnedOverrideUsageDate)""#
    }
    let action = unlockSources == nil ? "shield" : "unshield"
    let request = unlockSources == nil ? "lock games" : "unlock games"

    return Data("""
    {
      "command_id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
      "action": "\(action)",
      "tier": "savedList",
      "issued_at": "2026-01-01T00:00:00Z",
      "target": {
        "list_id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
        "list_name": "Games",
        "original_request": "\(request)"\(targetExtra)
      }\(topLevel)
    }
    """.utf8)
}
```

In `OverrideSuppressionTests`, replace the obsolete test that simulates the
parent process writing the child's App Group directly. Use a unique suite and
pin metadata validation plus foreground ordering. Update the file header too:
the writer is now the child command executor/NSE using the backend canonical
date, not `ProfileView` using `TimeZone.current`.

```swift
func test_currentCanonicalPolicyUsageDate_requiresRuntimeTimezone() {
    let store = EarnedTimeStore(
        suiteName: "test.override.no-runtime-tz.\(UUID().uuidString)",
        useInProcessLock: true
    )

    XCTAssertNil(store.currentCanonicalPolicyUsageDate(
        now: Date(timeIntervalSince1970: 1_768_436_400)
    ))
    store.removeAll()
}

func test_currentCanonicalPolicyUsageDate_ignoresDeviceTimezone() {
    let store = EarnedTimeStore(
        suiteName: "test.override.canonical-tz.\(UUID().uuidString)",
        useInProcessLock: true
    )
    let instant = ISO8601DateFormatter().date(
        from: "2026-07-16T02:00:00Z"
    )!
    XCTAssertEqual(
        store.reconcileRuntimePolicy(
            usageDate: "2026-07-15",
            timezoneIdentifier: "America/New_York",
            poolMinutes: 120,
            capMinutes: 120,
            remainingMinutes: 120,
            estimatedMinutes: 0,
            syncedAt: instant
        ),
        .reconciled(0)
    )

    XCTAssertEqual(
        store.currentCanonicalPolicyUsageDate(now: instant),
        "2026-07-15"
    )
    XCTAssertEqual(
        EarnedTimeStore.appLimitUsageDate(
            now: instant,
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        ),
        "2026-07-16"
    )
    store.removeAll()
}

@MainActor
func test_foregroundOverrideCommand_persistsFlagBeforeEarnedSourceRemoval() async throws {
    let suite = "test.override.foreground.\(UUID().uuidString)"
    let earnedStore = EarnedTimeStore(
        suiteName: suite,
        useInProcessLock: true
    )
    earnedStore.removeAll()
    _ = await ActiveLockStore.shared.unshieldAll()

    let listID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
    let record = makeEarnedRecord(listID: listID)
    _ = await ActiveLockStore.shared.addShield(record)
    var overrideWasSetAtRemoval = false
    let executor = ActionExecutor(
        authorizationStatusProvider: { .approved },
        earnedTimeStore: earnedStore,
        overrideUsageDateProvider: { "2026-07-15" },
        afterMutationCheckpoint: { checkpoint in
            if checkpoint == .unshieldRemoved {
                overrideWasSetAtRemoval = earnedStore.isOverridden(
                    forUsageDate: "2026-07-15"
                )
            }
        }
    )
    let result = await executor.execute(
        makeEarnedOverrideCommand(
            listID: listID,
            usageDate: "2026-07-15"
        ),
        expectedChildID: overrideDeviceID,
        identityIsCurrent: { $0 == overrideDeviceID }
    )

    guard case .confirmedExact(let verb, _, _) = result else {
        return XCTFail("Expected an exact unshield confirmation, got \(result)")
    }
    XCTAssertEqual(verb, .unshield)
    XCTAssertTrue(overrideWasSetAtRemoval)
    XCTAssertTrue(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
    XCTAssertFalse(EarnedSampleReporter.shouldApplyEarnedShield(
        thresholdN: 120,
        effectiveCap: 60,
        usageDate: "2026-07-15",
        store: earnedStore
    ))
    _ = await ActiveLockStore.shared.unshieldAll()
    earnedStore.removeAll()
}

@MainActor
func test_foregroundMarkerOnlyOverride_persistsAndConfirmsWithoutListID() async {
    let earnedStore = EarnedTimeStore(
        suiteName: "test.override.marker.\(UUID().uuidString)",
        useInProcessLock: true
    )
    let executor = ActionExecutor(
        authorizationStatusProvider: { .approved },
        earnedTimeStore: earnedStore,
        overrideUsageDateProvider: { "2026-07-15" }
    )
    let command = LockCommand(
        id: UUID(),
        action: .unshield,
        tier: .savedList,
        target: CommandTarget(
            listName: "Locked set",
            listID: nil,
            originalRequest: "override today's screen time",
            targetDisplay: "Screen time override",
            targetChildID: overrideDeviceID,
            unlockSources: ["earned_time"],
            earnedOverrideUsageDate: "2026-07-15"
        ),
        durationMinutes: nil,
        issuedAt: Date()
    )

    let result = await executor.execute(
        command,
        expectedChildID: overrideDeviceID,
        identityIsCurrent: { $0 == overrideDeviceID }
    )

    guard case .confirmedExact(let verb, _, _) = result else {
        return XCTFail("Expected marker-only override confirmation, got \(result)")
    }
    XCTAssertEqual(verb, .unshield)
    XCTAssertTrue(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
    earnedStore.removeAll()
}

@MainActor
func test_foregroundPriorDayOverride_failsBeforeMarkerOrUnshield() async {
    let earnedStore = EarnedTimeStore(
        suiteName: "test.override.stale-day.\(UUID().uuidString)",
        useInProcessLock: true
    )
    let executor = ActionExecutor(
        authorizationStatusProvider: { .approved },
        earnedTimeStore: earnedStore,
        overrideUsageDateProvider: { "2026-07-15" }
    )

    let result = await executor.execute(
        makeEarnedOverrideCommand(
            listID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            usageDate: "2026-07-14"
        ),
        expectedChildID: overrideDeviceID,
        identityIsCurrent: { $0 == overrideDeviceID }
    )

    guard case .failed(.malformed) = result else {
        return XCTFail("Expected stale override metadata to fail closed")
    }
    XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-14"))
    earnedStore.removeAll()
}

@MainActor
func test_foregroundMissingCanonicalTimezone_failsBeforeOverrideMarker() async {
    let earnedStore = EarnedTimeStore(
        suiteName: "test.override.missing-tz.\(UUID().uuidString)",
        useInProcessLock: true
    )
    let executor = ActionExecutor(
        authorizationStatusProvider: { .approved },
        earnedTimeStore: earnedStore
    )

    let result = await executor.execute(
        makeEarnedOverrideCommand(
            listID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            usageDate: "2026-07-15"
        ),
        expectedChildID: overrideDeviceID,
        identityIsCurrent: { $0 == overrideDeviceID }
    )

    guard case .failed(.malformed) = result else {
        return XCTFail("Expected missing canonical timezone to fail closed")
    }
    XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
    earnedStore.removeAll()
}

@MainActor
func test_foregroundIdentitySwitch_failsBeforeOverrideMarker() async {
    let earnedStore = EarnedTimeStore(
        suiteName: "test.override.stale-identity.\(UUID().uuidString)",
        useInProcessLock: true
    )
    let executor = ActionExecutor(
        authorizationStatusProvider: { .approved },
        earnedTimeStore: earnedStore,
        overrideUsageDateProvider: { "2026-07-15" }
    )

    _ = await executor.execute(
        makeEarnedOverrideCommand(
            listID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            usageDate: "2026-07-15"
        ),
        expectedChildID: overrideDeviceID,
        identityIsCurrent: { _ in false }
    )

    XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
    earnedStore.removeAll()
}

private let overrideDeviceID =
    UUID(uuidString: "00000000-0000-0000-0000-000000000400")!

private func makeEarnedRecord(listID: UUID) -> ShieldRecord {
    ShieldRecord(
        recordKey: ShieldRecord.makeRecordKey(
            tier: .savedList,
            targetKey: listID.uuidString
        ),
        tier: .savedList,
        targetKey: listID.uuidString,
        displayName: "Locked set",
        lastCommandID: UUID(),
        appTokens: [],
        categoryTokens: [],
        webDomainTokens: [],
        appliesToAll: true,
        issuedAt: Date(),
        expiresAt: nil,
        originalRequest: "automatic earned lock",
        targetChildID: overrideDeviceID,
        sources: [.earnedTime]
    )
}

private func makeEarnedOverrideCommand(
    listID: UUID,
    usageDate: String
) -> LockCommand {
    LockCommand(
        id: UUID(),
        action: .unshield,
        tier: .savedList,
        target: CommandTarget(
            listName: "Locked set",
            listID: listID,
            originalRequest: "override today's screen time",
            targetDisplay: "Locked set",
            targetChildID: overrideDeviceID,
            unlockSources: ["earned_time"],
            earnedOverrideUsageDate: usageDate
        ),
        durationMinutes: nil,
        issuedAt: Date()
    )
}
```

Keep these helpers local to `OverrideSuppressionTests`; do not add test-only
convenience to production `AckResult`.

In `NSEUnshieldTests`, add seven tests with an isolated `ActiveLockStore` and a
unique `EarnedTimeStore` suite:

```swift
func test_nseWireAndApply_persistsOverrideThenRemovesEarnedOnly() async throws {
    let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
        usageDate: "2026-07-15"
    ))
    XCTAssertEqual(command.target.earnedOverrideUsageDate, "2026-07-15")

    let activeStore = ActiveLockStore()
    let earnedStore = makeEarnedStore()
    let record = makeMixedRecord()
    _ = await activeStore.addShield(record)
    let outcome = await NSEUnshieldCommandApplier.apply(
        command,
        recordKey: record.recordKey,
        store: activeStore,
        earnedTimeStore: earnedStore,
        fetchedDeviceID: overrideDeviceID,
        currentDeviceID: overrideDeviceID,
        currentUsageDate: "2026-07-15"
    )

    XCTAssertEqual(outcome, .confirmed)
    XCTAssertTrue(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
    let snapshot = await activeStore.allCurrent()
    let remaining = try XCTUnwrap(snapshot.shields.first {
        $0.recordKey == record.recordKey
    })
    XCTAssertEqual(remaining.sources, [.manual])
    earnedStore.removeAll()
}

func test_nseInvalidOverrideDate_failsBeforeRemovingSource() async throws {
    let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
        usageDate: "not-a-date"
    ))
    let activeStore = ActiveLockStore()
    let earnedStore = makeEarnedStore()
    let record = makeMixedRecord()
    _ = await activeStore.addShield(record)

    let outcome = await NSEUnshieldCommandApplier.apply(
        command,
        recordKey: record.recordKey,
        store: activeStore,
        earnedTimeStore: earnedStore,
        fetchedDeviceID: overrideDeviceID,
        currentDeviceID: overrideDeviceID,
        currentUsageDate: "2026-07-15"
    )

    XCTAssertNil(outcome)
    XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "not-a-date"))
    let snapshot = await activeStore.allCurrent()
    let unchanged = try XCTUnwrap(snapshot.shields.first {
        $0.recordKey == record.recordKey
    })
    XCTAssertEqual(unchanged.sources, [.manual, .earnedTime])
    earnedStore.removeAll()
}

func test_nseMarkerOnlyOverride_persistsWithoutListIdentity() async throws {
    let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
        usageDate: "2026-07-15",
        listID: nil
    ))
    XCTAssertNil(command.target.listID)
    let activeStore = ActiveLockStore()
    let earnedStore = makeEarnedStore()

    let outcome = await NSEUnshieldCommandApplier.apply(
        command,
        recordKey: ShieldRecord.makeRecordKey(
            tier: .savedList,
            targetKey: "?"
        ),
        store: activeStore,
        earnedTimeStore: earnedStore,
        fetchedDeviceID: overrideDeviceID,
        currentDeviceID: overrideDeviceID,
        currentUsageDate: "2026-07-15"
    )

    XCTAssertEqual(outcome, .confirmed)
    XCTAssertTrue(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
    let snapshot = await activeStore.allCurrent()
    XCTAssertTrue(snapshot.shields.isEmpty)
    earnedStore.removeAll()
}

func test_nsePriorDayOverride_failsBeforeMarkerOrSourceRemoval() async throws {
    let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
        usageDate: "2026-07-14"
    ))
    let activeStore = ActiveLockStore()
    let earnedStore = makeEarnedStore()
    let record = makeMixedRecord()
    _ = await activeStore.addShield(record)

    let outcome = await NSEUnshieldCommandApplier.apply(
        command,
        recordKey: record.recordKey,
        store: activeStore,
        earnedTimeStore: earnedStore,
        fetchedDeviceID: overrideDeviceID,
        currentDeviceID: overrideDeviceID,
        currentUsageDate: "2026-07-15"
    )

    XCTAssertNil(outcome)
    XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-14"))
    let staleDaySnapshot = await activeStore.allCurrent()
    let unchanged = try XCTUnwrap(staleDaySnapshot.shields.first {
        $0.recordKey == record.recordKey
    })
    XCTAssertEqual(unchanged.sources, [.manual, .earnedTime])
    earnedStore.removeAll()
}

func test_nseMissingCanonicalTimezone_failsBeforeMarkerOrSourceRemoval() async throws {
    let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
        usageDate: "2026-07-15"
    ))
    let activeStore = ActiveLockStore()
    let earnedStore = makeEarnedStore()
    let record = makeMixedRecord()
    _ = await activeStore.addShield(record)

    let outcome = await NSEUnshieldCommandApplier.apply(
        command,
        recordKey: record.recordKey,
        store: activeStore,
        earnedTimeStore: earnedStore,
        fetchedDeviceID: overrideDeviceID,
        currentDeviceID: overrideDeviceID,
        currentUsageDate: nil
    )

    XCTAssertNil(outcome)
    XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
    let missingTimezoneSnapshot = await activeStore.allCurrent()
    let unchanged = try XCTUnwrap(missingTimezoneSnapshot.shields.first {
        $0.recordKey == record.recordKey
    })
    XCTAssertEqual(unchanged.sources, [.manual, .earnedTime])
    earnedStore.removeAll()
}

func test_nseIdentitySwitch_failsBeforeMarkerOrSourceRemoval() async throws {
    let command = try NSECommandWireDecoder.decode(overrideCommandJSON(
        usageDate: "2026-07-15"
    ))
    let activeStore = ActiveLockStore()
    let earnedStore = makeEarnedStore()
    let record = makeMixedRecord()
    _ = await activeStore.addShield(record)
    let switchedDeviceID =
        UUID(uuidString: "00000000-0000-0000-0000-000000000499")!

    let outcome = await NSEUnshieldCommandApplier.apply(
        command,
        recordKey: record.recordKey,
        store: activeStore,
        earnedTimeStore: earnedStore,
        fetchedDeviceID: overrideDeviceID,
        currentDeviceID: switchedDeviceID,
        currentUsageDate: "2026-07-15"
    )

    XCTAssertNil(outcome)
    XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
    let switchedIdentitySnapshot = await activeStore.allCurrent()
    let unchanged = try XCTUnwrap(switchedIdentitySnapshot.shields.first {
        $0.recordKey == record.recordKey
    })
    XCTAssertEqual(unchanged.sources, [.manual, .earnedTime])
    earnedStore.removeAll()
}

func test_nseEarnedReleaseWithoutOverrideMetadata_doesNotSuppressFutureLocks() async throws {
    let activeStore = ActiveLockStore()
    let earnedStore = makeEarnedStore()
    let record = makeMixedRecord()
    _ = await activeStore.addShield(record)
    let command = LockCommand(
        id: UUID(),
        action: .unshield,
        tier: .savedList,
        target: CommandTarget(
            listName: "Locked set",
            listID: overrideListID,
            originalRequest: "pool raised",
            targetDisplay: "Locked set",
            unlockSources: ["earned_time"],
            earnedOverrideUsageDate: nil
        ),
        durationMinutes: nil,
        issuedAt: Date()
    )

    let outcome = await NSEUnshieldCommandApplier.apply(
        command,
        recordKey: record.recordKey,
        store: activeStore,
        earnedTimeStore: earnedStore
    )

    XCTAssertEqual(outcome, .confirmed)
    XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
    let snapshot = await activeStore.allCurrent()
    let remaining = try XCTUnwrap(snapshot.shields.first {
        $0.recordKey == record.recordKey
    })
    XCTAssertEqual(remaining.sources, [.manual])
    earnedStore.removeAll()
}

private let overrideListID =
    UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
private let overrideDeviceID =
    UUID(uuidString: "00000000-0000-0000-0000-000000000404")!

private func makeEarnedStore() -> EarnedTimeStore {
    EarnedTimeStore(
        suiteName: "test.override.nse.\(UUID().uuidString)",
        useInProcessLock: true
    )
}

private func makeMixedRecord() -> ShieldRecord {
    ShieldRecord(
        recordKey: ShieldRecord.makeRecordKey(
            tier: .savedList,
            targetKey: overrideListID.uuidString
        ),
        tier: .savedList,
        targetKey: overrideListID.uuidString,
        displayName: "Locked set",
        lastCommandID: UUID(),
        appTokens: [],
        categoryTokens: [],
        webDomainTokens: [],
        appliesToAll: true,
        issuedAt: Date(),
        expiresAt: nil,
        originalRequest: "mixed lock",
        targetChildID: overrideDeviceID,
        sources: [.manual, .earnedTime]
    )
}

private func overrideCommandJSON(
    usageDate: String,
    listID: UUID? = overrideListID
) -> Data {
    let listIDJSON = listID.map { "\"\($0.uuidString)\"" } ?? "null"
    Data("""
    {
      "command_id": "00000000-0000-0000-0000-000000000403",
      "action": "unshield",
      "tier": "savedList",
      "duration_minutes": null,
      "issued_at": "2026-07-15T12:00:00Z",
      "unlock_sources": ["earned_time"],
      "target": {
        "list_id": \(listIDJSON),
        "list_name": "Locked set",
        "original_request": "override today's screen time",
        "target_display": "Locked set",
        "target_child_id": "\(overrideDeviceID.uuidString)",
        "unlock_sources": ["earned_time"],
        "earned_override_usage_date": "\(usageDate)"
      }
    }
    """.utf8)
}
```

- [ ] **Step 2: Run focused tests and verify decode/order failures**

```bash
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/CommandProvenanceTests \
  -only-testing:Evlin\ iOSTests/NSEUnshieldTests \
  -only-testing:Evlin\ iOSTests/OverrideSuppressionTests
```

Expected: wire tests fail because the field is absent; behavior tests fail
because neither executor writes the day override from a command or rejects a
stale-day/changed-identity override before mutation.

- [ ] **Step 3: Add the optional wire field to both decoding paths**

Add to `CommandTarget` with a default so every existing memberwise call remains
source-compatible:

```swift
var earnedOverrideUsageDate: String? = nil
```

Add `earned_override_usage_date: String?` to `PollTargetDTO`, its `CodingKeys`
and custom decoder, then map it in `CommandPoller.lockCommand`:

```swift
earnedOverrideUsageDate: poll.target.earned_override_usage_date,
```

Move the existing private `NSEWireCommand` and `NSEWireTarget` definitions out
of `NotificationService.swift` into the new
`Models/NSECommandWireModels.swift`; do not leave duplicate definitions behind.
Keep their current fields/mapping byte-for-byte, make the types internal, add
`earned_override_usage_date` to `NSEWireTarget`/`CodingKeys`/decode, and map it
to `CommandTarget.earnedOverrideUsageDate`. Add this file to the
`EvlinPushApplier` membership-exception list in `project.pbxproj`; filesystem
sync includes it in the app/test target automatically.

In the same shared file add:

```swift
nonisolated enum NSECommandWireDecoder {
    static func decode(_ data: Data) throws -> LockCommand {
        let dto = try JSONDecoder().decode(NSEWireCommand.self, from: data)
        return NSEWireCommand.lockCommand(from: dto)
    }
}
```

Change `NotificationService.fetchCommand` to call
`try? NSECommandWireDecoder.decode(data)` and delete the old private wire-model
section. This makes the NSE's actual decoder directly executable by XCTest
rather than testing a lookalike.

Old JSON without the field must continue decoding to `nil` in both paths.

- [ ] **Step 4: Add the shared fail-closed metadata applier**

In `EarnedTimeStore.swift`, add `currentCanonicalPolicyUsageDate` inside
`EarnedTimeStore`, and add the applier at file scope:

```swift
func currentCanonicalPolicyUsageDate(now: Date = Date()) -> String? {
    guard let timezoneIdentifier = runtimeTimezoneIdentifier,
          let timeZone = TimeZone(identifier: timezoneIdentifier)
    else { return nil }
    return Self.appLimitUsageDate(now: now, timeZone: timeZone)
}

nonisolated enum EarnedOverrideCommandApplier {
    enum Outcome: Equatable, Sendable {
        case absent
        case applied(String)
        case invalid
    }

    static func applyIfPresent(
        _ command: LockCommand,
        currentUsageDate: String?,
        store: EarnedTimeStore
    ) -> Outcome {
        guard let usageDate = command.target.earnedOverrideUsageDate else {
            return .absent
        }
        guard command.action == .unshield,
              command.tier == .savedList,
              command.unlockSources == ["earned_time"],
              EarnedTimeStore.isCanonicalUsageDate(usageDate),
              currentUsageDate == usageDate
        else { return .invalid }

        store.setOverride(true, forUsageDate: usageDate)
        return .applied(usageDate)
    }
}
```

Make `setOverride` flush the App Group write through its existing injected
synchronizer after set/remove:

```swift
if let defaults {
    if value {
        defaults.set(true, forKey: overrideKey(for: usageDate))
    } else {
        defaults.removeObject(forKey: overrideKey(for: usageDate))
    }
    _ = synchronizeDefaults(defaults)
}
```

- [ ] **Step 5: Call the applier before source removal in both executors**

Add `private let earnedTimeStore: EarnedTimeStore`, an injected
`overrideUsageDateProvider: () -> String?`, and initializer parameters in
`ActionExecutor`. The store defaults to `.shared`; the provider defaults to
`earnedTimeStore.currentCanonicalPolicyUsageDate()`. Tests inject a fixed
date. In the `.savedList` branch, move
override handling before the existing `guard let id = cmd.target.listID` so a
marker-only command can succeed without a guessed record key:

```swift
private let earnedTimeStore: EarnedTimeStore
private let overrideUsageDateProvider: () -> String?

// Add these parameters to the existing initializer without changing its other seams.
earnedTimeStore: EarnedTimeStore = .shared,
overrideUsageDateProvider: (() -> String?)? = nil,

self.earnedTimeStore = earnedTimeStore
self.overrideUsageDateProvider = overrideUsageDateProvider ?? {
    earnedTimeStore.currentCanonicalPolicyUsageDate()
}
```

```swift
var overrideMarkerApplied = false
if cmd.target.earnedOverrideUsageDate != nil {
    guard let expectedChildID = identity.expectedChildID,
          cmd.target.targetChildID == expectedChildID,
          identity.isCurrent
    else { return Self.staleIdentityResult }
    guard await prepareForMutation(identity) else {
        return Self.staleIdentityResult
    }
    guard case .applied = EarnedOverrideCommandApplier.applyIfPresent(
        cmd,
        currentUsageDate: overrideUsageDateProvider(),
        store: earnedTimeStore
    ) else { return .failed(.malformed) }
    overrideMarkerApplied = true
}

guard let id = cmd.target.listID else {
    guard overrideMarkerApplied else { return .failed(.nothingToUnlock) }
    return .confirmedExact(
        verb: .unshield,
        displayName: "Screen time override",
        effectiveState: nil
    )
}
```

After that guard, build the existing record key and keep the per-source identity
checks/removals unchanged. Do not apply metadata before the identity firewall.

Extend `NSEUnshieldCommandApplier.apply` with
`earnedTimeStore: EarnedTimeStore = .shared`, `fetchedDeviceID`,
`currentDeviceID`, and `currentUsageDate` seams. These three seams are required
only for commands carrying override metadata; ordinary legacy/config-raise
releases retain their current behavior. Before its current source loop:

```swift
if command.target.earnedOverrideUsageDate != nil {
    guard let fetchedDeviceID,
          currentDeviceID == fetchedDeviceID,
          command.target.targetChildID == fetchedDeviceID
    else { return nil }
}

switch EarnedOverrideCommandApplier.applyIfPresent(
    command,
    currentUsageDate: currentUsageDate,
    store: earnedTimeStore
) {
case .invalid:
    return nil
case .absent, .applied:
    break
}
```

The production foreground provider reads the store's canonical policy-date
context at execution time. Change `NSELockApplier.apply` to accept the device ID
used for the fetch. In `NotificationService`, pass that captured ID into
`NSELockApplier.apply`, and immediately before the unshield helper pass it plus
a fresh `NSEConfig.deviceID` read and
`earnedTimeStore.currentCanonicalPolicyUsageDate()`. That second identity
read closes the fetch-to-mutation switch window; do not cache it beside the
pre-network read.

This ordering is normative: current-day/identity checks, marker write, then
source removal. An ordinary earned-time config-raise command has no metadata
and stays on `.absent`.

- [ ] **Step 6: Run focused tests and both extension builds**

Run Step 2 again, then:

```bash
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -configuration Debug -destination 'generic/platform=iOS'
xcodebuild build -project 'Evlin iOS.xcodeproj' -scheme 'Evlin iOS' \
  -configuration Release -destination 'generic/platform=iOS'
```

Expected: all focused tests pass; app, DAM, and PushApplier compile in Debug and
Release; old command JSON remains compatible.

- [ ] **Step 7: Commit only override-command files**

```bash
git add 'Evlin iOS/Models/CommandModels.swift' \
        'Evlin iOS/Models/NSECommandWireModels.swift' \
        'Evlin iOS/Services/CommandPoller.swift' \
        'Evlin iOS/Services/ActiveLockStore.swift' \
        'Evlin iOS/Services/EarnedTimeStore.swift' \
        'Evlin iOS/Services/ActionExecutor.swift' \
        EvlinPushApplier/NotificationService.swift \
        'Evlin iOS.xcodeproj/project.pbxproj' \
        'Evlin iOSTests/CommandProvenanceTests.swift' \
        'Evlin iOSTests/NSEUnshieldTests.swift' \
        'Evlin iOSTests/OverrideSuppressionTests.swift'
git add -p 'Evlin iOS/Services/APIClient.swift'
git diff --cached --check
git commit -m 'fix: persist earned override before release'
```

`APIClient.swift` contains unrelated agreement work. Stage only the PollTarget
override field hunk here; its summary `usage_date` hunk belongs to Task 5.

---

### Task 5: Wire Canonical Usage Date and the Separate Override Action

**Files:**
- Modify: `Evlin iOS/Services/APIClient.swift:2690-2720`
- Modify: `Evlin iOS/Views/Profile/ProfileView.swift:130-305,1245-1310,1760-1830`
- Test: `Evlin iOSTests/EarnedDisplayTests.swift`
- Test: `Evlin iOSTests/SelectedSetClientTests.swift`

**Interfaces:**
- Consumes: backend `SummaryResponse.usage_date`, lock snapshots' `covering_sources`, Task 2's projection/action runner.
- Produces: `APIClient.EarnedSummaryDTO.usage_date: String?` and a compact automatic-status row whose optional action calls only `APIClient.unlockOverride(childProfileID:usageDate:)`.

- [ ] **Step 1: Pin canonical date decoding and manual-state independence**

Add to `EarnedDisplayTests.swift`:

```swift
func test_earnedSummaryDTO_decodesCanonicalUsageDate() throws {
    let data = #"{"usage_date":"2026-07-15","state":"exhausted","remaining_minutes":0}"#
        .data(using: .utf8)!
    let summary = try JSONDecoder().decode(APIClient.EarnedSummaryDTO.self, from: data)
    XCTAssertEqual(summary.usage_date, "2026-07-15")
}
```

Add to `SelectedSetClientTests.swift`:

```swift
func test_manualPresentation_staysGreenWhenOnlyAutomaticSourcesExist() {
    let manualState = ManualLockAggregateState.reduce(
        expectedDeviceCount: 2,
        coveringSources: [["earnedTime"], ["task_pause"]]
    )
    let presentation = ManualLockButtonPresentation.from(
        state: manualState,
        childName: "Sam"
    )

    XCTAssertEqual(manualState, .unlocked)
    XCTAssertEqual(presentation.title, "Lock Sam's devices")
    XCTAssertEqual(presentation.tone, .lock)
}
```

- [ ] **Step 2: Run the tests and verify canonical-date decoding fails**

```bash
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/EarnedDisplayTests \
  -only-testing:Evlin\ iOSTests/SelectedSetClientTests
```

Expected: `test_earnedSummaryDTO_decodesCanonicalUsageDate` fails to compile because `EarnedSummaryDTO` has no `usage_date`; the manual presentation assertion already passes and becomes a regression pin.

- [ ] **Step 3: Decode the backend's existing canonical usage date**

In `EarnedSummaryDTO`, add a defaulted optional so existing memberwise
initializers in `FamilyStoreTests` remain source-compatible. It must be `var`,
not `let`: synthesized `Decodable` does not overwrite an immutable property
that already has a default value.

```swift
var usage_date: String? = nil
```

and add `case usage_date` to `CodingKeys`. Do not compute this date with `Date()` or `TimeZone.current`; the backend value is canonical.

- [ ] **Step 4: Store automatic sources independently of manual aggregate state**

Add Profile state:

```swift
@State private var automaticCoveringSources: [String] = []
@State private var automaticActionBusy = false
@State private var automaticActionError: String?
```

Add the computed projection:

```swift
private var automaticLockNotice: AutomaticLockNotice? {
    AutomaticLockNotice.make(
        coveringSources: automaticCoveringSources,
        exhausted: earnedSummary?.state == "exhausted",
        overrideActive: earnedSummary?.override_active == true,
        usageDate: earnedSummary?.usage_date
    )
}
```

Inside `applyLockSnapshots`, after constructing `sources`, update the
automatic-source input only from a complete all-device snapshot. A partial
poll preserves the prior automatic notice, matching the existing manual and
automatic aggregate behavior:

```swift
if let completeSources = AutomaticLockNotice.completeCoveringSources(
    expectedDeviceCount: deviceIDs.count,
    coveringSources: sources
) {
    automaticCoveringSources = completeSources
}
```

- [ ] **Step 5: Add the dedicated override execution path**

Add to `ProfileView`:

```swift
@MainActor
private func performAutomaticLockAction(_ action: AutomaticLockNoticeAction) async {
    guard !automaticActionBusy,
          let childProfileID = childProfileUUID
    else { return }

    automaticActionBusy = true
    automaticActionError = nil
    defer { automaticActionBusy = false }

    do {
        try await AutomaticLockActionRunner.run(
            action: action,
            childProfileID: childProfileID
        ) { id, usageDate in
            _ = try await apiClient.unlockOverride(
                childProfileID: id,
                usageDate: usageDate
            )
        }
        await refreshEarnedSummary()
        await refreshLockState()
    } catch {
        automaticActionError = error.localizedDescription
    }
}
```

This method must not call `toggleDeviceLock`, `lockSelectedForChild`, or `unlockSelectedForChild`.

- [ ] **Step 6: Render one inline reason/action row below the manual CTA**

Inside the existing CTA `VStack`, after the manual button and before existing error/note captions, add:

```swift
if let notice = automaticLockNotice {
    HStack(alignment: .center, spacing: 8) {
        Image(systemName: notice.systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.evOnSurfaceVariant)

        Text(notice.message)
            .font(.custom("Inter", size: 11).weight(.medium))
            .foregroundStyle(Color.evOnSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

        if let title = notice.actionTitle,
           let action = notice.action {
            Button {
                Task { await performAutomaticLockAction(action) }
            } label: {
                if automaticActionBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(title)
                        .font(.custom("Inter", size: 11).weight(.semibold))
                }
            }
            .buttonStyle(.borderless)
            .disabled(automaticActionBusy)
        }
    }
    .frame(maxWidth: .infinity)
}

if let automaticActionError {
    Text(automaticActionError)
        .font(.custom("Inter", size: 11).weight(.medium))
        .foregroundStyle(Color.evError)
        .frame(maxWidth: .infinity)
}
```

Do not wrap this row in another rounded rectangle/card.

- [ ] **Step 7: Run focused iOS tests and compile both phone and iPad surfaces**

```bash
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/AutomaticLockNoticeTests \
  -only-testing:Evlin\ iOSTests/EarnedDisplayTests \
  -only-testing:Evlin\ iOSTests/SelectedSetClientTests

xcodebuild build \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPad (A16)'
```

Expected: all focused tests PASS and the iPad simulator build reports `BUILD SUCCEEDED`.

- [ ] **Step 8: Stage only Phase 0 hunks and commit**

```bash
git diff -- 'Evlin iOS/Services/APIClient.swift' 'Evlin iOS/Views/Profile/ProfileView.swift' 'Evlin iOSTests/EarnedDisplayTests.swift' 'Evlin iOSTests/SelectedSetClientTests.swift'
git add -p 'Evlin iOS/Services/APIClient.swift'
git add 'Evlin iOS/Views/Profile/ProfileView.swift' 'Evlin iOSTests/EarnedDisplayTests.swift' 'Evlin iOSTests/SelectedSetClientTests.swift'
git diff --cached --check
git diff --cached -- 'Evlin iOS/Services/APIClient.swift'
git commit -m 'feat: expose automatic lock reasons separately'
```

The staged APIClient diff must contain only `EarnedSummaryDTO.usage_date` and its coding key, never the unrelated agreement API additions.

---

### Task 6: Pin Existing Backend Manual-Only Semantics and Run the Phase Gate

**Files:**
- Verify only: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/tests/test_selected_set_lock.py:997-1197`
- Verify only: all Phase 0 iOS files from Tasks 1, 2, 4, and 5

**Interfaces:**
- Consumes: existing backend child-wide routes and accounting snapshot tests.
- Produces: recorded evidence that Phase 0 did not broaden the manual button or mutate metering state.

- [ ] **Step 1: Run the existing backend contract tests**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend
EVLIN_TEST_DATABASE_URL='postgresql+asyncpg://ale_user:ale_pass@localhost:5433/ale_test' \
  .venv/bin/pytest \
  tests/test_selected_set_lock.py::test_child_wide_manual_lock_queues_each_device_without_mutating_accounting \
  tests/test_selected_set_lock.py::test_child_wide_manual_unlock_queues_each_device_without_mutating_accounting \
  -q
```

Expected: `2 passed`. Each command carries only `manual`, and the seeded pool/day/device state including override and task suppression remains byte-equivalent. Then run `tests/test_earned_override.py` again to pin the separate earned-only path.

- [ ] **Step 2: Run the complete Phase 0 iOS regression set**

```bash
cd /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS
xcodebuild test \
  -project 'Evlin iOS.xcodeproj' \
  -scheme 'Evlin iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:Evlin\ iOSTests/EarnedDisplayTests \
  -only-testing:Evlin\ iOSTests/AutomaticLockNoticeTests \
  -only-testing:Evlin\ iOSTests/SelectedSetClientTests \
  -only-testing:Evlin\ iOSTests/CommandProvenanceTests \
  -only-testing:Evlin\ iOSTests/NSEUnshieldTests \
  -only-testing:Evlin\ iOSTests/OverrideSuppressionTests
```

Expected: all selected tests PASS with no new crash/failure.

- [ ] **Step 3: Verify the UI states on iPhone and iPad without waiting for metering**

Use injected/backend fixture state rather than waiting for real usage:

1. Snapshot A: device A `remaining_to_cap=120/cap=120`, device B `60/60`, shared remaining `35`. Verify both bars are full; labels may both say `35 mins left`.
2. Snapshot B: automatic `task_pause` source with no manual source. Verify CTA stays green `Lock`, and the task reason explicitly directs the parent to the task list below. Approving an existing bypass request remains a task-row action; the manual CTA never performs that bypass.
3. Snapshot C: exhausted summary with canonical `usage_date`. Verify CTA still follows manual provenance, `Override today` is separate, and tapping it does not flip the CTA optimistically.
4. Snapshot D: mixed manual state across two devices. Verify the existing in-progress multi-device reconciliation copy/state remains intact.
5. Snapshot E: active reflection. Verify the existing `ParentReflectionStatusCard` replaces the summary/manual CTA and remains the discoverable reflection action surface; do not manufacture a reflection source from selected-set state.
6. Snapshot F: exact-app limit. Verify its status remains discoverable in the device/App Limits surface and does not change the child-wide manual CTA.

Capture one iPhone and one iPad screenshot for the task review. Check that the inline status does not overlap the CTA or truncate at Dynamic Type `AX2`.

- [ ] **Step 4: Audit scope and record the final commit range**

```bash
git status --short
git log --oneline -4
git diff HEAD~4..HEAD --check
git diff HEAD~4..HEAD --name-only

git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend log --oneline -1
git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend diff HEAD~1..HEAD --check
git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend diff HEAD~1..HEAD --name-only
```

Expected changed production files are limited to:

```text
Evlin iOS/Models/AutomaticLockNotice.swift
Evlin iOS/Models/CommandModels.swift
Evlin iOS/Models/NSECommandWireModels.swift
Evlin iOS/Services/EarnedDisplayFormatters.swift
Evlin iOS/Services/APIClient.swift (PollTarget + usage_date hunks only)
Evlin iOS/Services/CommandPoller.swift
Evlin iOS/Services/ActiveLockStore.swift
Evlin iOS/Services/EarnedTimeStore.swift
Evlin iOS/Services/ActionExecutor.swift
Evlin iOS/Views/Profile/ProfileView.swift
EvlinPushApplier/NotificationService.swift
Evlin iOS.xcodeproj/project.pbxproj
```

Expected backend production files are limited to:

```text
app/services/earned_time_service.py
app/services/app_control_execution.py
app/api/routes/earned_time.py
app/schemas/earned_time.py
```

They may only complete the dedicated override with earned-only per-device
release commands; no sample, scheduler policy, or ledger-math change is allowed.
