import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringEpochPhase3VectorTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Vector: Decodable {
            let id: String
            let expectedSourcesAfterExactRelease: [String]?
            let futureSource: String?
            let expectedSourcesAfterRoundTrip: [String]?
        }

        let schemaVersion: Int
        let cases: [Vector]
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/metering_epoch_phase3_vectors.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testP3V01_releasingEarnedSourceUsesRealShieldRecordCAS() throws {
        let vector = try XCTUnwrap(loadFixture().cases.first { $0.id == "P3V01" })
        let expected = ShieldRecord(
            recordKey: "all",
            tier: .all,
            targetKey: "all",
            displayName: "All Apps",
            lastCommandID: UUID(uuidString: "31000000-0000-0000-0000-000000000001")!,
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(timeIntervalSince1970: 1_752_588_000),
            expiresAt: nil,
            originalRequest: "earned time",
            targetChildID: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000031")!,
            sources: [.manual, .taskPause, .earnedTime]
        )
        var newer = expected
        newer.displayName = "Newer record"

        XCTAssertEqual(
            EarnedShieldCAS.releasingEarnedSource(current: newer, expectedApplied: expected),
            newer,
            "a mismatched record must remain byte-for-byte equivalent"
        )

        let released = EarnedShieldCAS.releasingEarnedSource(
            current: expected,
            expectedApplied: expected
        )
        XCTAssertEqual(
            released?.sources.map(\.rawValue).sorted(),
            vector.expectedSourcesAfterExactRelease
        )
        XCTAssertEqual(released?.sources, [.manual, .taskPause])
    }

    func testP3V02_unknownFutureSourceSurvivesDecodeMergeAndEncode() throws {
        let vector = try XCTUnwrap(loadFixture().cases.first { $0.id == "P3V02" })
        let source = try XCTUnwrap(vector.futureSource)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let decoded = try decoder.decode(ShieldSource.self, from: Data("\"\(source)\"".utf8))
        XCTAssertEqual(decoded.rawValue, source)

        let record = ShieldRecord(
            recordKey: "all",
            tier: .all,
            targetKey: "all",
            displayName: "All Apps",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(timeIntervalSince1970: 1_752_588_000),
            expiresAt: nil,
            originalRequest: "limit",
            targetChildID: UUID(),
            sources: [.limit]
        )
        let merged = ShieldSourceLogic.unioning(record, intoSources: [decoded])
        let roundTripped = try decoder.decode(ShieldRecord.self, from: encoder.encode(merged))

        XCTAssertEqual(
            roundTripped.sources.map(\.rawValue).sorted(),
            vector.expectedSourcesAfterRoundTrip
        )
    }

    func testPhase3GoldenVectorsEvaluateAllReferenceEffects() throws {
        let suite = try MeteringGoldenVectorSuite.load()
        let executed = suite.phase3Cases.map { vector in
            let actual = MeteringReferenceRules.evaluatePhase3(vector.input)
            XCTAssertEqual(actual, vector.expected, vector.id)
            return vector.id
        }

        XCTAssertEqual(executed, (24...39).map { String(format: "V%02d", $0) })
    }
}
