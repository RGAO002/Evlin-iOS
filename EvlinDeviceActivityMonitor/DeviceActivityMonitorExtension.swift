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

        // Two activity namespaces fire here:
        //   "evlin.shield.<16-byte-hex-of-recordKey>" — timed shield expiring
        //   "evlin.block.<16-byte-hex-of-bundleID>"  — timed block expiring
        // Both result in the matching record being dropped from the App
        // Group store and the effective ManagedSettings state being
        // recomputed from what remains.
        let raw = activity.rawValue
        if raw.hasPrefix("evlin.shield.") {
            let hashHex = String(raw.dropFirst("evlin.shield.".count))
            removeShieldByHashAndRecompute(hashHex: hashHex)
        } else if raw.hasPrefix("evlin.block.") {
            let hashHex = String(raw.dropFirst("evlin.block.".count))
            removeBlockByHashAndRecompute(hashHex: hashHex)
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        if event.rawValue == "evlin.bigkid.chunk" {
            Task { await BigKidExtensionReporter.shared.reportChunk() }
        }
    }

    private func removeShieldByHashAndRecompute(hashHex: String) {
        guard let shieldData = defaults?.data(forKey: shieldsKey),
              var shields = try? PropertyListDecoder().decode([String: ShieldRecord].self, from: shieldData)
        else { return }

        // Find the record whose derived name matches the hash
        let targetKey = shields.keys.first(where: { key in
            let data = key.data(using: .utf8) ?? Data()
            let prefix = sha256Hex16(data)
            return prefix == hashHex
        })
        guard let recordKey = targetKey else { return }
        shields.removeValue(forKey: recordKey)

        if let updated = try? PropertyListEncoder().encode(shields) {
            defaults?.set(updated, forKey: shieldsKey)
        }

        // Recompute & apply (same logic as ActiveLockStore.recomputeAndApply)
        let blocks: [String: BlockRecord] = {
            guard let d = defaults?.data(forKey: blocksKey),
                  let decoded = try? PropertyListDecoder().decode([String: BlockRecord].self, from: d) else {
                return [:]
            }
            return decoded
        }()

        let blockedApps = Set(blocks.values.map { ManagedSettings.Application(bundleIdentifier: $0.bundleID) })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps

        if shields.values.contains(where: { $0.appliesToAll }) {
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()
            store.shield.applications = nil
            store.shield.webDomains = nil
            return
        }

        let allApp = Set(shields.values.flatMap(\.appTokens))
        let allCat = Set(shields.values.flatMap(\.categoryTokens))
        let allWeb = Set(shields.values.flatMap(\.webDomainTokens))

        store.shield.applications = allApp.isEmpty ? nil : allApp
        store.shield.applicationCategories = allCat.isEmpty ? nil : .specific(allCat)
        store.shield.webDomains = allWeb.isEmpty ? nil : allWeb
        store.shield.webDomainCategories = nil
    }

    /// Symmetric to `removeShieldByHashAndRecompute` but for timed
    /// blocks: locate the BlockRecord whose bundleID hashes to this
    /// activity, drop it, then recompute `application.blockedApplications`
    /// from whatever's left.
    private func removeBlockByHashAndRecompute(hashHex: String) {
        guard let blockData = defaults?.data(forKey: blocksKey),
              var blocks = try? PropertyListDecoder().decode([String: BlockRecord].self, from: blockData)
        else { return }

        let target = blocks.keys.first { bundleID in
            let prefix = sha256Hex16(bundleID.data(using: .utf8) ?? Data())
            return prefix == hashHex
        }
        guard let bundleID = target else { return }
        blocks.removeValue(forKey: bundleID)

        if let updated = try? PropertyListEncoder().encode(blocks) {
            defaults?.set(updated, forKey: blocksKey)
        }

        // Re-derive blockedApplications from the surviving records.
        let blockedApps = Set(blocks.values.map {
            ManagedSettings.Application(bundleIdentifier: $0.bundleID)
        })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps
    }
}

private func sha256Hex16(_ data: Data) -> String {
    let hash = SHA256.hash(data: data)
    return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
}
