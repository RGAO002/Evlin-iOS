import XCTest
@testable import Evlin_iOS

final class SaveValidationTests: XCTestCase {
    private func row(_ name: String? = nil, confirmed: Bool = false) -> PendingAppRow {
        var row = PendingAppRow(rowID: UUID(), tokenBase64: "VE9LRU4=")
        if let name {
            row.bind(CatalogSearchResult(canonicalName: name, bundleID: "com.example.\(name.lowercased())", aliases: []))
            if confirmed {
                row.confirm()
            }
        }
        return row
    }

    func testInvalidSaveKeepsSheetOpenAndShowsError() {
        var model = CaptureSheetModel(rows: [
            row("Instagram", confirmed: true),
            row()
        ])

        model.attemptSave()

        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.errorBanner, "1 app still needs a name")
        XCTAssertEqual(model.highlightedRows, [1])
        XCTAssertEqual(model.savedRows, [])
    }

    func testValidSaveDismissesAndSavesEveryRow() {
        let instagram = row("Instagram", confirmed: true)
        let tiktok = row("TikTok", confirmed: true)
        var model = CaptureSheetModel(rows: [instagram, tiktok])

        model.attemptSave()

        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.errorBanner)
        XCTAssertEqual(model.highlightedRows, [])
        XCTAssertEqual(model.savedRows, [instagram, tiktok])
    }

    func testConfirmedNameRequiredNoSilentDropOfUnconfirmedRows() {
        var namedButUnconfirmed = row("Instagram", confirmed: false)
        namedButUnconfirmed.bind(CatalogSearchResult(canonicalName: "TikTok", bundleID: "com.zhiliaoapp.musically", aliases: []))
        let valid = row("YouTube", confirmed: true)
        var model = CaptureSheetModel(rows: [namedButUnconfirmed, valid])

        model.attemptSave()

        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.highlightedRows, [0])
        XCTAssertEqual(model.savedRows, [])
    }
}
