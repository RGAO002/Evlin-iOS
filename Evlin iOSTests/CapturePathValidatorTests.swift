import XCTest
@testable import Evlin_iOS

final class CapturePathValidatorTests: XCTestCase {

    private func counts(app: Int, cat: Int, web: Int) -> SelectionCounts {
        SelectionCounts(applicationTokens: app, categoryTokens: cat, webDomainTokens: web)
    }

    // Add App gate

    func test_addApp_validForExactlyOneAppNoCatNoWeb() {
        let r = CapturePathValidator.validate(.app, counts(app: 1, cat: 0, web: 0))
        XCTAssertTrue(r.isValid)
        XCTAssertNil(r.reason)
    }

    func test_addApp_invalidForZeroApps() {
        let r = CapturePathValidator.validate(.app, counts(app: 0, cat: 0, web: 0))
        XCTAssertFalse(r.isValid)
        XCTAssertEqual(r.reason, .needExactlyOneApp)
    }

    func test_addApp_invalidForTwoApps() {
        let r = CapturePathValidator.validate(.app, counts(app: 2, cat: 0, web: 0))
        XCTAssertFalse(r.isValid)
        XCTAssertEqual(r.reason, .needExactlyOneApp)
    }

    func test_addApp_invalidWhenCategoryPresent() {
        let r = CapturePathValidator.validate(.app, counts(app: 1, cat: 1, web: 0))
        XCTAssertFalse(r.isValid)
        XCTAssertEqual(r.reason, .categoryOrWebNotAllowedForApp)
    }

    func test_addApp_invalidWhenWebDomainPresent() {
        let r = CapturePathValidator.validate(.app, counts(app: 1, cat: 0, web: 1))
        XCTAssertFalse(r.isValid)
        XCTAssertEqual(r.reason, .categoryOrWebNotAllowedForApp)
    }

    // Add List gate

    func test_addList_validForApps() {
        XCTAssertTrue(CapturePathValidator.validate(.list, counts(app: 3, cat: 0, web: 0)).isValid)
    }

    func test_addList_validForCategoriesOnly() {
        XCTAssertTrue(CapturePathValidator.validate(.list, counts(app: 0, cat: 2, web: 0)).isValid)
    }

    func test_addList_validForMixed() {
        XCTAssertTrue(CapturePathValidator.validate(.list, counts(app: 1, cat: 1, web: 1)).isValid)
    }

    func test_addList_invalidWhenEmpty() {
        let r = CapturePathValidator.validate(.list, counts(app: 0, cat: 0, web: 0))
        XCTAssertFalse(r.isValid)
        XCTAssertEqual(r.reason, .listEmpty)
    }
}
