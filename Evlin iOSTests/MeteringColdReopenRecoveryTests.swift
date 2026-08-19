import DeviceActivity
import FamilyControls
import Foundation
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringColdReopenRecoveryTests: XCTestCase {
    func testAppEntryRecoversPendingInstallFromSharedConfiguration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let entry = AppMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenTransport(),
            clock: fixture.clock,
            instanceID: UUID()
        )

        await entry.recoverIfConfigured()

        XCTAssertEqual(fixture.center.startCalls.count, 1)
    }

    func testDAMEntryLeavesFreshCurrentDayInstallForApp() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let entry = DAMMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenTransport(),
            clock: fixture.clock,
            instanceID: UUID()
        )

        await entry.recoverIfConfigured()

        XCTAssertTrue(fixture.center.startCalls.isEmpty)
        XCTAssertTrue(
            try fixture.store.read().installWork.values.contains {
                $0.phase == .pendingStart && $0.authorization == .registered
            }
        )
    }

    func testPushEntryCanRecoverPendingCurrentDayInstall() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let driver = MeteringProductionComposition.makeRecoveryDriverForTesting(
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            role: .pushApplier,
            instanceID: UUID(),
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenTransport(),
            clock: fixture.clock,
            releaseIdentityShield: { _, _ in }
        )

        try await driver.recover(ownerChildDeviceID: fixture.owner)

        XCTAssertEqual(
            fixture.center.startCalls.count,
            1,
            "a policy alert must be able to replace a stale current-day ladder without waiting for the host app"
        )
    }

    func testDAMEntryReplaysDurableV2CallbackJournalBeforeNetworkRecovery() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-cold-reopen-journal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = EarnedV2CallbackJournal(fileURL: journalURL)
        let activeRoute = try activateTodayRoute(in: fixture)
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: ColdReopenCallbackClock(
                now: fixture.clock.now.addingTimeInterval(5 * 60)
            ),
            journal: journal
        )

        let queued = try callback.handleDurably(
            MeteringAppleCallback(
                activityName: activeRoute.activityName,
                eventName: MeteringRouteNamespace.eventName(
                    routeID: activeRoute.routeID,
                    thresholdMinutes: 5
                ),
                observedAt: fixture.clock.now.addingTimeInterval(5 * 60)
            ),
            expectedOwnerChildDeviceID: fixture.owner
        )
        guard case .queued = queued else {
            return XCTFail("expected the extension callback to enter its durable journal")
        }
        XCTAssertEqual(try journal.pending(owner: fixture.owner).count, 1)
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)

        let entry = DAMMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenTransport(),
            clock: fixture.clock,
            instanceID: UUID(),
            callbackJournal: journal
        )

        await entry.recoverIfConfigured()

        XCTAssertTrue(
            try journal.pending(owner: fixture.owner).isEmpty,
            "the DeviceActivity process must import its durable callback before draining network work"
        )
        XCTAssertEqual(try fixture.store.read().sampleWork.count, 1)
    }

    func testDAMEntryDrainsDurableV2CallbackWithoutRunningDaemonRecovery() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let callbackClock = ColdReopenCallbackClock(
            now: fixture.clock.now.addingTimeInterval(5 * 60)
        )
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-fast-drain-journal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = EarnedV2CallbackJournal(fileURL: journalURL)
        let activeRoute = try activateTodayRoute(in: fixture)
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: callbackClock,
            journal: journal
        )

        let queued = try callback.handleDurably(
            MeteringAppleCallback(
                activityName: activeRoute.activityName,
                eventName: MeteringRouteNamespace.eventName(
                    routeID: activeRoute.routeID,
                    thresholdMinutes: 5
                ),
                observedAt: callbackClock.now
            ),
            expectedOwnerChildDeviceID: fixture.owner
        )
        guard case .queued = queued else {
            return XCTFail("expected a durable callback before the fast drain")
        }

        let entry = DAMMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenAcceptingTransport(owner: fixture.owner),
            clock: callbackClock,
            instanceID: UUID(),
            callbackJournal: journal
        )

        await entry.deliverPendingCallbacksIfConfigured()

        XCTAssertTrue(try journal.pending(owner: fixture.owner).isEmpty)
        let samples = try fixture.store.read().sampleWork.values
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.retry.terminal, .succeeded)
        XCTAssertEqual(
            fixture.center.activitiesReadCount,
            0,
            "the synchronous extension callback must not spend its bounded lifetime on daemon reconciliation"
        )
    }

    func testCompactEarnedCallbackSubmitsBeforeEpochRootReplay() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-direct-receipt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = EarnedV2CallbackJournal(fileURL: journalURL)
        let activeRoute = try activateTodayRoute(in: fixture)
        let callbackClock = ColdReopenCallbackClock(
            now: fixture.clock.now.addingTimeInterval(5 * 60)
        )
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: callbackClock,
            journal: journal
        )
        let transport = ColdReopenRecordingTransport(owner: fixture.owner)

        let queued = try callback.handleDurably(
            MeteringAppleCallback(
                activityName: activeRoute.activityName,
                eventName: MeteringRouteNamespace.eventName(
                    routeID: activeRoute.routeID,
                    thresholdMinutes: 5
                ),
                observedAt: callbackClock.now
            ),
            expectedOwnerChildDeviceID: fixture.owner
        )
        guard case .queued = queued else {
            return XCTFail("expected a durable callback fact")
        }
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)

        let delivered = try await journal.submitPendingTransport(
            owner: fixture.owner,
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            transport: transport,
            recordedAt: callbackClock.now
        )

        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertTrue(
            try fixture.store.read().sampleWork.isEmpty,
            "transporting an immutable callback fact must not require rewriting the epoch root"
        )
        let pending = try journal.pending(owner: fixture.owner)
        XCTAssertEqual(pending.count, 1)
        XCTAssertNotNil(pending.first?.transportReceipt)

        let duplicateDelivery = try await journal.submitPendingTransport(
            owner: fixture.owner,
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            transport: transport,
            recordedAt: callbackClock.now.addingTimeInterval(1)
        )
        XCTAssertEqual(duplicateDelivery, 0)
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testDrainBudgetStopsAfterReservedRequestsAndLeavesTheRestPending() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-budget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = EarnedV2CallbackJournal(fileURL: journalURL)
        let activeRoute = try activateTodayRoute(in: fixture)
        let callbackClock = ColdReopenCallbackClock(
            now: fixture.clock.now.addingTimeInterval(10 * 60)
        )
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: callbackClock,
            journal: journal
        )
        let transport = ColdReopenRecordingTransport(owner: fixture.owner)

        for threshold in [5, 10] {
            let queued = try callback.handleDurably(
                MeteringAppleCallback(
                    activityName: activeRoute.activityName,
                    eventName: MeteringRouteNamespace.eventName(
                        routeID: activeRoute.routeID,
                        thresholdMinutes: threshold
                    ),
                    observedAt: callbackClock.now
                ),
                expectedOwnerChildDeviceID: fixture.owner
            )
            guard case .queued = queued else {
                return XCTFail("expected a durable callback fact for t\(threshold)")
            }
        }
        XCTAssertEqual(try journal.pending(owner: fixture.owner).count, 2)

        // One pass, one request allowed: exactly one entry gets a receipt, the
        // other is left untouched (no receipt, no claim) for a later pass.
        let budget = MeteringDrainBudget(maxRequests: 1, deadline: .distantFuture)
        let delivered = try await journal.submitPendingTransport(
            owner: fixture.owner,
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            transport: transport,
            recordedAt: callbackClock.now,
            budget: budget
        )
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(budget.requestsUsed, 1)
        XCTAssertEqual(
            transport.lastRequestTimeout, 4,
            "a far deadline keeps the journal's own 4s cap"
        )
        let afterOne = try journal.pending(owner: fixture.owner)
        XCTAssertEqual(afterOne.filter { $0.transportReceipt != nil }.count, 1)
        XCTAssertEqual(afterOne.filter { $0.transportReceipt == nil }.count, 1)

        // An already-expired deadline reserves nothing at all.
        let expired = MeteringDrainBudget(maxRequests: 8, deadline: .distantPast)
        let none = try await journal.submitPendingTransport(
            owner: fixture.owner,
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            transport: transport,
            recordedAt: callbackClock.now,
            budget: expired
        )
        XCTAssertEqual(none, 0)
        XCTAssertEqual(transport.requestCount, 1)

        // A pass with ~2s left clamps the request below the journal's 4s and
        // finishes the remaining entry.
        let short = MeteringDrainBudget(maxRequests: 8, deadline: Date().addingTimeInterval(2))
        let clamped = try await journal.submitPendingTransport(
            owner: fixture.owner,
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            transport: transport,
            recordedAt: callbackClock.now.addingTimeInterval(1),
            budget: short
        )
        XCTAssertEqual(clamped, 1)
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(transport.lastRequestTimeout), 2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(transport.lastRequestTimeout), 1)
        XCTAssertTrue(try journal.pending(owner: fixture.owner).allSatisfy { $0.transportReceipt != nil })
    }

    func testCompactEarnedCallbackTrustsExactReadbackWhenSynchronizeHintIsFalse() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let suiteName = "metering-callback-sync-hint-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(FalseSynchronizeCallbackDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let journal = EarnedV2CallbackJournal(defaults: defaults)
        let activeRoute = try activateTodayRoute(in: fixture)
        let callbackClock = ColdReopenCallbackClock(
            now: fixture.clock.now.addingTimeInterval(5 * 60)
        )
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: callbackClock,
            journal: journal
        )
        let transport = ColdReopenRecordingTransport(owner: fixture.owner)

        _ = try callback.handleDurably(
            MeteringAppleCallback(
                activityName: activeRoute.activityName,
                eventName: MeteringRouteNamespace.eventName(
                    routeID: activeRoute.routeID,
                    thresholdMinutes: 5
                ),
                observedAt: callbackClock.now
            ),
            expectedOwnerChildDeviceID: fixture.owner
        )
        defaults.synchronizeResult = false

        let delivered = try await journal.submitPendingTransport(
            owner: fixture.owner,
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            transport: transport,
            recordedAt: callbackClock.now
        )

        XCTAssertEqual(delivered, 1)
        XCTAssertNotNil(try journal.pending(owner: fixture.owner).first?.transportReceipt)
    }

    func testCompactEarnedCallbackKeepsFactWhenTransportFails() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-direct-retry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = EarnedV2CallbackJournal(fileURL: journalURL)
        let activeRoute = try activateTodayRoute(in: fixture)
        let callbackClock = ColdReopenCallbackClock(
            now: fixture.clock.now.addingTimeInterval(5 * 60)
        )
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: callbackClock,
            journal: journal
        )
        _ = try callback.handleDurably(
            MeteringAppleCallback(
                activityName: activeRoute.activityName,
                eventName: MeteringRouteNamespace.eventName(
                    routeID: activeRoute.routeID,
                    thresholdMinutes: 5
                ),
                observedAt: callbackClock.now
            ),
            expectedOwnerChildDeviceID: fixture.owner
        )

        let delivered = try await journal.submitPendingTransport(
            owner: fixture.owner,
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            transport: ColdReopenTransport(),
            recordedAt: callbackClock.now
        )

        XCTAssertEqual(delivered, 0)
        let pending = try journal.pending(owner: fixture.owner)
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending.first?.transportReceipt)
    }

    func testCompactEarnedCallbackDoesNotBypassRegistration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-direct-registration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = EarnedV2CallbackJournal(fileURL: journalURL)
        let waitingJournalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-direct-waiting-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: waitingJournalURL) }
        let waitingJournal = EarnedV2CallbackJournal(fileURL: waitingJournalURL)
        let activeRoute = try activateTodayRoute(in: fixture)
        let callbackClock = ColdReopenCallbackClock(
            now: fixture.clock.now.addingTimeInterval(5 * 60)
        )
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: callbackClock,
            journal: journal
        )
        _ = try callback.handleDurably(
            MeteringAppleCallback(
                activityName: activeRoute.activityName,
                eventName: MeteringRouteNamespace.eventName(
                    routeID: activeRoute.routeID,
                    thresholdMinutes: 5
                ),
                observedAt: callbackClock.now
            ),
            expectedOwnerChildDeviceID: fixture.owner
        )
        let prepared = try XCTUnwrap(journal.pending(owner: fixture.owner).first)
        let waitingWork = EpochSampleWork(
            workID: prepared.work.workID,
            ownerChildDeviceID: prepared.work.ownerChildDeviceID,
            epochID: prepared.work.epochID,
            routeID: prepared.work.routeID,
            request: prepared.work.request,
            authorization: .waitingForRegistration,
            claim: nil,
            retry: prepared.work.retry,
            createdAt: prepared.work.createdAt
        )
        try waitingJournal.enqueue(input: prepared.input, work: waitingWork)
        let transport = ColdReopenRecordingTransport(owner: fixture.owner)

        let delivered = try await waitingJournal.submitPendingTransport(
            owner: fixture.owner,
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            transport: transport,
            recordedAt: callbackClock.now
        )

        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertNil(try waitingJournal.pending(owner: fixture.owner).first?.transportReceipt)
    }

    func testDAMEarnedIntervalEndDoesNotFreshStartCurrentDayInstall() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let entry = DAMMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenTransport(),
            clock: fixture.clock,
            instanceID: UUID()
        )

        await entry.handleIntervalDidEnd(
            activityName: "\(MeteringRouteNamespace.prefix)\(UUID().uuidString.lowercased())"
        )

        XCTAssertTrue(fixture.center.startCalls.isEmpty)
        XCTAssertTrue(
            try fixture.store.read().installWork.values.contains {
                $0.phase == .pendingStart && $0.authorization == .registered
            }
        )
    }

    func testProductionCompositionUsesOneStableIdentityPerProcessRole() {
        XCTAssertEqual(
            MeteringProductionComposition.instanceID(for: .app),
            MeteringProductionComposition.instanceID(for: .app)
        )
        XCTAssertEqual(
            MeteringProductionComposition.instanceID(for: .deviceActivityMonitor),
            MeteringProductionComposition.instanceID(for: .deviceActivityMonitor)
        )
        XCTAssertNotEqual(
            MeteringProductionComposition.instanceID(for: .app),
            MeteringProductionComposition.instanceID(for: .deviceActivityMonitor)
        )
    }

    func testMalformedSharedConfigurationDoesNotCreateMonitorWork() async throws {
        let fixture = try makeFixture(configureDefaults: false, seedWork: false)
        defer { fixture.cleanUp() }
        fixture.defaults.set("file:///tmp/not-http", forKey: MeteringProductionComposition.baseURLKey)
        fixture.defaults.set("not-a-uuid", forKey: MeteringProductionComposition.ownerKey)
        let before = try fixture.store.read()
        let app = AppMeteringEntry(
            defaults: fixture.defaults,
            store: fixture.store,
            center: fixture.center,
            transport: ColdReopenTransport(),
            clock: fixture.clock,
            instanceID: UUID()
        )

        await app.recoverIfConfigured()

        XCTAssertEqual(try fixture.store.read(), before)
        XCTAssertTrue(fixture.center.startCalls.isEmpty)
        XCTAssertTrue(fixture.center.stopCalls.isEmpty)
    }

    func testProductionSourcesWireAppAndDAMButKeepPushNonOwner() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try source(root, "Evlin iOS/Evlin_iOSApp.swift")
        let dam = try source(root, "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift")
        let processEntries = try source(root, "Evlin iOS/Services/MeteringProcessEntries.swift")
        let push = try source(root, "EvlinPushApplier/NotificationService.swift")
        let auth = try source(root, "Evlin iOS/Services/Auth/AuthService.swift")
        let familyGone = try source(root, "Evlin iOS/Services/FamilyGoneDetector.swift")
        let childRoot = try source(root, "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift")

        XCTAssertTrue(app.contains("AppMeteringEntry.shared.recoverIfConfigured"))
        // 2026-08-19: the extension no longer runs the FULL recovery driver
        // (network + DeviceActivityCenter reconciliation) inside a callback —
        // that was the XS Max's every re-arm-time death. Heavy recovery is the
        // host app's job; the extension keeps local shield re-projection only.
        XCTAssertFalse(dam.contains("DAMMeteringEntry.shared.recoverMeteringIfConfigured"))
        XCTAssertTrue(dam.contains("DAMMeteringEntry.shared.recoverShieldEffectsIfConfigured"))
        XCTAssertTrue(dam.contains("DAMMeteringEntry.shared.handle"))
        XCTAssertFalse(dam.contains("DAMMeteringEntry.shared.handleIntervalDidEnd"))
        XCTAssertTrue(processEntries.contains("await replayCallbacks(owner: configuration.owner)"))
        XCTAssertTrue(dam.contains("projectShields: project"))
        XCTAssertTrue(dam.contains("self?.recomputeAndApplyShields(shields)"))
        let synchronousHandle = try XCTUnwrap(
            dam.range(of: "let outcome = try DAMMeteringEntry.shared.handle")
        )
        let asyncRecovery = try XCTUnwrap(
            dam.range(
                of: "Task { @MainActor in",
                range: synchronousHandle.upperBound..<dam.endIndex
            )
        )
        // The earned threshold path: synchronous handle (state + journal +
        // terminal shield) → non-blocking drain kick → MainActor shield
        // continuation. Nothing in between may wait.
        let drainKick = try XCTUnwrap(
            dam.range(
                of: "DAMDrainCoordinator.shared.requestDrain(",
                range: synchronousHandle.upperBound..<asyncRecovery.lowerBound
            )
        )
        XCTAssertNil(
            dam.range(
                of: "awaitBounded",
                range: synchronousHandle.upperBound..<asyncRecovery.lowerBound
            ),
            "the earned threshold callback must not block on uploads"
        )
        XCTAssertLessThan(synchronousHandle.lowerBound, drainKick.lowerBound)
        XCTAssertLessThan(drainKick.lowerBound, asyncRecovery.lowerBound)
        XCTAssertTrue(auth.contains("EarnedBudgetArming.teardownFamilyIdentity"))
        XCTAssertTrue(familyGone.contains("EarnedBudgetArming.teardownFamilyIdentity"))
        XCTAssertTrue(childRoot.contains("EarnedBudgetArming.mirrorChildIdentity"))
        XCTAssertTrue(childRoot.contains("AppMeteringEntry.shared.recoverIfConfigured"))

        XCTAssertTrue(
            push.contains("MeteringProductionComposition.recoverFromSharedConfiguration")
                && push.contains("role: .pushApplier"),
            "an earned-policy alert must run the shared v2 recovery owner"
        )
        let earnedStart = try XCTUnwrap(push.range(of: "private func persistEarnedPolicy"))
        let earnedBody = push[earnedStart.lowerBound...]
        let pendingAck = try XCTUnwrap(earnedBody.range(of: "try await NSENetwork.ack("))
        let recover = try XCTUnwrap(
            earnedBody.range(of: "MeteringProductionComposition.recoverFromSharedConfiguration")
        )
        XCTAssertLessThan(
            pendingAck.lowerBound,
            recover.lowerBound,
            "the pending receipt must precede recovery so a later exact readback cannot be overwritten"
        )
        XCTAssertFalse(
            push.contains("DatedRouteInstaller("),
            "the push extension must reuse the shared recovery composition rather than fork an installer"
        )
    }

    func testDAMBoundedNetworkWorkDoesNotInheritTheBlockedMainActor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dam = try source(root, "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift")
        let helperStart = try XCTUnwrap(dam.range(of: "private func awaitBounded"))
        let helperTail = dam[helperStart.lowerBound...]
        let helperEnd = try XCTUnwrap(helperTail.range(of: "\n    private func handleV2MeteringThreshold"))
        let helper = helperTail[..<helperEnd.lowerBound]

        XCTAssertTrue(
            helper.contains("Task.detached"),
            "the semaphore blocks the callback actor, so bounded network work must run on a detached task"
        )
        XCTAssertFalse(
            helper.contains("Task {"),
            "an inherited task cannot start while the callback actor is blocked waiting for it"
        )
    }

    func testMeteringIntervalStartKeepsOnlyLocalShieldRecoveryAndNeverBlocks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dam = try source(
            root,
            "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift"
        )
        let branchStart = try XCTUnwrap(
            dam.range(of: "if raw.hasPrefix(MeteringRouteNamespace.prefix)")
        )
        let tail = dam[branchStart.lowerBound...]
        let branchEnd = try XCTUnwrap(
            tail.range(of: "\n        switch AppLimitIntervalStartRouter")
        )
        let branch = tail[..<branchEnd.lowerBound]

        // 2026-08-19 contract: the interval boundary does NOT run the full
        // recovery driver and does NOT wait on anything. Heavy recovery
        // (network drain, DeviceActivityCenter reconciliation, route repair)
        // belongs to the host app's watchdog; the extension re-projects
        // pending shield effects locally, without blocking.
        XCTAssertFalse(
            branch.contains("awaitBounded"),
            "intervalDidStart must not block the callback"
        )
        XCTAssertFalse(
            branch.contains("recoverMeteringIfConfigured"),
            "intervalDidStart must not run the full recovery driver"
        )
        XCTAssertTrue(
            branch.contains("recoverShieldEffectsSynchronouslyIfConfigured("),
            "local shield re-projection runs synchronously inside the callback"
        )
        XCTAssertFalse(
            branch.contains("Task {") || branch.contains("Task.detached"),
            "a task scheduled after return may never run if the extension is suspended at once"
        )
        XCTAssertFalse(
            branch.contains("DAMMeteringEntry.shared.recoverIfConfigured("),
            "the callback must not wait on MainActor-only shield projection"
        )
    }

    func testMeteringIntervalEndKeepsOnlyLocalShieldRecoveryAndNeverBlocks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dam = try source(
            root,
            "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift"
        )
        let callbackStart = try XCTUnwrap(
            dam.range(of: "override func intervalDidEnd")
        )
        let callbackTail = dam[callbackStart.lowerBound...]
        let branchStart = try XCTUnwrap(
            callbackTail.range(of: "if raw.hasPrefix(MeteringRouteNamespace.prefix)")
        )
        let branchTail = callbackTail[branchStart.lowerBound...]
        let branchEnd = try XCTUnwrap(
            branchTail.range(of: "\n        // Two activity namespaces fire here:")
        )
        let branch = branchTail[..<branchEnd.lowerBound]

        // Same 2026-08-19 contract as intervalDidStart: no blocking, no full
        // recovery driver; local shield re-projection only.
        XCTAssertFalse(
            branch.contains("awaitBounded"),
            "intervalDidEnd must not block the callback"
        )
        XCTAssertFalse(
            branch.contains("recoverMeteringIfConfigured"),
            "intervalDidEnd must not run the full recovery driver"
        )
        XCTAssertTrue(
            branch.contains("recoverShieldEffectsSynchronouslyIfConfigured("),
            "local shield re-projection runs synchronously inside the callback"
        )
        XCTAssertFalse(
            branch.contains("Task {") || branch.contains("Task.detached"),
            "a task scheduled after return may never run if the extension is suspended at once"
        )
        XCTAssertFalse(
            branch.contains("handleIntervalDidEnd("),
            "the callback must not route rollover work through a MainActor-only entry"
        )
    }

    func testPushTargetIncludesTheSharedV2RecoveryClosure() throws {
        let project = try projectSource()
        let marker = "Exceptions for \"Evlin iOS\" folder in \"EvlinPushApplier\" target"
        let range = try XCTUnwrap(project.range(of: marker))
        let tail = project[range.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n\t\t};"))
        let exceptions = String(tail[..<end.lowerBound])

        for path in [
            "Models/BigKid/BigKidModels.swift",
            "Models/EarnedScreenTimeHelpers.swift",
            "Services/MeteringDeviceActivityCenter.swift",
            "Services/MeteringCallbackRoute.swift",
            "Services/MeteringDaemonProbe.swift",
            "Services/MeteringDatedSchedule.swift",
            "Services/DatedRouteInstaller.swift",
            "Services/MeteringEpochDelivery.swift",
            "Services/EarnedMeteringCallback.swift",
            "Services/EarnedMeteringRecoveryDriver.swift",
            "Services/EarnedSampleReporter.swift",
            "Services/MeteringPolicyOwnerReadbackClient.swift",
            "Services/MeteringProductionComposition.swift",
        ] {
            XCTAssertTrue(exceptions.contains(path), "Push must compile \(path) for shared v2 recovery")
        }
    }

    private func makeFixture(
        configureDefaults: Bool = true,
        seedWork: Bool = true
    ) throws -> ColdReopenFixture {
        let owner = UUID()
        let suiteName = "metering-cold-reopen-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-cold-reopen-\(UUID().uuidString).json")
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let center = ColdReopenCenter()
        let clock = ColdReopenClock()
        if configureDefaults {
            defaults.set("https://example.invalid/api/v1", forKey: MeteringProductionComposition.baseURLKey)
            defaults.set(owner.uuidString, forKey: MeteringProductionComposition.ownerKey)
        }
        if seedWork {
            let selectionBytes = try JSONEncoder().encode(FamilyActivitySelection())
            let generation = MeteringGenerationKey(
                protocolVersion: 2,
                childDeviceID: owner,
                canonicalTimezone: "America/New_York",
                policyRevision: "cold-reopen-r1",
                measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                    persistedBytes: selectionBytes
                ),
                enforcementSetID: UUID()
            )
            _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
                ownerChildDeviceID: owner,
                today: "2026-09-13",
                generationKey: generation,
                persistedSelectionBytes: selectionBytes,
                poolMinutes: 20,
                deviceCapMinutes: 10,
                authoritativeBaseAcceptedMinutes: 0,
                now: clock.now
            ))
            try store.transaction(expectedOwner: owner) { state in
                for workID in state.registrationWork.keys {
                    guard let work = state.registrationWork[workID] else { continue }
                    state.registrationWork[workID]?.retry.terminal = .succeeded
                    state.epochs[work.epochID]?.registeredAt = clock.now
                }
                for workID in state.installWork.keys {
                    guard let work = state.installWork[workID],
                          let route = state.routes[work.routeID]
                    else { continue }
                    if route.usageDate == "2026-09-13" {
                        state.installWork[workID]?.authorization = .registered
                    } else {
                        state.installWork[workID]?.phase = .verified
                    }
                }
            }
        }
        return ColdReopenFixture(
            owner: owner,
            suiteName: suiteName,
            defaults: defaults,
            storeURL: storeURL,
            store: store,
            center: center,
            clock: clock
        )
    }

    private func source(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func projectSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Evlin iOS.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
    }

    private func activateTodayRoute(
        in fixture: ColdReopenFixture
    ) throws -> MeteringCallbackRoute {
        let initial = try fixture.store.read()
        let route = try XCTUnwrap(initial.routes.values.first {
            $0.usageDate == "2026-09-13"
        })
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state.routes[route.routeID]?.lifecycle = .active
            state.epochs[route.epochID]?.status = .active
            state.activeGenerationID = route.generationID
            state.activeEpochID = route.epochID
            state.activeRouteID = route.routeID
            state.ratchets[fixture.owner] = MeteringOwnerRatchet(
                ownerChildDeviceID: fixture.owner,
                advertisedVersion: 2,
                localSelection: .v2,
                registeredV2At: fixture.clock.now,
                dualActiveAt: fixture.clock.now,
                activatedV2At: fixture.clock.now
            )
            for workID in state.activationWork.keys {
                guard state.activationWork[workID]?.routeID == route.routeID else { continue }
                state.activationWork[workID]?.retry.terminal = .succeeded
            }
            for workID in state.installWork.keys {
                guard state.installWork[workID]?.routeID == route.routeID else { continue }
                state.installWork[workID]?.authorization = .registered
                state.installWork[workID]?.phase = .active
                state.installWork[workID]?.retry.terminal = .succeeded
            }
        }
        return try XCTUnwrap(try fixture.store.read().routes[route.routeID])
    }
}

