import XCTest
@testable import Evlin_iOS

final class MatchedStateTests: XCTestCase {
    func testHasAliasKeyAndLocalTokenPresent_isMatched() {
        XCTAssertEqual(
            MatchedState.from(
                hasAliasKey: true,
                localTokenPresent: true,
                currentDeviceCatalogConfirmed: true
            ),
            .matched
        )
    }

    func testOldDeviceAliasIsNotShownAsMatchedForNewDevice() {
        XCTAssertEqual(
            MatchedState.from(
                hasAliasKey: true,
                localTokenPresent: true,
                currentDeviceCatalogConfirmed: false
            ),
            .matchedNeedsRefresh
        )
    }

    func testHasAliasKeyButTokenMissing_needsRefresh() {
        XCTAssertEqual(
            MatchedState.from(
                hasAliasKey: true,
                localTokenPresent: false,
                currentDeviceCatalogConfirmed: true
            ),
            .matchedNeedsRefresh
        )
    }

    func testNoAliasKeyButTokenPresent_isUnmatched() {
        XCTAssertEqual(
            MatchedState.from(
                hasAliasKey: false,
                localTokenPresent: true,
                currentDeviceCatalogConfirmed: false
            ),
            .unmatched
        )
    }

    func testNoAliasKeyAndNoToken_isUnmatched() {
        XCTAssertEqual(
            MatchedState.from(
                hasAliasKey: false,
                localTokenPresent: false,
                currentDeviceCatalogConfirmed: false
            ),
            .unmatched
        )
    }
}
