import XCTest
@testable import Evlin_iOS

final class BigKidDisplayNameTests: XCTestCase {
    func testAuthoritativeMultiwordNameIsNotTruncated() {
        XCTAssertEqual(
            BigKidDisplayName.resolve(server: "Hongq said", local: "Hongq"),
            "Hongq said"
        )
    }

    func testLocalNameIsUsedOnlyForServerPlaceholder() {
        XCTAssertEqual(
            BigKidDisplayName.resolve(server: "your kid", local: "Hongq said"),
            "Hongq said"
        )
    }

    func testMissingNamesUseNeutralFallback() {
        XCTAssertEqual(BigKidDisplayName.resolve(server: "", local: ""), "there")
    }
}
