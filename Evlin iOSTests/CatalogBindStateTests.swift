import XCTest
@testable import Evlin_iOS

final class CatalogBindStateTests: XCTestCase {
    private func pick(_ name: String, _ bundle: String?, _ aliases: [String] = []) -> CatalogSearchResult {
        CatalogSearchResult(canonicalName: name, bundleID: bundle, aliases: aliases)
    }

    func test_newRow_unboundAndNotLockable() {
        let row = PendingAppRow(rowID: UUID(), tokenBase64: "QUJD")
        XCTAssertNil(row.boundEntry)
        XCTAssertFalse(row.confirmed)
        XCTAssertFalse(row.isLockableApp)
    }

    func test_bindSetsEntryButRequiresConfirmation() {
        var row = PendingAppRow(rowID: UUID(), tokenBase64: "QUJD")
        row.bind(pick("Instagram", "com.burbn.instagram", ["IG"]))
        XCTAssertEqual(row.boundEntry?.canonicalName, "Instagram")
        XCTAssertFalse(row.confirmed)
        XCTAssertFalse(row.isLockableApp)
    }

    func test_confirmAfterBindMakesLockable() {
        var row = PendingAppRow(rowID: UUID(), tokenBase64: "QUJD")
        row.bind(pick("Instagram", "com.burbn.instagram", ["IG"]))
        row.confirm()
        XCTAssertTrue(row.confirmed)
        XCTAssertTrue(row.isLockableApp)
    }

    func test_confirmWithoutBindIsNoop() {
        var row = PendingAppRow(rowID: UUID(), tokenBase64: "QUJD")
        row.confirm()
        XCTAssertFalse(row.confirmed)
        XCTAssertFalse(row.isLockableApp)
    }

    func test_rebindClearsConfirmation() {
        var row = PendingAppRow(rowID: UUID(), tokenBase64: "QUJD")
        row.bind(pick("Instagram", "com.burbn.instagram", ["IG"]))
        row.confirm()
        row.bind(pick("TikTok", "com.zhiliaoapp.musically", ["tt"]))
        XCTAssertEqual(row.boundEntry?.canonicalName, "TikTok")
        XCTAssertFalse(row.confirmed)
        XCTAssertFalse(row.isLockableApp)
    }

    func test_makeUploadAppFromConfirmedRowCarriesCatalogFields() throws {
        let rowID = UUID()
        let sourceDeviceID = UUID()
        var row = PendingAppRow(rowID: rowID, tokenBase64: "VE9LRU4=")
        row.bind(pick("Instagram", "com.burbn.instagram", ["IG", "Instagram", "insta"]))
        row.confirm()

        let app = try XCTUnwrap(row.makeUploadApp(sourceDeviceID: sourceDeviceID))
        XCTAssertEqual(app.aliasKey, rowID)
        XCTAssertEqual(app.displayName, "Instagram")
        XCTAssertEqual(app.tokenKind, "app")
        XCTAssertEqual(app.bundleID, "com.burbn.instagram")
        XCTAssertEqual(app.tokenDataBase64, "VE9LRU4=")
        XCTAssertEqual(app.sourceDeviceID, sourceDeviceID)
        XCTAssertEqual(app.aliases, ["Instagram", "com.burbn.instagram", "IG", "insta"])
    }

    func test_makeUploadAppNilForUnconfirmedRow() {
        var row = PendingAppRow(rowID: UUID(), tokenBase64: "QUJD")
        row.bind(pick("Instagram", "com.burbn.instagram"))
        XCTAssertNil(row.makeUploadApp(sourceDeviceID: UUID()))
    }

    func test_makeUploadAppNilWhenTokenUnavailable() {
        var row = PendingAppRow(rowID: UUID(), tokenBase64: "", tokenAvailable: false)
        row.bind(pick("Instagram", "com.burbn.instagram"))
        row.confirm()
        XCTAssertNil(row.makeUploadApp(sourceDeviceID: UUID()))
    }

    func test_uploadAllowsUnknownBundleAfterConfirmation() throws {
        var row = PendingAppRow(rowID: UUID(), tokenBase64: "QUJD")
        row.bind(pick("Unknown App", nil, []))
        row.confirm()

        let app = try XCTUnwrap(row.makeUploadApp(sourceDeviceID: nil))
        XCTAssertEqual(app.displayName, "Unknown App")
        XCTAssertNil(app.bundleID)
        XCTAssertEqual(app.aliases, ["Unknown App"])
    }
}