@MainActor
private final class ColdReopenFixture {
    let owner: UUID
    let suiteName: String
    let defaults: UserDefaults
    let storeURL: URL
    let store: DeviceEpochStore
    let center: ColdReopenCenter
    let clock: ColdReopenClock

    init(
        owner: UUID,
        suiteName: String,
        defaults: UserDefaults,
        storeURL: URL,
        store: DeviceEpochStore,
        center: ColdReopenCenter,
        clock: ColdReopenClock
    ) {
        self.owner = owner
        self.suiteName = suiteName
        self.defaults = defaults
        self.storeURL = storeURL
        self.store = store
        self.center = center
        self.clock = clock
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storeURL)
    }

}

private nonisolated final class ColdReopenCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    private var records: [DeviceActivityName: (DeviceActivitySchedule, [DeviceActivityEvent.Name: DeviceActivityEvent])] = [:]
    var startCalls: [DeviceActivityName] = []
    var stopCalls: [[DeviceActivityName]] = []
    var activitiesReadCount = 0
    var activities: [DeviceActivityName] {
        activitiesReadCount += 1
        return Array(records.keys)
    }

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? {
        records[activity]?.0
    }

    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        records[activity]?.1 ?? [:]
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startCalls.append(activity)
        records[activity] = (schedule, events)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopCalls.append(activities)
        for activity in activities { records.removeValue(forKey: activity) }
    }
}

