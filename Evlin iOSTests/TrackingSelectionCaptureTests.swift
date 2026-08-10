import FamilyControls
import XCTest
@testable import Evlin_iOS

@MainActor
final class TrackingSelectionCaptureTests: XCTestCase {
    func testEmptySelectionIsRejectedRatherThanSavedAsNothing() async {
        let capture = TrackingSelectionCapture()
        capture.selection = FamilyActivitySelection()

        await capture.commit()

        XCTAssertEqual(capture.state, .needsSelection)
    }

    func testUnauthorizedRequestDoesNotOpenThePicker() {
        let capture = TrackingSelectionCapture()

        XCTAssertFalse(capture.requestPicker(authorized: false))
        XCTAssertEqual(capture.state, .notAuthorized)
    }

    func testAuthorizedRequestClearsPriorAuthorizationError() {
        let capture = TrackingSelectionCapture()
        _ = capture.requestPicker(authorized: false)

        XCTAssertTrue(capture.requestPicker(authorized: true))
        XCTAssertEqual(capture.state, .idle)
    }

    func testDefaultSelectionIncludesEntireCategories() {
        XCTAssertTrue(TrackingSelectionCapture().selection.includeEntireCategory)
    }

    func testValidSelectionRunsTheV2RefreshExactlyOnce() async {
        let capture = TrackingSelectionCapture(isSelectionEmpty: { false })
        var refreshes = 0

        await capture.commit {
            refreshes += 1
        }

        XCTAssertEqual(capture.state, .saved)
        XCTAssertEqual(refreshes, 1)
    }

    func testEmptySelectionDoesNotRunV2Refresh() async {
        let capture = TrackingSelectionCapture(isSelectionEmpty: { true })
        var refreshes = 0

        await capture.commit {
            refreshes += 1
        }

        XCTAssertEqual(capture.state, .needsSelection)
        XCTAssertEqual(refreshes, 0)
    }
}
