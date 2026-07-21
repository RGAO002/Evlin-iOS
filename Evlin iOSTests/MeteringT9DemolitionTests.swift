import FamilyControls
import Foundation
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringT9DemolitionTests: XCTestCase {
    func testDeadEarnedLockedTokenBlobIsAbsentFromProduction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let forbidden = ["locked", "Set", "Token", "Data"].joined()
        let productionRoots = ["Evlin iOS", "EvlinDeviceActivityMonitor"]

        for relativeRoot in productionRoots {
            let directory = root.appendingPathComponent(relativeRoot)
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            )
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                XCTAssertFalse(
                    source.contains(forbidden),
                    "dead earned token blob remains in \(fileURL.path)"
                )
            }
        }
    }

    func testLockedSetIdentityAndFlagsRemainIndependentOfLegacyBlobBytes() throws {
        let suiteName = "MeteringT9DemolitionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(suiteName: suiteName)
        let listID = UUID()
        let aliasID = UUID()

        defaults.set(Data("orphaned-dead-value".utf8), forKey: "earned.lockedSetTokenData")
        store.saveLockedSetID(listID.uuidString, tokenData: nil)
        store.saveLockedSetListAliasKey(aliasID)
        store.saveLockedSetAllSelected(true)

        XCTAssertEqual(store.lockedSetID, listID.uuidString)
        XCTAssertEqual(store.lockedSetListAliasKey, aliasID)
        XCTAssertTrue(store.lockedSetAllSelected)
    }

    func testDefaultLockGroupRemainsTheTokenAuthority() throws {
        let suiteName = "MeteringT9DefaultGroup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selection = FamilyActivitySelection()

        let encoded = try JSONEncoder().encode(selection)
        defaults.set(encoded, forKey: "evlin.defaultLockGroup.selection")

        let loaded = try JSONDecoder().decode(
            FamilyActivitySelection.self,
            from: try XCTUnwrap(defaults.data(forKey: "evlin.defaultLockGroup.selection"))
        )
        XCTAssertEqual(loaded.applicationTokens, selection.applicationTokens)
        XCTAssertEqual(loaded.categoryTokens, selection.categoryTokens)
        XCTAssertEqual(loaded.webDomainTokens, selection.webDomainTokens)
    }
}
