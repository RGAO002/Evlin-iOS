import CryptoKit
import DeviceActivity
import FamilyControls
import XCTest
@testable import Evlin_iOS

final class ActionExecutorTests: XCTestCase {
    override func setUp() async throws {
        await clearActiveLockState()
    }

    override func tearDown() async throws {
        await clearActiveLockState()
    }

    func testTimedBlockRequestsAutoUnblockSchedule() async throws {
        let bundleID = "com.burbn.instagram"
        let spy = DeviceActivitySchedulerSpy()
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved }
        )
        let command = makeBlockCommand(bundleID: bundleID, minutes: 15)

        _ = await executor.execute(command)

        XCTAssertEqual(spy.started.count, 1)
        let request = try XCTUnwrap(spy.started.first)
        XCTAssertEqual(request.name.rawValue, expectedBlockActivityName(bundleID: bundleID))
        XCTAssertFalse(request.schedule.repeats)

        let startSeconds = try secondsSinceStartOfDay(request.schedule.intervalStart)
        let endSeconds = try secondsSinceStartOfDay(request.schedule.intervalEnd)
        let interval = (endSeconds - startSeconds + 86_400) % 86_400
        XCTAssertGreaterThan(interval, 0)
    }

    func testIdentityChangeWhileMutationIsDelayedCannotPersistOldBlock() async {
        let oldID = UUID()
        let newID = UUID()
        var currentID = oldID
        var resumeMutation: CheckedContinuation<Void, Never>?
        let spy = DeviceActivitySchedulerSpy()
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved },
            beforeMutation: {
                await withCheckedContinuation { resumeMutation = $0 }
            }
        )
        let command = makeBlockCommand(
            bundleID: "com.example.old-family",
            minutes: 15
        )

        let execution = Task {
            await executor.execute(
                command,
                expectedChildID: oldID,
                identityIsCurrent: { $0 == currentID }
            )
        }
        while resumeMutation == nil { await Task.yield() }
        currentID = newID
        resumeMutation?.resume()
        let result = await execution.value

        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        let blocks = await ActiveLockStore.shared.allCurrent().blocks
        XCTAssertFalse(blocks.contains { $0.bundleID == "com.example.old-family" })
        XCTAssertTrue(spy.started.isEmpty)
    }

    @MainActor
    func testIdentityChangeBeforeSavedListMutationCannotPersistOldConfig() async {
        let store = EarnedTimeStore.shared
        let defaults = UserDefaults(suiteName: EarnedTimeStore.appGroupSuiteName)
        let originalID = store.lockedSetID
        let originalTokenData = store.lockedSetTokenData
        let originalSavedListTokens = defaults?.object(forKey: "evlin.savedListTokens")
        defer {
            if let originalID {
                store.saveLockedSetID(originalID, tokenData: originalTokenData)
            } else {
                defaults?.removeObject(forKey: "earned.lockedSetID")
                defaults?.removeObject(forKey: "earned.lockedSetTokenData")
            }
            if let originalSavedListTokens {
                defaults?.set(originalSavedListTokens, forKey: "evlin.savedListTokens")
            } else {
                defaults?.removeObject(forKey: "evlin.savedListTokens")
            }
            defaults?.synchronize()
        }

        let priorListID = UUID()
        let commandListID = UUID()
        let oldChildID = UUID()
        let newChildID = UUID()
        var currentChildID = oldChildID
        var resumeMutation: CheckedContinuation<Void, Never>?
        store.saveLockedSetID(priorListID.uuidString, tokenData: nil)
        DefaultLockGroupStore.save(FamilyActivitySelection())

        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            beforeMutation: {
                await withCheckedContinuation { resumeMutation = $0 }
            }
        )
        var target = CommandTarget(
            listName: "Locked set",
            listID: commandListID,
            originalRequest: "lock Locked set",
            targetDisplay: "Locked set",
            targetChildID: oldChildID
        )
        target.defaultLockGroup = true
        let command = LockCommand(
            id: UUID(),
            action: .shield,
            tier: .savedList,
            target: target,
            durationMinutes: nil,
            issuedAt: Date()
        )

        let execution = Task {
            await executor.execute(
                command,
                expectedChildID: oldChildID,
                identityIsCurrent: { $0 == currentChildID }
            )
        }
        while resumeMutation == nil { await Task.yield() }
        let persistedWhileSuspended = store.lockedSetID
        currentChildID = newChildID
        resumeMutation?.resume()
        let result = await execution.value

        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        XCTAssertEqual(persistedWhileSuspended, priorListID.uuidString)
        XCTAssertEqual(store.lockedSetID, priorListID.uuidString)
    }

    private func makeBlockCommand(bundleID: String, minutes: Int) -> LockCommand {
        LockCommand(
            id: UUID(),
            action: .block,
            tier: .exactApp,
            target: CommandTarget(
                bundleID: bundleID,
                originalRequest: "block Instagram",
                targetDisplay: "Instagram",
                targetChildID: UUID()
            ),
            durationMinutes: minutes,
            issuedAt: Date()
        )
    }

    private func clearActiveLockState() async {
        _ = await ActiveLockStore.shared.unblockAll()
        _ = await ActiveLockStore.shared.unshieldAll()

        let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
        defaults?.removeObject(forKey: "evlin.blockRecords")
        defaults?.removeObject(forKey: "evlin.shieldRecords")
    }

    private func expectedBlockActivityName(bundleID: String) -> String {
        "evlin.block.\(sha256Hex16(Data(bundleID.utf8)))"
    }

    private func sha256Hex16(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func secondsSinceStartOfDay(
        _ components: DateComponents,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        let hour = try XCTUnwrap(components.hour, "Missing hour", file: file, line: line)
        let minute = try XCTUnwrap(components.minute, "Missing minute", file: file, line: line)
        let second = try XCTUnwrap(components.second, "Missing second", file: file, line: line)
        XCTAssert((0..<24).contains(hour), "Hour is outside a day", file: file, line: line)
        XCTAssert((0..<60).contains(minute), "Minute is outside an hour", file: file, line: line)
        XCTAssert((0..<60).contains(second), "Second is outside a minute", file: file, line: line)
        return hour * 3_600 + minute * 60 + second
    }
}

private final class DeviceActivitySchedulerSpy: DeviceActivityScheduling {
    private(set) var started: [(name: DeviceActivityName, schedule: DeviceActivitySchedule)] = []
    private(set) var startedWithEvents: [(name: DeviceActivityName, schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent])] = []
    private(set) var stopped: [[DeviceActivityName]?] = []
    /// Live armed set backing `monitoredActivities()` — added on start, removed
    /// on stop.
    private(set) var activeActivities: Set<DeviceActivityName> = []

    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        started.append((name, schedule))
        activeActivities.insert(name)
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startedWithEvents.append((activity, schedule, events))
        activeActivities.insert(activity)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopped.append(activities)
        for a in activities { activeActivities.remove(a) }
    }

    func stopMonitoring() {
        stopped.append(nil)
        activeActivities.removeAll()
    }

    func monitoredActivities() -> [DeviceActivityName] { Array(activeActivities) }
}
