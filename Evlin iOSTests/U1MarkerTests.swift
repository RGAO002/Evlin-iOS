import XCTest
@testable import Evlin_iOS

final class U1MarkerBuilderTests: XCTestCase {
    func test_allMarker() {
        let m = ChatViewModel.buildU1Marker(token: "abc123", mode: .all)
        XCTAssertEqual(m, "U1:abc123:all")
    }

    func test_selectedMarkerWithIndices() {
        let m = ChatViewModel.buildU1Marker(token: "abc123", mode: .selected([0, 2, 5]))
        XCTAssertEqual(m, "U1:abc123:selected:0,2,5")
    }

    func test_selectedMarkerEmptyIndicesNotAllowed() {
        let m = ChatViewModel.buildU1Marker(token: "abc123", mode: .selected([]))
        XCTAssertNil(m)
    }
}
