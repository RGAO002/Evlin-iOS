import XCTest
@testable import Evlin_iOS

/// Multi-child gate (MVP) — Task 5.
/// `ChatViewModel.effectiveChildDeviceID` decides whether the chat send path
/// pins the stored child device id or nil-s it out so the backend
/// disambiguation gate can ask "which child?".
final class MultiChildSendTests: XCTestCase {
    func testEffectiveChildDeviceIDNilWhenMultiChild() {
        let stored = "11111111-1111-1111-1111-111111111111"
        // >1 child → nil (let the backend gate ask which child).
        XCTAssertNil(ChatViewModel.effectiveChildDeviceID(childCount: 2, storedChildDeviceID: stored))
        // Exactly one child → keep the pinned id (fast path, no card).
        XCTAssertEqual(ChatViewModel.effectiveChildDeviceID(childCount: 1, storedChildDeviceID: stored), stored)
        // Zero children (not yet loaded) → keep whatever is stored; never crash.
        XCTAssertEqual(ChatViewModel.effectiveChildDeviceID(childCount: 0, storedChildDeviceID: stored), stored)
    }

    func testEffectiveChildDeviceIDNilStoredStaysNil() {
        // No stored id → nil regardless of child count.
        XCTAssertNil(ChatViewModel.effectiveChildDeviceID(childCount: 1, storedChildDeviceID: nil))
        XCTAssertNil(ChatViewModel.effectiveChildDeviceID(childCount: 3, storedChildDeviceID: nil))
    }
}
