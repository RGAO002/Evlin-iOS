import XCTest
@testable import Evlin_iOS

final class APIClientResolveInstallIDTests: XCTestCase {
    func test_resolveInstallID_usesOverrideWhenNonEmpty() {
        XCTAssertEqual(APIClient.resolveInstallID("abc-123"), "abc-123")
    }
    func test_resolveInstallID_fallsBackToClientInstallIDWhenNilOrBlank() {
        XCTAssertEqual(APIClient.resolveInstallID(nil), APIClient.clientInstallID)
        XCTAssertEqual(APIClient.resolveInstallID(""), APIClient.clientInstallID)
        XCTAssertEqual(APIClient.resolveInstallID("   "), APIClient.clientInstallID)
    }
}
