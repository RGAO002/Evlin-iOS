import XCTest
@testable import Evlin_iOS

/// Verifies that N concurrent 401s trigger exactly ONE /auth/refresh call
/// (single-flight), all callers await the same refresh, and each retries once.
/// §14.7. Uses the injectable TokenRefresher actor directly — no network.
final class SingleFlightRefreshTests: XCTestCase {

    func testConcurrent401sShareOneRefresh() async throws {
        let counter = RefreshCallCounter()
        let refresher = SingleFlightRefresher { () async throws -> String in
            await counter.increment()
            try await Task.sleep(nanoseconds: 20_000_000)  // simulate network
            return "new-access-token"
        }

        // 10 concurrent callers all observe a 401 and await a refresh.
        let results: [String] = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await refresher.refreshedToken() }
            }
            var acc: [String] = []
            for try await r in group { acc.append(r) }
            return acc
        }

        XCTAssertEqual(results.count, 10)
        XCTAssertTrue(results.allSatisfy { $0 == "new-access-token" })
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "expected exactly one refresh for concurrent 401s")
    }

    func testSecondRoundRefreshesAgain() async throws {
        let counter = RefreshCallCounter()
        let refresher = SingleFlightRefresher { () async throws -> String in
            await counter.increment()
            return "tok"
        }
        _ = try await refresher.refreshedToken()
        _ = try await refresher.refreshedToken()  // after first completes, a new flight
        let calls = await counter.value
        XCTAssertEqual(calls, 2)
    }
}

actor RefreshCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
