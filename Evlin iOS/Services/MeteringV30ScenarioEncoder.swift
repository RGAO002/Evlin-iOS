import CryptoKit
import Foundation

nonisolated enum MeteringV30ScenarioEncoder {
    static let ownerID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000030")!
    static let epochID = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000030")!
    static let routeID = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000030")!
    static let enforcementSetID = UUID(uuidString: "cccccccc-0000-0000-0000-000000000030")!
    static let usageDate = "2026-07-15"
    static let timezone = "America/New_York"
    static let policyRevision = "30000000-0000-0000-0000-000000000030:40000000-0000-0000-0000-000000000030"
    static let selectionDigest = String(repeating: "3", count: 64)
    static let startedAt = Date(timeIntervalSince1970: 1_784_124_300)
    static let verifiedAt = Date(timeIntervalSince1970: 1_784_124_302)
    static let v2ObservedAt = Date(timeIntervalSince1970: 1_784_124_600)
    static let staleV1ObservedAt = Date(timeIntervalSince1970: 1_784_124_900)

    static let fileNames = [
        "01-v1.json", "02-registration.json", "03-activation.json",
        "04-v2.json", "05-stale-v1.json", "manifest.json",
    ]

    private struct ManifestEntry: Codable {
        let filename: String
        let byteCount: Int
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case filename, byteCount = "byte_count", sha256
        }
    }

    private struct ManifestIdentity: Codable {
        let filename: String
        let schemaVersion: Int

        enum CodingKeys: String, CodingKey {
            case filename, schemaVersion = "schema_version"
        }
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let manifest: ManifestIdentity
        let files: [ManifestEntry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", manifest, files
        }
    }

    @discardableResult
    static func writeScenario(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let requestFiles: [(String, Data)] = try [
            ("01-v1.json", encoded(v1Request(threshold: 5, estimate: 5, observedAt: v2ObservedAt))),
            ("02-registration.json", encoded(registrationRequest())),
            ("03-activation.json", encoded(activationRequest())),
            ("04-v2.json", encoded(v2Request())),
            ("05-stale-v1.json", encoded(v1Request(threshold: 10, estimate: 10, observedAt: staleV1ObservedAt))),
        ]

        var written: [URL] = []
        var entries: [ManifestEntry] = []
        for (filename, data) in requestFiles {
            let url = directory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            written.append(url)
            entries.append(ManifestEntry(
                filename: filename,
                byteCount: data.count,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            ))
        }

        let manifest = Manifest(
            schemaVersion: 1,
            manifest: ManifestIdentity(filename: "manifest.json", schemaVersion: 1),
            files: entries
        )
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try encoded(manifest).write(to: manifestURL, options: .atomic)
        written.append(manifestURL)
        return written
    }

    private static func registrationRequest() -> EpochRegistrationRequestDTO {
        EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: epochID,
            deviceID: ownerID,
            usageDate: usageDate,
            timezone: timezone,
            policyRevision: policyRevision,
            measurementSelectionDigest: selectionDigest,
            enforcementSetID: enforcementSetID,
            startedAt: startedAt,
            baseAcceptedMinutes: 5,
            reason: .initial
        )
    }

    private static func activationRequest() -> EpochActivationRequestDTO {
        EpochActivationRequestDTO(
            protocolVersion: 2,
            deviceID: ownerID,
            routeID: routeID,
            verifiedAt: verifiedAt
        )
    }

    private static func v2Request() -> EpochSampleRequestDTO {
        EpochSampleRequestDTO(
            deviceID: ownerID,
            usageDate: usageDate,
            timezone: timezone,
            activityName: MeteringSampleWireAliases.activityName(routeID: routeID),
            eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: 5),
            thresholdMinutes: 5,
            estimatedMinutes: 10,
            observedAt: v2ObservedAt,
            clientSampleID: MeteringSampleWireAliases.clientSampleID(
                lane: .v2,
                routeID: routeID,
                thresholdMinutes: 5
            ),
            protocolVersion: 2,
            epochID: epochID,
            generationArmedAt: nil,
            generationOffsetMinutes: nil
        )
    }

    private static func v1Request(
        threshold: Int,
        estimate: Int,
        observedAt: Date
    ) -> EpochSampleRequestDTO {
        EpochSampleRequestDTO(
            deviceID: ownerID,
            usageDate: usageDate,
            timezone: timezone,
            activityName: "evlin.earned.budget",
            eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: threshold),
            thresholdMinutes: threshold,
            estimatedMinutes: estimate,
            observedAt: observedAt,
            clientSampleID: MeteringSampleWireAliases.clientSampleID(
                lane: .v1,
                routeID: routeID,
                thresholdMinutes: threshold
            ),
            protocolVersion: nil,
            epochID: nil,
            generationArmedAt: nil,
            generationOffsetMinutes: nil
        )
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
