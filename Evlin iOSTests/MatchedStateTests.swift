import XCTest
@testable import Evlin_iOS

final class MatchedStateTests: XCTestCase {
    func testHasAliasKeyAndLocalTokenPresent_isMatched() {
        XCTAssertEqual(
            MatchedState.from(hasAliasKey: true, localTokenPresent: true),
            .matched
        )
    }

    func testHasAliasKeyButTokenMissing_needsRefresh() {
        XCTAssertEqual(
            MatchedState.from(hasAliasKey: true, localTokenPresent: false),
            .matchedNeedsRefresh
        )
    }

    func testNoAliasKeyButTokenPresent_isUnmatched() {
        XCTAssertEqual(
            MatchedState.from(hasAliasKey: false, localTokenPresent: true),
            .unmatched
        )
    }

    func testNoAliasKeyAndNoToken_isUnmatched() {
        XCTAssertEqual(
            MatchedState.from(hasAliasKey: false, localTokenPresent: false),
            .unmatched
        )
    }
}
