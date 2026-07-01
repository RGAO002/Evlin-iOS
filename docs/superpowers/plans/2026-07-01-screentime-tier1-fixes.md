# Screen-Time Tier 1 Immediate Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land two low-risk stability fixes: (1) device identity survives reinstall via a Keychain mirror, and (2) the device-facing "remaining" is recomputed from the current pool (not a stale persisted column).

> `effective_date` bleed is split into `2026-07-01-screentime-effective-date-scope.md` (a scope/design doc, not yet executable) because it is a multi-site policy-read change (shared-loader parameter threading + inline queries + supersede semantics), not a near-zero-risk edit.

**Architecture:** Fix 1 is iOS (a Keychain mirror alongside the existing `UserDefaults` device-id interface — no call-site churn). Fix 2 is a backend recompute inside one SQLAlchemy service function. Each fix is independently testable and shippable.

**Tech Stack:** Swift, Security (Keychain / `SecItem`), XCTest; Python, FastAPI, SQLAlchemy async, pytest.

## Global Constraints

- Device-id UserDefaults keys (verbatim): `evlin.parentDeviceID`, `evlin.childDeviceID`.
- Keychain mirror service (verbatim): `com.evlin.deviceid`.
- **Do NOT change the scattered device-id read/write sites** (`@AppStorage`, `UserDefaults.standard.string/set/removeObject`, onboarding/profile/home/command-poller). UserDefaults stays the runtime interface; Keychain is only a recovery mirror.
- Sign-out / reset MUST call `DeviceIdentity.shared.clear()` (else a logged-out identity resurrects on next launch).
- Backend "remaining" is compute-only for device-facing reads: `max(0, current_pool - used)`. Never regress a kid's local usage from a stale value (spec Part B guard rail).
- Commits include ONLY the files named in each task. Never stage unrelated `project.pbxproj` churn beyond new-file membership, `xcuserstate`, or `.DS_Store`.

---

## File Structure

- **Create** `Evlin iOS/Services/DeviceIdentity.swift` — Keychain mirror for the two device-id UUIDs (app target only).
- **Create** `Evlin iOSTests/DeviceIdentityTests.swift` — mirror tests.
- **Modify** `Evlin iOS/Evlin_iOSApp.swift` — `hydrate()` at launch, `capture()` on background.
- **Modify** `Evlin iOS/Services/Auth/AuthService.swift:109` — `clear()` in `signOutLocally()`.
- **Modify** `Evlin iOS/Views/Home/HomeSettingsSheet.swift` — `clear()` at the device-id reset points (lines ~1623, ~1796, ~2314).
- **Modify** `Evlin-Backend/app/services/earned_time_service.py:500` — recompute remaining (Fix 2).
- **Create** `Evlin-Backend/tests/test_earned_time_remaining_recompute.py` — Fix 2 regression test.

---

## Task 1: `DeviceIdentity` Keychain mirror (Fix 1 — reinstall keeps usage)

**Files:**
- Create: `Evlin iOS/Services/DeviceIdentity.swift`
- Test: `Evlin iOSTests/DeviceIdentityTests.swift`
- Modify: `Evlin iOS/Evlin_iOSApp.swift`, `Evlin iOS/Services/Auth/AuthService.swift`, `Evlin iOS/Views/Home/HomeSettingsSheet.swift`

**Interfaces:**
- Produces: `final class DeviceIdentity` with `static let shared`, `init(defaults: UserDefaults, keychainService: String)`, and `func hydrate()`, `func capture()`, `func clear()`. Static keys `DeviceIdentity.parentKey = "evlin.parentDeviceID"`, `DeviceIdentity.childKey = "evlin.childDeviceID"`.

Behavior contract (from the spec + review):
- `hydrate()` per key: if UserDefaults has a valid UUID → mirror it into Keychain (UserDefaults wins); else if Keychain has a valid UUID → restore it into UserDefaults (reinstall recovery).
- `capture()` per key: mirror the current UserDefaults UUID (if valid) into Keychain.
- `clear()`: delete both parent+child Keychain entries.
- Only valid UUID strings are mirrored/restored (garbage never propagates).

- [ ] **Step 1: Write the failing test**

