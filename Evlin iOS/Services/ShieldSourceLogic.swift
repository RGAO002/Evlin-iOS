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
        intoSources newSources: Set<ShieldSource>,
        limitRuleIDs newLimitRuleIDs: Set<UUID> = []
    ) -> ShieldRecord {
        var updated = record
        updated.sources = record.sources.union(newSources)
        updated.limitRuleIDs.formUnion(newLimitRuleIDs)
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
        if source == .limit {
            updated.limitRuleIDs = []
        }
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

/// Wave-1 Task 5: one-time re-key sweep for the "immortal lock" bug.
///
/// `ShieldRecord.makeRecordKey` now lowercases the `.savedList` targetKey
/// segment, but records persisted BEFORE that fix may still be keyed
/// `savedList:<UPPERCASE-UUID>` (written via the pre-fix `id.uuidString`
/// unlock path). Those stale keys would never again be found by a
/// `removeSource`/`removeShield` call built through the now-normalized
/// helper, leaving them "immortal". `ActiveLockStore.restore()` runs this
/// sweep once per decode to re-key (or merge) any such records.
///
/// Pure, side-effect-free — mirrors `ShieldSourceLogic`'s dict-transform
/// style so it's independently testable without an `ActiveLockStore`
/// instance or an injected `UserDefaults` suite.
enum ScreenTimeRecordKeySweep {

    /// Re-key every `savedList:`-prefixed entry whose key isn't already its
    /// lowercased form. When the lowercase form already exists in `dict`, the
    /// two records are merged by unioning `sources` (the existing lowercase
    /// record's other fields — tokens, displayName, expiry, etc. — win, since
    /// it's the canonical/newer record going forward). When no lowercase twin
    /// exists, the record is simply re-keyed in place (all fields preserved,
    /// `recordKey`/`targetKey` updated to match the new key).
    static func sweep(_ dict: [String: ShieldRecord]) -> [String: ShieldRecord] {
        let prefix = "savedList:"
        var out = dict
        for (key, record) in dict {
            guard key.hasPrefix(prefix) else { continue }
            // Lowercase only the segment AFTER the prefix — `key.lowercased()`
            // would also fold "savedList" itself to "savedlist", breaking the
            // `hasPrefix("savedList:")` convention every other call site relies on.
            let targetSegment = String(key.dropFirst(prefix.count))
            let loweredKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: targetSegment)
            guard loweredKey != key else { continue }

            out.removeValue(forKey: key)
            if let twin = out[loweredKey] {
                out[loweredKey] = ShieldSourceLogic.unioning(
                    twin,
                    intoSources: record.sources,
                    limitRuleIDs: record.limitRuleIDs
                )
            } else {
                // `recordKey`/`targetKey` are immutable (`let`) — rebuild the
                // record rather than mutate in place. Every other field is
                // carried over unchanged.
                out[loweredKey] = ShieldRecord(
                    recordKey: loweredKey,
                    tier: record.tier,
                    targetKey: record.targetKey.lowercased(),
                    displayName: record.displayName,
                    lastCommandID: record.lastCommandID,
                    appTokens: record.appTokens,
                    categoryTokens: record.categoryTokens,
                    webDomainTokens: record.webDomainTokens,
                    appliesToAll: record.appliesToAll,
                    issuedAt: record.issuedAt,
                    expiresAt: record.expiresAt,
                    originalRequest: record.originalRequest,
                    targetChildID: record.targetChildID,
                    sources: record.sources,
                    limitRuleIDs: record.limitRuleIDs
                )
            }
        }
        return out
    }
}
