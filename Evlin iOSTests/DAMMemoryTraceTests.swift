import XCTest
@testable import Evlin_iOS

final class DAMMemoryTraceTests: XCTestCase {
    func testReadingMissingTraceDoesNotCreateFile() throws {
        let trace = makeTrace(capacity: 8)

        XCTAssertFalse(FileManager.default.fileExists(atPath: traceURL.path))
        XCTAssertTrue(trace.readRecords().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: traceURL.path))
    }

    private var directoryURL: URL!
    private var traceURL: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dam-memory-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        traceURL = directoryURL.appendingPathComponent("trace.bin")
        stateURL = directoryURL.appendingPathComponent("state.json")
        try Data(repeating: 0x41, count: 12_345).write(to: stateURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testRingHasFixedRecordAndFileSize() throws {
        let trace = makeTrace(capacity: 512)

        for index in 0..<2_000 {
            _ = trace.record(
                callbackID: UInt64(index + 1),
                kind: .thresholdPool,
                stage: .entry,
                activityName: "activity-\(index)",
                eventName: "event-\(index)"
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: traceURL.path)
        XCTAssertEqual(DAMMemoryTrace.recordByteCount, 64)
        XCTAssertEqual(attributes[.size] as? NSNumber, NSNumber(value: 64 + (512 * 64)))
    }

    func testRingKeepsOnlyNewestRecordsInSequenceOrder() throws {
        let trace = makeTrace(capacity: 4)

        for callbackID in 1...7 {
            _ = trace.record(
                callbackID: UInt64(callbackID),
                kind: .thresholdAppLimit,
                stage: .entry,
                activityName: "activity",
                eventName: "event"
            )
        }

        let records = trace.readRecords()
        XCTAssertEqual(records.map(\.sequence), [4, 5, 6, 7])
        XCTAssertEqual(records.map(\.callbackID), [4, 5, 6, 7])
        XCTAssertEqual(records.map(\.stateFileBytes), [12_345, 12_345, 12_345, 12_345])
    }

    func testReaderIgnoresTornOrCorruptSlot() throws {
        let trace = makeTrace(capacity: 4)
        _ = trace.record(
            callbackID: 1,
            kind: .intervalStart,
            stage: .entry,
            activityName: "activity",
            eventName: nil
        )
        _ = trace.record(
            callbackID: 1,
            kind: .intervalStart,
            stage: .exit,
            activityName: "activity",
            eventName: nil
        )

        let descriptor = open(traceURL.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var corruptByte: UInt8 = 0xFF
        XCTAssertEqual(pwrite(descriptor, &corruptByte, 1, 64 + 64 + 10), 1)

        let records = trace.readRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.stage, .entry)
    }

    func testLifecycleSummaryFindsEntryWithoutExit() throws {
        let trace = makeTrace(capacity: 16)
        let completed = trace.begin(
            kind: .thresholdPool,
            activityName: "earned",
            eventName: "t5"
        )
        trace.mark(completed, stage: .afterJournal)
        trace.mark(completed, stage: .exit)

        let incomplete = trace.begin(
            kind: .thresholdAppLimit,
            activityName: "limit",
            eventName: "budget"
        )
        trace.mark(incomplete, stage: .beforeDrain)

        let summary = DAMMemoryTraceLifecycle.summarize(trace.readRecords())
        XCTAssertEqual(summary.completedCallbackCount, 1)
        XCTAssertEqual(summary.incompleteCallbacks.map(\.callbackID), [incomplete.callbackID])
        XCTAssertEqual(summary.incompleteCallbacks.first?.lastStage, .beforeDrain)
    }

    func testLifecycleSummaryDistinguishesTimedOutDrainFromLaterCompletion() throws {
        let trace = makeTrace(capacity: 16)
        _ = trace.record(
            callbackID: 10,
            kind: .thresholdPool,
            stage: .afterDrainWait,
            flags: .waitTimedOut,
            activityName: "earned",
            eventName: "t5"
        )
        _ = trace.record(
            callbackID: 11,
            kind: .thresholdPool,
            stage: .afterDrainWait,
            flags: .waitTimedOut,
            activityName: "earned",
            eventName: "t10"
        )
        _ = trace.record(
            callbackID: 11,
            kind: .thresholdPool,
            stage: .afterDrainWait,
            flags: .asyncCompleted,
            activityName: "earned",
            eventName: "t10"
        )

        let summary = DAMMemoryTraceLifecycle.summarize(trace.readRecords())
        XCTAssertEqual(summary.unfinishedTimedOutDrainCallbackIDs, [10])
    }

    func testAllDAMCallbacksUseEntryAndDeferredExitTrace() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertEqual(source.components(separatedBy: "memoryTrace.begin(").count - 1, 3)
        XCTAssertEqual(
            source.components(
                separatedBy: "defer { memoryTrace.mark(traceContext, stage: .exit) }"
            ).count - 1,
            3
        )
        XCTAssertTrue(source.contains("flags: .asyncCompleted"))
        XCTAssertTrue(source.contains(".waitCompleted : .waitTimedOut"))
    }

    private func makeTrace(capacity: Int) -> DAMMemoryTrace {
        DAMMemoryTrace(
            fileURL: traceURL,
            stateFileURL: stateURL,
            capacity: capacity,
            metrics: {
                DAMMemorySnapshot(
                    availableBytes: 3_000_000,
                    footprintBytes: 2_000_000,
                    peakFootprintBytes: 2_500_000,
                    pid: 42
                )
            }
        )
    }
}
