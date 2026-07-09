# Per-App Limit Daily Reset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent yesterday's per-app usage offset and reported high-water mark from being added to today's DeviceActivity thresholds.

**Architecture:** Keep the existing App Group store, but scope per-app usage keys by `(ruleID, usageDate)`. `EarnedTimeStore`, already compiled into both the app and monitor extension, becomes the sole Gregorian/POSIX local-date formatter and prunes stale keys for a rule on every write. The monitor extension and state poller both pass the shared usage date through the existing same-day re-arm flow.

**Tech Stack:** Swift, XCTest, FamilyControls, DeviceActivity, App Group `UserDefaults`, Xcode 26.3.

## Global Constraints

- This is an iOS-only fix; do not modify the backend or remote database.
- Preserve same-day carry-forward through task pauses and DeviceActivity re-arms.
- A different usage date must read offset `0` and reported high-water mark `0`.
- Use one shared formatter with `Calendar(identifier: .gregorian)`, `Locale(identifier: "en_US_POSIX")`, and `TimeZone.current`.
- Do not migrate legacy unscoped values; remove them on the next write for that rule.
- On write, retain at most the current date's offset and reported keys for that rule; never remove another rule's keys.
- Keep the existing prefixes `evlin.appLimitUsageOffset.` and `evlin.appLimitReported.`.
- Do not change enforcement thresholds, lock precedence, backend aggregation, or timezone authority.
- Preserve all pre-existing worktree changes. `BigKidStatePoller.swift` already contains an unrelated earned-budget hunk; edit and stage only the usage-date hunk.

---

### Task 1: Date-scope Per-App Usage State End To End

