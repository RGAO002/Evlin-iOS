import XCTest
@testable import Evlin_iOS

final class DAMDrainCoordinatorTests: XCTestCase {
    /// The kick must return before the work does — that is the whole point.
    func testRequestDrainReturnsWithoutWaitingForTheWork() async throws {
        let gate = DispatchSemaphore(value: 0)
        let finished = expectation(description: "round finished")
        let coordinator = DAMDrainCoordinator(
            work: { _ in
                await Task.detached { gate.wait() }.value
            },
            onRoundFinished: { _ in finished.fulfill() }
        )

        let started = Date()
        let startedWorker = coordinator.requestDrain(traceContext: nil)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(startedWorker)
        XCTAssertLessThan(elapsed, 0.2, "requestDrain blocked on the work")
        gate.signal()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(coordinator.roundCount, 1)
    }

    /// Kicks that arrive while a round is running coalesce into ONE more
    /// round, and every waiting trace context is handed to that round.
    func testKicksDuringARunningRoundCoalesceIntoOneMoreRound() async throws {
        let gate = DispatchSemaphore(value: 0)
        let roundsFinished = expectation(description: "two rounds")
        roundsFinished.expectedFulfillmentCount = 2
        let contextsLock = NSLock()
        var contextsPerRound: [[UInt64]] = []
        let coordinator = DAMDrainCoordinator(
            work: { _ in
                await Task.detached { gate.wait() }.value
            },
            onRoundFinished: { contexts in
                contextsLock.lock()
                contextsPerRound.append(contexts.map(\.callbackID))
                contextsLock.unlock()
                roundsFinished.fulfill()
            }
        )
        let trace = makeTrace()
        let first = trace.begin(kind: .thresholdPool, activityName: "a", eventName: "t1")
        XCTAssertTrue(coordinator.requestDrain(traceContext: first))

        var later: [UInt64] = []
        for n in 2...6 {
            let context = trace.begin(kind: .thresholdPool, activityName: "a", eventName: "t\(n)")
            later.append(context.callbackID)
            XCTAssertFalse(
                coordinator.requestDrain(traceContext: context),
                "a kick during a running round must coalesce, not start a worker"
            )
        }
        gate.signal() // round 1
        gate.signal() // round 2 (the coalesced one)
        await fulfillment(of: [roundsFinished], timeout: 5)

        XCTAssertEqual(coordinator.roundCount, 2)
        contextsLock.lock()
        let rounds = contextsPerRound
        contextsLock.unlock()
        XCTAssertEqual(rounds.count, 2)
        XCTAssertEqual(rounds[0], [first.callbackID])
        XCTAssertEqual(rounds[1], later)
    }

    /// After a worker finishes with nothing pending, the next kick starts a
    /// fresh worker (single-flight, not single-shot).
    func testANewKickAfterAnIdleWorkerStartsAgain() async throws {
        let finished = expectation(description: "rounds")
        finished.expectedFulfillmentCount = 2
        let coordinator = DAMDrainCoordinator(
            work: { _ in },
            onRoundFinished: { _ in finished.fulfill() }
        )
        XCTAssertTrue(coordinator.requestDrain())
        // Let the (empty) round retire before kicking again.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(coordinator.requestDrain())
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(coordinator.roundCount, 2)
    }

    func testBudgetReservesUpToMaxRequestsAndRespectsDeadline() {
        let budget = MeteringDrainBudget(maxRequests: 2, deadline: .distantFuture)
        XCTAssertTrue(budget.reserveRequest())
        XCTAssertTrue(budget.reserveRequest())
        XCTAssertFalse(budget.reserveRequest())
        XCTAssertEqual(budget.requestsUsed, 2)

        let expired = MeteringDrainBudget(maxRequests: 8, deadline: Date(timeIntervalSinceNow: -1))
        XCTAssertFalse(expired.reserveRequest())

        let unlimited = MeteringDrainBudget.unlimited()
        for _ in 0..<1_000 { XCTAssertTrue(unlimited.reserveRequest()) }

        let ext = MeteringDrainBudget.extensionDefault(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(ext.maxRequests, MeteringDrainBudget.extensionMaxRequests)
        XCTAssertEqual(ext.deadline, Date(timeIntervalSince1970: MeteringDrainBudget.extensionWallClockSeconds))
    }

    /// Pin the callback contract in the extension source: earned threshold,
    /// both interval callbacks and the legacy earned path no longer wait; the
    /// only remaining `awaitBounded` caller is the per-app drain (P0-3).
    func testExtensionEarnedAndIntervalPathsDoNotBlockOnUploads() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("recoverMeteringIfConfigured()"),
            "interval callbacks must not run the full recovery driver"
        )
        XCTAssertEqual(
            source.components(separatedBy: "DAMDrainCoordinator.shared.requestDrain(").count - 1,
            1,
            "the earned threshold path kicks the single-flight drain exactly once"
        )
        XCTAssertEqual(
            source.components(separatedBy: "awaitBounded(traceContext: traceContext) {").count - 1,
            1,
            "only the per-app drain may still wait (until P0-3)"
        )
        XCTAssertEqual(
            source.components(separatedBy: "DispatchSemaphore(").count - 1,
            1,
            "no new semaphores in the extension"
        )
    }

    private func makeTrace() -> DAMMemoryTrace {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dam-drain-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DAMMemoryTrace(
            fileURL: dir.appendingPathComponent("trace.bin"),
            stateFileURL: dir.appendingPathComponent("state.json"),
            capacity: 64,
            metrics: { DAMMemorySnapshot(availableBytes: 1, footprintBytes: 1, peakFootprintBytes: 1, pid: 1) }
        )
    }
}
