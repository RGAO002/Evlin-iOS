import XCTest
@testable import Evlin_iOS

final class BigKidAPIClientTests: XCTestCase {
    func testGetStateBuildsCorrectRequest() throws {
        let client = BigKidAPIClient(
            baseURL: URL(string: "http://localhost:8000/api/v1")!,
            childId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let req = try client.makeRequest(path: "/child/state", method: "GET")
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:8000/api/v1/child/state")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Child-Id"),
                       "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(req.httpMethod, "GET")
    }
}
