import Foundation

/// Pure, side-effect-free transforms over the `[String: ShieldRecord]` shields
/// dict for the multi-source / earned-time subsystem (B1+).
///
/// Membership: this file is a member of BOTH the main app target (so the test
/// target can `@testable import Evlin_iOS` it) AND the `EvlinDeviceActivityMonitor`
/// extension target (so B5's extension enforcement path can call it). Keep it
/// free of any app-only / extension-only API. NO actor, NO UserDefaults.
enum ShieldSourceLogic {

    // MARK: - Record-level operations

    /// Return `record` with `newSources` unioned into its `sources` set.
    /// Pure: the original record is unchanged; a new value is returned.
    static func unioning(
        _ record: ShieldRecord,
        intoSources newSources: Set<ShieldSource>
    ) -> ShieldRecord {
        var updated = record
        updated.sources = record.sources.union(newSources)
        return updated
    }

    /// Return `record` with `source` removed from its `sources` set, or `nil`
    /// when the set becomes empty (signals the caller to delete the record).
    /// Pure: the original record is unchanged.
    static func removing(
        _ source: ShieldSource,
        from record: ShieldRecord
    ) -> ShieldRecord? {
        var remaining = record.sources
        remaining.remove(source)
        guard !remaining.isEmpty else { return nil }
        var updated = record
        updated.sources = remaining
        return updated
    }

    // MARK: - Dict-level operations

    /// Return `dict` with `source` removed from the record at `key`. If the
    /// record's `sources` set becomes empty the key is deleted. If `key` is not
    /// in `dict` the dict is returned unchanged. Pure.
    static func removingSource(
        _ source: ShieldSource,
        fromRecordKey key: String,
        in dict: [String: ShieldRecord]
    ) -> [String: ShieldRecord] {
        guard let record = dict[key] else { return dict }
        var out = dict
        if let updated = removing(source, from: record) {
            out[key] = updated
        } else {
            out.removeValue(forKey: key)
        }
        return out
    }

    /// Return `dict` with `source` stripped from EVERY record. Records whose
    /// `sources` set becomes empty are deleted. Analogous to
    /// `LimitShieldLogic.strippingLimitShields` but operates on an arbitrary
    /// source value rather than the `.limit` sentinel. Pure.
    static func strippingSource(
        _ source: ShieldSource,
        from dict: [String: ShieldRecord]
    ) -> [String: ShieldRecord] {
        var out = dict
        for (key, record) in dict {
            if let updated = removing(source, from: record) {
                out[key] = updated
            } else {
                out.removeValue(forKey: key)
            }
        }
        return out
    }
}
