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

    func testExpectedIdentityWithoutCheckerFailsClosed() async {
        let spy = DeviceActivitySchedulerSpy()
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved }
        )

        let result = await executor.execute(
            makeBlockCommand(bundleID: "com.example.missing-checker", minutes: 15),
            expectedChildID: UUID()
        )

        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        let blocks = await ActiveLockStore.shared.allCurrent().blocks
        XCTAssertFalse(blocks.contains { $0.bundleID == "com.example.missing-checker" })
        XCTAssertTrue(spy.started.isEmpty)
    }

    func testIdentityChangeAfterBlockEffectiveStateReadRollsBackBlockAndSchedule() async {
        let oldID = UUID()
        var currentID = oldID
        var reachedCheckpoint = false
        let spy = DeviceActivitySchedulerSpy()
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved },
            afterMutationCheckpoint: { checkpoint in
                guard checkpoint == .blockEffectiveStateResolved else { return }
                reachedCheckpoint = true
                currentID = UUID()
            }
        )

        let result = await executor.execute(
            makeBlockCommand(bundleID: "com.example.old-block", minutes: 15),
            expectedChildID: oldID,
            identityIsCurrent: { $0 == currentID }
        )

        XCTAssertTrue(reachedCheckpoint)
        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        let blocks = await ActiveLockStore.shared.allCurrent().blocks
        XCTAssertFalse(blocks.contains { $0.bundleID == "com.example.old-block" })
        XCTAssertTrue(spy.started.isEmpty)
    }

    func testBlockRollbackDoesNotOverwriteNewerDurableSameBundleWrite() async {
        let oldID = UUID()
        let newerID = UUID()
        let bundleID = "com.example.same-block"
        let newerRecord = BlockRecord(
            bundleID: bundleID,
            displayName: "New Family Block",
            blockedAt: Date(timeIntervalSince1970: 2_000),
            lastCommandID: UUID(),
            originalRequest: "new family block",
            targetChildID: newerID,
            expiresAt: nil
        )
        var currentID = oldID
        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            afterMutationCheckpoint: { checkpoint in
                guard checkpoint == .blockEffectiveStateResolved else { return }
                self.persistBlockRecords([bundleID: newerRecord])
                currentID = newerID
            }
        )

        let result = await executor.execute(
            makeBlockCommand(bundleID: bundleID, minutes: 15),
            expectedChildID: oldID,
            identityIsCurrent: { $0 == currentID }
        )

        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        let durable = await ActiveLockStore().allCurrent().blocks
        XCTAssertEqual(durable.first { $0.bundleID == bundleID }, newerRecord)
    }

    func testIdentityChangeInsideBlockStartMonitoringCancelsNewScheduleAndRollsBack() async {
        let oldID = UUID()
        var currentID = oldID
        let spy = DeviceActivitySchedulerSpy()
        spy.onStart = { currentID = UUID() }
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved }
        )
        let bundleID = "com.example.post-schedule-block"

        let result = await executor.execute(
            makeBlockCommand(bundleID: bundleID, minutes: 15),
            expectedChildID: oldID,
            identityIsCurrent: { $0 == currentID }
        )

        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        let blocks = await ActiveLockStore.shared.allCurrent().blocks
        XCTAssertTrue(blocks.isEmpty)
        XCTAssertTrue(spy.activeActivities.isEmpty)
        XCTAssertTrue(spy.stopped.contains { $0 == [DeviceActivityName(expectedBlockActivityName(bundleID: bundleID))] })
    }

    func testIdentityChangeAfterShieldEffectiveStateReadRollsBackShieldAndSchedule() async {
        let oldID = UUID()
        var currentID = oldID
        var reachedCheckpoint = false
        let spy = DeviceActivitySchedulerSpy()
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved },
            afterMutationCheckpoint: { checkpoint in
                guard checkpoint == .shieldEffectiveStateResolved else { return }
                reachedCheckpoint = true
                currentID = UUID()
            }
        )
        let command = makeAllShieldCommand(childID: oldID, minutes: 15)

        let result = await executor.execute(
            command,
            expectedChildID: oldID,
            identityIsCurrent: { $0 == currentID }
        )

        XCTAssertTrue(reachedCheckpoint)
        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        let shieldsAfterRollback = await ActiveLockStore.shared.allCurrent().shields
        XCTAssertTrue(shieldsAfterRollback.isEmpty)
        XCTAssertTrue(spy.started.isEmpty)
    }

    func testIdentityChangeInsideShieldStartMonitoringCancelsNewScheduleAndRollsBack() async {
        let oldID = UUID()
        var currentID = oldID
        let spy = DeviceActivitySchedulerSpy()
        spy.onStart = { currentID = UUID() }
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved }
        )
        let command = makeAllShieldCommand(childID: oldID, minutes: 15)

        let result = await executor.execute(
            command,
            expectedChildID: oldID,
            identityIsCurrent: { $0 == currentID }
        )

        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        let shields = await ActiveLockStore.shared.allCurrent().shields
        XCTAssertTrue(shields.isEmpty)
        XCTAssertTrue(spy.activeActivities.isEmpty)
        XCTAssertTrue(spy.stopped.contains { $0?.count == 1 })
    }

    func testIdentityTeardownAfterUnshieldEffectiveStateReadDoesNotRestoreOldFamilyShield() async {
        let oldID = UUID()
        let record = makeCategoryShield(childID: oldID)
        _ = await ActiveLockStore.shared.addShield(record)
        var currentID = oldID
        var reachedCheckpoint = false
        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            afterMutationCheckpoint: { checkpoint in
                guard checkpoint == .unshieldEffectiveStateResolved else { return }
                reachedCheckpoint = true
                self.clearPersistedRestrictionsForIdentityTeardown()
                currentID = UUID()
            }
        )

        let result = await executor.execute(
            makeCategoryUnshieldCommand(childID: oldID),
            expectedChildID: oldID,
            identityIsCurrent: { $0 == currentID }
        )

        XCTAssertTrue(reachedCheckpoint)
        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        let shields = await ActiveLockStore.shared.allCurrent().shields
        XCTAssertFalse(shields.contains { $0.recordKey == record.recordKey })
    }

    func testIdentityTeardownAfterUnblockRemovalDoesNotRestoreOldFamilyBlock() async {
        let oldID = UUID()
        let bundleID = "com.example.old-family-block"
        _ = await ActiveLockStore.shared.addBlock(BlockRecord(
            bundleID: bundleID,
            displayName: "Old Family App",
            blockedAt: Date(),
            lastCommandID: UUID(),
            originalRequest: "old family block",
            targetChildID: oldID,
            expiresAt: nil
        ))
        var currentID = oldID
        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            afterMutationCheckpoint: { checkpoint in
                guard checkpoint == .unblockRemoved else { return }
                self.clearPersistedRestrictionsForIdentityTeardown()
                currentID = UUID()
            }
        )
        let command = LockCommand(
            id: UUID(),
            action: .unblock,
            tier: .exactApp,
            target: CommandTarget(
                bundleID: bundleID,
                originalRequest: "unblock old family app",
                targetDisplay: "Old Family App",
                targetChildID: oldID
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )

        let result = await executor.execute(
            command,
            expectedChildID: oldID,
            identityIsCurrent: { $0 == currentID }
        )

        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        let blocks = await ActiveLockStore.shared.allCurrent().blocks
        XCTAssertFalse(blocks.contains { $0.bundleID == bundleID })
    }

    func testShieldRollbackDoesNotOverwriteNewerDurableSameRecordWrite() async throws {
        let oldID = UUID()
        let newerID = UUID()
        let recordKey = ShieldRecord.makeRecordKey(tier: .all, targetKey: "all")
        let newerRecord = ShieldRecord(
            recordKey: recordKey,
            tier: .all,
            targetKey: "all",
            displayName: "New Family Lock",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(timeIntervalSince1970: 2_000),
            expiresAt: nil,
            originalRequest: "new family lock",
            targetChildID: newerID,
            sources: [.manual]
        )
        var currentID = oldID
        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            afterMutationCheckpoint: { checkpoint in
                guard checkpoint == .shieldEffectiveStateResolved else { return }
                self.persistShieldRecords([recordKey: newerRecord])
                currentID = newerID
            }
        )

        let result = await executor.execute(
            makeAllShieldCommand(childID: oldID, minutes: 15),
            expectedChildID: oldID,
            identityIsCurrent: { $0 == currentID }
        )

        XCTAssertEqual(result, .failed(.execution("stale_identity")))
        let durable = await ActiveLockStore().allCurrent().shields
        XCTAssertEqual(durable.first { $0.recordKey == recordKey }, newerRecord)
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

    private func makeAllShieldCommand(childID: UUID, minutes: Int) -> LockCommand {
        LockCommand(
            id: UUID(),
            action: .shield,
            tier: .all,
            target: CommandTarget(
                originalRequest: "lock everything",
                targetDisplay: "Everything",
                targetChildID: childID
            ),
            durationMinutes: minutes,
            issuedAt: Date()
        )
    }

    private func makeCategoryShield(childID: UUID) -> ShieldRecord {
        ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: .category, targetKey: "social"),
            tier: .category,
            targetKey: "social",
            displayName: "Social",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "lock Social",
            targetChildID: childID,
            sources: [.manual]
        )
    }

    private func makeCategoryUnshieldCommand(childID: UUID) -> LockCommand {
        LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .category,
            target: CommandTarget(
                categoryHint: "social",
                originalRequest: "unlock Social",
                targetDisplay: "Social",
                targetChildID: childID
            ),
            durationMinutes: nil,
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

    private func persistShieldRecords(_ records: [String: ShieldRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(records)
        let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
        defaults?.set(data, forKey: "evlin.shieldRecords")
        defaults?.synchronize()
    }

    private func persistBlockRecords(_ records: [String: BlockRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(records)
        let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
        defaults?.set(data, forKey: "evlin.blockRecords")
        defaults?.synchronize()
    }

    private func clearPersistedRestrictionsForIdentityTeardown() {
        let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
        defaults?.removeObject(forKey: "evlin.shieldRecords")
        defaults?.removeObject(forKey: "evlin.blockRecords")
        defaults?.synchronize()
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
    var onStart: () -> Void = {}

    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        started.append((name, schedule))
        activeActivities.insert(name)
        onStart()
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startedWithEvents.append((activity, schedule, events))
        activeActivities.insert(activity)
        onStart()
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
