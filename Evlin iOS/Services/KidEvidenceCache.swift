import Foundation

/// Local on-disk cache of evidence photos the kid submitted.
///
/// Decouples the kid's "did I really send my photo?" UX from backend
/// persistence. The current BigKid backend stores blobs in process
/// memory, which means every Railway redeploy wipes them — kid would
/// re-open a previously submitted task and see a placeholder, even
/// though they did nothing wrong. With this cache the kid always sees
/// the most recent photo they uploaded for a given task, indefinitely.
///
/// Parent visibility still depends on the backend serving the URL —
/// when backend persistence lands (Phase 13), this cache becomes a
/// nice-to-have offline fallback rather than the only way the kid
/// can see their own work.
enum KidEvidenceCache {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BigKidEvidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for taskId: UUID) -> URL {
        directory.appendingPathComponent("\(taskId.uuidString).jpg")
    }

    static func save(taskId: UUID, photoData: Data) {
        do {
            try photoData.write(to: fileURL(for: taskId), options: .atomic)
        } catch {
            print("[KidEvidenceCache] save failed for \(taskId): \(error)")
        }
    }

    static func load(taskId: UUID) -> Data? {
        let url = fileURL(for: taskId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func clear(taskId: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: taskId))
    }
}
