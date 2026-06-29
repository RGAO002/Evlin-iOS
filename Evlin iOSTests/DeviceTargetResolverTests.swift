import XCTest
@testable import Evlin_iOS

final class DeviceTargetResolverTests: XCTestCase {
    func testTappedDeviceUUIDWinsOverPairedDeviceID() {
        let tapped = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let paired = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        XCTAssertEqual(
            DeviceTargetResolver.selectedChildDeviceID(
                tappedDeviceUUID: tapped,
                pairedChildDeviceID: paired
            ),
            tapped
        )
    }

    func testFallsBackToPairedDeviceWhenTappedDeviceIsMissing() {
        let paired = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        XCTAssertEqual(
            DeviceTargetResolver.selectedChildDeviceID(
                tappedDeviceUUID: nil,
                pairedChildDeviceID: paired
            ),
            UUID(uuidString: paired)
        )
    }

    func testInvalidPairedDeviceReturnsNilWhenTappedDeviceIsMissing() {
        XCTAssertNil(
            DeviceTargetResolver.selectedChildDeviceID(
                tappedDeviceUUID: nil,
                pairedChildDeviceID: "not-a-uuid"
            )
        )
    }
}
