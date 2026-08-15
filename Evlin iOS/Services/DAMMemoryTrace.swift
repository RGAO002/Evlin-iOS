import Foundation
import Darwin

nonisolated struct DAMMemorySnapshot: Sendable, Equatable {
    let availableBytes: UInt64
    let footprintBytes: UInt64
    let peakFootprintBytes: UInt64
    let pid: Int32

    static func live() -> DAMMemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        return DAMMemorySnapshot(
            availableBytes: UInt64(os_proc_available_memory()),
            footprintBytes: result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0,
            peakFootprintBytes: result == KERN_SUCCESS
                ? UInt64(max(0, info.ledger_phys_footprint_peak))
                : 0,
            pid: getpid()
        )
    }
}

nonisolated final class DAMMemoryTrace: @unchecked Sendable {
    enum CallbackKind: UInt8, Sendable {
        case intervalStart = 1
        case intervalEnd = 2
        case thresholdPool = 3
        case thresholdAppLimit = 4
        case thresholdOther = 5
    }

    enum Stage: UInt8, Sendable {
        case entry = 1
        case beforeState = 2
        case afterState = 3
        case afterJournal = 4
        case beforeDrain = 5
        case afterDrainWait = 6
        case afterShield = 7
        case exit = 8
    }

    struct Flags: OptionSet, Sendable {
        let rawValue: UInt8

        static let waitCompleted = Flags(rawValue: 1 << 0)
        static let waitTimedOut = Flags(rawValue: 1 << 1)
        static let asyncCompleted = Flags(rawValue: 1 << 2)
        static let failed = Flags(rawValue: 1 << 3)
    }

    struct Context: Sendable, Equatable {
        let callbackID: UInt64
        let kind: CallbackKind
        fileprivate let activityHash: UInt32
        fileprivate let eventHash: UInt32
    }

    struct Record: Sendable, Equatable {
        let sequence: UInt64
        let callbackID: UInt64
        let kind: CallbackKind
        let stage: Stage
        let flags: Flags
        let monotonicMilliseconds: UInt32
        let wallEpochSeconds: UInt32
        let availableBytes: UInt32
        let footprintBytes: UInt32
        let peakFootprintBytes: UInt32
        let stateFileBytes: UInt32
        let pid: UInt32
        let activityHash: UInt32
        let eventHash: UInt32
    }

    static let recordByteCount = 64
    static let defaultCapacity = 512
    static let appGroupIdentifier = "group.com.evlin.ios"
    static let traceFileName = "dam-memory-trace-v1.bin"
    static let stateFileName = "metering-device-epoch-store-v4.json"

    static let shared: DAMMemoryTrace = {
        let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? FileManager.default.temporaryDirectory
        return DAMMemoryTrace(
            fileURL: directory.appendingPathComponent(traceFileName),
            stateFileURL: directory.appendingPathComponent(stateFileName)
        )
    }()

    private static let headerMagic: UInt32 = 0x4556_4C48
    private static let recordMagic: UInt32 = 0x4556_4C52
    private static let formatVersion: UInt8 = 1
    private static let headerByteCount = 64

    private let fileURL: URL
    private let stateFileURL: URL
    private let capacity: Int
    private let metrics: @Sendable () -> DAMMemorySnapshot

    init(
        fileURL: URL,
        stateFileURL: URL,
        capacity: Int = DAMMemoryTrace.defaultCapacity,
        metrics: @escaping @Sendable () -> DAMMemorySnapshot = DAMMemorySnapshot.live
    ) {
        precondition(capacity > 0)
        self.fileURL = fileURL
        self.stateFileURL = stateFileURL
        self.capacity = capacity
        self.metrics = metrics
    }

    @discardableResult
    func begin(
        kind: CallbackKind,
        activityName: String,
        eventName: String?
    ) -> Context {
        let activityHash = Self.stableHash(activityName)
        let eventHash = eventName.map(Self.stableHash) ?? 0
        let sequence = append(
            callbackID: nil,
            kind: kind,
            stage: .entry,
            flags: [],
            activityHash: activityHash,
            eventHash: eventHash
        ) ?? 0
        return Context(
            callbackID: sequence,
            kind: kind,
            activityHash: activityHash,
            eventHash: eventHash
        )
    }

    func mark(_ context: Context, stage: Stage, flags: Flags = []) {
        _ = append(
            callbackID: context.callbackID,
            kind: context.kind,
            stage: stage,
            flags: flags,
            activityHash: context.activityHash,
            eventHash: context.eventHash
        )
    }

    @discardableResult
    func record(
        callbackID: UInt64,
        kind: CallbackKind,
        stage: Stage,
        flags: Flags = [],
        activityName: String,
        eventName: String?
    ) -> UInt64? {
        append(
            callbackID: callbackID,
            kind: kind,
            stage: stage,
            flags: flags,
            activityHash: Self.stableHash(activityName),
            eventHash: eventName.map(Self.stableHash) ?? 0
        )
    }

    func readRecords() -> [Record] {
        let descriptor = open(fileURL.path, O_RDONLY)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH) == 0 else { return [] }
        defer { flock(descriptor, LOCK_UN) }

        var records: [Record] = []
        records.reserveCapacity(capacity)
        for slot in 0..<capacity {
            guard let data = read(
                descriptor: descriptor,
                count: Self.recordByteCount,
                offset: Self.headerByteCount + (slot * Self.recordByteCount)
            ), let record = Self.decodeRecord(data) else { continue }
            records.append(record)
        }
        return records.sorted { $0.sequence < $1.sequence }
    }

    private func append(
        callbackID: UInt64?,
        kind: CallbackKind,
        stage: Stage,
        flags: Flags,
        activityHash: UInt32,
        eventHash: UInt32
    ) -> UInt64? {
        guard let descriptor = openWritableDescriptor() else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        guard prepareFile(descriptor: descriptor) else { return nil }

        let nextSequence = readHeader(descriptor: descriptor).map { $0 + 1 } ?? 1
        guard writeHeader(nextSequence: nextSequence, descriptor: descriptor) else { return nil }

        let snapshot = metrics()
        let record = Record(
            sequence: nextSequence,
            callbackID: callbackID ?? nextSequence,
            kind: kind,
            stage: stage,
            flags: flags,
            monotonicMilliseconds: UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000),
            wallEpochSeconds: Self.clampToUInt32(Date().timeIntervalSince1970),
            availableBytes: Self.clampToUInt32(snapshot.availableBytes),
            footprintBytes: Self.clampToUInt32(snapshot.footprintBytes),
            peakFootprintBytes: Self.clampToUInt32(snapshot.peakFootprintBytes),
            stateFileBytes: stateFileByteCount(),
            pid: UInt32(bitPattern: snapshot.pid),
            activityHash: activityHash,
            eventHash: eventHash
        )
        let slot = Int((nextSequence - 1) % UInt64(capacity))
        let data = Self.encode(record)
        guard write(
            data,
            descriptor: descriptor,
            offset: Self.headerByteCount + (slot * Self.recordByteCount)
        ) else { return nil }
        return nextSequence
    }

    private func openWritableDescriptor() -> Int32? {
        let descriptor = open(fileURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        return descriptor >= 0 ? descriptor : nil
    }

    private func prepareFile(descriptor: Int32) -> Bool {
        let expectedSize = Self.headerByteCount + (capacity * Self.recordByteCount)
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else { return false }
        if fileInfo.st_size != expectedSize {
            guard ftruncate(descriptor, off_t(expectedSize)) == 0 else { return false }
            return writeHeader(nextSequence: 0, descriptor: descriptor)
        }
        if readHeader(descriptor: descriptor) == nil {
            return writeHeader(nextSequence: 0, descriptor: descriptor)
        }
        return true
    }

    private func readHeader(descriptor: Int32) -> UInt64? {
        guard let data = read(
            descriptor: descriptor,
            count: Self.headerByteCount,
            offset: 0
        ), data.count == Self.headerByteCount,
              Self.readUInt32(data, at: 0) == Self.headerMagic,
              data[4] == Self.formatVersion,
              Self.readUInt16(data, at: 6) == UInt16(Self.recordByteCount),
              Self.readUInt32(data, at: 8) == UInt32(capacity),
              Self.readUInt32(data, at: 60) == Self.checksum(data.prefix(60))
        else { return nil }
        return Self.readUInt64(data, at: 16)
    }

    private func writeHeader(nextSequence: UInt64, descriptor: Int32) -> Bool {
        var data = Data(repeating: 0, count: Self.headerByteCount)
        Self.writeUInt32(Self.headerMagic, to: &data, at: 0)
        data[4] = Self.formatVersion
        Self.writeUInt16(UInt16(Self.recordByteCount), to: &data, at: 6)
        Self.writeUInt32(UInt32(capacity), to: &data, at: 8)
        Self.writeUInt64(nextSequence, to: &data, at: 16)
        Self.writeUInt32(Self.checksum(data.prefix(60)), to: &data, at: 60)
        return write(data, descriptor: descriptor, offset: 0)
    }

    private func stateFileByteCount() -> UInt32 {
        var fileInfo = stat()
        guard stat(stateFileURL.path, &fileInfo) == 0 else { return 0 }
        return Self.clampToUInt32(UInt64(max(0, fileInfo.st_size)))
    }

    private func read(descriptor: Int32, count: Int, offset: Int) -> Data? {
        var data = Data(repeating: 0, count: count)
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, count, off_t(offset))
        }
        return bytesRead == count ? data : nil
    }

    private func write(_ data: Data, descriptor: Int32, offset: Int) -> Bool {
        data.withUnsafeBytes { buffer in
            pwrite(descriptor, buffer.baseAddress, data.count, off_t(offset)) == data.count
        }
    }

    private static func encode(_ record: Record) -> Data {
        var data = Data(repeating: 0, count: recordByteCount)
        writeUInt32(recordMagic, to: &data, at: 0)
        data[4] = formatVersion
        data[5] = record.kind.rawValue
        data[6] = record.stage.rawValue
        data[7] = record.flags.rawValue
        writeUInt64(record.sequence, to: &data, at: 8)
        writeUInt64(record.callbackID, to: &data, at: 16)
        writeUInt32(record.monotonicMilliseconds, to: &data, at: 24)
        writeUInt32(record.wallEpochSeconds, to: &data, at: 28)
        writeUInt32(record.availableBytes, to: &data, at: 32)
        writeUInt32(record.footprintBytes, to: &data, at: 36)
        writeUInt32(record.peakFootprintBytes, to: &data, at: 40)
        writeUInt32(record.stateFileBytes, to: &data, at: 44)
        writeUInt32(record.pid, to: &data, at: 48)
        writeUInt32(record.activityHash, to: &data, at: 52)
        writeUInt32(record.eventHash, to: &data, at: 56)
        writeUInt32(checksum(data.prefix(60)), to: &data, at: 60)
        return data
    }

    private static func decodeRecord(_ data: Data) -> Record? {
        guard data.count == recordByteCount,
              readUInt32(data, at: 0) == recordMagic,
              data[4] == formatVersion,
              readUInt32(data, at: 60) == checksum(data.prefix(60)),
              let kind = CallbackKind(rawValue: data[5]),
              let stage = Stage(rawValue: data[6])
        else { return nil }
        return Record(
            sequence: readUInt64(data, at: 8),
            callbackID: readUInt64(data, at: 16),
            kind: kind,
            stage: stage,
            flags: Flags(rawValue: data[7]),
            monotonicMilliseconds: readUInt32(data, at: 24),
            wallEpochSeconds: readUInt32(data, at: 28),
            availableBytes: readUInt32(data, at: 32),
            footprintBytes: readUInt32(data, at: 36),
            peakFootprintBytes: readUInt32(data, at: 40),
            stateFileBytes: readUInt32(data, at: 44),
            pid: readUInt32(data, at: 48),
            activityHash: readUInt32(data, at: 52),
            eventHash: readUInt32(data, at: 56)
        )
    }

    private static func stableHash(_ value: String) -> UInt32 {
        checksum(value.utf8)
    }

    private static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        bytes.reduce(UInt32(2_166_136_261)) { partial, byte in
            (partial ^ UInt32(byte)) &* 16_777_619
        }
    }

    private static func clampToUInt32(_ value: UInt64) -> UInt32 {
        UInt32(min(value, UInt64(UInt32.max)))
    }

    private static func clampToUInt32(_ value: TimeInterval) -> UInt32 {
        guard value > 0 else { return 0 }
        return clampToUInt32(UInt64(value))
    }

    private static func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        for index in 0..<4 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
        }
    }

    private static func writeUInt64(_ value: UInt64, to data: inout Data, at offset: Int) {
        for index in 0..<8 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, index in
            value | (UInt32(data[offset + index]) << UInt32(index * 8))
        }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { value, index in
            value | (UInt64(data[offset + index]) << UInt64(index * 8))
        }
    }
}

