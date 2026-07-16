import XCTest
import SwiftUI
@testable import Evlin_iOS

@MainActor
final class ProfileSnapshotTests: XCTestCase {
    func test_debugFixtureCanSeedProfileWithoutLiveRuntimeEffects() {
        let fixture = ProfileView.ProfileSnapshotFixture_v1(
            child: .previewLiam,
            tasks: [],
            devices: [],
            rules: ProfileMockData.rules(for: "liam", dailyLimitMinutes: 120),
            dailyLimitMinutes: 120,
            localStatus: .unlocked,
            manualLockState: .unlocked,
            automaticCoveringSources: [],
            earnedSummary: nil,
            profileTab: .overview
        )

        _ = ProfileView(snapshotFixture: fixture)
    }
}
