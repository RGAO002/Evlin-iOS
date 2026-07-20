import XCTest
@testable import Evlin_iOS

@MainActor
final class AppLimitWakeRecoveryTests: XCTestCase {
    func testNSESetRecoversOnLaunchAndConfirmsOnlyAfterReceiptReadback() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(setEnvelope(token: 10))
        let readback = RecordingReadback(store: harness.store)
        let effects = RecordingEffects(beforeApply: {
            let count = await readback.count
            XCTAssertEqual(count, 0)
        })
        let driver = makeDriver(harness: harness, effects: effects, readback: readback)

        await driver.recover(ownerChildDeviceID: ownerID)

        let appliedTokens = await effects.tokens
        let confirmationCount = await readback.count
        XCTAssertEqual(appliedTokens, [10])
        XCTAssertEqual(confirmationCount, 1)
        let receipt = try XCTUnwrap(harness.store.read().slots[ruleID]?.appliedReceipt)
        XCTAssertEqual(receipt.orderingToken, 10)
        XCTAssertNil(try harness.store.read().slots[ruleID]?.pendingOwnerWork)
    }

    func testNSEClearRecoversOnSilentWake() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(clearEnvelope(token: 11))
        let readback = RecordingReadback(store: harness.store)
        let effects = RecordingEffects()
        let driver = makeDriver(harness: harness, effects: effects, readback: readback)

        await driver.recover(ownerChildDeviceID: ownerID)

        let appliedKinds = await effects.kinds
        let confirmedCommands = await readback.commandIDs
        XCTAssertEqual(appliedKinds, [.clear])
        XCTAssertEqual(confirmedCommands, [clearCommandID])
        XCTAssertEqual(try harness.store.read().slots[ruleID]?.appliedReceipt?.commandKind, .clear)
    }

    func testForegroundRecoveryIsIdempotent() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(setEnvelope(token: 10))
        let readback = RecordingReadback(store: harness.store)
        let effects = RecordingEffects()
        let driver = makeDriver(harness: harness, effects: effects, readback: readback)

        await driver.recover(ownerChildDeviceID: ownerID)
        await driver.recover(ownerChildDeviceID: ownerID)

        let appliedTokens = await effects.tokens
        let confirmationCount = await readback.count
        XCTAssertEqual(appliedTokens, [10])
        XCTAssertEqual(confirmationCount, 1)
    }

    func testPollCompletionInvokesSharedRecoveryEntry() async {
        let poller = CommandPoller.shared
        let originalDevice = poller.childDeviceIDProvider
        let originalPoll = poller.oneShotPollOverride
        let originalRecovery = poller.appLimitRecoveryOverride
        defer {
            poller.childDeviceIDProvider = originalDevice
            poller.oneShotPollOverride = originalPoll
            poller.appLimitRecoveryOverride = originalRecovery
        }
        poller.childDeviceIDProvider = { ownerID }
        poller.oneShotPollOverride = { _, _ in }
        var recoveries = 0
        poller.appLimitRecoveryOverride = { recoveries += 1 }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(recoveries, 1)
    }

    func testEqualPollDuringRecoveryDoesNotDuplicateEffect() async throws {
        let harness = makeHarness()
        let envelope = setEnvelope(token: 10)
        _ = try harness.coordinator.ingest(envelope)
        let gate = AsyncGate()
        let readback = RecordingReadback(store: harness.store)
        let effects = RecordingEffects(beforeApply: { await gate.wait() })
        let driver = makeDriver(harness: harness, effects: effects, readback: readback)

        let first = Task { await driver.recover(ownerChildDeviceID: ownerID) }
        await effects.waitUntilStarted()
        XCTAssertEqual(try harness.coordinator.ingest(envelope), .duplicatePending)
        await driver.recover(ownerChildDeviceID: ownerID)
        await gate.open()
        await first.value

        let appliedTokens = await effects.tokens
        let confirmationCount = await readback.count
        XCTAssertEqual(appliedTokens, [10])
        XCTAssertEqual(confirmationCount, 1)
    }

    func testCrashAfterClaimBeforeEffectRemainsRecoverableWithoutDuplicateEffect() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(setEnvelope(token: 10))
        let readback = RecordingReadback(store: harness.store)
        let effects = RecordingEffects()
        let crash = CrashOnce()
        let driver = AppLimitOwnerRecoveryDriver(
            store: harness.store,
            effectPort: effects,
            readbackPort: readback,
            afterClaim: { _ in
                try crash.checkpoint()
            }
        )

        await driver.recover(ownerChildDeviceID: ownerID)
        await driver.recover(ownerChildDeviceID: ownerID)

        let appliedTokens = await effects.tokens
        let confirmationCount = await readback.count
        XCTAssertEqual(appliedTokens, [10])
        XCTAssertEqual(confirmationCount, 1)
    }

    func testNewerClearWhileOldSetEffectInFlightPreventsOldReceipt() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(setEnvelope(token: 10))
        let gate = AsyncGate()
        let readback = RecordingReadback(store: harness.store)
        let effects = RecordingEffects(beforeApply: { work in
            if work.orderingToken == 10 { await gate.wait() }
        })
        let driver = makeDriver(harness: harness, effects: effects, readback: readback)

        let oldRecovery = Task { await driver.recover(ownerChildDeviceID: ownerID) }
        await effects.waitUntilStarted()
        _ = try harness.coordinator.ingest(clearEnvelope(token: 11))
        await driver.recover(ownerChildDeviceID: ownerID)
        await gate.open()
        await oldRecovery.value

        let appliedTokens = await effects.tokens
        let confirmedCommands = await readback.commandIDs
        XCTAssertEqual(appliedTokens, [10, 11])
        XCTAssertEqual(confirmedCommands, [clearCommandID])
        XCTAssertEqual(try harness.store.read().slots[ruleID]?.appliedReceipt?.orderingToken, 11)
    }

    func testNewerClearBeforeConfirmPreventsStaleConfirmation() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(setEnvelope(token: 10))
        let readback = RecordingReadback(store: harness.store)
        let effects = RecordingEffects()
        let driver = AppLimitOwnerRecoveryDriver(
            store: harness.store,
            effectPort: effects,
            readbackPort: readback,
            beforeConfirm: { _ in
                _ = try harness.coordinator.ingest(self.clearEnvelope(token: 11))
            }
        )

        await driver.recover(ownerChildDeviceID: ownerID)

        let confirmations = await readback.commandIDs
        XCTAssertEqual(confirmations, [])
        let slot = try XCTUnwrap(harness.store.read().slots[ruleID])
        XCTAssertEqual(slot.latestKind, .clear)
        XCTAssertEqual(slot.latestOrderingToken, 11)
        XCTAssertNotNil(slot.pendingOwnerWork)
    }

    func testAllFourProductionEntrypointsNameTheSharedRecoveryEntry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Evlin iOS/Evlin_iOSApp.swift"))
        let poller = try String(contentsOf: root.appendingPathComponent("Evlin iOS/Services/CommandPoller.swift"))
        XCTAssertTrue(app.contains("AppLimitRecoveryTrigger.launch"))
        XCTAssertTrue(app.contains("AppLimitRecoveryTrigger.foreground"))
        XCTAssertTrue(app.contains("recoveryReason: .silentRemoteNotification"))
        XCTAssertTrue(poller.contains("AppLimitRecoveryTrigger.silentRemoteNotification"))
        XCTAssertTrue(poller.contains("AppLimitRecoveryTrigger.pollCompletion"))
        XCTAssertFalse(app.contains(
            "pollOnceForCurrentDevice()\n            await AppLimitRecoveryTrigger.silentRemoteNotification"
        ))
    }

    private func makeHarness() -> RecoveryHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limit-recovery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppLimitEpochStore(
            fileURL: directory.appendingPathComponent("epoch.json"),
            lock: AppLimitRecoveryTestLock(),
            ownerProvider: { ownerID },
            legacyDefaults: nil
        )
        return RecoveryHarness(
            store: store,
            coordinator: AppLimitCommandCoordinator(
                store: store,
                expectedOwnerProvider: { ownerID }
            )
        )
    }

    private func makeDriver(
        harness: RecoveryHarness,
        effects: RecordingEffects,
        readback: RecordingReadback
    ) -> AppLimitOwnerRecoveryDriver {
        AppLimitOwnerRecoveryDriver(
            store: harness.store,
            effectPort: effects,
            readbackPort: readback
        )
    }

    private func setEnvelope(token: Int64) -> AppLimitCommandEnvelope {
        let rule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.example.focus",
            displayName: "Focus",
            budgetMinutes: 30,
            window: AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: "UTC"),
            effectiveFrom: referenceDate,
            expiresAt: nil
        )
        return AppLimitCommandEnvelope(
            commandID: setCommandID,
            ruleID: ruleID,
            orderingToken: token,
            kind: .set,
            payloadDigest: "set-\(token)",
            receivedAt: referenceDate,
            source: .notificationServiceExtension,
            rule: rule
        )
    }

    private func clearEnvelope(token: Int64) -> AppLimitCommandEnvelope {
        AppLimitCommandEnvelope(
            commandID: clearCommandID,
            ruleID: ruleID,
            orderingToken: token,
            kind: .clear,
            payloadDigest: "clear-\(token)",
            receivedAt: referenceDate,
            source: .notificationServiceExtension,
            rule: nil
        )
    }
}

