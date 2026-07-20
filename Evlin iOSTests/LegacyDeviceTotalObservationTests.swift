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
            startLegacyDeviceTotal: { events.append("legacy-start"); return true },
            stopLegacyDeviceTotal: { events.append("legacy-stop") },
            reportEffectiveState: { events.append("heartbeat") }
        )

        await poller.refreshNow()

        XCTAssertEqual(events, ["legacy-stop", "epoch-recovery", "heartbeat"])
    }

    func testActiveStartsLegacyForProtocolOneCompatibility() async {
        let response = snapshot(mode: .active, protocolVersion: 1)
        let state = BigKidState(snapshot: response)
        var starts = 0
        var stops = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            startLegacyDeviceTotal: { starts += 1; return true },
            stopLegacyDeviceTotal: { stops += 1 }
        )

        await poller.refreshNow()

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
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
            startLegacyDeviceTotal: { events.append("start"); return true },
            stopLegacyDeviceTotal: { events.append("stop") }
        )

        await poller.refreshNow()
        await poller.refreshNow()
        await poller.refreshNow()

        XCTAssertEqual(events, ["start", "stop", "start"])
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
            "startLegacyDeviceTotal",
            "stopLegacyDeviceTotal",
        ] {
            XCTAssertTrue(sources.contains(symbol), symbol)
        }
    }
}
