import XCTest
@testable import Evlin_iOS

final class BigKidAPIClientTests: XCTestCase {
    func testDefaultBackendIsProductionRender() {
        XCTAssertEqual(APIClient.defaultURL, "https://evlin-backend.onrender.com/api/v1")
    }

    func testReleaseBuildMigratesSavedLocalBackendToProductionRender() {
        let url = APIClient.effectiveInitialBaseURL(
            saved: "http://192.168.1.175:8000/api/v1",
            isDebugBuild: false
        )

        XCTAssertEqual(url, APIClient.defaultURL)
    }

    func testDebugBuildKeepsSavedLocalBackend() {
        let local = "http://192.168.1.175:8000/api/v1"
        let url = APIClient.effectiveInitialBaseURL(
            saved: local,
            isDebugBuild: true
        )

        XCTAssertEqual(url, local)
    }

    func testReleaseBuildPersistsMigrationForSavedLocalBackend() {
        XCTAssertTrue(
            APIClient.shouldPersistInitialBaseURLMigration(
                saved: "http://192.168.1.175:8000/api/v1",
                effective: APIClient.defaultURL,
                isDebugBuild: false
            )
        )
    }

    func testReleaseSaveNormalizesLocalBackendToProductionRender() {
        let url = APIClient.effectiveSavedBaseURL(
            "http://192.168.1.175:8000/api/v1",
            isDebugBuild: false
        )

        XCTAssertEqual(url, APIClient.defaultURL)
    }

    func testGetStateBuildsCorrectRequest() throws {
        let client = BigKidAPIClient(
            baseURL: URL(string: "http://localhost:8000/api/v1")!,
            childId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let req = try client.makeRequest(path: "/child/state", method: "GET")
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:8000/api/v1/child/state")
        XCTAssertEqual(req.allHTTPHeaderFields?["X-Child-Id"],
                       "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(req.httpMethod, "GET")
    }
}
