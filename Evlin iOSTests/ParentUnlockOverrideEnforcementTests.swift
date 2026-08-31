import Foundation
import FamilyControls
import DeviceActivity
import XCTest
@testable import Evlin_iOS

final class ParentUnlockOverrideEnforcementTests: XCTestCase {
    private let ownerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_777_255_200)

    @MainActor
    func testReflectionRecordAndEffectiveShieldSurviveOverride() async throws {
        let selectedKey = "savedList:BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let reflectionKey = "all:reflection:CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        let selected = makeShield(
            key: selectedKey,
            tier: .savedList,
            sources: [.manual, .earnedTime, .taskPause, .limit]
        )
        let reflection = makeShield(
            key: reflectionKey,
            tier: .allApps,
            appliesToAll: true,
            sources: [.manual]
        )

        let projected = ParentUnlockOverridePolicy.project(
            shields: [selectedKey: selected, reflectionKey: reflection],
            blocks: [:],
            snapshot: activeSnapshot(),
            reflectionActive: true
        )

        XCTAssertNil(projected.shields[selectedKey])
        XCTAssertEqual(projected.shields[reflectionKey], reflection)
        XCTAssertEqual(
            ActiveShieldProjection.make(records: Array(projected.shields.values)).applications,
            .all
        )

        let harness = try makeOverrideHarness()
        _ = try harness.store.ingest(
            envelope(),
            expectedOwner: ownerID,
            now: now
        )
        let suiteName = "parent-unlock-real-projection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var observed: ParentUnlockOverridePolicy.Projection?
        let lockStore = ActiveLockStore(
            defaults: defaults,
            parentUnlockOverrideStore: harness.store,
            parentUnlockOverrideOwnerProvider: { self.ownerID },
            effectiveProjectionObserver: { observed = $0 }
        )

        _ = await lockStore.addShield(selected)
        _ = await lockStore.addShield(reflection)
        _ = await lockStore.addBlock(makeBlock(bundleID: "com.example.blocked"))

        let effective = try XCTUnwrap(observed)
        XCTAssertNil(effective.shields[selectedKey])
        XCTAssertEqual(effective.shields[reflectionKey], reflection)
        XCTAssertTrue(effective.blocks.isEmpty)
        let durable = await lockStore.allCurrent()
        XCTAssertEqual(Set(durable.shields.map(\.recordKey)), [selectedKey, reflectionKey])
        XCTAssertEqual(durable.blocks.map(\.bundleID), ["com.example.blocked"])
    }

    func testOverrideRemovesManualEarnedTaskAndLimitEffects() {
        let manual = makeShield(key: "manual", tier: .exactApp, sources: [.manual])
        let earned = makeShield(key: "earned", tier: .savedList, sources: [.earnedTime])
        let task = makeShield(key: "task", tier: .category, sources: [.taskPause])
        let limit = makeShield(key: "limit", tier: .exactApp, sources: [.limit])
        let future = makeShield(
            key: "future",
            tier: .exactApp,
            sources: [ShieldSource(rawValue: "future-source")]
        )
        let block = makeBlock(bundleID: "com.example.blocked")

        let projected = ParentUnlockOverridePolicy.project(
            shields: [
                manual.recordKey: manual,
                earned.recordKey: earned,
                task.recordKey: task,
                limit.recordKey: limit,
                future.recordKey: future,
            ],
            blocks: [block.bundleID: block],
            snapshot: activeSnapshot(),
            reflectionActive: false
        )

        XCTAssertNil(projected.shields[manual.recordKey])
        XCTAssertNil(projected.shields[earned.recordKey])
        XCTAssertNil(projected.shields[task.recordKey])
        XCTAssertNil(projected.shields[limit.recordKey])
        XCTAssertEqual(projected.shields[future.recordKey], future)
        XCTAssertTrue(projected.blocks.isEmpty)
    }

    func testNoSnapshotLeavesProjectionUnchanged() {
        let shield = makeShield(
            key: "mixed",
            tier: .savedList,
            sources: [.manual, .earnedTime, .taskPause, .limit]
        )
        let block = makeBlock(bundleID: "com.example.blocked")
        let originalShields = [shield.recordKey: shield]
        let originalBlocks = [block.bundleID: block]

        let projected = ParentUnlockOverridePolicy.project(
            shields: originalShields,
            blocks: originalBlocks,
            snapshot: nil,
            reflectionActive: false
        )

        XCTAssertEqual(projected.shields, originalShields)
        XCTAssertEqual(projected.blocks, originalBlocks)
    }

    func testTimedLockExpiryPreservesPreexistingPermanentManualOwnership() {
        let key = DefaultLockGroup.shared.recordKey
        let existing = makeShield(
            key: key,
            tier: .savedList,
            sources: [.manual]
        )

        let locked = DefaultGroupLockApplier.reconcilingTimedParentLock(
            in: [key: existing],
            selection: FamilyActivitySelection(),
            childID: ownerID,
            commandID: UUID(),
            locked: true
        )
        XCTAssertEqual(locked[key]?.sources, [.manual, .parentTimedLock])

        let expired = DefaultGroupLockApplier.reconcilingTimedParentLock(
            in: locked,
            selection: FamilyActivitySelection(),
            childID: ownerID,
            commandID: UUID(),
            locked: false
        )
        XCTAssertEqual(expired[key]?.sources, [.manual])
    }

    func testTimedLockExpiryDeletesTemporaryOnlyRecord() {
        let key = DefaultLockGroup.shared.recordKey
        let locked = DefaultGroupLockApplier.reconcilingTimedParentLock(
            in: [:],
            selection: FamilyActivitySelection(),
            childID: ownerID,
            commandID: UUID(),
            locked: true
        )

        XCTAssertEqual(locked[key]?.sources, [.parentTimedLock])

        let expired = DefaultGroupLockApplier.reconcilingTimedParentLock(
            in: locked,
            selection: FamilyActivitySelection(),
            childID: ownerID,
            commandID: UUID(),
            locked: false
        )
        XCTAssertNil(expired[key])
    }

    func testTimedLockDoesNotRunUnlockSuppressionProjection() {
        let shield = makeShield(key: "manual", tier: .savedList, sources: [.manual])
        let projected = ParentUnlockOverridePolicy.project(
            shields: [shield.recordKey: shield],
            blocks: [:],
            snapshot: activeSnapshot(desiredLocked: true),
            reflectionActive: false
        )

        XCTAssertEqual(projected.shields[shield.recordKey], shield)
    }

    func testOverrideFiltersEachScopeIndependently() {
        let key = "mixed"
        let record = makeShield(
            key: key,
            tier: .savedList,
            sources: [.manual, .earnedTime, .taskPause, .limit]
        )

        let cases: [(name: String, scope: ParentUnlockOverrideScope, expectedSources: Set<ShieldSource>)] = [
            ("manual", .manual, [.earnedTime, .taskPause, .limit]),
            ("earned_time", .earnedTime, [.manual, .taskPause, .limit]),
            ("task_pause", .taskPause, [.manual, .earnedTime, .limit]),
            ("device_limit", .deviceLimit, [.manual, .earnedTime, .taskPause]),
            ("per_app_limit", .perAppLimit, [.manual, .earnedTime, .taskPause]),
        ]

        for testCase in cases {
            let projected = ParentUnlockOverridePolicy.project(
                shields: [key: record],
                blocks: [:],
                snapshot: activeSnapshot(scopes: [testCase.scope]),
                reflectionActive: false
            )

            XCTAssertEqual(
                projected.shields[key]?.sources,
                testCase.expectedSources,
                testCase.name
            )
        }
    }

    func testEarnedTimeSuppressionDoesNotRequireManualSource() {
        let key = "earned-and-task"
        let record = makeShield(
            key: key,
            tier: .savedList,
            sources: [.earnedTime, .taskPause]
        )

        let projected = ParentUnlockOverridePolicy.project(
            shields: [key: record],
            blocks: [:],
            snapshot: activeSnapshot(scopes: [.earnedTime]),
            reflectionActive: false
        )

        XCTAssertEqual(projected.shields[key]?.sources, [.taskPause])
    }

    func testCancelledAndExpiredSnapshotsLeaveProjectionUnchanged() {
        let shield = makeShield(key: "manual", tier: .exactApp, sources: [.manual])
        let block = makeBlock(bundleID: "com.example.blocked")
        let originalShields = [shield.recordKey: shield]
        let originalBlocks = [block.bundleID: block]

        for status in [
            ParentUnlockOverrideSnapshot.Status.cancelled,
            ParentUnlockOverrideSnapshot.Status.expired,
        ] {
            let snapshot = ParentUnlockOverrideSnapshot(
                envelope: envelope(cancelled: status == .cancelled),
                status: status
            )
            let projected = ParentUnlockOverridePolicy.project(
                shields: originalShields,
                blocks: originalBlocks,
                snapshot: snapshot,
                reflectionActive: false
            )

            XCTAssertEqual(projected.shields, originalShields, "\(status)")
            XCTAssertEqual(projected.blocks, originalBlocks, "\(status)")
        }
    }

    @MainActor
    func testPersistHappensBeforeAnyManagedSettingsMutation() async throws {
        let harness = try makeOverrideHarness()
        var projectionObservedPersistedSnapshot = false

        let disposition = try await ParentUnlockOverrideCommandApplication.apply(
            envelope: envelope(),
            expectedOwner: ownerID,
            now: now,
            store: harness.store,
            setTimedParentLock: { _, _, _ in }
        ) {
            projectionObservedPersistedSnapshot = try harness.store.read(
                expectedOwner: self.ownerID
            )?.status == .active
        }

        XCTAssertEqual(disposition, .applied)
        XCTAssertTrue(projectionObservedPersistedSnapshot)
    }

    @MainActor
    func testCrossDayCancellationDoesNotReapplyPriorDayRestrictions() async throws {
        let harness = try makeOverrideHarness()
        var timedLockMutations: [Bool] = []
        var projectionCount = 0

        let disposition = try await ParentUnlockOverrideCommandApplication.apply(
            envelope: envelope(cancelled: true),
            expectedOwner: ownerID,
            now: now,
            currentUsageDate: "2026-04-27",
            store: harness.store,
            setTimedParentLock: { locked, _, _ in
                timedLockMutations.append(locked)
            },
            project: {
                projectionCount += 1
            }
        )

        XCTAssertEqual(disposition, .applied)
        XCTAssertEqual(timedLockMutations, [false])
        XCTAssertEqual(projectionCount, 0)
    }

    @MainActor
    func testSameDayCancellationReappliesCurrentRestrictions() async throws {
        let harness = try makeOverrideHarness()
        var projectionCount = 0

        let disposition = try await ParentUnlockOverrideCommandApplication.apply(
            envelope: envelope(cancelled: true),
            expectedOwner: ownerID,
            now: now,
            currentUsageDate: "2026-04-26",
            store: harness.store,
            setTimedParentLock: { _, _, _ in },
            project: {
                projectionCount += 1
            }
        )

        XCTAssertEqual(disposition, .applied)
        XCTAssertEqual(projectionCount, 1)
    }

    @MainActor
    func testMainAppEntryPointAppliesDurableOverrideBeforeProjection() async throws {
        let harness = try makeOverrideHarness()
        var projectedRevision: Int64?
        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            parentUnlockOverrideStore: harness.store,
            parentUnlockOverrideNow: { self.now },
            parentUnlockOverrideProjection: {
                projectedRevision = try harness.store.read(
                    expectedOwner: self.ownerID
                )?.revision
            }
        )

        let result = await executor.execute(
            overrideCommand(action: .parentUnlockOverride),
            expectedChildID: ownerID,
            identityIsCurrent: { $0 == self.ownerID }
        )

        guard case .confirmedExact = result else {
            return XCTFail("parent override must confirm after projection")
        }
        XCTAssertEqual(projectedRevision, 1)
    }

    @MainActor
    func testNSEEntryPointAppliesDurableOverrideBeforeProjection() async throws {
        let harness = try makeOverrideHarness()
        var projectedRevision: Int64?

        let disposition = try await ParentUnlockOverrideNSEApplication.apply(
            command: overrideCommand(action: .parentUnlockOverride),
            expectedOwner: ownerID,
            now: now,
            store: harness.store,
            setTimedParentLock: { _, _, _ in }
        ) {
            projectedRevision = try harness.store.read(
                expectedOwner: self.ownerID
            )?.revision
        }

        XCTAssertEqual(disposition, .applied)
        XCTAssertEqual(projectedRevision, 1)
    }

    @MainActor
    func testNSEEntryPointArmsExpiryBeforeRemovingRestrictions() async throws {
        let harness = try makeOverrideHarness()
        let scheduler = OrderedOverrideExpiryScheduler()

        let disposition = try await ParentUnlockOverrideNSEApplication.apply(
            command: overrideCommand(action: .parentUnlockOverride),
            expectedOwner: ownerID,
            now: now,
            store: harness.store,
            expiryScheduler: scheduler,
            setTimedParentLock: { _, _, _ in }
        ) {
            scheduler.recordProjection()
        }

        XCTAssertEqual(disposition, .applied)
        XCTAssertEqual(scheduler.events, ["activities", "start", "project"])
    }

    @MainActor
    func testProjectionCommitRejectsAcknowledgementWhenDurableStateCannotReload() async throws {
        let suiteName = "override-projection-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lockStore = ActiveLockStore(defaults: defaults)
        defaults.set(Data("not-json-or-plist".utf8), forKey: "evlin.blockRecords")

        do {
            try await ParentUnlockOverrideProjectionApplication.reapplyCurrentRestrictions(
                store: lockStore
            )
            XCTFail("a command must not confirm when restrictions were not projected")
        } catch let error as ParentUnlockOverrideCommandApplicationError {
            XCTAssertEqual(error, .projectionFailed)
        }
    }

    @MainActor
    func testCommandPollerEntryPointAppliesDurableOverrideBeforeProjection() async throws {
        let harness = try makeOverrideHarness()
        var projectedRevision: Int64?

        let disposition = try await CommandPoller.applyParentUnlockOverride(
            command: overrideCommand(action: .parentUnlockOverride),
            expectedOwner: ownerID,
            now: now,
            store: harness.store,
            expiryScheduler: nil
        ) {
            projectedRevision = try harness.store.read(
                expectedOwner: self.ownerID
            )?.revision
        }

        XCTAssertEqual(disposition, .applied)
        XCTAssertEqual(projectedRevision, 1)
    }

    @MainActor
    func testMasterLockPersistsRevisionBeforeApplyingManualLock() async throws {
        let harness = try makeOverrideHarness()
        var observedLocked: Bool?
        var observedRevision: Int64?

        let prepared = try ParentMasterControlCommandApplication.prepare(
            command: masterCommand(action: .parentMasterLock, revision: 2),
            expectedOwner: ownerID,
            now: now,
            store: harness.store
        )
        if let locked = prepared.desiredLocked {
            observedLocked = locked
            observedRevision = try harness.store.read(expectedOwner: self.ownerID)?.revision
        }

        XCTAssertEqual(prepared.disposition, .applied)
        XCTAssertEqual(observedLocked, true)
        XCTAssertEqual(observedRevision, 2)
    }

    @MainActor
    func testMasterUnlockPersistsRevisionBeforeRemovingOnlyManualSource() async throws {
        let harness = try makeOverrideHarness()
        var observedLocked: Bool?

        let prepared = try ParentMasterControlCommandApplication.prepare(
            command: masterCommand(action: .parentMasterUnlock, revision: 3),
            expectedOwner: ownerID,
            now: now,
            store: harness.store
        )
        if let locked = prepared.desiredLocked {
            observedLocked = locked
        }

        XCTAssertEqual(prepared.disposition, .applied)
        XCTAssertEqual(observedLocked, false)
        XCTAssertEqual(try harness.store.read(expectedOwner: ownerID)?.revision, 3)
    }

    @MainActor
    func testPermanentMasterControlClearsPriorTimedParentLockSource() async throws {
        let harness = try makeOverrideHarness()
        _ = try harness.store.ingest(
            envelope(revision: 1, desiredLocked: true),
            expectedOwner: ownerID,
            now: now
        )

        let prepared = try ParentMasterControlCommandApplication.prepare(
            command: masterCommand(action: .parentMasterUnlock, revision: 2),
            expectedOwner: ownerID,
            now: now,
            store: harness.store
        )

        XCTAssertEqual(prepared.disposition, .applied)
        XCTAssertEqual(prepared.desiredLocked, false)
        XCTAssertTrue(prepared.clearsTimedParentLock)
    }

    @MainActor
    func testStalePermanentMasterControlDoesNotClearTimedParentLockSource() async throws {
        let harness = try makeOverrideHarness()
        _ = try harness.store.ingest(
            envelope(revision: 3, desiredLocked: true),
            expectedOwner: ownerID,
            now: now
        )

        let prepared = try ParentMasterControlCommandApplication.prepare(
            command: masterCommand(action: .parentMasterUnlock, revision: 2),
            expectedOwner: ownerID,
            now: now,
            store: harness.store
        )

        XCTAssertEqual(prepared.disposition, .superseded(currentRevision: 3))
        XCTAssertNil(prepared.desiredLocked)
        XCTAssertFalse(prepared.clearsTimedParentLock)
    }

    @MainActor
    func testStaleMasterCommandCannotMutateLocalEnforcement() async throws {
        let harness = try makeOverrideHarness()
        _ = try harness.store.ingest(
            masterEnvelope(revision: 5),
            expectedOwner: ownerID,
            now: now
        )
        var mutationCount = 0

        let prepared = try ParentMasterControlCommandApplication.prepare(
            command: masterCommand(action: .parentMasterLock, revision: 4),
            expectedOwner: ownerID,
            now: now,
            store: harness.store
        )
        if prepared.desiredLocked != nil {
            mutationCount += 1
        }

        XCTAssertEqual(prepared.disposition, .superseded(currentRevision: 5))
        XCTAssertEqual(mutationCount, 0)
    }

    @MainActor
    func testActionExecutorConnectsMasterCommandToLocalEnforcement() async throws {
        let harness = try makeOverrideHarness()
        var mutations: [Bool] = []
        let executor = ActionExecutor(
            activityScheduler: LockSchedulerSpy(),
            authorizationStatusProvider: { .approved },
            parentUnlockOverrideStore: harness.store,
            parentUnlockOverrideNow: { self.now },
            parentMasterLockMutation: {
                mutations.append(true)
                return true
            }
        )

        let result = await executor.execute(
            masterCommand(action: .parentMasterLock, revision: 2),
            expectedChildID: ownerID,
            identityIsCurrent: { $0 == self.ownerID }
        )

        guard case .confirmedExact(let verb, _, _) = result else {
            return XCTFail("master lock must confirm after local enforcement")
        }
        XCTAssertEqual(verb.rawValue, "shield")
        XCTAssertEqual(mutations, [true])
    }

    @MainActor
    func testActionExecutorClearsTimedSourceBeforePermanentMasterMutation() async throws {
        let harness = try makeOverrideHarness()
        var effects: [String] = []
        let executor = ActionExecutor(
            activityScheduler: LockSchedulerSpy(),
            authorizationStatusProvider: { .approved },
            parentUnlockOverrideStore: harness.store,
            parentUnlockOverrideNow: { self.now },
            parentTimedLockMutation: { locked in
                effects.append("timed:\(locked)")
                return true
            },
            parentMasterUnlockMutation: {
                effects.append("manual:false")
                return true
            }
        )

        _ = await executor.execute(
            masterCommand(action: .parentMasterUnlock, revision: 2),
            expectedChildID: ownerID,
            identityIsCurrent: { $0 == self.ownerID }
        )

        XCTAssertEqual(effects, ["timed:false", "manual:false"])
    }

    func testOverrideAckVerbsFitBackendContract() {
        XCTAssertEqual(
            ParentUnlockOverrideAck.verb(for: .parentMasterLock),
            "shield"
        )
        XCTAssertEqual(
            ParentUnlockOverrideAck.verb(for: .parentMasterUnlock),
            "unshield"
        )
        XCTAssertEqual(
            ParentUnlockOverrideAck.verb(for: .parentUnlockOverride),
            "unshield_all"
        )
        XCTAssertEqual(
            ParentUnlockOverrideAck.verb(for: .parentLockOverride),
            "shield"
        )
        XCTAssertEqual(
            ParentUnlockOverrideAck.verb(for: .parentUnlockOverrideCancel),
            "reconcile"
        )
        for action in [
            CommandAction.parentMasterLock,
            .parentMasterUnlock,
            .parentUnlockOverride,
            .parentLockOverride,
            .parentUnlockOverrideCancel,
        ] {
            XCTAssertLessThanOrEqual(ParentUnlockOverrideAck.verb(for: action).count, 16)
        }
    }

    @MainActor
    func testCancelledOrExpiredOverrideReconcilesLatestRecords() async throws {
        let harness = try makeOverrideHarness()
        let selected = makeShield(
            key: "savedList:latest",
            tier: .savedList,
            sources: [.manual, .earnedTime, .taskPause, .limit]
        )
        let block = makeBlock(bundleID: "com.example.latest")

        for snapshot in [
            ParentUnlockOverrideSnapshot(
                envelope: envelope(cancelled: true),
                status: .cancelled
            ),
            ParentUnlockOverrideSnapshot(
                envelope: envelope(),
                status: .expired
            ),
        ] {
            let projected = try ParentUnlockOverrideProjectionApplication.project(
                shields: [selected.recordKey: selected],
                blocks: [block.bundleID: block],
                snapshot: snapshot
            )

            XCTAssertEqual(projected.shields[selected.recordKey], selected)
            XCTAssertEqual(projected.blocks[block.bundleID], block)
        }
        _ = harness
    }

    private func activeSnapshot(
        scopes: Set<ParentUnlockOverrideScope> = [
            .manual,
            .earnedTime,
            .taskPause,
            .deviceLimit,
            .perAppLimit,
        ],
        desiredLocked: Bool = false
    ) -> ParentUnlockOverrideSnapshot {
        ParentUnlockOverrideSnapshot(
            envelope: envelope(scopes: scopes, desiredLocked: desiredLocked),
            status: .active
        )
    }

    private func envelope(
        revision: Int64 = 1,
        scopes: Set<ParentUnlockOverrideScope> = [
            .manual,
            .earnedTime,
            .taskPause,
            .deviceLimit,
            .perAppLimit,
        ],
        cancelled: Bool = false,
        desiredLocked: Bool = false
    ) -> ParentUnlockOverrideEnvelope {
        ParentUnlockOverrideEnvelope(
            revision: revision,
            childDeviceID: ownerID,
            usageDate: "2026-04-26",
            startedAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            operationID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            desiredLocked: desiredLocked,
            scopes: scopes,
            cancelled: cancelled
        )
    }

    private func overrideCommand(action: CommandAction) -> LockCommand {
        LockCommand(
            id: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!,
            action: action,
            tier: nil,
            target: CommandTarget(
                originalRequest: "parent unlock override",
                targetDisplay: "Parent override",
                targetChildID: ownerID
            ),
            durationMinutes: nil,
            issuedAt: now,
            parentUnlockOverride: envelope(cancelled: action == .parentUnlockOverrideCancel)
        )
    }

    private func masterCommand(action: CommandAction, revision: Int64) -> LockCommand {
        LockCommand(
            id: UUID(),
            action: action,
            tier: nil,
            target: CommandTarget(
                originalRequest: "parent master control",
                targetDisplay: "Screen Time",
                targetChildID: ownerID
            ),
            durationMinutes: nil,
            issuedAt: now,
            parentUnlockOverride: masterEnvelope(revision: revision)
        )
    }

    private func masterEnvelope(revision: Int64) -> ParentUnlockOverrideEnvelope {
        ParentUnlockOverrideEnvelope(
            revision: revision,
            childDeviceID: ownerID,
            usageDate: "2026-04-26",
            startedAt: now,
            expiresAt: now,
            operationID: UUID(),
            scopes: [.manual, .earnedTime, .taskPause, .deviceLimit, .perAppLimit],
            cancelled: true
        )
    }

    private func makeOverrideHarness() throws -> (
        store: ParentUnlockOverrideStore,
        fileURL: URL
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "parent-unlock-enforcement-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(ParentUnlockOverrideStore.fileName)
        return (ParentUnlockOverrideStore(fileURL: fileURL), fileURL)
    }

    private func makeShield(
        key: String,
        tier: ShieldTier,
        appliesToAll: Bool = false,
        sources: Set<ShieldSource>
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: key,
            tier: tier,
            targetKey: key,
            displayName: key,
            lastCommandID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: appliesToAll,
            issuedAt: now,
            expiresAt: nil,
            originalRequest: key,
            targetChildID: ownerID,
            sources: sources
        )
    }

    private func makeBlock(bundleID: String) -> BlockRecord {
        BlockRecord(
            bundleID: bundleID,
            displayName: bundleID,
            blockedAt: now,
            lastCommandID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            originalRequest: bundleID,
            targetChildID: ownerID
        )
    }
}

private final class OrderedOverrideExpiryScheduler: DeviceActivityScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []

    func recordProjection() {
        lock.lock()
        events.append("project")
        lock.unlock()
    }

    func startMonitoring(
        _ name: DeviceActivityName,
        during schedule: DeviceActivitySchedule
    ) throws {
        lock.lock()
        events.append("start")
        lock.unlock()
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        try startMonitoring(activity, during: schedule)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {}
    func stopMonitoring() {}

    func monitoredActivities() -> [DeviceActivityName] {
        lock.lock()
        events.append("activities")
        lock.unlock()
        return []
    }
}
