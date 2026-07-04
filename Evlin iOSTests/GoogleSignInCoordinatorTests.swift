import XCTest
@testable import Evlin_iOS

@MainActor
final class GoogleSignInCoordinatorTests: XCTestCase {
    func testDiagnosticMessageIsNilForUserCancel() {
        XCTAssertNil(GoogleSignInCoordinator.GoogleSignInError.cancelled.diagnosticMessage)
    }

    func testDiagnosticMessageIncludesUnderlyingFailure() {
        let error = GoogleSignInCoordinator.GoogleSignInError.failed("GIDSignInError -2")
        XCTAssertEqual(error.diagnosticMessage, "Google sign-in failed: GIDSignInError -2")
    }

    func testPresenterWindowSelectionFallsBackToForegroundInactiveWindow() {
        let chosen = GoogleSignInCoordinator.choosePresenterWindowIndex([
            .init(isForegroundActive: false, isForegroundInactive: false, isKeyWindow: true, isHidden: false),
            .init(isForegroundActive: false, isForegroundInactive: true, isKeyWindow: false, isHidden: false),
        ])

        XCTAssertEqual(chosen, 1)
    }

    func testPresenterWindowSelectionPrefersVisibleKeyWindow() {
        let chosen = GoogleSignInCoordinator.choosePresenterWindowIndex([
            .init(isForegroundActive: true, isForegroundInactive: false, isKeyWindow: false, isHidden: false),
            .init(isForegroundActive: true, isForegroundInactive: false, isKeyWindow: true, isHidden: false),
        ])

        XCTAssertEqual(chosen, 1)
    }
}
