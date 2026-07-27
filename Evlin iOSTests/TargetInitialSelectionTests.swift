import XCTest
@testable import Evlin_iOS

/// How many devices start checked is a safety default, and the two directions
/// are not symmetric.
///
/// Pre-checking every device for `block` over-restricts at worst; the parent
/// sees it and unchecks. Pre-checking every device for `unblock` hands back
/// access on devices they may not have had in mind — the one direction where a
/// mis-tap is neither obvious nor cheap.
///
/// The backend decides (`initial_selection` on the card) because only it knows
/// the normalized verb. These pin what the client does with that answer, and
/// what it does when the answer is absent.
final class TargetInitialSelectionTests: XCTestCase {

    private let options = [
        TargetOption(id: "phone", label: "iPhone"),
        TargetOption(id: "ipad", label: "iPad"),
    ]

    func testTighteningStartsWithEveryStableID() {
        let model = TargetSelectionModel(
            options: options,
            allowsMultiple: true,
            initialSelection: .all
        )
        XCTAssertEqual(model.selectedIds, ["phone", "ipad"])
    }

    func testRelaxingStartsEmpty() {
        let model = TargetSelectionModel(
            options: options,
            allowsMultiple: true,
            initialSelection: .none
        )
        XCTAssertTrue(model.selectedIds.isEmpty)
    }

    /// A build that predates the policy, or a card kind that never carries one,
    /// must not pre-select. Selecting everything by omission is the failure the
    /// policy exists to prevent.
    func testAnAbsentPolicyStartsEmpty() {
        let model = TargetSelectionModel(options: options, allowsMultiple: true)
        XCTAssertTrue(model.selectedIds.isEmpty)
    }

    func testAnUnknownPolicyStringStartsEmpty() {
        XCTAssertEqual(TargetInitialSelection(wire: "everything"), TargetInitialSelection.none)
        XCTAssertEqual(TargetInitialSelection(wire: nil), TargetInitialSelection.none)
    }

    func testTheWireValuesDecode() {
        XCTAssertEqual(TargetInitialSelection(wire: "all"), .all)
        XCTAssertEqual(TargetInitialSelection(wire: "none"), TargetInitialSelection.none)
    }

    /// Pre-selection is a starting point, not a lock: the parent must be able to
    /// take devices out of a tightening action.
    func testAPreSelectedDeviceCanBeUnchecked() {
        var model = TargetSelectionModel(
            options: options,
            allowsMultiple: true,
            initialSelection: .all
        )
        model.toggle("ipad")
        XCTAssertEqual(model.selectedIds, ["phone"])
    }

    /// Selected ids are the batch's identity for the rest of the flow, and the
    /// receipt is rendered in this order — so it must follow the picker, not the
    /// order the parent happened to tap in.
    func testSelectedIdsFollowOptionOrderNotTapOrder() {
        var model = TargetSelectionModel(options: options, allowsMultiple: true)
        model.toggle("ipad")
        model.toggle("phone")
        XCTAssertEqual(model.selectedIds, ["phone", "ipad"])
    }

    /// Single-select is unaffected: pre-selection would silently answer a
    /// question the card is asking.
    func testSingleSelectIgnoresAPreSelectAllPolicy() {
        let model = TargetSelectionModel(
            options: options,
            allowsMultiple: false,
            initialSelection: .all
        )
        XCTAssertTrue(
            model.selectedIds.isEmpty,
            "a one-of-N question may not arrive already answered"
        )
    }
}
