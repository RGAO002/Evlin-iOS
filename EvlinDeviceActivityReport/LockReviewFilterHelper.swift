import Foundation

/// Byte-compatible mirror of the main app's lock-window audit record. The
/// report extension is a separate module, so it owns a tiny copy of this pure
/// Codable schema instead of depending on app-only sources.
struct LockWindowRecord: Codable {
    let recordKey: String
    let displayName: String
    let bundleID: String?
    let issuedAt: Date
    let expiresAt: Date?
}

enum LockWindowStore {
    static let key = "evlin.lockWindows"
}

/// Pure logic for constraining Lock Activity Review to apps with recorded lock
/// windows. This does not verify historical usage during those windows.
enum LockReviewFilterHelper {
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
