import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringRecoveryOutcomeTests: XCTestCase {
    func testMissingSharedConfigurationIsNotSuccess() async throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: EarnedTimeStore.appGroupSuiteName)
        )
        let savedBase = defaults.string(
            forKey: MeteringProductionComposition.baseURLKey
        )
        let savedOwner = defaults.string(
            forKey: MeteringProductionComposition.ownerKey
        )
        defaults.removeObject(forKey: MeteringProductionComposition.baseURLKey)
        defaults.removeObject(forKey: MeteringProductionComposition.ownerKey)
        defer {
            if let savedBase {
                defaults.set(savedBase, forKey: MeteringProductionComposition.baseURLKey)
            } else {
                defaults.removeObject(forKey: MeteringProductionComposition.baseURLKey)
            }
            if let savedOwner {
                defaults.set(savedOwner, forKey: MeteringProductionComposition.ownerKey)
            } else {
                defaults.removeObject(forKey: MeteringProductionComposition.ownerKey)
            }
        }

        let outcome = try await MeteringProductionComposition
            .recoverFromSharedConfiguration(role: .app)

        XCTAssertEqual(outcome, .skippedMissingConfiguration)
    }

    func testExpectedOwnerMismatchIsNotAttempted() async throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: EarnedTimeStore.appGroupSuiteName)
        )
        let savedBase = defaults.string(
            forKey: MeteringProductionComposition.baseURLKey
        )
        let savedOwner = defaults.string(
            forKey: MeteringProductionComposition.ownerKey
        )
        let configuredOwner = UUID()
        let baseURL = URL(string: "http://127.0.0.1:8000")!
        defaults.set(
            baseURL.absoluteString,
            forKey: MeteringProductionComposition.baseURLKey
        )
        defaults.set(
            configuredOwner.uuidString,
            forKey: MeteringProductionComposition.ownerKey
        )
        defer {
            if let savedBase {
                defaults.set(savedBase, forKey: MeteringProductionComposition.baseURLKey)
            } else {
                defaults.removeObject(forKey: MeteringProductionComposition.baseURLKey)
            }
            if let savedOwner {
                defaults.set(savedOwner, forKey: MeteringProductionComposition.ownerKey)
            } else {
                defaults.removeObject(forKey: MeteringProductionComposition.ownerKey)
            }
        }

        let outcome = try await MeteringProductionComposition
            .recoverFromSharedConfiguration(
                role: .app,
                expectedOwner: UUID(),
                expectedBaseURL: baseURL
            )

        XCTAssertEqual(outcome, .skippedConfigurationMismatch)
    }
}