nonisolated struct DAMMemoryTraceLifecycle: Sendable {
    struct IncompleteCallback: Sendable, Equatable {
        let callbackID: UInt64
        let kind: DAMMemoryTrace.CallbackKind
        let lastStage: DAMMemoryTrace.Stage
        let pid: UInt32
    }

    let completedCallbackCount: Int
    let incompleteCallbacks: [IncompleteCallback]
    let unfinishedTimedOutDrainCallbackIDs: [UInt64]

    static func summarize(_ records: [DAMMemoryTrace.Record]) -> DAMMemoryTraceLifecycle {
        let grouped = Dictionary(grouping: records.filter { $0.callbackID != 0 }) {
            $0.callbackID
        }
        var completed = 0
        var incomplete: [IncompleteCallback] = []
        var unfinishedTimedOutDrains: [UInt64] = []
        for (callbackID, callbackRecords) in grouped {
            let ordered = callbackRecords.sorted { $0.sequence < $1.sequence }
            guard let first = ordered.first, let last = ordered.last else { continue }
            if ordered.contains(where: { $0.stage == .exit }) {
                completed += 1
            } else {
                incomplete.append(IncompleteCallback(
                    callbackID: callbackID,
                    kind: first.kind,
                    lastStage: last.stage,
                    pid: last.pid
                ))
            }
            let timedOut = ordered.contains {
                $0.stage == .afterDrainWait && $0.flags.contains(.waitTimedOut)
            }
            let asyncCompleted = ordered.contains {
                $0.stage == .afterDrainWait && $0.flags.contains(.asyncCompleted)
            }
            if timedOut && !asyncCompleted {
                unfinishedTimedOutDrains.append(callbackID)
            }
        }
        return DAMMemoryTraceLifecycle(
            completedCallbackCount: completed,
            incompleteCallbacks: incomplete.sorted { $0.callbackID < $1.callbackID },
            unfinishedTimedOutDrainCallbackIDs: unfinishedTimedOutDrains.sorted()
        )
    }
}
