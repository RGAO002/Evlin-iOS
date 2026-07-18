import CryptoKit
import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringV30ProductionEncoderTests: XCTestCase {
    func testWritesSixExactScenarioFilesAndManifest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-v30-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = try MeteringV30ScenarioEncoder.writeScenario(to: directory)

        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), MeteringV30ScenarioEncoder.fileNames.sorted())
        XCTAssertEqual(files.count, 6)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            MeteringV30ScenarioEncoder.fileNames.sorted()
        )
        for file in files {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
            XCTAssertFalse(isDirectory.boolValue)
            XCTAssertGreaterThan(try Data(contentsOf: file).count, 0)
        }

        let v1 = try decode(EpochSampleRequestDTO.self, file: "01-v1.json", in: directory)
        XCTAssertEqual(v1.deviceID, MeteringV30ScenarioEncoder.ownerID)
        XCTAssertEqual(v1.protocolVersion, nil)
        XCTAssertEqual(v1.epochID, nil)
        XCTAssertEqual(v1.thresholdMinutes, 5)
        XCTAssertEqual(v1.estimatedMinutes, 5)
        XCTAssertEqual(v1.clientSampleID, "earned:v1:\(MeteringV30ScenarioEncoder.routeID.uuidString.lowercased()):t5")

        let registration = try decode(
            EpochRegistrationRequestDTO.self,
            file: "02-registration.json",
            in: directory
        )
        XCTAssertEqual(registration.protocolVersion, 2)
        XCTAssertEqual(registration.epochID, MeteringV30ScenarioEncoder.epochID)
        XCTAssertEqual(registration.deviceID, MeteringV30ScenarioEncoder.ownerID)
        XCTAssertEqual(registration.usageDate, MeteringV30ScenarioEncoder.usageDate)
        XCTAssertEqual(registration.timezone, MeteringV30ScenarioEncoder.timezone)
        XCTAssertEqual(registration.policyRevision, MeteringV30ScenarioEncoder.policyRevision)
        XCTAssertEqual(registration.measurementSelectionDigest, MeteringV30ScenarioEncoder.selectionDigest)
        XCTAssertEqual(registration.enforcementSetID, MeteringV30ScenarioEncoder.enforcementSetID)
        XCTAssertEqual(registration.baseAcceptedMinutes, 5)
        XCTAssertEqual(registration.reason, .initial)

        let activation = try decode(
            EpochActivationRequestDTO.self,
            file: "03-activation.json",
            in: directory
        )
        XCTAssertEqual(activation.protocolVersion, 2)
        XCTAssertEqual(activation.deviceID, MeteringV30ScenarioEncoder.ownerID)
        XCTAssertEqual(activation.routeID, MeteringV30ScenarioEncoder.routeID)

        let v2 = try decode(EpochSampleRequestDTO.self, file: "04-v2.json", in: directory)
        XCTAssertEqual(v2.protocolVersion, 2)
        XCTAssertEqual(v2.epochID, MeteringV30ScenarioEncoder.epochID)
        XCTAssertEqual(v2.activityName, MeteringSampleWireAliases.activityName(routeID: MeteringV30ScenarioEncoder.routeID))
        XCTAssertEqual(v2.eventName, MeteringSampleWireAliases.eventName(thresholdMinutes: 5))
        XCTAssertEqual(v2.thresholdMinutes, 5)
        XCTAssertEqual(v2.estimatedMinutes, 10)
        XCTAssertEqual(v2.clientSampleID, "earned:v2:\(MeteringV30ScenarioEncoder.routeID.uuidString.lowercased()):t5")

        let staleV1 = try decode(EpochSampleRequestDTO.self, file: "05-stale-v1.json", in: directory)
        XCTAssertNil(staleV1.protocolVersion)
        XCTAssertNil(staleV1.epochID)
        XCTAssertEqual(staleV1.thresholdMinutes, 10)
        XCTAssertEqual(staleV1.estimatedMinutes, 10)

        let manifest = try decode(Manifest.self, file: "manifest.json", in: directory)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.manifest, .init(filename: "manifest.json", schemaVersion: 1))
        XCTAssertEqual(manifest.files.map(\.filename), Array(MeteringV30ScenarioEncoder.fileNames.dropLast()))
        XCTAssertFalse(manifest.files.contains { $0.filename == "manifest.json" })
        for entry in manifest.files {
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.filename))
            XCTAssertEqual(entry.byteCount, data.count, entry.filename)
            XCTAssertEqual(entry.sha256, sha256(data), entry.filename)
        }
    }

    func testWritesCrossStackArtifact() throws {
        guard let raw = ProcessInfo.processInfo.environment["EVLIN_V30_ARTIFACT_DIR"],
              !raw.isEmpty
        else {
            throw XCTSkip("EVLIN_V30_ARTIFACT_DIR is only set by the cross-stack orchestrator")
        }
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        _ = try MeteringV30ScenarioEncoder.writeScenario(to: directory)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            MeteringV30ScenarioEncoder.fileNames.sorted()
        )
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        file: String,
        in directory: URL
    ) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: directory.appendingPathComponent(file)))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct Manifest: Decodable {
    let schemaVersion: Int
    let manifest: ManifestIdentity
    let files: [ManifestEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", manifest, files
    }
}

private struct ManifestIdentity: Decodable, Equatable {
    let filename: String
    let schemaVersion: Int

    enum CodingKeys: String, CodingKey {
        case filename, schemaVersion = "schema_version"
    }
}

private struct ManifestEntry: Decodable {
    let filename: String
    let byteCount: Int
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case filename, byteCount = "byte_count", sha256
    }
}
