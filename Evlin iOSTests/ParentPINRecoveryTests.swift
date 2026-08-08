import XCTest
@testable import Evlin_iOS

final class ParentPINRecoveryTests: XCTestCase {
    private func material(for pin: String) -> (salt: Data, digest: Data) {
        let store = EvlinPINStore(account: "evlin.pin.recovery.\(UUID().uuidString)")
        try! store.setPIN(pin)
        return store.recoveryMaterial()!
    }

    func testFindsFourDigitsIncludingLeadingZeros() {
        let material = material(for: "0042")
        XCTAssertEqual(
            ParentPINRecovery.sweep(
                salt: material.salt,
                digest: material.digest,
                from: .init(length: 4, next: 0),
                budget: 10_000,
                maxLength: 4
            ),
            .found("0042")
        )
    }

    func testBudgetCursorResumesWithoutRestarting() {
        let material = material(for: "9999")
        let first = ParentPINRecovery.sweep(
            salt: material.salt,
            digest: material.digest,
            from: ParentPINRecovery.startCursor,
            budget: 10,
            maxLength: 4
        )
        guard case .budgetSpent(let cursor) = first else {
            return XCTFail("expected budget cursor")
        }
        XCTAssertEqual(cursor, .init(length: 4, next: 10))
        XCTAssertEqual(
            ParentPINRecovery.sweep(
                salt: material.salt,
                digest: material.digest,
                from: cursor,
                budget: 10_000,
                maxLength: 4
            ),
            .found("9999")
        )
    }

    func testCorruptDigestExhaustsBoundedSpace() {
        var material = material(for: "1234")
        material.digest[0] ^= 0xff
        XCTAssertEqual(
            ParentPINRecovery.sweep(
                salt: material.salt,
                digest: material.digest,
                from: ParentPINRecovery.startCursor,
                budget: 10_000,
                maxLength: 4
            ),
            .exhausted
        )
    }
}
