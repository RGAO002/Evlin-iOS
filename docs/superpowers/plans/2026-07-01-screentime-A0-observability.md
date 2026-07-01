# Screen-Time A0 Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the local observability spine — a single `ScreenTimeEvent` type, an App-Group ring buffer + os_log emitter, wired at the DeviceActivity extension's lock/time points, surfaced in an in-app debug screen — so every later screen-time fix can be verified against a real event timeline.

**Architecture:** One `Codable` `ScreenTimeEvent` (schema from the spec) is emitted through `ScreenTimeEventLog.emit(_:)`, which writes each event two ways: (1) `os_log` (subsystem `com.evlin.screentime`) for live Xcode/Console, and (2) a capped JSONL ring buffer in App-Group `UserDefaults` for on-device reading. A SwiftUI debug screen reads the ring buffer. This is the A0 slice: local only — the backend upload (`screen_time_events`) is a later plan (A1).

**Tech Stack:** Swift, SwiftUI, `os.Logger`, `UserDefaults(suiteName:)` App Group, XCTest.

## Global Constraints

- App Group suite name (verbatim): `group.com.evlin.ios`
- os_log subsystem (verbatim): `com.evlin.screentime`
- Ring buffer key (verbatim): `evlin.screentime.events`
- Ring buffer cap: `500` entries (drop oldest)
- `ScreenTimeEvent.swift` and `ScreenTimeEventLog.swift` MUST be members of **both** Xcode targets: `Evlin iOS` **and** `EvlinDeviceActivityMonitor` (the extension emits events too). Add via File Inspector → Target Membership.
- Match the repo's existing App-Group pattern: `UserDefaults(suiteName: "group.com.evlin.ios")`, `[String]` arrays via `stringArray(forKey:)` (see `Evlin iOS/Services/CommandPoller.swift:47`, `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift:676`).
- A0 is local-only. Do NOT add any network upload in this plan.
- Commits include ONLY the files named in each task. Never stage `project.pbxproj` build-setting churn beyond the target-membership additions, `xcuserstate`, or `.DS_Store`.

---

## File Structure

- **Create** `Evlin iOS/Models/ScreenTimeEvent.swift` — the event value type + enums (shared to both targets).
- **Create** `Evlin iOS/Services/ScreenTimeEventLog.swift` — emitter: os_log + App-Group ring buffer (shared to both targets).
- **Create** `Evlin iOSTests/ScreenTimeEventTests.swift` — Codable + line-serialization tests.
- **Create** `Evlin iOSTests/ScreenTimeEventLogTests.swift` — ring buffer append/cap/read/clear tests.
- **Create** `Evlin iOS/Views/Debug/ScreenTimeEventLogView.swift` — in-app debug screen (events + current-restrictions truth).
- **Create** `Evlin iOS/Services/CurrentRestrictionsReader.swift` — reads the App-Group enforcement-truth shields/blocks (A0.5; reused by A1).
- **Create** `Evlin iOSTests/CurrentRestrictionsReaderTests.swift` — reader tests.
- **Modify** `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` — emit at the lock/time points.
- **Modify** `Evlin iOS/Views/Debug/SpikeView.swift` — add a navigation entry to the new debug screen.

---

## Task 1: `ScreenTimeEvent` value type

**Files:**
- Create: `Evlin iOS/Models/ScreenTimeEvent.swift`
- Test: `Evlin iOSTests/ScreenTimeEventTests.swift`

**Interfaces:**
- Produces: `struct ScreenTimeEvent: Codable, Equatable` with initializer `init(ts:emitter:deviceID:dayKey:kind:source:app:reason:nums:transition:policyGen:corrID:)`; enums `ScreenTimeEvent.Emitter`, `.Kind`, `.Source` (all `String, Codable`); nested `Nums` and `Transition` structs; `func jsonLine() -> String` and `static func from(jsonLine:) -> ScreenTimeEvent?`.

- [ ] **Step 1: Write the failing test**