Create `Evlin iOSTests/DeviceIdentityTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class DeviceIdentityTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var service: String!
    private var sut: DeviceIdentity!

    private let pKey = DeviceIdentity.parentKey
    private let cKey = DeviceIdentity.childKey

    override func setUp() {
        super.setUp()
        suite = "test.deviceid.\(UUID().uuidString)"
        service = "test.deviceid.svc.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        sut = DeviceIdentity(defaults: defaults, keychainService: service)
        sut.clear()
    }

    override func tearDown() {
        sut.clear()
        defaults.removePersistentDomain(forName: suite)
        defaults = nil; sut = nil
        super.tearDown()
    }

    // 1) defaults has, keychain empty -> capture into keychain
    func test_hydrate_capturesDefaultsIntoKeychain() {
        let id = UUID().uuidString
        defaults.set(id, forKey: pKey)
        sut.hydrate()
        // wipe defaults to simulate reinstall, then hydrate must restore from keychain
        defaults.removeObject(forKey: pKey)
        sut.hydrate()
        XCTAssertEqual(defaults.string(forKey: pKey), id)
    }

    // 2) defaults empty, keychain has -> restore into defaults
    func test_hydrate_restoresFromKeychain() {
        let id = UUID().uuidString
        defaults.set(id, forKey: cKey); sut.capture()   // mirror to keychain
        defaults.removeObject(forKey: cKey)             // reinstall wipes defaults
        sut.hydrate()
        XCTAssertEqual(defaults.string(forKey: cKey), id)
    }

    // 3) both present, defaults has value -> defaults wins, overwrites keychain
    func test_hydrate_defaultsWinsOverKeychain() {
        let oldID = UUID().uuidString
        defaults.set(oldID, forKey: pKey); sut.capture()   // keychain = oldID
        let newID = UUID().uuidString
        defaults.set(newID, forKey: pKey)                  // defaults = newID
        sut.hydrate()
        defaults.removeObject(forKey: pKey); sut.hydrate() // restore from keychain
        XCTAssertEqual(defaults.string(forKey: pKey), newID, "keychain should have been overwritten to newID")
    }

    // 4) clear removes both parent + child mirrors
    func test_clear_removesBothMirrors() {
        defaults.set(UUID().uuidString, forKey: pKey)
        defaults.set(UUID().uuidString, forKey: cKey)
        sut.capture()
        sut.clear()
        defaults.removePersistentDomain(forName: suite)   // wipe defaults
        defaults = UserDefaults(suiteName: suite)
        sut = DeviceIdentity(defaults: defaults, keychainService: service)
        sut.hydrate()
        XCTAssertNil(defaults.string(forKey: pKey))
        XCTAssertNil(defaults.string(forKey: cKey))
    }

    // 5) invalid UUID string is never mirrored / restored
    func test_invalidUUID_notMirrored() {
        defaults.set("not-a-uuid", forKey: pKey)
        sut.capture()
        defaults.removeObject(forKey: pKey)
        sut.hydrate()
        XCTAssertNil(defaults.string(forKey: pKey))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:"Evlin iOSTests/DeviceIdentityTests" 2>&1 | tail -20`
Expected: FAIL — `cannot find 'DeviceIdentity' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Evlin iOS/Services/DeviceIdentity.swift`:

```swift
import Foundation
import Security

/// Keychain MIRROR for the device identity UUIDs. UserDefaults stays the
/// runtime interface (every existing reader keeps using `evlin.parentDeviceID`
/// / `evlin.childDeviceID` unchanged); the Keychain copy survives app deletion
/// so a reinstall re-attaches to the same backend device instead of minting a
/// new id and losing usage. Sign-out/reset MUST call `clear()`, else a
/// logged-out identity resurrects on next launch.
final class DeviceIdentity {
    static let shared = DeviceIdentity(defaults: .standard, keychainService: "com.evlin.deviceid")

    static let parentKey = "evlin.parentDeviceID"
    static let childKey = "evlin.childDeviceID"

    private let defaults: UserDefaults
    private let service: String

    init(defaults: UserDefaults, keychainService: String) {
        self.defaults = defaults
        self.service = keychainService
    }

    /// Launch: UserDefaults wins when present (fresh backend value → mirror it);
    /// otherwise restore from the Keychain mirror (reinstall recovery).
    func hydrate() {
        for key in [Self.parentKey, Self.childKey] {
            let ud = validUUID(defaults.string(forKey: key))
            let kc = validUUID(keychainGet(account: key))
            if let ud {
                if ud != kc { keychainSet(ud, account: key) }
            } else if let kc {
                defaults.set(kc, forKey: key)
            }
        }
    }

    /// Background: mirror whatever UserDefaults currently holds into Keychain.
    func capture() {
        for key in [Self.parentKey, Self.childKey] {
            if let ud = validUUID(defaults.string(forKey: key)) {
                keychainSet(ud, account: key)
            }
        }
    }

    /// Sign-out / reset: drop the mirror so a logged-out identity does not
    /// resurrect on next launch.
    func clear() {
        for key in [Self.parentKey, Self.childKey] { keychainDelete(account: key) }
    }

    private func validUUID(_ s: String?) -> String? {
        guard let s, UUID(uuidString: s) != nil else { return nil }
        return s
    }

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private func keychainGet(account: String) -> String? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func keychainSet(_ value: String, account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attrs = baseQuery(account: account)
        attrs[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
    }
    private func keychainDelete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:"Evlin iOSTests/DeviceIdentityTests" 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 5: Wire hydrate() at launch + capture() on background**

`Evlin_iOSApp.swift` **already has** an `init()` (line ~41), already declares `@Environment(\.scenePhase) private var scenePhase` (line ~24), and already has an `.onChange(of: scenePhase) { _, phase in switch phase { ... } }` handler with a `.background` case. Add to those existing sites — do NOT create new ones.

(a) In the existing `init()` (line ~41), add hydrate as the FIRST line, before `ActiveLockMigration.runIfNeeded()`, so the ids are restored before anything reads them. The result:

```swift
    init() {
        DeviceIdentity.shared.hydrate()
        // One-shot migration from legacy evlin.activeLocks store.
        ActiveLockMigration.runIfNeeded()
        EvlinShieldIconPublisher.publish()
    }
```

(b) In the existing `.onChange(of: scenePhase)` handler's `.background` case (which currently contains `startBackgroundPollerIfPaired()`), add the capture call:

```swift
                    case .background:
                        startBackgroundPollerIfPaired()
                        DeviceIdentity.shared.capture()
```

- [ ] **Step 6: Wire clear() into sign-out + reset**

In `Evlin iOS/Services/Auth/AuthService.swift`, inside `func signOutLocally()` (line ~109), add as the first line:

```swift
        DeviceIdentity.shared.clear()
```

In `Evlin iOS/Views/Home/HomeSettingsSheet.swift`, at each of the three device-id reset points, add `DeviceIdentity.shared.clear()` immediately after the existing `removeObject(forKey: "evlin.childDeviceID")`:
- after line ~1624 (`...removeObject(forKey: "evlin.childDeviceID")`)
- after line ~1797
- after line ~2315

```swift
                        DeviceIdentity.shared.clear()
```

- [ ] **Step 7: Build to verify it compiles**

Run: `xcodebuild build -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Manual verification (device)**

1. Pair a kid device; confirm `evlin.childDeviceID` is set.
2. Delete the app, reinstall, launch. Confirm the same `evlin.childDeviceID` is restored (Debug → check, or observe that backend usage continues rather than resetting).
3. Sign out, relaunch — confirm the id does NOT resurrect (mirror cleared).

- [ ] **Step 9: Commit**

```bash
git add "Evlin iOS/Services/DeviceIdentity.swift" "Evlin iOSTests/DeviceIdentityTests.swift" "Evlin iOS/Evlin_iOSApp.swift" "Evlin iOS/Services/Auth/AuthService.swift" "Evlin iOS/Views/Home/HomeSettingsSheet.swift" "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "fix(screentime): mirror device identity to Keychain so reinstall keeps usage"
```

---

## Task 2: Recompute device-facing remaining (Fix 2)

**Files:**
- Modify: `Evlin-Backend/app/services/earned_time_service.py:500`
- Test: `Evlin-Backend/tests/test_earned_time_remaining_recompute.py`

**Interfaces:**
- No signature change. `current_device_day_snapshot(...)` (line ~443) already loads the current active-config `pool` (lines ~482–487) but returns the *persisted* `child_day.remaining_minutes` (line ~500). Change it to recompute from that `pool`.

The problem: after a parent lowers the pool **without** a new sample ingest, `child_day.remaining_minutes` (written at ingest time, line ~365) is stale, while `get_summary` recomputes from the live pool (line ~784). So the device (which reads `current_device_day_snapshot`) and the parent (`get_summary`) disagree until the next sample. Fix: make the device-facing snapshot recompute too.

- [ ] **Step 1: Write the failing test**

