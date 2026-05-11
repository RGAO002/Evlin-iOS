import Foundation
import DeviceActivity
import ManagedSettings
import FamilyControls
import CryptoKit

/// Fires when a scheduled shield interval ends. Removes the ShieldRecord from
/// App Group persistence and recomputes shield state for remaining records.
/// See spec §3.6 and §3.7.
class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let shieldsKey = "evlin.shieldRecords"
    private let blocksKey = "evlin.blockRecords"
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let store = ManagedSettingsStore()

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        let raw = activity.rawValue
        // Diagnostic marker — every intervalDidEnd entry writes its name + ts
        // to the App Group so the main app can show "extension fired at X"
        // in Settings. Without this we can't tell whether iOS dispatched the
        // callback at all (vs the extension running but failing to clear).
        let ts = ISO8601DateFormatter().string(from: Date())
        let marker = "fired \(ts) activity=\(raw)"
        defaults?.set(marker, forKey: "evlin.lastIntervalDidEnd")
        NSLog("[Evlin/Ext] intervalDidEnd %@", marker)

        // Two activity namespaces fire here:
        //   "evlin.shield.<16-byte-hex-of-recordKey>" — timed shield expiring
        //   "evlin.block.<16-byte-hex-of-bundleID>"  — timed block expiring
        if raw.hasPrefix("evlin.shield.") {
            let hashHex = String(raw.dropFirst("evlin.shield.".count))
            let found = removeShieldByHashAndRecompute(hashHex: hashHex)
            // On miss, surface what keys ARE in the dict so we can tell whether
            // the stored key drifted from what we hashed against, or the dict
            // is empty (main-app sweepExpired already cleared it).
            var detail = "\(marker) shieldRemoved=\(found)"
            if !found {
                let keys: [String] = {
                    guard let data = defaults?.data(forKey: shieldsKey),
                          let shields = decodeShields(from: data)
                    else { return [] }
                    return Array(shields.keys)
                }()
                detail += " keysCount=\(keys.count) keys=\(keys)"
            }
            defaults?.set(detail, forKey: "evlin.lastIntervalDidEnd")
            NSLog("[Evlin/Ext] %@", detail)
        } else if raw.hasPrefix("evlin.block.") {
            let hashHex = String(raw.dropFirst("evlin.block.".count))
            let found = removeBlockByHashAndRecompute(hashHex: hashHex)
            defaults?.set("\(marker) blockRemoved=\(found)", forKey: "evlin.lastIntervalDidEnd")
            NSLog("[Evlin/Ext] block remove found=%d hash=%@", found ? 1 : 0, hashHex)
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        if event.rawValue == "evlin.bigkid.chunk" {
            Task { await BigKidExtensionReporter.shared.reportChunk() }
        }
    }

    @discardableResult
    private func removeShieldByHashAndRecompute(hashHex: String) -> Bool {
        // Read whatever the App Group says is current. If main-app sweepExpired
        // already pre-empted us, this dict may already be missing the hashed
        // record — that's fine, we still need to force-recompute the store
        // (the previous `store.shield.applications` write may not have
        // propagated, or sweepExpired set it from an actor thread that
        // springboard hasn't picked up yet). Idempotent recompute is safe.
        let shields: [String: ShieldRecord] = {
            guard let data = defaults?.data(forKey: shieldsKey),
                  let decoded = decodeShields(from: data) else { return [:] }
            return decoded
        }()

        let targetKey = shields.keys.first(where: { key in
            let data = key.data(using: .utf8) ?? Data()
            let prefix = sha256Hex16(data)
            return prefix == hashHex
        })

        var mutated = shields
        let removedRecord: Bool
        if let recordKey = targetKey {
            mutated.removeValue(forKey: recordKey)
            if let updated = encodeShields(mutated) {
                defaults?.set(updated, forKey: shieldsKey)
            }
            removedRecord = true
        } else {
            // Dict already swept by main app — still recompute to ensure
            // the store reflects the current (possibly empty) record set.
            removedRecord = false
        }

        // Recompute & apply (same logic as ActiveLockStore.recomputeAndApply)
        let blocks: [String: BlockRecord] = {
            guard let d = defaults?.data(forKey: blocksKey),
                  let decoded = decodeBlocks(from: d) else {
                return [:]
            }
            return decoded
        }()

        let blockedApps = Set(blocks.values.map { ManagedSettings.Application(bundleIdentifier: $0.bundleID) })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps

        if mutated.values.contains(where: { $0.appliesToAll }) {
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()
            store.shield.applications = nil
            store.shield.webDomains = nil
        } else {
            let allApp = Set(mutated.values.flatMap(\.appTokens))
            let allCat = Set(mutated.values.flatMap(\.categoryTokens))
            let allWeb = Set(mutated.values.flatMap(\.webDomainTokens))

            store.shield.applications = allApp.isEmpty ? nil : allApp
            store.shield.applicationCategories = allCat.isEmpty ? nil : .specific(allCat)
            store.shield.webDomains = allWeb.isEmpty ? nil : allWeb
            store.shield.webDomainCategories = nil
        }

        // Mark that the extension forced its own recompute. The diagnostic in
        // HomeSettingsSheet's "Last Extension Fire" already shows shieldRemoved;
        // augment it so we can tell apart 'pre-empted by main app + idempotent
        // recompute' (removedRecord=false) from 'extension did the work itself'
        // (removedRecord=true).
        let ts = ISO8601DateFormatter().string(from: Date())
        defaults?.set(
            "ext_recompute_at=\(ts) shieldsRemaining=\(mutated.count)"
                + " blocksRemaining=\(blocks.count) removedHere=\(removedRecord)",
            forKey: "evlin.lastRecompute"
        )

        return removedRecord
    }

    /// Symmetric to `removeShieldByHashAndRecompute` but for timed
    /// blocks: locate the BlockRecord whose bundleID hashes to this
    /// activity, drop it, then recompute `application.blockedApplications`
    /// from whatever's left.
    @discardableResult
    private func removeBlockByHashAndRecompute(hashHex: String) -> Bool {
        guard let blockData = defaults?.data(forKey: blocksKey),
              var blocks = decodeBlocks(from: blockData)
        else { return false }

        let target = blocks.keys.first { bundleID in
            let prefix = sha256Hex16(bundleID.data(using: .utf8) ?? Data())
            return prefix == hashHex
        }
        guard let bundleID = target else { return false }
        blocks.removeValue(forKey: bundleID)

        if let updated = encodeBlocks(blocks) {
            defaults?.set(updated, forKey: blocksKey)
        }

        // Re-derive blockedApplications from the surviving records.
        let blockedApps = Set(blocks.values.map {
            ManagedSettings.Application(bundleIdentifier: $0.bundleID)
        })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps
        return true
    }
}

/// Match `ActiveLockStore` — JSON for token-heavy `ShieldRecord`; plist only for legacy payloads.
private func decodeShields(from data: Data) -> [String: ShieldRecord]? {
    if let d = try? JSONDecoder().decode([String: ShieldRecord].self, from: data) { return d }
    return try? PropertyListDecoder().decode([String: ShieldRecord].self, from: data)
}

private func encodeShields(_ shields: [String: ShieldRecord]) -> Data? {
    try? JSONEncoder().encode(shields)
}

private func decodeBlocks(from data: Data) -> [String: BlockRecord]? {
    if let d = try? JSONDecoder().decode([String: BlockRecord].self, from: data) { return d }
    return try? PropertyListDecoder().decode([String: BlockRecord].self, from: data)
}

private func encodeBlocks(_ blocks: [String: BlockRecord]) -> Data? {
    try? JSONEncoder().encode(blocks)
}

private func sha256Hex16(_ data: Data) -> String {
    let hash = SHA256.hash(data: data)
    return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
}
