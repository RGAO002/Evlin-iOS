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

        XCTAssertFalse(source.contains(staleReason))
        XCTAssertFalse(source.contains("n > min(pool, cap)"))
    }
}
