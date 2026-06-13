// Evlin iOSTests/APNsTokenUploadDecisionTests.swift
//
// Unit tests for the pure APNs-token-upload decision extracted from
// AppDelegate (Fix 1: token can be lost if it arrives before pairing).
// `shouldUploadAPNsToken` returns the upload args only when both a cached
// token and a parseable childDeviceID are present — no UIKit/UserDefaults
// involved, so it's testable in isolation (mirrors AppControlRouter).
import XCTest
@testable import Evlin_iOS

final class APNsTokenUploadDecisionTests: XCTestCase {
    private let validToken = "a1b2c3d4e5f6"
    private let validChildID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

    func test_bothPresent_returnsUploadArgs() {
        let result = AppDelegate.shouldUploadAPNsToken(
            cachedToken: validToken,
            childDeviceID: validChildID
        )
        XCTAssertEqual(result?.token, validToken)
        XCTAssertEqual(result?.deviceID, UUID(uuidString: validChildID))
    }

    func test_missingToken_returnsNil() {
        XCTAssertNil(
            AppDelegate.shouldUploadAPNsToken(cachedToken: nil, childDeviceID: validChildID)
        )
    }

    func test_emptyToken_returnsNil() {
        XCTAssertNil(
            AppDelegate.shouldUploadAPNsToken(cachedToken: "", childDeviceID: validChildID)
        )
    }

    func test_missingChildDeviceID_returnsNil() {
        XCTAssertNil(
            AppDelegate.shouldUploadAPNsToken(cachedToken: validToken, childDeviceID: nil)
        )
    }

    func test_emptyChildDeviceID_returnsNil() {
        XCTAssertNil(
            AppDelegate.shouldUploadAPNsToken(cachedToken: validToken, childDeviceID: "")
        )
    }

    func test_nonUUIDChildDeviceID_returnsNil() {
        XCTAssertNil(
            AppDelegate.shouldUploadAPNsToken(cachedToken: validToken, childDeviceID: "not-a-uuid")
        )
    }

    // MARK: - Mode-aware routing (parent push transport)

    private let validParentID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    func test_parentMode_routesToParentDeviceID() {
        // A parent device uploads to its OWN parent row, never to the kid's
        // remote childDeviceID (which would clobber the kid's lock token).
        let result = AppDelegate.shouldUploadAPNsToken(
            cachedToken: validToken, appMode: "parent",
            childDeviceID: validChildID, parentDeviceID: validParentID
        )
        XCTAssertEqual(result?.deviceID, UUID(uuidString: validParentID))
        XCTAssertEqual(result?.token, validToken)
    }

    func test_parentMode_missingParentDeviceID_returnsNil_doesNotFallBackToChild() {
        // Critical: parent mode must NOT silently fall back to childDeviceID.
        XCTAssertNil(
            AppDelegate.shouldUploadAPNsToken(
                cachedToken: validToken, appMode: "parent",
                childDeviceID: validChildID, parentDeviceID: nil
            )
        )
    }

    func test_childMode_routesToChildDeviceID() {
        let result = AppDelegate.shouldUploadAPNsToken(
            cachedToken: validToken, appMode: "child",
            childDeviceID: validChildID, parentDeviceID: validParentID
        )
        XCTAssertEqual(result?.deviceID, UUID(uuidString: validChildID))
        XCTAssertEqual(result?.route, .childRegisterAPNs)
    }

    func test_prePairingMode_keepsLegacyChildPath() {
        // "setup" / "" (mode not yet decided) keep the legacy childDeviceID path.
        for mode in ["", "setup"] {
            let result = AppDelegate.shouldUploadAPNsToken(
                cachedToken: validToken, appMode: mode,
                childDeviceID: validChildID, parentDeviceID: nil
            )
            XCTAssertEqual(result?.deviceID, UUID(uuidString: validChildID), "mode=\(mode)")
            XCTAssertEqual(result?.route, .childRegisterAPNs, "mode=\(mode)")
        }
    }
}