This test uses the repo's real test infrastructure (verified in `tests/conftest.py` — the `client` fixture overrides `get_async_session` to yield the SAME `session`, so an HTTP POST and a direct service call share one session; both are DB-gated on `EVLIN_TEST_DATABASE_URL`). It ingests a sample via the real `/child/earned-time/sample` route, then lowers the pool, then calls the service function under test directly.

Create `Evlin-Backend/tests/test_earned_time_remaining_recompute.py`:

```python
"""Fix 2 regression: the device-facing remaining recomputes from the LIVE pool,
not the stale persisted column, after a pool change with no new sample."""
from __future__ import annotations

import os
from datetime import date, datetime, timezone as _tz

import pytest

pytestmark = [
    pytest.mark.asyncio,
    pytest.mark.skipif(
        not os.getenv("EVLIN_TEST_DATABASE_URL"),
        reason="EVLIN_TEST_DATABASE_URL not set; local Postgres required",
    ),
]

from app.db.models import Device, DeviceMode, Family
from app.db.models.child_profile import ChildProfile
from app.db.models.earned_time import EarnedTimeConfig
from app.services import earned_time_service as ets

USAGE_DATE = date(2026, 6, 23)


async def _make_family_device_profile(session):
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
    return fam, profile, device


def _add_config(session, *, family_id, child_profile_id, pool_minutes, superseded_at=None):
    cfg = EarnedTimeConfig(
        family_id=family_id, child_profile_id=child_profile_id,
        effective_date=USAGE_DATE, daily_pool_minutes=pool_minutes,
        timezone="America/New_York", enabled=True, superseded_at=superseded_at,
    )
    session.add(cfg)
    return cfg


def _sample_body(device_id, threshold_minutes):
    return {
        "device_id": str(device_id),
        "usage_date": USAGE_DATE.isoformat(),
        "timezone": "America/New_York",
        "activity_name": "evlin.earned.budget",
        "event_name": f"evlin.earned.t{threshold_minutes}",
        "threshold_minutes": threshold_minutes,
        "estimated_minutes": threshold_minutes,
        "observed_at": "2026-06-23T15:04:00Z",
        "client_sample_id": f"earned:{device_id}:{USAGE_DATE}:t{threshold_minutes}",
    }


async def test_snapshot_remaining_recomputes_after_pool_lowered(client, session):
    fam, profile, device = await _make_family_device_profile(session)
    cfg120 = _add_config(session, family_id=fam.id,
                         child_profile_id=profile.id, pool_minutes=120)
    await session.commit()

    # Ingest 30 used against the 120 pool -> persisted remaining 90.
    resp = await client.post(
        "/child/earned-time/sample",
        json=_sample_body(device.id, 30),
        headers={"X-Evlin-Child-Device-ID": str(device.id)},
    )
    assert resp.status_code == 200, resp.text

    # Lower the pool to 60 by superseding the 120 config — no new sample.
    cfg120.superseded_at = datetime.now(_tz.utc)
    _add_config(session, family_id=fam.id, child_profile_id=profile.id, pool_minutes=60)
    await session.commit()

    snap = await ets.current_device_day_snapshot(
        session, child_device=device, usage_date=USAGE_DATE
    )
    assert snap.remaining_minutes == 30  # 60 - 30, NOT the stale persisted 90
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Evlin-Backend && .venv/bin/python -m pytest tests/test_earned_time_remaining_recompute.py -x -q 2>&1 | tail -20`
Expected: FAIL — `assert 90 == 30` (returns the stale persisted value).

- [ ] **Step 3: Write minimal implementation**

In `Evlin-Backend/app/services/earned_time_service.py`, change line ~500 inside `current_device_day_snapshot`'s `return DeviceDaySnapshot(...)`:

```python
        remaining_minutes=(
            max(0, pool - child_day.used_minutes) if child_day is not None else pool
        ),
```
(`pool` is already computed just above at lines ~482–487 from the live active config.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Evlin-Backend && .venv/bin/python -m pytest tests/test_earned_time_remaining_recompute.py -x -q 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Run the earned-time suite to check no regression**

Run: `cd Evlin-Backend && .venv/bin/python -m pytest tests/ -k earned_time -q 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add "Evlin-Backend/app/services/earned_time_service.py" "Evlin-Backend/tests/test_earned_time_remaining_recompute.py"
git commit -m "fix(earned-time): device-facing remaining recomputes from live pool"
```

---

*The `effective_date` bleed fix (formerly Task 3) is tracked in its own scope doc — `2026-07-01-screentime-effective-date-scope.md` — because it is a multi-site policy-read change.*
