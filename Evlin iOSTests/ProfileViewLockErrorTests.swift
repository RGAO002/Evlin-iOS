// Evlin iOSTests/ProfileViewLockErrorTests.swift
//
// Unit tests for ProfileView.isNoLockedSetError(_:) — the pure classifier
// that distinguishes "no Locked set configured" (4xx) from other failures.
// No UI involved; no device needed.

import XCTest
@testable import Evlin_iOS

final class ProfileViewLockErrorTests: XCTestCase {

    // MARK: - Positive: 400-range serverErrors → no-Locked-set path

    func test_400_isNoLockedSetError() {
        XCTAssertTrue(ProfileView.isNoLockedSetError(APIError.serverError(400)))
    }

    func test_409_isNoLockedSetError() {
        // 409 Conflict — also raised when the locked set is empty/conflict.
        XCTAssertTrue(ProfileView.isNoLockedSetError(APIError.serverError(409)))
    }

    func test_422_isNoLockedSetError() {
        XCTAssertTrue(ProfileView.isNoLockedSetError(APIError.serverError(422)))
    }

    func test_401_isNotNoLockedSetError() {
        // 401 (Unauthorized) is an auth failure, not a missing locked-set error.
        XCTAssertFalse(ProfileView.isNoLockedSetError(APIError.serverError(401)))
    }

    // MARK: - Negative: errors that should fall through to raw-error display

    func test_404_isNotNoLockedSetError() {
        // 404 = route not yet deployed — diagnosable infra gap, NOT a missing set.
        XCTAssertFalse(ProfileView.isNoLockedSetError(APIError.serverError(404)))
    }

    func test_500_isNotNoLockedSetError() {
        XCTAssertFalse(ProfileView.isNoLockedSetError(APIError.serverError(500)))
    }

    func test_503_isNotNoLockedSetError() {
        XCTAssertFalse(ProfileView.isNoLockedSetError(APIError.serverError(503)))
    }

    func test_nonAPIError_isNotNoLockedSetError() {
        // Non-APIError (e.g. URLError) should fall through to raw display.
        let networkError = URLError(.notConnectedToInternet)
        XCTAssertFalse(ProfileView.isNoLockedSetError(networkError))
    }
}
