import XCTest
@testable import Evlin_iOS

@MainActor
final class EvlinPINStoreTests: XCTestCase {
    private var store: EvlinPINStore!
    private var account: String!

    override func setUp() {
        super.setUp()
        account = "evlin.pin.test.\(UUID().uuidString)"
        store = EvlinPINStore(account: account)
        store.clear()
    }

    override func tearDown() {
        store.clear()
        store = nil
        account = nil
        super.tearDown()
    }

    func test_isSet_falseBeforeAnyPIN() {
        XCTAssertFalse(store.isSet())
    }

    func test_setPIN_thenIsSetTrue() throws {
        try store.setPIN("1234")
        XCTAssertTrue(store.isSet())
    }

    func test_verify_correctPIN_returnsTrue() throws {
        try store.setPIN("1234")
        XCTAssertTrue(store.verify("1234"))
    }

    func test_verify_wrongPIN_returnsFalse() throws {
        try store.setPIN("1234")
        XCTAssertFalse(store.verify("9999"))
    }

    func test_verify_whenNoPINSet_returnsFalse() {
        XCTAssertFalse(store.verify("1234"))
    }

    func test_setPIN_rejectsTooShort() {
        XCTAssertThrowsError(try store.setPIN("12")) { error in
            XCTAssertEqual(error as? EvlinPINStore.PINError, .invalidLength)
        }
    }

    func test_setPIN_rejectsNonASCIIDigits() {
        XCTAssertThrowsError(try store.setPIN("１２３４")) { error in
            XCTAssertEqual(error as? EvlinPINStore.PINError, .invalidLength)
        }
        XCTAssertThrowsError(try store.setPIN("١٢٣٤")) { error in
            XCTAssertEqual(error as? EvlinPINStore.PINError, .invalidLength)
        }
    }

    func test_setPIN_overwritesPreviousPIN() throws {
        try store.setPIN("1234")
        try store.setPIN("5678")
        XCTAssertFalse(store.verify("1234"))
        XCTAssertTrue(store.verify("5678"))
    }

    func test_clear_removesPIN() throws {
        try store.setPIN("1234")
        store.clear()
        XCTAssertFalse(store.isSet())
        XCTAssertFalse(store.verify("1234"))
    }

    func test_salt_makesHashNonTrivial_twoStoresDifferentSalts() throws {
        try store.setPIN("1234")
        let other = EvlinPINStore(account: "evlin.pin.test.\(UUID().uuidString)")
        other.clear()
        try other.setPIN("1234")
        XCTAssertNotEqual(store.debugStoredBlob(), other.debugStoredBlob())
        other.clear()
    }
}
