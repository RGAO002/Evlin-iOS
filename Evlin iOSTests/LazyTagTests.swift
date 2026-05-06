// Evlin iOSTests/LazyTagTests.swift
import XCTest
@testable import Evlin_iOS

final class LazyTagPersistenceTests: XCTestCase {
    /// Passing a non-token Any (e.g. String) for `.app` mode must produce
    /// `.wrongTokenType`. We can't mint real ApplicationToken in tests
    /// (FamilyControls auth is unavailable), so we test only the
    /// type-mismatch branch — the success branch is covered by manual E2E.
    func test_persistAlias_rejectsWrongTypeForApp() {
        let result = LazyTagPersistence.persistAlias(
            token: "not a token" as Any,
            kind: .app,
            target: "Instagram"
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType failure")
        }
    }

    func test_persistAlias_rejectsWrongTypeForCategory() {
        let result = LazyTagPersistence.persistAlias(
            token: 42 as Any,
            kind: .category,
            target: "games"
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType failure")
        }
    }

    func test_persistAlias_rejectsEmptyTarget() {
        let result = LazyTagPersistence.persistAlias(
            token: "x" as Any,
            kind: .app,
            target: "   "
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .emptyTarget)
        case .success: XCTFail("expected emptyTarget failure")
        }
    }
}