Create `Evlin iOSTests/ScreenTimeEventTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class ScreenTimeEventTests: XCTestCase {

    private func sample() -> ScreenTimeEvent {
        ScreenTimeEvent(
            ts: "2026-07-01T15:02:00-04:00",
            emitter: .kidExtension,
            deviceID: "DEV-123",
            dayKey: "2026-07-01@America/New_York",
            kind: .lock,
            source: .perAppLimit,
            app: "com.instagram.app",
            reason: "budget_reached",
            nums: .init(used: 30, budget: 30, poolUsed: 45, poolTotal: 120, cap: 180, remaining: 0, rounded: 0),
            transition: .init(before: "shielded:false", after: "shielded:true"),
            policyGen: 7,
            corrID: "corr-abc"
        )
    }

    func test_jsonLine_roundTrips() {
        let e = sample()
        let line = e.jsonLine()
        XCTAssertFalse(line.contains("\n"), "a JSONL line must be single-line")
        let decoded = ScreenTimeEvent.from(jsonLine: line)
        XCTAssertEqual(decoded, e)
    }

    func test_from_returnsNil_onGarbage() {
        XCTAssertNil(ScreenTimeEvent.from(jsonLine: "not json"))
    }

    func test_enumsUseStableRawValues() {
        XCTAssertEqual(ScreenTimeEvent.Emitter.kidExtension.rawValue, "kid_extension")
        XCTAssertEqual(ScreenTimeEvent.Source.perAppLimit.rawValue, "perAppLimit")
        XCTAssertEqual(ScreenTimeEvent.Kind.commandAck.rawValue, "command_ack")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:"Evlin iOSTests/ScreenTimeEventTests" 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ScreenTimeEvent' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Evlin iOS/Models/ScreenTimeEvent.swift`:

```swift
import Foundation

/// One structured screen-time observability event. Emitted on the kid
/// extension, kid app, parent app, and (later) backend, serialized as a
/// single JSON line for the App-Group ring buffer and os_log.
///
/// Membership: this file MUST be in BOTH the `Evlin iOS` and
/// `EvlinDeviceActivityMonitor` targets.
struct ScreenTimeEvent: Codable, Equatable {

    enum Emitter: String, Codable, Equatable {
        case parentApp = "parent_app"
        case kidApp = "kid_app"
        case kidExtension = "kid_extension"
        case backend = "backend"
    }

    enum Kind: String, Codable, Equatable {
        case lock, unlock, sample, decision, cascade, reset, drop
        case commandEmit = "command_emit"
        case commandAck = "command_ack"
    }

    enum Source: String, Codable, Equatable {
        case manual, perAppLimit, devicePool, earnedPool, deviceCap, taskPause
    }

    struct Nums: Codable, Equatable {
        var used: Int?
        var budget: Int?
        var poolUsed: Int?
        var poolTotal: Int?
        var cap: Int?
        var remaining: Int?
        var rounded: Int?
    }

    struct Transition: Codable, Equatable {
        var before: String?
        var after: String?
    }

    var ts: String
    var emitter: Emitter
    var deviceID: String?
    var dayKey: String?
    var kind: Kind
    var source: Source?
    var app: String?
    var reason: String?
    var nums: Nums?
    var transition: Transition?
    var policyGen: Int?
    var corrID: String?

    func jsonLine() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(self),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    static func from(jsonLine line: String) -> ScreenTimeEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ScreenTimeEvent.self, from: data)
    }
}
```

