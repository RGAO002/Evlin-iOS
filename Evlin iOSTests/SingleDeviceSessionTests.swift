import XCTest
@testable import Evlin_iOS

@MainActor   // SingleDeviceSession.shared is a @MainActor singleton — test class must match.
final class SingleDeviceSessionTests: XCTestCase {
    private let d = UserDefaults.standard

    override func tearDown() {
        SingleDeviceSession.shared.resetForNewRun()   // nil auth → no Keychain/AuthService touch
        super.tearDown()
    }

    func test_enable_setsFlag_and_isActiveNeedsRealIDs() {
        SingleDeviceSession.shared.resetForNewRun()
        SingleDeviceSession.shared.enable()
        XCTAssertTrue(SingleDeviceSession.shared.isEnabled)
        XCTAssertFalse(SingleDeviceSession.shared.isActive)   // enabled but ids missing → no float
        d.set(UUID().uuidString, forKey: "evlin.childDeviceID")
        d.set(UUID().uuidString, forKey: "evlin.parentDeviceID")
        d.set(UUID().uuidString, forKey: "evlin.familyID")
        XCTAssertTrue(SingleDeviceSession.shared.isActive)
    }

    func test_resetForNewRun_clearsIDsAndFlag_andMintsFreshDemoIdentity() {
        SingleDeviceSession.shared.resetForNewRun()
        SingleDeviceSession.shared.enable()
        d.set("old-child", forKey: "evlin.childDeviceID")
        let firstEmail = SingleDeviceSession.shared.demoEmail
        let firstInstall = SingleDeviceSession.shared.clientInstallIDOverride
        XCTAssertFalse(firstEmail.isEmpty)
        XCTAssertFalse(firstInstall.isEmpty)

        SingleDeviceSession.shared.resetForNewRun()   // test path: auth == nil

        XCTAssertEqual(d.string(forKey: "evlin.childDeviceID") ?? "", "")
        XCTAssertFalse(SingleDeviceSession.shared.isEnabled)

        SingleDeviceSession.shared.enable()           // a new run mints a DIFFERENT email + install id (avoids /pair 409)
        XCTAssertNotEqual(SingleDeviceSession.shared.demoEmail, firstEmail)
        XCTAssertNotEqual(SingleDeviceSession.shared.clientInstallIDOverride, firstInstall)
    }

    func test_demoPassword_meetsBackendMinLength() {
        SingleDeviceSession.shared.resetForNewRun()
        SingleDeviceSession.shared.enable()
        XCTAssertGreaterThanOrEqual(SingleDeviceSession.shared.demoPassword.count, 8)  // POST /auth/email min 8
    }
}