**Files:**
- Modify: `Evlin iOSTests/EarnedTimeStoreTests.swift`
- Modify: `Evlin iOS/Services/EarnedTimeStore.swift`
- Modify: `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `Evlin iOS/Services/BigKidStatePoller.swift`

**Interfaces:**
- Produces: `EarnedTimeStore.appLimitUsageDate(now:timeZone:) -> String`
- Produces: `appLimitUsageOffsetMinutes(ruleID:usageDate:) -> Int`
- Produces: `setAppLimitUsageOffset(ruleID:usageDate:usedMinutes:)`
- Produces: `appLimitReportedMinutes(ruleID:usageDate:) -> Int`
- Produces: `recordAppLimitUsage(ruleID:usageDate:usedMinutes:)`
- Consumes: Existing App Group suite `group.com.evlin.ios` and existing `AppLimitRuleStore` rules.

- [ ] **Step 1: Add failing store and clock tests**

Append these tests inside `EarnedTimeStoreTests` before its final closing brace:

```swift
    // MARK: - Per-app usage day scoping

    func test_appLimitUsageDate_isGregorianAndTimezoneAware() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 7
        components.day = 9
        components.hour = 23
        components.minute = 30
        let instant = try XCTUnwrap(components.date)

        XCTAssertEqual(
            EarnedTimeStore.appLimitUsageDate(
                now: instant,
                timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
            ),
            "2026-07-09"
        )
        XCTAssertEqual(
            EarnedTimeStore.appLimitUsageDate(
                now: instant,
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
            ),
            "2026-07-10"
        )
    }

    func test_appLimitOffset_persistsWithinSameUsageDate() {
        let store = freshStore()
        let ruleID = UUID()

        store.setAppLimitUsageOffset(
            ruleID: ruleID, usageDate: "2026-07-08", usedMinutes: 20
        )

        XCTAssertEqual(
            store.appLimitUsageOffsetMinutes(ruleID: ruleID, usageDate: "2026-07-08"),
            20
        )
    }

    func test_appLimitOffset_doesNotLeakIntoNextUsageDate() {
        let store = freshStore()
        let ruleID = UUID()

        store.setAppLimitUsageOffset(
            ruleID: ruleID, usageDate: "2026-07-08", usedMinutes: 20
        )

        XCTAssertEqual(
            store.appLimitUsageOffsetMinutes(ruleID: ruleID, usageDate: "2026-07-09"),
            0
        )
    }

    func test_appLimitReported_isMonotoneOnlyWithinUsageDate() {
        let store = freshStore()
        let ruleID = UUID()

        store.recordAppLimitUsage(
            ruleID: ruleID, usageDate: "2026-07-08", usedMinutes: 45
        )
        store.recordAppLimitUsage(
            ruleID: ruleID, usageDate: "2026-07-08", usedMinutes: 30
        )

        XCTAssertEqual(
            store.appLimitReportedMinutes(ruleID: ruleID, usageDate: "2026-07-08"),
            45
        )
        XCTAssertEqual(
            store.appLimitReportedMinutes(ruleID: ruleID, usageDate: "2026-07-09"),
            0
        )
    }

    func test_appLimitLegacyUnscopedValues_areIgnored() throws {
        let store = freshStore()
        let ruleID = UUID()
        let suite = try XCTUnwrap(UserDefaults(suiteName: "group.com.evlin.ios"))
        let id = ruleID.uuidString.lowercased()
        suite.set(99, forKey: "evlin.appLimitUsageOffset.\(id)")
        suite.set(99, forKey: "evlin.appLimitReported.\(id)")

        XCTAssertEqual(
            store.appLimitUsageOffsetMinutes(ruleID: ruleID, usageDate: "2026-07-09"),
            0
        )
        XCTAssertEqual(
            store.appLimitReportedMinutes(ruleID: ruleID, usageDate: "2026-07-09"),
            0
        )
    }

    func test_appLimitWrite_prunesSameRuleOldDatesAndLegacyOnly() throws {
        let store = freshStore()
        let ruleA = UUID()
        let ruleB = UUID()
        let day1 = "2026-07-08"
        let day2 = "2026-07-09"
        let suite = try XCTUnwrap(UserDefaults(suiteName: "group.com.evlin.ios"))
        let idA = ruleA.uuidString.lowercased()
        let idB = ruleB.uuidString.lowercased()

        store.setAppLimitUsageOffset(ruleID: ruleA, usageDate: day1, usedMinutes: 20)
        store.recordAppLimitUsage(ruleID: ruleA, usageDate: day1, usedMinutes: 45)
        store.setAppLimitUsageOffset(ruleID: ruleB, usageDate: day1, usedMinutes: 7)
        suite.set(88, forKey: "evlin.appLimitUsageOffset.\(idA)")
        suite.set(88, forKey: "evlin.appLimitReported.\(idA)")

        store.setAppLimitUsageOffset(ruleID: ruleA, usageDate: day2, usedMinutes: 5)

        XCTAssertNil(suite.object(forKey: "evlin.appLimitUsageOffset.\(idA).\(day1)"))
        XCTAssertNil(suite.object(forKey: "evlin.appLimitReported.\(idA).\(day1)"))
        XCTAssertNil(suite.object(forKey: "evlin.appLimitUsageOffset.\(idA)"))
        XCTAssertNil(suite.object(forKey: "evlin.appLimitReported.\(idA)"))
        XCTAssertEqual(
            suite.integer(forKey: "evlin.appLimitUsageOffset.\(idA).\(day2)"), 5
        )
        XCTAssertEqual(
            suite.integer(forKey: "evlin.appLimitUsageOffset.\(idB).\(day1)"), 7
        )
    }
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
xcodebuild test \
  -project "Evlin iOS.xcodeproj" \
  -scheme "Evlin iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_appLimitUsageDate_isGregorianAndTimezoneAware" \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_appLimitOffset_persistsWithinSameUsageDate" \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_appLimitOffset_doesNotLeakIntoNextUsageDate" \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_appLimitReported_isMonotoneOnlyWithinUsageDate" \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_appLimitLegacyUnscopedValues_areIgnored" \
  -only-testing:"Evlin iOSTests/EarnedTimeStoreTests/test_appLimitWrite_prunesSameRuleOldDatesAndLegacyOnly"
