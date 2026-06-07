import XCTest
@testable import Evlin_iOS

final class AuthKeychainStoreTests: XCTestCase {
    private let store = KeychainStore(service: "com.evlin.session.tests")

    override func setUp() {
        super.setUp()
        store.clear()
    }

    override func tearDown() {
        store.clear()
        super.tearDown()
    }

    func testSaveAndLoadRoundTrip() throws {
        let tokens = StoredTokens(accessToken: "acc-1", refreshToken: "ref-1",
                                  accountID: "acct-1", familyID: "fam-1",
                                  displayName: "Pat", needsFamily: false)
        try store.save(tokens)
        let loaded = store.load()
        XCTAssertEqual(loaded?.accessToken, "acc-1")
        XCTAssertEqual(loaded?.refreshToken, "ref-1")
        XCTAssertEqual(loaded?.accountID, "acct-1")
        // §15.7: familyID + displayName survive the round-trip (not discarded).
        XCTAssertEqual(loaded?.familyID, "fam-1")
        XCTAssertEqual(loaded?.displayName, "Pat")
        XCTAssertEqual(loaded?.needsFamily, false)
    }

    func testOverwriteReplacesValue() throws {
        try store.save(StoredTokens(accessToken: "a", refreshToken: "r",
                                    accountID: "id", familyID: nil,
                                    displayName: nil, needsFamily: true))
        try store.save(StoredTokens(accessToken: "a2", refreshToken: "r2",
                                    accountID: "id2", familyID: "fam-2",
                                    displayName: "Sam", needsFamily: false))
        XCTAssertEqual(store.load()?.accessToken, "a2")
        XCTAssertEqual(store.load()?.refreshToken, "r2")
        XCTAssertEqual(store.load()?.familyID, "fam-2")
    }

    func testClearRemovesValue() throws {
        try store.save(StoredTokens(accessToken: "x", refreshToken: "y",
                                    accountID: "z", familyID: nil,
                                    displayName: nil, needsFamily: true))
        store.clear()
        XCTAssertNil(store.load())
    }

    func testLoadEmptyReturnsNil() {
        XCTAssertNil(store.load())
    }
}
