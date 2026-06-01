import Foundation

/// Audit log of a single lock's time window, persisted to the App Group so the
/// Lock Activity Review can annotate which apps were under a lock and when.
/// This is not execution state; missing entries never imply enforcement either way.
struct LockWindowRecord: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(recordKey)#\(issuedAt.timeIntervalSince1970)" }
    let recordKey: String
    let displayName: String
    let bundleID: String?
    let issuedAt: Date
    let expiresAt: Date?
}

/// Append-only, capped App Group store. Pure of FamilyControls so tests do not
/// need Screen Time authorization.
enum LockWindowStore {
    static let key = "evlin.lockWindows"
    private static let suite = "group.com.evlin.ios"
    private static let cap = 200

    static func load() -> [LockWindowRecord] {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: key) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LockWindowRecord].self, from: data)) ?? []
    }

    static func append(_ record: LockWindowRecord) {
        var all = load()
        all.append(record)
        if all.count > cap {
            all = Array(all.suffix(cap))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else {
            return
        }
        UserDefaults(suiteName: suite)?.set(data, forKey: key)
    }

    /// Windows for a bundle whose [issuedAt, expiresAt] overlaps the query interval.
    /// Permanent windows (nil expiresAt) count as open-ended.
    static func windows(
        forBundleID bundleID: String,
        overlapping interval: DateInterval
    ) -> [LockWindowRecord] {
        load().filter { record in
            guard record.bundleID == bundleID else { return false }
            let end = record.expiresAt ?? .distantFuture
            return record.issuedAt <= interval.end && end >= interval.start
        }
    }
}
