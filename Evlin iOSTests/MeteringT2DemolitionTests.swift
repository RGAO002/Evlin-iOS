import Foundation
import XCTest

final class MeteringT2DemolitionTests: XCTestCase {
    func testMutablePoolAndCapDoNotRejectImmutableRouteCallbacks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift"
            ),
            encoding: .utf8
        )
        let staleReason = ["stale", "_ladder", "_drop"].joined()
        let thresholdHandler = try XCTUnwrap(
            source.range(of: "private func handleEarnedThreshold(")
                .flatMap { start in
                    source.range(
                        of: "private func handleAcceptedEarnedThreshold(",
                        range: start.lowerBound..<source.endIndex
                    ).map { end in String(source[start.lowerBound..<end.lowerBound]) }
                }
        )
        let immutableTrustPrefix = try XCTUnwrap(
            thresholdHandler.range(of: "let adjustedN =")
                .map { String(thresholdHandler[..<$0.lowerBound]) }
        )

        XCTAssertFalse(source.contains(staleReason))
        XCTAssertFalse(source.contains("n > min(pool, cap)"))
        XCTAssertFalse(immutableTrustPrefix.contains(".poolMinutes"))
        XCTAssertFalse(immutableTrustPrefix.contains(".capMinutes"))
    }
}