private struct ColdReopenClock: MeteringClock {
    let now = Date(timeIntervalSince1970: 1_789_286_400)
}

private struct ColdReopenCallbackClock: MeteringClock {
    let now: Date
}

private struct ColdReopenTransport: MeteringHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private struct ColdReopenAcceptingTransport: MeteringHTTPTransport {
    let owner: UUID

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let snapshot = DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: "2026-09-13",
            estimatedMinutes: 5,
            capMinutes: 10,
            childDayState: "available",
            usedMinutes: 5,
            remainingMinutes: 15,
            counted: true,
            warning: nil
        )
        return (try JSONEncoder().encode(snapshot), response)
    }
}

private final class ColdReopenRecordingTransport: MeteringHTTPTransport, @unchecked Sendable {
    private let owner: UUID
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    init(owner: UUID) {
        self.owner = owner
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    var lastRequestTimeout: TimeInterval? {
        lock.withLock { requests.last?.timeoutInterval }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { requests.append(request) }
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let snapshot = DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: "2026-09-13",
            estimatedMinutes: 5,
            capMinutes: 10,
            childDayState: "available",
            usedMinutes: 5,
            remainingMinutes: 15,
            counted: true,
            warning: nil
        )
        return (try JSONEncoder().encode(snapshot), response)
    }
}

private final class FalseSynchronizeCallbackDefaults: UserDefaults {
    var synchronizeResult = true

    override func synchronize() -> Bool {
        _ = super.synchronize()
        return synchronizeResult
    }
}
