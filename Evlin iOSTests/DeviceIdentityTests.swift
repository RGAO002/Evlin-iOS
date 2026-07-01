import XCTest
@testable import Evlin_iOS

final class DeviceIdentityTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var service: String!
    private var sut: DeviceIdentity!

    private let pKey = DeviceIdentity.parentKey
    private let cKey = DeviceIdentity.childKey

    override func setUp() {
        super.setUp()
        suite = "test.deviceid.\(UUID().uuidString)"
        service = "test.deviceid.svc.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        sut = DeviceIdentity(defaults: defaults, keychainService: service)
        sut.clear()
    }

    override func tearDown() {
        sut.clear()
        defaults.removePersistentDomain(forName: suite)
        defaults = nil; sut = nil
        super.tearDown()
    }

    // 1) defaults has, keychain empty -> capture into keychain
    func test_hydrate_capturesDefaultsIntoKeychain() {
        let id = UUID().uuidString
        defaults.set(id, forKey: pKey)
        sut.hydrate()
        defaults.removeObject(forKey: pKey)   // simulate reinstall
        sut.hydrate()
        XCTAssertEqual(defaults.string(forKey: pKey), id)
    }

    // 2) defaults empty, keychain has -> restore into defaults
    func test_hydrate_restoresFromKeychain() {
        let id = UUID().uuidString
        defaults.set(id, forKey: cKey); sut.capture()
        defaults.removeObject(forKey: cKey)
        sut.hydrate()
        XCTAssertEqual(defaults.string(forKey: cKey), id)
    }

    // 3) both present, defaults has value -> defaults wins, overwrites keychain
    func test_hydrate_defaultsWinsOverKeychain() {
        let oldID = UUID().uuidString
        defaults.set(oldID, forKey: pKey); sut.capture()
        let newID = UUID().uuidString
        defaults.set(newID, forKey: pKey)
        sut.hydrate()
        defaults.removeObject(forKey: pKey); sut.hydrate()
        XCTAssertEqual(defaults.string(forKey: pKey), newID)
    }

    // 4) clear removes both parent + child mirrors (hydrate can't restore after clear)
    func test_clear_removesBothMirrors() {
        defaults.set(UUID().uuidString, forKey: pKey)
        defaults.set(UUID().uuidString, forKey: cKey)
        sut.capture()                        // keychain mirrors both
        sut.clear()                          // drop the mirrors
        defaults.removeObject(forKey: pKey)  // simulate reinstall wiping defaults
        defaults.removeObject(forKey: cKey)
        sut.hydrate()                        // must NOT restore (keychain empty)
        XCTAssertNil(defaults.string(forKey: pKey))
        XCTAssertNil(defaults.string(forKey: cKey))
    }

    // 5) invalid UUID string is never mirrored / restored
    func test_invalidUUID_notMirrored() {
        defaults.set("not-a-uuid", forKey: pKey)
        sut.capture()
        defaults.removeObject(forKey: pKey)
        sut.hydrate()
        XCTAssertNil(defaults.string(forKey: pKey))
    }
}
