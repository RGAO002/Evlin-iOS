import XCTest
@testable import Evlin_iOS

/// THE SAFETY INVARIANT, pinned: a normal parent or kid device (flag NOT set) can NEVER show
/// the P/K float. This guards against any future regression that would leak the demo float into
/// real-parent / real-kid builds.
@MainActor
final class SingleDeviceGatingTests: XCTestCase {
    private let d = UserDefaults.standard

    override func setUp() { super.setUp(); SingleDeviceSession.shared.resetForNewRun() }
    override func tearDown() { SingleDeviceSession.shared.resetForNewRun(); super.tearDown() }

    func test_normalParent_noFloat() {
        d.set("parent", forKey: "appMode")
        d.set(UUID().uuidString, forKey: "evlin.familyID")
        d.set(UUID().uuidString, forKey: "evlin.parentDeviceID")
        d.set(UUID().uuidString, forKey: "evlin.childDeviceID")   // even with all ids present…
        XCTAssertFalse(SingleDeviceSession.shared.isEnabled)       // …flag is not set →
        XCTAssertFalse(SingleDeviceSession.shared.isActive)        // …no float.
    }

    func test_normalKid_noFloat() {
        d.set("child", forKey: "appMode")
        d.set(UUID().uuidString, forKey: "evlin.familyID")
        d.set(UUID().uuidString, forKey: "evlin.childDeviceID")
        XCTAssertFalse(SingleDeviceSession.shared.isActive)
    }

    func test_singleDevice_withRealIDs_showsFloat() {
        SingleDeviceSession.shared.enable()
        d.set(UUID().uuidString, forKey: "evlin.familyID")
        d.set(UUID().uuidString, forKey: "evlin.parentDeviceID")
        d.set(UUID().uuidString, forKey: "evlin.childDeviceID")
        XCTAssertTrue(SingleDeviceSession.shared.isActive)
    }

    func test_singleDevice_flagSetButIdsMissing_noFloatYet() {
        SingleDeviceSession.shared.enable()           // mid-onboarding: flag on, ids not all present
        d.set(UUID().uuidString, forKey: "evlin.familyID")
        XCTAssertFalse(SingleDeviceSession.shared.isActive)
    }
}