Then in Xcode: select `ScreenTimeEvent.swift` → File Inspector → check **both** `Evlin iOS` and `EvlinDeviceActivityMonitor` under Target Membership.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:"Evlin iOSTests/ScreenTimeEventTests" 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Models/ScreenTimeEvent.swift" "Evlin iOSTests/ScreenTimeEventTests.swift" "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "feat(screentime): add ScreenTimeEvent observability value type"
```
(`project.pbxproj` is staged here only because the new file + its dual target membership changed it. Review `git diff --cached` to confirm no unrelated build-setting churn.)

---

## Task 2: `ScreenTimeEventLog` (os_log + App-Group ring buffer)

**Files:**
- Create: `Evlin iOS/Services/ScreenTimeEventLog.swift`
- Test: `Evlin iOSTests/ScreenTimeEventLogTests.swift`

**Interfaces:**
- Consumes: `ScreenTimeEvent` (Task 1).
- Produces: `enum ScreenTimeEventLog` with `static func emit(_ event: ScreenTimeEvent)`, `static func read() -> [ScreenTimeEvent]` (oldest-first), `static func clear()`. Also `static func emit(_:into:)` and `static func read(from:)`/`clear(in:)` taking an injected `UserDefaults` for tests. Constant `static let cap = 500`, `static let key = "evlin.screentime.events"`.

- [ ] **Step 1: Write the failing test**

Create `Evlin iOSTests/ScreenTimeEventLogTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class ScreenTimeEventLogTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "test.screentime.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func event(_ reason: String) -> ScreenTimeEvent {
        ScreenTimeEvent(ts: "2026-07-01T00:00:00Z", emitter: .kidExtension,
                        deviceID: "D", dayKey: "2026-07-01@UTC", kind: .lock,
                        source: .perAppLimit, app: "a", reason: reason,
                        nums: nil, transition: nil, policyGen: nil, corrID: nil)
    }

    func test_emit_thenRead_returnsInOrder() {
        ScreenTimeEventLog.emit(event("one"), into: defaults)
        ScreenTimeEventLog.emit(event("two"), into: defaults)
        let read = ScreenTimeEventLog.read(from: defaults)
        XCTAssertEqual(read.map { $0.reason }, ["one", "two"])
    }

    func test_ringBuffer_capsAtCap_droppingOldest() {
        for i in 0..<(ScreenTimeEventLog.cap + 10) {
            ScreenTimeEventLog.emit(event("r\(i)"), into: defaults)
        }
        let read = ScreenTimeEventLog.read(from: defaults)
        XCTAssertEqual(read.count, ScreenTimeEventLog.cap)
        XCTAssertEqual(read.first?.reason, "r10")   // oldest 10 dropped
        XCTAssertEqual(read.last?.reason, "r\(ScreenTimeEventLog.cap + 9)")
    }

    func test_clear_empties() {
        ScreenTimeEventLog.emit(event("x"), into: defaults)
        ScreenTimeEventLog.clear(in: defaults)
        XCTAssertTrue(ScreenTimeEventLog.read(from: defaults).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:"Evlin iOSTests/ScreenTimeEventLogTests" 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ScreenTimeEventLog' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Evlin iOS/Services/ScreenTimeEventLog.swift`:

```swift
import Foundation
import os

/// Emits `ScreenTimeEvent`s to (1) os_log for live Xcode/Console viewing and
/// (2) a capped JSONL ring buffer in App-Group UserDefaults for on-device
/// reading (see `ScreenTimeEventLogView`). Local only — no network here.
///
/// Membership: this file MUST be in BOTH the `Evlin iOS` and
/// `EvlinDeviceActivityMonitor` targets.
enum ScreenTimeEventLog {

    static let key = "evlin.screentime.events"
    static let cap = 500
    static let suiteName = "group.com.evlin.ios"

    private static let logger = Logger(subsystem: "com.evlin.screentime", category: "event")
    private static var shared: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func emit(_ event: ScreenTimeEvent) {
        guard let d = shared else { return }
        emit(event, into: d)
    }

    static func emit(_ event: ScreenTimeEvent, into defaults: UserDefaults) {
        let line = event.jsonLine()
        // (1) os_log — filter in Console/Xcode by subsystem com.evlin.screentime
        logger.log("\(line, privacy: .public)")
        // (2) ring buffer
        var log = defaults.stringArray(forKey: key) ?? []
        log.append(line)
        if log.count > cap {
            log = Array(log.suffix(cap))
        }
        defaults.set(log, forKey: key)
    }

    static func read() -> [ScreenTimeEvent] {
        guard let d = shared else { return [] }
        return read(from: d)
    }

    static func read(from defaults: UserDefaults) -> [ScreenTimeEvent] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(ScreenTimeEvent.from(jsonLine:))
    }

    static func clear() {
        guard let d = shared else { return }
        clear(in: d)
    }

    static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
    }
}
```

Then in Xcode: add `ScreenTimeEventLog.swift` to **both** `Evlin iOS` and `EvlinDeviceActivityMonitor` target memberships.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:"Evlin iOSTests/ScreenTimeEventLogTests" 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Services/ScreenTimeEventLog.swift" "Evlin iOSTests/ScreenTimeEventLogTests.swift" "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "feat(screentime): add ScreenTimeEventLog os_log + App Group ring buffer"
```

---

## Task 3: Emit at the DeviceActivity extension lock/time points

**Files:**
- Modify: `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`

**Interfaces:**
- Consumes: `ScreenTimeEvent`, `ScreenTimeEventLog.emit(_:)` (Tasks 1–2).
- Produces: no new symbols; adds emission side-effects at existing methods.

This wiring runs inside the DeviceActivity extension process and is not unit-testable (it requires the OS to fire callbacks). It is verified in Task 4 via the debug screen and in Console.app. Emit the event at each point below; keep each call one line so it can't throw or block the callback.

- [ ] **Step 1: Add a helper at the top of the class**

In `DeviceActivityMonitorExtension.swift`, just below the existing `private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")` (line ~14), add:

```swift
    /// Build the canonical day key "YYYY-MM-DD@<tz>" in the device's current tz.
    private func currentDayKey() -> String {
        let tz = TimeZone.current
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        return "\(f.string(from: Date()))@\(tz.identifier)"
    }

    /// Emit a ScreenTimeEvent from the extension (emitter = kid_extension).
    private func emitEvent(kind: ScreenTimeEvent.Kind,
                           source: ScreenTimeEvent.Source?,
                           app: String?,
                           reason: String,
                           transition: ScreenTimeEvent.Transition? = nil) {
        let iso = ISO8601DateFormatter()
        let e = ScreenTimeEvent(
            ts: iso.string(from: Date()),
            emitter: .kidExtension,
            deviceID: defaults?.string(forKey: "evlin.childDeviceID"),
            dayKey: currentDayKey(),
            kind: kind, source: source, app: app, reason: reason,
            nums: nil, transition: transition, policyGen: nil, corrID: nil)
        ScreenTimeEventLog.emit(e)
    }
```

- [ ] **Step 2: Emit on dropped events (usageCountingAllowed == false)**

In `usageCountingAllowed(eventName:)` (line ~161), in the branch that returns `false` (after the `guard EarnedTimeStore.shared.usageCountingAllowed else {` at line ~162), add before returning false:

```swift
            emitEvent(kind: .drop, source: nil, app: eventName,
                      reason: "usage_counting_disabled")
```

- [ ] **Step 3: Emit on per-app limit shield (applyLimitShield)**

In `applyLimitShield(eventName:)` (line ~178), immediately after the existing `NSLog("[Evlin/Ext] limit threshold shielded rule=%@", ruleId.uuidString)` (line ~208), add:

```swift
        emitEvent(kind: .lock, source: .perAppLimit,
                  app: LimitShieldLogic.recordKey(for: rule),
                  reason: "budget_reached",
                  transition: .init(before: "shielded:false", after: "shielded:true"))
```

- [ ] **Step 4: Emit the earned-pool decision (two exact anchors)**

(a) **Pool under cap (no shield).** In `handleEarnedThreshold(eventName:activity:)`, inside the `else` block of `guard EarnedSampleReporter.shouldApplyEarnedShield(...) else { ... }` (lines ~366–375), after the existing `NSLog("[Evlin/Ext] earned t%d ... no shield", ...)` (~372–373) and before the `return`:

```swift
            emitEvent(kind: .decision, source: .earnedPool, app: "device-wide",
                      reason: "pool_under_cap")
```

(b) **Pool exhausted (shield applied).** As the LAST statement of `applyEarnedTimeShield(earnedStore:thresholdN:)` (the method starting ~line 387) — after the record is persisted + recomputed (after the `if let data = encodeShields(current) { ... }` block near line ~430). This is more precise than emitting in `handleEarnedThreshold`, because `applyEarnedTimeShield` is the method that actually writes the shield:

```swift
        emitEvent(kind: .lock, source: .earnedPool, app: "device-wide",
                  reason: "pool_exhausted",
                  transition: .init(before: "shielded:false", after: "shielded:true"))
```

- [ ] **Step 5: Emit on the two reset paths**

In `resetLimitShields(activity:)` (line ~481), after it strips the `.limit` records, add:

```swift
        emitEvent(kind: .reset, source: .perAppLimit, app: "device-wide",
                  reason: "interval_reset")
```

In `resetEarnedTimeShields(activity:)` (line ~446), after it strips the `.earnedTime` records, add:

```swift
        emitEvent(kind: .reset, source: .earnedPool, app: "device-wide",
                  reason: "interval_reset")
```

- [ ] **Step 6: Emit the net shield transition (recomputeAndApplyShields)**

`recomputeAndApplyShields(_:)` (line ~575) ends with `return blocks.count` (line ~611) and has no single "applied token count" local, so compute one from `shields` and emit just before that return:

```swift
        let broad = shields.values.contains(where: \.appliesToAll)
        let shieldTokenCount = broad ? -1
            : Set(shields.values.flatMap(\.appTokens)).count
              + Set(shields.values.flatMap(\.categoryTokens)).count
              + Set(shields.values.flatMap(\.webDomainTokens)).count
        emitEvent(kind: .decision, source: nil, app: "device-wide",
                  reason: broad ? "recompute_broad_lock" : "recompute_applied",
                  transition: .init(before: nil, after: "shield_tokens:\(shieldTokenCount)"))
        return blocks.count
```
(`-1` denotes a full/broad device lock. The `else` branch at lines ~600–609 already unions the same token sets; this re-derives the count inline to keep the emit self-contained.)

- [ ] **Step 7: Build the extension to verify it compiles**

Run: `xcodebuild build -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED` (the extension target compiles with the new emit calls).

- [ ] **Step 8: Commit**

```bash
git add "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift"
git commit -m "feat(screentime): emit ScreenTimeEvents at extension lock/time points"
```

---

## Task 4: In-app debug screen

**Files:**
- Create: `Evlin iOS/Views/Debug/ScreenTimeEventLogView.swift`
- Modify: `Evlin iOS/Views/Debug/SpikeView.swift`

**Interfaces:**
- Consumes: `ScreenTimeEventLog.read()`, `ScreenTimeEventLog.clear()`, `ScreenTimeEvent`.
- Produces: `struct ScreenTimeEventLogView: View`.

- [ ] **Step 1: Create the debug screen**

Create `Evlin iOS/Views/Debug/ScreenTimeEventLogView.swift`:

```swift
import SwiftUI

/// Reads the App-Group `ScreenTimeEventLog` ring buffer and shows the events
/// newest-first. Verification surface for every screen-time fix.
struct ScreenTimeEventLogView: View {
    @State private var refreshTick = 0

    private var events: [ScreenTimeEvent] {
        _ = refreshTick
        return ScreenTimeEventLog.read()
    }

    var body: some View {
        List {
            Section {
                if events.isEmpty {
                    Text("No screen-time events recorded yet.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(events.reversed().enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.kind.rawValue.uppercased())  \(e.source?.rawValue ?? "-")  \(e.app ?? "-")")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text("\(e.reason ?? "-")  ·  \(e.emitter.rawValue)  ·  \(e.dayKey ?? "-")")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(e.ts)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Screen-time events (newest first) · \(events.count)")
            }

            Section {
                Button { refreshTick += 1 } label: { Text("Refresh") }
                Button(role: .destructive) {
                    ScreenTimeEventLog.clear()
                    refreshTick += 1
                } label: { Text("Clear all events") }
            }
        }
        .navigationTitle("Screen-Time Events")
    }
}
```

- [ ] **Step 2: Add a navigation entry in SpikeView**

In `Evlin iOS/Views/Debug/SpikeView.swift`, inside its top-level `List`/`Form` (find an existing `NavigationLink(...)` to copy the style), add:

```swift
        NavigationLink("Screen-Time Events") {
            ScreenTimeEventLogView()
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual verification (device or simulator)**

1. Run the app on a device/simulator, trigger a per-app limit or earned lock (or, on simulator, call `ScreenTimeEventLog.emit(...)` from a debug button).
2. Open SpikeView → "Screen-Time Events".
3. Confirm events appear newest-first with kind/source/app/reason.
4. In Console.app, filter subsystem `com.evlin.screentime` and confirm the same lines appear (including from the extension process).

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Views/Debug/ScreenTimeEventLogView.swift" "Evlin iOS/Views/Debug/SpikeView.swift" "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "feat(screentime): in-app debug screen for the event ring buffer"
```

---

## Task 5 (A0.5): Current-restrictions snapshot reader + debug section

**Files:**
- Create: `Evlin iOS/Services/CurrentRestrictionsReader.swift`
- Create: `Evlin iOSTests/CurrentRestrictionsReaderTests.swift`
- Modify: `Evlin iOS/Views/Debug/ScreenTimeEventLogView.swift`

**Interfaces:**
- Consumes: `ShieldRecord`, `BlockRecord`, `ActiveLockStore.shared.allCurrent()`.
- Produces: `enum CurrentRestrictionsReader` with `static func decodeDict<T: Decodable>(_:key:from:) -> [T]`, `static func persistedShields(from:) -> [ShieldRecord]`, `static func persistedBlocks(from:) -> [BlockRecord]`, and zero-arg convenience `persistedShields()`/`persistedBlocks()` using the App-Group suite. (A1 reuses this reader to upload the snapshot.)

Why: the App-Group dicts `evlin.shieldRecords`/`evlin.blockRecords` are the **enforcement truth** the extension writes. `ActiveLockStore.shared` is an in-memory copy that can lag them. Showing both makes divergence visible (spec Part B.1).

- [ ] **Step 1: Write the failing test**

Create `Evlin iOSTests/CurrentRestrictionsReaderTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class CurrentRestrictionsReaderTests: XCTestCase {

    private struct Fake: Codable, Equatable, Hashable { let id: String; let n: Int }

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "test.restrictions.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func test_decodeDict_roundTripsValues() {
        let dict = ["a": Fake(id: "a", n: 1), "b": Fake(id: "b", n: 2)]
        defaults.set(try! JSONEncoder().encode(dict), forKey: "k")
        let out = CurrentRestrictionsReader.decodeDict(Fake.self, key: "k", from: defaults)
        XCTAssertEqual(Set(out), Set(dict.values))
    }

    func test_decodeDict_absentKey_returnsEmpty() {
        XCTAssertTrue(CurrentRestrictionsReader.decodeDict(Fake.self, key: "missing", from: defaults).isEmpty)
    }

    func test_decodeDict_garbage_returnsEmpty() {
        defaults.set(Data([0x00, 0x01]), forKey: "k")
        XCTAssertTrue(CurrentRestrictionsReader.decodeDict(Fake.self, key: "k", from: defaults).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:"Evlin iOSTests/CurrentRestrictionsReaderTests" 2>&1 | tail -20`
Expected: FAIL — `cannot find 'CurrentRestrictionsReader' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Evlin iOS/Services/CurrentRestrictionsReader.swift`:

```swift
import Foundation

/// Reads the *enforcement truth* — the App-Group dicts the DeviceActivity
/// extension actually writes (`evlin.shieldRecords` / `evlin.blockRecords`,
/// suite `group.com.evlin.ios`) — decoded with the same `.iso8601` strategy
/// `ActiveLockStore` persists with (see `ActiveLockStore.swift:503`).
/// Used by the A0.5 debug screen now and by the A1 snapshot upload later.
enum CurrentRestrictionsReader {
    static let suiteName = "group.com.evlin.ios"
    static let shieldsKey = "evlin.shieldRecords"
    static let blocksKey = "evlin.blockRecords"

    static func decodeDict<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> [T] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let dict = (try? dec.decode([String: T].self, from: data)) ?? [:]
        return Array(dict.values)
    }

    static func persistedShields(from defaults: UserDefaults) -> [ShieldRecord] {
        decodeDict(ShieldRecord.self, key: shieldsKey, from: defaults)
    }
    static func persistedBlocks(from defaults: UserDefaults) -> [BlockRecord] {
        decodeDict(BlockRecord.self, key: blocksKey, from: defaults)
    }
    static func persistedShields() -> [ShieldRecord] {
        UserDefaults(suiteName: suiteName).map { persistedShields(from: $0) } ?? []
    }
    static func persistedBlocks() -> [BlockRecord] {
        UserDefaults(suiteName: suiteName).map { persistedBlocks(from: $0) } ?? []
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:"Evlin iOSTests/CurrentRestrictionsReaderTests" 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Add current-restrictions state + async refresh + debug section**

`ActiveLockStore` is an `actor` (`ActiveLockStore.swift:13`), so `allCurrent()` must be `await`-ed and **cannot** be called synchronously in a SwiftUI `body`. Read it into `@State` via an async refresh.

In `Evlin iOS/Views/Debug/ScreenTimeEventLogView.swift`:

(a) Add state + async loader to the struct (next to the existing `@State private var refreshTick`):

```swift
    @State private var memoryShields: [ShieldRecord] = []
    @State private var memoryBlocks: [BlockRecord] = []

    @MainActor
    private func refreshCurrentRestrictions() async {
        let cur = await ActiveLockStore.shared.allCurrent()
        memoryShields = cur.shields
        memoryBlocks = cur.blocks
    }
```

(b) Load on appear — add to the `List` (e.g. after `.navigationTitle(...)`):

```swift
        .task { await refreshCurrentRestrictions() }
```

(c) Make the existing "Refresh" button (from Task 4) also reload the actor snapshot:

```swift
                Button {
                    refreshTick += 1
                    Task { await refreshCurrentRestrictions() }
                } label: { Text("Refresh") }
```

(d) Add the "Current restrictions" section at the top of the `List` (above the events section). It reads the App-Group enforcement truth synchronously (plain `UserDefaults`) and compares against the `@State` actor snapshot:

```swift
            Section {
                let truthShields = CurrentRestrictionsReader.persistedShields()
                let truthBlocks = CurrentRestrictionsReader.persistedBlocks()
                let shieldDiverges = Set(truthShields.map(\.recordKey)) != Set(memoryShields.map(\.recordKey))
                let blockDiverges = Set(truthBlocks.map(\.bundleID)) != Set(memoryBlocks.map(\.bundleID))
                let diverges = shieldDiverges || blockDiverges

                Text(diverges
                     ? "⚠️ App-Group truth and ActiveLockStore in-memory DIVERGE"
                     : "✓ enforcement truth == in-memory")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(diverges ? .orange : .secondary)

                Text("— enforcement truth (App-Group) — shields \(truthShields.count) / blocks \(truthBlocks.count)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                ForEach(Array(truthShields.enumerated()), id: \.offset) { _, s in
                    Text("SHIELD \(s.recordKey) · tier \(s.tier.rawValue) · \(s.displayName) · sources \(s.sources.map(\.rawValue).sorted().joined(separator: ",")) · exp \(s.expiresAt.map { "\($0)" } ?? "—")")
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                ForEach(Array(truthBlocks.enumerated()), id: \.offset) { _, b in
                    Text("BLOCK \(b.bundleID) · \(b.displayName)")
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                Text("— ActiveLockStore in-memory — shields \(memoryShields.count) / blocks \(memoryBlocks.count)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            } header: {
                Text("Current restrictions (device truth)")
            }
```

Accessor note (pinned): `s.tier` is `ShieldTier` — a `String`-backed enum (`ShieldTier.swift:5`) → use `s.tier.rawValue`. `s.sources` is `Set<ShieldSource>` — `ShieldSource` is `String`-backed (`ShieldRecord.swift:16`) → use `.rawValue`. `s.expiresAt` is `Date?` (`ShieldRecord.swift:66`).

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodebuild build -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Manual verification**

1. On the kid device, trigger an earned-pool lock (exhaust the pool) or a per-app limit.
2. Open SpikeView → "Screen-Time Events" → "Current restrictions" section.
3. Confirm the earned-pool lock shows as a shield with `sources` including `earnedTime`.
4. Background the app while the extension writes a lock, reopen, and confirm the divergence banner correctly flags when in-memory lags the App-Group truth.

- [ ] **Step 8: Commit**

```bash
git add "Evlin iOS/Services/CurrentRestrictionsReader.swift" "Evlin iOSTests/CurrentRestrictionsReaderTests.swift" "Evlin iOS/Views/Debug/ScreenTimeEventLogView.swift" "Evlin iOS.xcodeproj/project.pbxproj"
git commit -m "feat(screentime): A0.5 current-restrictions truth reader + debug section"
```

---

## Self-Review Notes

- **Spec coverage (A0 slice):** `ScreenTimeEvent` schema (Task 1) ✓; os_log + App-Group ring buffer sink (Task 2) ✓; extension emission points — threshold/drop/reset/recompute (Task 3) ✓; in-app debug screen (Task 4) ✓; **A0.5 current-restrictions truth reader + debug section + divergence banner (Task 5) ✓** (spec Part B.1, success criterion 7). Backend `screen_time_events` sink + parent/kid-app emission + the snapshot **upload** and chat "prefer device snapshot" are intentionally deferred to Plan 3 (A1) / Tier 2 per the spec's scoping.
- **Placeholders:** none — every code step shows real code; the one judgment call (hoisting `appliedCount` in Task 3 Step 6) is spelled out.
- **Type consistency:** `ScreenTimeEventLog.emit/read/clear` names and the `emit(_:into:)`/`read(from:)`/`clear(in:)` test-injection overloads are used consistently across Tasks 2–4; enum raw values are pinned by Task 1's `test_enumsUseStableRawValues`.
- **Deferred to A1/Tier2:** device-facing `deviceID` for the parent app; `policy_gen`/`corr_id` population (best-effort now, populated when the backend pipeline lands); `nums` population at each site (added incrementally as each Tier-2 fix needs the numbers it asserts on).
