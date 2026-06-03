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
}
