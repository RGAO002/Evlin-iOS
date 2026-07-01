import Foundation

/// Reads the *enforcement truth* — the App-Group dicts the DeviceActivity
/// extension actually writes (`evlin.shieldRecords` / `evlin.blockRecords`,
/// suite `group.com.evlin.ios`) — decoded with the same `.iso8601` strategy
/// `ActiveLockStore` persists with (see `ActiveLockStore.swift:503`).
/// Used by the A0.5 debug screen now and by the A1 snapshot upload later.
enum CurrentRestrictionsReader {
    static let suiteName = "group.com.evlin.ios"
    static let shieldsKey = "evlin.shieldRecords"
    static let blocksKey = "evlin.blockRecords"

    static func decodeDict<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> [T] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let dict = (try? dec.decode([String: T].self, from: data)) ?? [:]
        return Array(dict.values)
    }

    static func persistedShields(from defaults: UserDefaults) -> [ShieldRecord] {
        decodeDict(ShieldRecord.self, key: shieldsKey, from: defaults)
    }
    static func persistedBlocks(from defaults: UserDefaults) -> [BlockRecord] {
        decodeDict(BlockRecord.self, key: blocksKey, from: defaults)
    }
    static func persistedShields() -> [ShieldRecord] {
        UserDefaults(suiteName: suiteName).map { persistedShields(from: $0) } ?? []
    }
    static func persistedBlocks() -> [BlockRecord] {
        UserDefaults(suiteName: suiteName).map { persistedBlocks(from: $0) } ?? []
    }
}
