import XCTest
@testable import Evlin_iOS

/// `Slider` traps when its bound value falls outside its range, so the handle's
/// starting position is computed rather than assigned — and a device cap CAN
/// legitimately sit outside today's range (a cap saved when the pool was 240
/// survives the pool being lowered to 120).
final class DeviceDailyTotalEditorTests: XCTestCase {

    func testStartsAtTheCurrentCap() {
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: 120, poolMinutes: 240),
            120
        )
    }

    /// No cap yet means "as much as allowed", which is the pool — but never
    /// past the product maximum.
    func testWithoutACapStartsAtTheCeiling() {
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: nil, poolMinutes: 120),
            120
        )
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: nil, poolMinutes: 240),
            180,
            "a 4h pool is a test artefact; the editor still stops at the 3h product maximum"
        )
    }

    /// The reason this ceiling exists: we set a 4h pool on 2026-07-25 to keep
    /// testing after the day's pool ran out, and the slider then offered 4h —
    /// a value the parent UI must never produce.
    func testAPoolAboveTheProductMaximumDoesNotWidenTheEditor() {
        XCTAssertEqual(EarnedLimitRange.ceiling(poolMinutes: 240), 180)
        XCTAssertEqual(EarnedLimitRange.ceiling(poolMinutes: 1440), 180)
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: 240, poolMinutes: 240),
            180
        )
    }

    /// Below the maximum the pool is still the binding constraint.
    func testAPoolBelowTheProductMaximumIsTheCeiling() {
        XCTAssertEqual(EarnedLimitRange.ceiling(poolMinutes: 90), 90)
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: 180, poolMinutes: 90),
            90
        )
    }

    /// The pool was lowered under an existing cap. Clamping down is the only
    /// safe reading: the backend would 422 anything above the pool anyway.
    func testACapAboveTodaysPoolIsClampedToThePool() {
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: 240, poolMinutes: 120),
            120
        )
    }

    func testACapBelowTheFloorIsRaisedToTheFloor() {
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: 5, poolMinutes: 240),
            15
        )
    }

    /// A pool smaller than the 15-minute floor collapses the range; the value
    /// must still be inside it rather than trapping on the floor constant.
    func testAPoolSmallerThanTheFloorStillYieldsAnInRangeValue() {
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: 15, poolMinutes: 10),
            10
        )
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: nil, poolMinutes: 10),
            10
        )
    }

    /// Off-step values come from presets and older builds; the slider steps by
    /// 5, and an off-step start would jump on first touch.
    func testOffStepValuesSnapToTheStep() {
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: 47, poolMinutes: 240),
            45
        )
        XCTAssertEqual(
            DeviceDailyTotalEditor.initialValue(current: 48, poolMinutes: 240),
            50
        )
    }

    /// Snapping must never push the handle past the ceiling it just snapped to.
    func testSnappingCannotOvershootThePool() {
        XCTAssertLessThanOrEqual(
            DeviceDailyTotalEditor.initialValue(current: 238, poolMinutes: 238),
            238
        )
    }
}
