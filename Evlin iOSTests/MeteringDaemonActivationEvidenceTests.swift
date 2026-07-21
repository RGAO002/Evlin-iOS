#if DEBUG
import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringDaemonActivationEvidenceTests: XCTestCase {
    func testV1NeverClaimsV2Ready() {
        let evidence = MeteringDaemonActivationEvidence.make(input: input(selection: .v1))
        XCTAssertEqual(evidence.stage, .v1)
        XCTAssertFalse(evidence.v2Ready)
    }

    func testDualActiveIncompleteDoesNotClaimV2Ready() {
        let evidence = MeteringDaemonActivationEvidence.make(input: input(
            selection: .dualActive,
            installPhase: .installed,
            activationAcknowledged: false,
            exactDaemonReadback: false
        ))
        XCTAssertEqual(evidence.stage, .dualActiveIncomplete)
        XCTAssertFalse(evidence.v2Ready)
    }

    func testFullyInstalledDualActiveStillWaitsForActivationAcknowledgement() {
        let evidence = MeteringDaemonActivationEvidence.make(input: input(
            selection: .dualActive,
            installPhase: .verified,
            activationAcknowledged: false,
            exactDaemonReadback: true
        ))
        XCTAssertEqual(evidence.stage, .dualActiveAwaitingActivation)
        XCTAssertFalse(evidence.v2Ready)
    }

    func testV2RequiresRatchetActiveRouteActiveInstallAckAndExactDaemonReadback() {
        var fixture = input(
            selection: .v2,
            routeLifecycle: .active,
            installPhase: .active,
            activationAcknowledged: true,
            exactDaemonReadback: true
        )
        XCTAssertTrue(MeteringDaemonActivationEvidence.make(input: fixture).v2Ready)

        fixture.exactDaemonReadback = false
        let mismatch = MeteringDaemonActivationEvidence.make(input: fixture)
        XCTAssertEqual(mismatch.stage, .inconsistent)
        XCTAssertFalse(mismatch.v2Ready)
    }

    func testExactReadbackRequiresEveryActiveDatedRouteToMatch() {
        let first = entry(sequence: 1, activityName: "earned.one", result: .match)
        XCTAssertFalse(MeteringDaemonActivationEvidence.allRoutesHaveExactReadback(
            routeActivityNames: ["earned.one", "earned.two"],
            entries: [first]
        ))

        let second = entry(sequence: 2, activityName: "earned.two", result: .match)
        XCTAssertTrue(MeteringDaemonActivationEvidence.allRoutesHaveExactReadback(
            routeActivityNames: ["earned.one", "earned.two"],
            entries: [first, second]
        ))

        let laterMismatch = entry(sequence: 3, activityName: "earned.two", result: .mismatch)
        XCTAssertFalse(MeteringDaemonActivationEvidence.allRoutesHaveExactReadback(
            routeActivityNames: ["earned.one", "earned.two"],
            entries: [first, second, laterMismatch]
        ))
    }

    private func input(
        selection: MeteringLocalProtocolSelection,
        routeLifecycle: MeteringRouteLifecycle? = .planned,
        installPhase: ActivityInstallPhase? = .pendingStart,
        activationAcknowledged: Bool = false,
        exactDaemonReadback: Bool = false
    ) -> MeteringDaemonActivationEvidenceInput {
        .init(
            advertisedVersion: selection == .v1 ? 1 : 2,
            localSelection: selection,
            epochID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            routeID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
            routeLifecycle: routeLifecycle,
            installPhase: installPhase,
            activationAcknowledged: activationAcknowledged,
            exactDaemonReadback: exactDaemonReadback
        )
    }

    private func entry(
        sequence: UInt64,
        activityName: String,
        result: MeteringDiagnosticResult
    ) -> MeteringDaemonDiagnosticEntry {
        MeteringDaemonDiagnosticEntry(sequence: sequence, draft: .init(
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            process: "test",
            operation: .readback,
            activityName: activityName,
            namespace: "earned",
            armID: nil,
            expected: nil,
            actual: nil,
            result: result,
            mismatchReasons: result == .mismatch ? ["events"] : [],
            message: nil
        ))
    }
}
#endif
