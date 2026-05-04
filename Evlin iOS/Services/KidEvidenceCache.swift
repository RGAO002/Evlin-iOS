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
    private static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BigKidEvidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One subdirectory per task — holds N photos as `0.jpg`, `1.jpg`, …
    /// in the order the kid added them. Directory layout means we can
    /// list all photos for a task without tracking a separate index.
    private static func taskDirectory(for taskId: UUID) -> URL {
        let dir = rootDirectory.appendingPathComponent(taskId.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Save a batch as the full evidence set — clears any existing photos
    /// first so the cache mirrors the backend's "list replaces previous"
    /// semantics.
    static func save(taskId: UUID, photos: [Data]) {
        clear(taskId: taskId)
        let dir = taskDirectory(for: taskId)
        for (idx, data) in photos.enumerated() {
            let url = dir.appendingPathComponent("\(idx).jpg")
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("[KidEvidenceCache] save failed for \(taskId) idx=\(idx): \(error)")
            }
        }
    }

    /// Load all cached photos for a task, in submission order. Empty if
    /// the task was never submitted on this device or after `clear`.
    static func load(taskId: UUID) -> [Data] {
        let dir = taskDirectory(for: taskId)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        // Sort numerically so 10.jpg comes after 9.jpg, not after 1.jpg.
        let sorted = names.sorted { (a: String, b: String) in
            let ai = Int((a as NSString).deletingPathExtension) ?? Int.max
            let bi = Int((b as NSString).deletingPathExtension) ?? Int.max
            return ai < bi
        }
        return sorted.compactMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
    }

    static func clear(taskId: UUID) {
        try? FileManager.default.removeItem(at: taskDirectory(for: taskId))
    }
}
