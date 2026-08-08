import Foundation
import FamilyControls
import ManagedSettings

/// Thin wrapper over the same App-Group-persisted saved-list storage
/// `LocalAliasStore` uses, scoped to the single default lock group's
/// `FamilyActivitySelection`. Reads/writes the saved list named after
/// `DefaultLockGroup.shared.name` ("Locked set").
///
/// ## Task 3 (paper-lock fix): self-contained storage, not a `LocalAliasStore` call-through
///
/// This file is compiled into BOTH the `Evlin iOS` app target AND the
/// `EvlinDeviceActivityMonitor` extension target (see `project.pbxproj`
/// `B6F1645E2F999D8A008E858C` membershipExceptions) — the extension's
/// `applyEarnedTimeShield` needs `load()` to read the kid's live selection
/// for the earned-time-exhaustion shield path (Task 3, mirroring
/// `ActionExecutor`'s parent-lock path).
///
/// It intentionally does NOT call through to `LocalAliasStore` (unlike the
/// original single-target version of this file), because `LocalAliasStore`
/// also carries catalog alias-key bookkeeping (`saveCatalogAliasKey`,
/// `catalogListMembers(...)`) whose types (`CatalogListMemberUpload`,
/// `CatalogListMemberTargetType`) live in `APIClient.swift` — a large,
/// app-only networking file. Adding `LocalAliasStore.swift` to the extension
/// target pulls those types in transitively and fails to compile there.
/// Rather than dragging `APIClient.swift` into the extension (out of scope,
/// and the kind of blast-radius this plan's task brief explicitly warns
/// against), this file duplicates ONLY the minimal saved-list read/write
/// primitives, using the EXACT SAME UserDefaults suite, key, and JSON/plist
/// codec `LocalAliasStore` uses for its `saveList`/`savedList(named:)` pair
/// (see `LocalAliasStore.swift`'s `listKey`, `_encodeTokenJSON`/
/// `_decodeTokenAny`), so both targets read/write the identical on-disk
/// format and stay interoperable. If `LocalAliasStore`'s storage format for
/// saved lists ever changes, this file's `_encodeTokenJSON`/`_decodeTokenAny`
/// analogues below must change in lockstep.
enum DefaultLockGroupStore {
    private static let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private static let listKey = "evlin.savedListTokens"

    private static var listName: String { DefaultLockGroup.shared.name }

    static func load() -> FamilyActivitySelection {
        let dict = loadListDict()
        guard let data = dict[listName.lowercased()] else { return FamilyActivitySelection() }
        return decodeTokenAny(FamilyActivitySelection.self, from: data) ?? FamilyActivitySelection()
    }

    static func save(_ selection: FamilyActivitySelection) {
        var dict = loadListDict()
        if let data = encodeTokenJSON(selection) {
            dict[listName.lowercased()] = data
            persistListDict(dict)
        }
    }

    /// Identity teardown: drop EVERY saved list (not just the default lock
    /// group). Saved lists carry opaque tokens scoped to the family and the
    /// authorization epoch that picked them; surviving an account switch they
    /// pre-populate App Controls with dead tokens that arm silent monitors
    /// (WhatsApp 2026-08-06: catalog kept re-uploading a prior family's token,
    /// so every per-app limit watched an app that no longer existed for iOS).
    static func clearAllListsForIdentityTeardown() {
        defaults?.removeObject(forKey: listKey)
    }

    static func removeApp(_ token: ApplicationToken) {
        var s = load()
        s.applicationTokens.remove(token)
        save(s)
    }

    static func removeCategory(_ token: ActivityCategoryToken) {
        var s = load()
        s.categoryTokens.remove(token)
        save(s)
    }

    // MARK: - Private storage (mirrors LocalAliasStore's saved-list format)

    private static func loadListDict() -> [String: Data] {
        (defaults?.dictionary(forKey: listKey) as? [String: Data]) ?? [:]
    }

    private static func persistListDict(_ dict: [String: Data]) {
        defaults?.set(dict, forKey: listKey)
    }

    /// `PropertyListEncoder` trips `swift_dynamicCastFailure` when encoding
    /// FamilyControls tokens on iOS 26 (binary plist Swift rewrite regression).
    /// JSON encoding round-trips the same tokens without hitting that codepath.
    /// Mirrors `LocalAliasStore.swift`'s fileprivate `_encodeTokenJSON`.
    private static func encodeTokenJSON<T: Encodable>(_ value: T) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try? e.encode(value)
    }

    /// Try JSON first (new format), fall back to PropertyList (legacy data
    /// already in UserDefaults from previous app versions). Mirrors
    /// `LocalAliasStore.swift`'s fileprivate `_decodeTokenAny`.
    private static func decodeTokenAny<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let jd = JSONDecoder()
        jd.dateDecodingStrategy = .iso8601
        if let v = try? jd.decode(type, from: data) { return v }
        return try? PropertyListDecoder().decode(type, from: data)
    }
}
