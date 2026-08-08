import XCTest
@testable import Evlin_iOS

@MainActor
final class FamilyGoneDetectorTests: XCTestCase {
    func test_failOpenStopsEarnedBeforeClearingPairingAndMirror() async throws {
        let standardSuite = "FamilyGoneDetectorTests.standard.\(UUID().uuidString)"
        let groupSuite = "FamilyGoneDetectorTests.group.\(UUID().uuidString)"
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardSuite))
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: groupSuite))
        defer {
            standard.removePersistentDomain(forName: standardSuite)
            appGroup.removePersistentDomain(forName: groupSuite)
        }
        standard.set(UUID().uuidString, forKey: CommandPoller.childDeviceIDDefaultsKey)
        standard.set(UUID().uuidString, forKey: "evlin.familyID")
        standard.set(true, forKey: "onboardingComplete")
        appGroup.set(UUID().uuidString, forKey: "evlin.childId")
        var events: [String] = []

        await FamilyGoneDetector.failOpen(
            defaults: standard,
            appGroupDefaults: appGroup,
            releaseRestrictions: { events.append("release") },
            teardownEarned: {
                events.append("earned")
                XCTAssertNotNil(appGroup.string(forKey: "evlin.childId"))
            }
        )

        XCTAssertEqual(events, ["earned", "release"])
        XCTAssertNil(appGroup.string(forKey: "evlin.childId"))
        XCTAssertNil(standard.string(forKey: CommandPoller.childDeviceIDDefaultsKey))
        XCTAssertNil(standard.string(forKey: "evlin.familyID"))
        XCTAssertFalse(standard.bool(forKey: "onboardingComplete"))
    }
}
