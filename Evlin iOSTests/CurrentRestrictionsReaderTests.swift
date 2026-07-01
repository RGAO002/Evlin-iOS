import XCTest
@testable import Evlin_iOS

final class CurrentRestrictionsReaderTests: XCTestCase {

    private struct Fake: Codable, Equatable, Hashable { let id: String; let n: Int }

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "test.restrictions.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func test_decodeDict_roundTripsValues() {
        let dict = ["a": Fake(id: "a", n: 1), "b": Fake(id: "b", n: 2)]
        defaults.set(try! JSONEncoder().encode(dict), forKey: "k")
        let out = CurrentRestrictionsReader.decodeDict(Fake.self, key: "k", from: defaults)
        XCTAssertEqual(Set(out), Set(dict.values))
    }

    func test_decodeDict_absentKey_returnsEmpty() {
        XCTAssertTrue(CurrentRestrictionsReader.decodeDict(Fake.self, key: "missing", from: defaults).isEmpty)
    }

    func test_decodeDict_garbage_returnsEmpty() {
        defaults.set(Data([0x00, 0x01]), forKey: "k")
        XCTAssertTrue(CurrentRestrictionsReader.decodeDict(Fake.self, key: "k", from: defaults).isEmpty)
    }
}
