import XCTest
@testable import Evlin_iOS

@MainActor
final class MainActorDeinitBackDeployTests: XCTestCase {
    func testAuthServiceCanBeReleasedInsideTheTestProcess() {
        weak var released: AuthService?
        autoreleasepool {
            var service: AuthService? = AuthService(
                api: APIClient(baseURL: "https://example.invalid")
            )
            released = service
            service = nil
        }
        XCTAssertNil(released)
    }

    func testFamilyStoreCanBeReleasedInsideTheTestProcess() {
        weak var released: FamilyStore?
        autoreleasepool {
            var store: FamilyStore? = FamilyStore(
                api: APIClient(baseURL: "https://example.invalid")
            )
            released = store
            store = nil
        }
        XCTAssertNil(released)
    }

    func testBigKidStatePollerCanBeReleasedInsideTheTestProcess() {
        weak var released: BigKidStatePoller?
        autoreleasepool {
            var poller: BigKidStatePoller? = BigKidStatePoller(
                state: BigKidState(snapshot: .fixture(tasks: [])),
                fetchState: { throw CancellationError() },
                reconcileReflectionLock: { _ in }
            )
            released = poller
            poller = nil
        }
        XCTAssertNil(released)
    }
}
