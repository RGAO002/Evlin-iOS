import Foundation
import Darwin

nonisolated final class ActiveLockPersistenceLock: @unchecked Sendable {
    static let shared = ActiveLockPersistenceLock()
    private let processLock = NSRecursiveLock()
    private let recursionKey = "com.evlin.active-lock-persistence-lock.depth"

    func withLock<T>(_ body: () -> T) -> T? {
        processLock.lock()
        defer { processLock.unlock() }

        let threadState = Thread.current.threadDictionary
        let depth = threadState[recursionKey] as? Int ?? 0
        if depth > 0 {
            threadState[recursionKey] = depth + 1
            defer { threadState[recursionKey] = depth }
            return body()
        }
        threadState[recursionKey] = 1
        defer { threadState.removeObject(forKey: recursionKey) }

        let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.evlin.ios"
        ) ?? FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("active-lock-store.lock")
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            return nil
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return body()
    }
}
