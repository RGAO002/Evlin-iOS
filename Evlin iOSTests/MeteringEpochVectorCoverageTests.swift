import Foundation
import XCTest

final class MeteringEpochVectorCoverageTests: XCTestCase {
    private struct VectorCase: Decodable {
        let id: String
    }

    private struct VectorSuite: Decodable {
        let schemaVersion: Int
        let generationCases: [VectorCase]
        let callbackCases: [VectorCase]
        let gateCases: [VectorCase]
        let ledgerCases: [VectorCase]
        let manualCases: [VectorCase]
        let protocolCases: [VectorCase]
        let perAppOrderingCases: [VectorCase]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case generationCases = "generation_cases"
            case callbackCases = "callback_cases"
            case gateCases = "gate_cases"
            case ledgerCases = "ledger_cases"
            case manualCases = "manual_cases"
            case protocolCases = "protocol_cases"
            case perAppOrderingCases = "per_app_ordering_cases"
        }

        var allCases: [VectorCase] {
            generationCases
                + callbackCases
                + gateCases
                + ledgerCases
                + manualCases
                + protocolCases
                + perAppOrderingCases
        }
    }

    private static func sourceFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("metering_epoch_vectors.json")
    }

    private static func backendFixtureURL(from sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent() // Fixtures
            .deletingLastPathComponent() // Evlin iOSTests
            .deletingLastPathComponent() // Evlin-iOS
            .deletingLastPathComponent() // code.nosync
            .appendingPathComponent("Evlin-Backend/tests/fixtures/metering_epoch_vectors.json")
    }

    func testCanonicalVectorCoverageAndBackendByteParity() throws {
        let sourceURL = Self.sourceFixtureURL()
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return XCTFail("canonical fixture missing at \(sourceURL.path)")
        }
        let sourceData = try Data(contentsOf: sourceURL)
        let suite = try JSONDecoder().decode(VectorSuite.self, from: sourceData)
        let allIDs = suite.allCases.map(\.id).sorted()

        XCTAssertEqual(suite.schemaVersion, 1)
        XCTAssertEqual(allIDs, (1...23).map { String(format: "V%02d", $0) })
        XCTAssertEqual(Set(allIDs).count, 23)

        let backendURL = Self.backendFixtureURL(from: sourceURL)
        if !FileManager.default.fileExists(atPath: backendURL.path),
           ProcessInfo.processInfo.environment["EVLIN_IOS_ONLY_CI"] == "1" {
            return
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backendURL.path),
            "backend fixture missing at \(backendURL.path)"
        )
        XCTAssertEqual(
            sourceData,
            try Data(contentsOf: backendURL),
            "iOS and backend canonical fixtures have drifted"
        )
    }
}
