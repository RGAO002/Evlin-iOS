import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringT11DemolitionTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let epochID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let startedAt = Date(timeIntervalSince1970: 1_784_937_600)

    func testLegacyPlusFiveSymbolsAreAbsentFromSwiftSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = [
            "Evlin iOS",
            "EvlinDeviceActivityMonitor",
            "EvlinPushApplier",
            "Evlin iOSTests",
        ]
        let forbidden = [
            ["Earned", "Threshold", "Plausibility"].joined(),
            ["tolerance", "Minutes"].joined(),
        ]

        for relativeRoot in roots {
            let directory = root.appendingPathComponent(relativeRoot)
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            )
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                for token in forbidden {
                    XCTAssertFalse(
                        source.contains(token),
                        "forbidden plus-five symbol \(token) remains in \(fileURL.path)"
                    )
                }
            }
        }
    }

    func testLegacyCoordinatorUsesStrictThirtySecondBoundary() {
        XCTAssertEqual(legacyOutcome(after: 1), .rejected)
        XCTAssertEqual(legacyOutcome(after: 269), .rejected)
        XCTAssertEqual(legacyOutcome(after: 270), .accepted)
        XCTAssertEqual(legacyOutcome(after: 271), .accepted)
    }

    func testSixtySecondMaximumBoundaryAndLateCallbackRemainValid() {
        XCTAssertEqual(
            MeteringEpochContract.callbackVerdict(strictInput(after: 240, jitterSeconds: 60)),
            .accept
        )
        XCTAssertEqual(
            MeteringEpochContract.callbackVerdict(strictInput(after: 239, jitterSeconds: 60)),
            .rejectTooEarly
        )
        XCTAssertEqual(
            MeteringEpochContract.callbackVerdict(strictInput(after: 24 * 60 * 60)),
            .accept
        )
    }

    func testJitterConfigurationAboveMaximumFailsClosed() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-t11-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { [owner] in owner })
        let callback = EarnedMeteringCallback(
            store: store,
            clock: T11Clock(now: startedAt),
            jitterSeconds: 61
        )

        let outcome = try callback.handle(
            MeteringAppleCallback(
                activityName: "not-a-route",
                eventName: "not-an-event",
                observedAt: startedAt
            ),
            expectedOwnerChildDeviceID: owner
        )

        XCTAssertEqual(outcome, .discarded(reason: "invalid_jitter"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    private func legacyOutcome(after seconds: TimeInterval)
        -> EarnedThresholdProductionCoordinator.Outcome {
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: owner.uuidString,
            offsetMinutes: 50,
            usageDate: "2026-07-18",
            timezoneIdentifier: "America/New_York",
            armedAt: startedAt
        )
        return EarnedThresholdProductionCoordinator.process(
            generation: generation,
            eventName: "evlin.earned.t5",
            rawThresholdMinutes: 5,
            adjustedEstimateMinutes: 55,
            callbackAt: startedAt.addingTimeInterval(seconds),
            currentUsageDate: generation.usageDate,
            recordDiagnostic: { _ in },
            runAcceptedProductionPath: {}
        )
    }

    private func strictInput(
        after seconds: TimeInterval,
        jitterSeconds: Int = MeteringEpochContract.defaultJitterSeconds
    ) -> MeteringCallbackInput {
        MeteringCallbackInput(
            activeEpochID: epochID,
            callbackEpochID: epochID,
            activeOwnerDeviceID: owner,
            callbackOwnerDeviceID: owner,
            activeUsageDate: "2026-07-18",
            callbackUsageDate: "2026-07-18",
            activePolicyRevision: "policy-1",
            callbackPolicyRevision: "policy-1",
            expectedEventNamespace: "metering.v2",
            callbackEventNamespace: "metering.v2",
            adjustedEstimateMinutes: 5,
            baseAcceptedMinutes: 0,
            startedAt: startedAt,
            callbackAt: startedAt.addingTimeInterval(seconds),
            jitterSeconds: jitterSeconds
        )
    }
}

private struct T11Clock: MeteringClock {
    let now: Date
}
