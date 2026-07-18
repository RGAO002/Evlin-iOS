import Foundation
import XCTest

final class MeteringT1DemolitionTests: XCTestCase {
    func testLegacyScalarArmingIdentityHasNoSwiftReferences() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let forbidden = [
            ["arm", "Signature", "Key"].joined(),
            ["make", "Arm", "Signature"].joined(),
            ["should", "Start", "Monitoring"].joined(),
            ["previous", "Arm", "Signature"].joined(),
            ["selection", "Fingerprint"].joined(),
            ["current", "Arm", "Signature"].joined(),
        ]
        let paths = [
            "Evlin iOS",
            "EvlinDeviceActivityMonitor",
            "EvlinPushApplier",
            "Evlin iOSTests",
        ]

        var violations: [String] = []
        for path in paths {
            let directory = root.appendingPathComponent(path)
            guard let files = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden where source.contains(token) {
                    violations.append("\(file.path): \(token)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Legacy scalar arming identity remains:\n\(violations.joined(separator: "\n"))"
        )

        let persistedField = ["arm", "Signature"].joined()
        for path in [
            "Evlin iOS/Services/EarnedTimeStore.swift",
            "Evlin iOS/Services/DeviceEpochStore.swift",
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains(persistedField), "Persisted field remains in \(path)")
        }
    }
}
