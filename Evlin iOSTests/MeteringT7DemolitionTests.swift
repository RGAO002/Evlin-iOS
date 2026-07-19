import Foundation
import XCTest

final class MeteringT7DemolitionTests: XCTestCase {
    func testLegacyCounterRecoveryFlagsAndDecreaseLatchAreAbsent() throws {
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
            ["counter", "Recovery", "Required"].joined(),
            ["pending", "Uncounted", "Reconciliation"].joined(),
            ["requires", "Counter", "Recovery"].joined(),
            ["allow", "Same", "Day", "Decrease"].joined(),
            ["rearm", "Usage", "Counters", "Result"].joined(),
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
                        "forbidden T7 state \(token) remains in \(fileURL.path)"
                    )
                }
            }
        }
    }
}