```

Expected: build/test fails because `appLimitUsageDate(now:timeZone:)` and the `usageDate:` overloads do not exist. Confirm the failure is for the new API, not an unrelated compile error.

- [ ] **Step 3: Implement the shared date helper and date-scoped store**

Replace the four existing unscoped per-app methods in `EarnedTimeStore.swift` with:

```swift
    static func appLimitUsageDate(
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    private func appLimitUsageKey(
        prefix: String,
        ruleID: UUID,
        usageDate: String
    ) -> String {
        "\(prefix)\(ruleID.uuidString.lowercased()).\(usageDate)"
    }

    private func pruneAppLimitUsageKeys(ruleID: UUID, keeping usageDate: String) {
        guard let suite = defaults else { return }
        let id = ruleID.uuidString.lowercased()
        let offsetRoot = appLimitUsageOffsetPrefix + id
        let reportedRoot = appLimitReportedPrefix + id
        let keep = Set([
            "\(offsetRoot).\(usageDate)",
            "\(reportedRoot).\(usageDate)",
        ])

        suite.dictionaryRepresentation().keys
            .filter { key in
                let belongsToRule = key == offsetRoot
                    || key.hasPrefix(offsetRoot + ".")
                    || key == reportedRoot
                    || key.hasPrefix(reportedRoot + ".")
                return belongsToRule && !keep.contains(key)
            }
            .forEach { suite.removeObject(forKey: $0) }
    }

    func appLimitUsageOffsetMinutes(ruleID: UUID, usageDate: String) -> Int {
        let key = appLimitUsageKey(
            prefix: appLimitUsageOffsetPrefix,
            ruleID: ruleID,
            usageDate: usageDate
        )
        guard defaults?.object(forKey: key) != nil else { return 0 }
        return max(0, defaults?.integer(forKey: key) ?? 0)
    }

    func setAppLimitUsageOffset(
        ruleID: UUID,
        usageDate: String,
        usedMinutes: Int
    ) {
        pruneAppLimitUsageKeys(ruleID: ruleID, keeping: usageDate)
        let key = appLimitUsageKey(
            prefix: appLimitUsageOffsetPrefix,
            ruleID: ruleID,
            usageDate: usageDate
        )
        defaults?.set(max(0, usedMinutes), forKey: key)
        defaults?.synchronize()
    }

    func appLimitReportedMinutes(ruleID: UUID, usageDate: String) -> Int {
        let key = appLimitUsageKey(
            prefix: appLimitReportedPrefix,
            ruleID: ruleID,
            usageDate: usageDate
        )
        guard defaults?.object(forKey: key) != nil else { return 0 }
        return max(0, defaults?.integer(forKey: key) ?? 0)
    }

    func recordAppLimitUsage(
        ruleID: UUID,
        usageDate: String,
        usedMinutes: Int
    ) {
        pruneAppLimitUsageKeys(ruleID: ruleID, keeping: usageDate)
        let key = appLimitUsageKey(
            prefix: appLimitReportedPrefix,
            ruleID: ruleID,
            usageDate: usageDate
        )
        let current = appLimitReportedMinutes(ruleID: ruleID, usageDate: usageDate)
        defaults?.set(max(current, usedMinutes), forKey: key)
        defaults?.synchronize()
    }
```

Keep `clearUsageStateForIdentityChange()` unchanged; its existing prefix sweep already removes legacy and date-scoped keys.

- [ ] **Step 4: Wire the monitor extension to the shared date and explicit keys**

In `DeviceActivityMonitorExtension.swift`:

1. Replace `currentDayKey()`'s local formatter body with:

```swift
    private func currentDayKey() -> String {
        let timeZone = TimeZone.current
        let date = EarnedTimeStore.appLimitUsageDate(timeZone: timeZone)
        return "\(date)@\(timeZone.identifier)"
    }
```

2. Replace every `todayISODate()` call with `EarnedTimeStore.appLimitUsageDate()` and delete the private `todayISODate()` function.

3. In `postAppLimitUsageSample`, pass the already-computed date into store reads/writes:

```swift
        let usageDate = EarnedTimeStore.appLimitUsageDate()
        let tz = TimeZone.current.identifier
        let offset = EarnedTimeStore.shared.appLimitUsageOffsetMinutes(
            ruleID: ruleID,
            usageDate: usageDate
        )
        let isBudgetSample = clientSampleID?.hasSuffix(":budget") == true
        let adjustedThreshold = isBudgetSample ? thresholdMinutes : min(1440, offset + thresholdMinutes)
        let adjustedEstimate = isBudgetSample ? estimatedMinutes : min(1440, offset + estimatedMinutes)
        EarnedTimeStore.shared.recordAppLimitUsage(
            ruleID: ruleID,
            usageDate: usageDate,
            usedMinutes: adjustedEstimate
        )
```

Do not alter the budget-sample exception or network payload.

- [ ] **Step 5: Wire the state poller to the same shared date**

Immediately before `let adjustedRules = AppLimitRuleStore.shared.all()...` in `BigKidStatePoller.rearmUsageCountersFromStoredPolicy()`, add:

```swift
        let appLimitUsageDate = EarnedTimeStore.appLimitUsageDate()
```

Then replace the three store calls in that closure with:

```swift
            let used = max(
                store.appLimitUsageOffsetMinutes(
                    ruleID: rule.id,
                    usageDate: appLimitUsageDate
                ),
                store.appLimitReportedMinutes(
                    ruleID: rule.id,
                    usageDate: appLimitUsageDate
                )
            )
            store.setAppLimitUsageOffset(
                ruleID: rule.id,
                usageDate: appLimitUsageDate,
                usedMinutes: used
            )
```

Do not change the existing earned-budget `remainingPolicy` hunk earlier in this function.

- [ ] **Step 6: Run targeted tests and verify GREEN**

Run the Step 2 command again.

Expected: all six new `EarnedTimeStoreTests` cases pass. The command remains
serial because the tests intentionally share the App Group `UserDefaults` suite;
parallel simulator clones would race each other's `removeAll()` teardown.

- [ ] **Step 7: Verify both targets use one date implementation**

Run:

```bash
rg -n "todayISODate|appLimitUsageDate|appLimitUsageOffsetMinutes|appLimitReportedMinutes|setAppLimitUsageOffset|recordAppLimitUsage" \
  "Evlin iOS/Services/EarnedTimeStore.swift" \
  "Evlin iOS/Services/BigKidStatePoller.swift" \
  EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift
```

Expected:

- no `todayISODate` remains;
- the only date formatter implementation is `EarnedTimeStore.appLimitUsageDate`;
- every per-app offset/reported call supplies `usageDate`.

- [ ] **Step 8: Build the app and extensions**

Run:

```bash
xcodebuild build \
  -project "Evlin iOS.xcodeproj" \
  -scheme "Evlin iOS" \
  -destination 'generic/platform=iOS Simulator'
```

Expected: `** BUILD SUCCEEDED **`. This verifies the main app and DeviceActivity monitor extension compile against the same shared API.

- [ ] **Step 9: Check the final diff and preserve unrelated work**

Run:

```bash
git diff --check
git diff -- "Evlin iOS/Services/EarnedTimeStore.swift" \
  "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift" \
  "Evlin iOS/Services/BigKidStatePoller.swift" \
  "Evlin iOSTests/EarnedTimeStoreTests.swift"
```

Expected: no whitespace errors. In `BigKidStatePoller.swift`, the pre-existing `remainingPolicy` change remains untouched and is visibly separate from the new `appLimitUsageDate` hunk.

- [ ] **Step 10: Commit only this fix**

Stage the three clean files normally:

```bash
git add \
  "Evlin iOS/Services/EarnedTimeStore.swift" \
  EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift \
  "Evlin iOSTests/EarnedTimeStoreTests.swift"
```

Interactively stage only the new usage-date hunk in the already-dirty poller:

```bash
git add -p "Evlin iOS/Services/BigKidStatePoller.swift"
```

Answer `n` for the pre-existing `remainingPolicy` hunk and `y` for the new `appLimitUsageDate` hunk. Then verify and commit:

```bash
git diff --cached --check
git diff --cached --stat
git commit -m "fix(applimit): reset local usage state by day"
```

Expected staged files: `EarnedTimeStore.swift`, `DeviceActivityMonitorExtension.swift`, `EarnedTimeStoreTests.swift`, plus only the usage-date hunk from `BigKidStatePoller.swift`. No backend or workspace-user-state files are staged.