private struct RecoveryHarness {
    let store: AppLimitEpochStore
    let coordinator: AppLimitCommandCoordinator
}

private enum RecoveryTestError: Error { case simulatedCrash }

@MainActor
private final class CrashOnce {
    private var shouldCrash = true

    func checkpoint() throws {
        guard shouldCrash else { return }
        shouldCrash = false
        throw RecoveryTestError.simulatedCrash
    }
}

private actor RecordingReadback: AppLimitOwnerReadbackPort {
    private let store: AppLimitEpochStore
    private(set) var commandIDs: [UUID] = []
    var count: Int { commandIDs.count }

    init(store: AppLimitEpochStore) { self.store = store }

    func confirm(commandID: UUID, receipt: AppLimitApplyReceipt) async throws {
        let persisted = try store.read().slots[receipt.ruleID]?.appliedReceipt
        XCTAssertEqual(persisted, receipt)
        commandIDs.append(commandID)
    }
}

private actor RecordingEffects: AppLimitOwnerEffectPort {
    private let beforeApply: @Sendable (AppLimitOwnerWork) async -> Void
    private(set) var tokens: [Int64] = []
    private(set) var kinds: [AppLimitCommandKind] = []
    private var hasStarted = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []

    init(beforeApply: @escaping @Sendable () async -> Void = {}) {
        self.beforeApply = { _ in await beforeApply() }
    }

    init(beforeApply: @escaping @Sendable (AppLimitOwnerWork) async -> Void) {
        self.beforeApply = beforeApply
    }

    func apply(
        work: AppLimitOwnerWork,
        slot: AppLimitVersionSlot
    ) async throws -> AppLimitOwnerEffectResult {
        hasStarted = true
        let continuations = startedContinuations
        startedContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await beforeApply(work)
        tokens.append(work.orderingToken)
        kinds.append(work.commandKind)
        return AppLimitOwnerEffectResult(armID: nil, source: "app_owner")
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startedContinuations.append($0) }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private final class AppLimitRecoveryTestLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()
    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private let ownerID = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
private let ruleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000400")!
private let setCommandID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000010")!
private let clearCommandID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000011")!
private let referenceDate = Date(timeIntervalSince1970: 1_721_174_400)
