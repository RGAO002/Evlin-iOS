import XCTest
@testable import Evlin_iOS

/// Multi-device gate for per-device chat controls.
/// `ChatViewModel.effectiveChildDeviceID` decides whether the chat send path
/// pins the stored child device id or nil-s it out so the backend
/// disambiguation gate can ask for the exact device.
final class MultiChildSendTests: XCTestCase {
    func testEffectiveChildDeviceIDNilWhenMultipleDevices() {
        let stored = "11111111-1111-1111-1111-111111111111"
        XCTAssertNil(ChatViewModel.effectiveChildDeviceID(deviceCount: 2, storedChildDeviceID: stored))
        XCTAssertEqual(ChatViewModel.effectiveChildDeviceID(deviceCount: 1, storedChildDeviceID: stored), stored)
        XCTAssertEqual(ChatViewModel.effectiveChildDeviceID(deviceCount: 0, storedChildDeviceID: stored), stored)
    }

    func testEffectiveChildDeviceIDNilStoredStaysNil() {
        XCTAssertNil(ChatViewModel.effectiveChildDeviceID(deviceCount: 1, storedChildDeviceID: nil))
        XCTAssertNil(ChatViewModel.effectiveChildDeviceID(deviceCount: 3, storedChildDeviceID: nil))
    }
}
