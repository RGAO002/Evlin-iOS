import XCTest
@testable import Evlin_iOS

@MainActor
final class LegacyDeviceTotalObservationTests: XCTestCase {
    private func snapshot(
        mode: LegacyDeviceTotalMode,
        protocolVersion: Int = 2,
        runtime: EarnedTimeRuntime? = nil
    ) -> ChildStateResponse {
        ChildStateResponse(
            childName: "Liam",
            minutesLeft: 120,
            minutesMax: 120,
            tasks: [],
            reflectionRequest: nil,
            notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: false,
            screenTimeFinishedAcknowledged: false,
            lastResolvedReflection: nil,
            usageCountingAllowed: true,
            earnedTimeRuntime: runtime,
            meteringProtocolVersion: protocolVersion,
            legacyDeviceTotalMode: mode
        )
    }

    func testObserveDisabledStopsOnlyLegacyAndKeepsEpochRecoveryAndHeartbeat() async {
        let runtime = EarnedTimeRuntime(
            usageDate: "2026-07-20",
            timezone: "America/New_York",
            policyRevision: "policy-r1",
            dailyPoolMinutes: 120,
            deviceCapMinutes: 90,
            remainingMinutes: 90,
            estimatedMinutes: 0
        )
        let response = snapshot(mode: .observeDisabled, runtime: runtime)
        let state = BigKidState(snapshot: response)
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            reconcileMeteringRuntime: { _, _ in events.append("epoch-recovery") },
            stopLegacyDeviceTotal: { events.append("legacy-stop") },
            reportEffectiveState: { events.append("heartbeat") }
        )

        await poller.refreshNow()

        XCTAssertEqual(events, ["legacy-stop", "epoch-recovery", "heartbeat"])
    }

    func testActiveLegacyModeStopsLegacyBeforeV2Recovery() async {
        let response = snapshot(mode: .active, protocolVersion: 1)
        let state = BigKidState(snapshot: response)
        var stops = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            stopLegacyDeviceTotal: { stops += 1 }
        )

        await poller.refreshNow()

        XCTAssertEqual(stops, 1)
    }

    func testAuthoritativeTransitionsConvergeWithoutPersistedLatch() async {
        var responses = [
            snapshot(mode: .active),
            snapshot(mode: .observeDisabled),
            snapshot(mode: .active),
        ]
        let state = BigKidState(snapshot: responses[0])
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { responses.removeFirst() },
            reconcileReflectionLock: { _ in },
            stopLegacyDeviceTotal: { events.append("stop") }
        )

        await poller.refreshNow()
        await poller.refreshNow()
        await poller.refreshNow()

        XCTAssertEqual(events, ["stop", "stop", "stop"])
    }

    func testT6ObservationKeepsLegacyChainPresentUntilReleaseGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = try [
            "Evlin iOS/Models/BigKid/BigKidModels.swift",
            "Evlin iOS/Services/BigKidStatePoller.swift",
            "Evlin iOS/Services/BigKidActivityScheduler.swift",
            "Evlin iOS/Services/BigKidTimeReporter.swift",
        ].map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        for symbol in [
            "legacyDeviceTotalMode",
            "evlin.bigkid.freeplay",
            "stopLegacyDeviceTotal",
        ] {
            XCTAssertTrue(sources.contains(symbol), symbol)
        }
    }
}
