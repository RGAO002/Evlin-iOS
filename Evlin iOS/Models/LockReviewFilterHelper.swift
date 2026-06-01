import Foundation

/// Pure logic for the Lock Activity Review. Audit-only and best-effort: it
/// surfaces which locked bundleIDs to constrain the report to, not whether
/// usage fell inside a historical lock window.
enum LockReviewFilterHelper {
    /// Distinct app bundleIDs that have a recorded lock window.
    static func lockedBundleIDs(from windows: [LockWindowRecord]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for window in windows {
            guard let bundleID = window.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleID.isEmpty,
                  seen.insert(bundleID).inserted
            else {
                continue
            }
            output.append(bundleID)
        }
        return output.sorted()
    }
}
