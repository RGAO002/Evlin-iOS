import XCTest
import FamilyControls
@testable import Evlin_iOS

/// C-3 Task 2: both Home settings lock buttons route through ONE stable
/// manual `ActiveLockStore` record instead of writing ManagedSettings shield
/// fields via ScreenTimeManager. The unlock action removes ONLY the Home
/// settings manual record — automatic-source records must survive.
final class HomeSettingsLockRoutingTests: XCTestCase {

    // MARK: - Record construction

    func test_empty_selection_returns_nil() {
        XCTAssertNil(HomeSettingsLockRouting.makeRecord(
            selection: FamilyActivitySelection(),
            childID: UUID()
        ))
    }

    func test_record_uses_stable_manual_savedList_shape() {
        let childID = UUID()
        let commandID = UUID()
        let issuedAt = Date(timeIntervalSince1970: 3_000)

        let record = HomeSettingsLockRouting.makeRecordUnchecked(
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            childID: childID,
            issuedAt: issuedAt,
            commandID: commandID
        )

        XCTAssertEqual(record.tier, .savedList)
        XCTAssertEqual(record.recordKey, "savedList:home-settings-selected")
        XCTAssertEqual(record.recordKey, HomeSettingsLockRouting.recordKey)
        XCTAssertEqual(record.targetKey, "home-settings-selected")
        XCTAssertEqual(record.sources, [.manual])
        XCTAssertFalse(record.webOpen)
        XCTAssertFalse(record.appliesToAll)
        XCTAssertNil(record.expiresAt, "Home settings lock is permanent until unlocked")
        XCTAssertEqual(record.targetChildID, childID)
        XCTAssertEqual(record.lastCommandID, commandID)
        XCTAssertEqual(record.issuedAt, issuedAt)
    }

    // MARK: - lock / unlock routing

    func test_lock_rejects_empty_selection_without_touching_store() async throws {
        let (store, defaults, suite) = try makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let locked = await HomeSettingsLockRouting.lock(
            selection: FamilyActivitySelection(),
            childID: UUID(),
            store: store
        )

        XCTAssertFalse(locked)
        let shields = await store.allCurrent().shields
        XCTAssertTrue(shields.isEmpty)
    }

    func test_unlock_removes_only_home_record_and_automatic_record_survives() async throws {
        let (store, defaults, suite) = try makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let childID = UUID()
        let home = HomeSettingsLockRouting.makeRecordUnchecked(
            appTokens: [], categoryTokens: [], webDomainTokens: [],
            childID: childID, issuedAt: Date(), commandID: UUID()
        )
        let automatic = Self.makeAutomaticFixtureRecord(childID: childID)

        _ = await store.addShield(home, force: true)
        _ = await store.addShield(automatic, force: true)

        let unlocked = await HomeSettingsLockRouting.unlock(store: store)

        XCTAssertTrue(unlocked)
        let remaining = await store.allCurrent().shields
        XCTAssertEqual(remaining.map(\.recordKey), [automatic.recordKey],
                       "Home unlock must remove ONLY the Home settings manual record")
        XCTAssertEqual(remaining.first?.sources, [.earnedTime])
    }

    func test_unlock_with_no_home_record_reports_false() async throws {
        let (store, defaults, suite) = try makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let unlocked = await HomeSettingsLockRouting.unlock(store: store)

        XCTAssertFalse(unlocked)
    }

    // MARK: - Architecture guard (source-level)

    func test_settings_sheet_has_no_direct_screen_time_shield_calls() throws {
        let source = try Self.sourceText("Evlin iOS/Views/Home/HomeSettingsSheet.swift")
        XCTAssertFalse(source.contains("screenTimeManager.shieldApps()"),
                       "Home lock button must route through HomeSettingsLockRouting")
        XCTAssertFalse(source.contains("screenTimeManager.clearAllShields()"),
                       "Home unlock/reset must route through ActiveLockStore records")
    }

    /// C-3 Task 3: the dead direct-write shield APIs must not return.
    /// Needles are concatenated so the repo-wide `rg` dead-API gate does not
    /// match this test file itself.
    func test_screen_time_manager_has_no_dead_direct_writers() throws {
        let source = try Self.sourceText("Evlin iOS/Services/ScreenTimeManager.swift")
        XCTAssertFalse(source.contains("func shieldApps" + "("),
                       "ScreenTimeManager must not expose a second shield writer")
        XCTAssertFalse(source.contains("func clearAllShields" + "("),
                       "ScreenTimeManager must not expose a second unshield writer")
        XCTAssertFalse(source.contains("func shieldAllApps" + "("),
                       "shieldAllApps was a zero-caller direct ManagedSettings writer")
        XCTAssertFalse(source.contains("func unshieldApps" + "("),
                       "unshieldApps-forMinutes was a zero-caller direct ManagedSettings writer")
    }

    func test_active_lock_store_is_the_only_main_app_shield_block_field_writer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Evlin iOS")
        let directWriteNeedles = [
            ".shield." + "applications =",
            ".shield." + "applicationCategories =",
            ".shield." + "webDomains =",
            ".shield." + "webDomainCategories =",
            ".application." + "blockedApplications =",
        ]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        var offenders: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard fileURL.lastPathComponent != "ActiveLockStore.swift" else { continue }
            // Explicit diagnostic probes exercise ManagedSettings directly and
            // are not production lock routing. They live under a Debug folder;
            // every non-debug main-app path remains covered by this guard.
            guard !fileURL.pathComponents.contains("Debug") else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            if directWriteNeedles.contains(where: source.contains) {
                offenders.append(fileURL.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }

        XCTAssertEqual(
            offenders,
            [],
            "All main-app shield/block field writes must be projected by ActiveLockStore"
        )
    }

    // MARK: - Helpers

    /// Resolve repository paths from `#filePath` (never the process cwd).
    static func sourceText(_ repoRelativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Evlin iOSTests
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent(repoRelativePath),
            encoding: .utf8
        )
    }

    private func makeIsolatedStore() throws -> (ActiveLockStore, UserDefaults, String) {
        let suite = "HomeSettingsLockRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (ActiveLockStore(defaults: defaults), defaults, suite)
    }

    /// An automatic-source (earned-time) record that MUST survive Home unlock.
    private static func makeAutomaticFixtureRecord(childID: UUID) -> ShieldRecord {
        ShieldRecord(
            recordKey: "allApps:earned",
            tier: .allApps,
            targetKey: "earned",
            displayName: "Earned time",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "earned",
            targetChildID: childID,
            sources: [.earnedTime]
        )
    }
}
