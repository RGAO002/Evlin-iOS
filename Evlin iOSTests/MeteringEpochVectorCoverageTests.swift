import Foundation
import XCTest

final class MeteringEpochVectorCoverageTests: XCTestCase {
    private typealias JSONObject = [String: Any]

    private enum FixtureLoadError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case let .missing(path):
                return "canonical fixture missing at \(path)"
            }
        }
    }

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
            generationCases + callbackCases + gateCases + ledgerCases + manualCases
                + protocolCases + perAppOrderingCases
        }
    }

    private static let expectedGroupIDs: [(String, [String])] = [
        ("generation_cases", ["V01", "V02", "V03", "V07"]),
        ("callback_cases", ["V04", "V05", "V06", "V08", "V13"]),
        ("gate_cases", ["V09", "V10", "V11", "V12", "V21", "V22"]),
        ("ledger_cases", ["V14", "V15", "V16", "V17"]),
        ("manual_cases", ["V18"]),
        ("protocol_cases", ["V19", "V20"]),
        ("per_app_ordering_cases", ["V23"])
    ]

    private static let expectedInputKinds = [
        "V01": "generation_poll_churn", "V02": "generation_mutable_offset",
        "V03": "generation_selection_digest", "V04": "callback_physical_plausibility",
        "V05": "callback_delayed_accept", "V06": "callback_progress_polls",
        "V07": "generation_readiness_replacement", "V08": "callback_stale_day",
        "V09": "gate_canonical_rollover", "V10": "gate_pause_resume",
        "V11": "gate_task_bypass", "V12": "gate_reflection_precedence",
        "V13": "callback_identity_firewall", "V14": "ledger_device_attribution",
        "V15": "ledger_device_cap", "V16": "ledger_shared_exhaustion",
        "V17": "ledger_per_app_limit", "V18": "manual_lock_unlock",
        "V19": "protocol_v1_compatibility", "V20": "protocol_v1_terminal_drop",
        "V21": "gate_timezone_split", "V22": "gate_canonical_timezone_replacement",
        "V23": "per_app_ordering"
    ]

    private static let effectKeys: Set<String> = [
        "local_estimate_mutations", "retry_enqueues", "network_dispatches",
        "backend_sample_rows", "ledger_mutations", "notifications",
        "shield_mutations", "monitor_starts", "monitor_stops", "epoch_replacements"
    ]

    private static let observationKeys: Set<String> = [
        "kind", "child_device_id", "source", "credential_kind", "credential_id"
    ]

    private static func sourceFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("metering_epoch_vectors.json")
    }

    private static func backendFixtureURL(from sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Evlin-Backend/tests/fixtures/metering_epoch_vectors.json")
    }

    private func sourceFixtureData() throws -> Data {
        let sourceURL = Self.sourceFixtureURL()
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw FixtureLoadError.missing(sourceURL.path)
        }
        return try Data(contentsOf: sourceURL)
    }

    func testCanonicalVectorSchemaAndCoverage() throws {
        let sourceData = try sourceFixtureData()
        let suite = try JSONDecoder().decode(VectorSuite.self, from: sourceData)
        let allIDs = suite.allCases.map(\.id).sorted()

        XCTAssertEqual(suite.schemaVersion, 1)
        XCTAssertEqual(allIDs, (1...23).map { String(format: "V%02d", $0) })
        XCTAssertEqual(Set(allIDs).count, 23)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: sourceData) as? JSONObject)
        for (group, expectedIDs) in Self.expectedGroupIDs {
            let cases = try XCTUnwrap(root[group] as? [JSONObject], "missing \(group)")
            XCTAssertEqual(cases.map { $0["id"] as? String }, expectedIDs, "\(group) IDs")
            for vector in cases {
                XCTAssertTrue(
                    Set(["id", "description", "input", "expected"]).isSubset(of: Set(vector.keys)),
                    "\(group) case missing required keys"
                )
                let id = try XCTUnwrap(vector["id"] as? String)
                let input = try XCTUnwrap(vector["input"] as? JSONObject, "\(id) input")
                XCTAssertEqual(input["kind"] as? String, Self.expectedInputKinds[id], "\(id) input.kind")
                let expected = try XCTUnwrap(vector["expected"] as? JSONObject, "\(id) expected")
                let effects = try XCTUnwrap(expected["effects"] as? JSONObject, "\(id) effects")
                XCTAssertEqual(Set(effects.keys), Self.effectKeys, "\(id) effects keys")
            }
        }

        let ledgerCases = try XCTUnwrap(root["ledger_cases"] as? [JSONObject])
        for vector in ledgerCases {
            let id = try XCTUnwrap(vector["id"] as? String)
            let expected = try XCTUnwrap(vector["expected"] as? JSONObject)
            let observations = try XCTUnwrap(expected["attributed_observations"] as? [JSONObject], "\(id) observations")
            XCTAssertFalse(observations.isEmpty, "\(id) observations")
            for observation in observations {
                XCTAssertEqual(Set(observation.keys), Self.observationKeys, "\(id) observation keys")
                try assertObservationIdentityIsDerivedFromInput(vector, observation: observation)
            }
        }
    }

    private func assertObservationIdentityIsDerivedFromInput(_ vector: JSONObject, observation: JSONObject) throws {
        let input = try XCTUnwrap(vector["input"] as? JSONObject)
        let kind = try XCTUnwrap(input["kind"] as? String)

        if ["ledger_device_attribution", "ledger_device_cap", "ledger_shared_exhaustion"].contains(kind) {
            let accepted = try XCTUnwrap(input["accepted"] as? JSONObject)
            let credential = try XCTUnwrap(accepted["credential"] as? JSONObject)
            if observation["credential_kind"] as? String == "epoch" {
                XCTAssertEqual(observation["child_device_id"] as? String, accepted["child_device_id"] as? String)
                XCTAssertEqual(observation["source"] as? String, accepted["source"] as? String)
                XCTAssertEqual(observation["credential_id"] as? String, credential["id"] as? String)
                return
            }

            let sets = (input["enforcement_sets"] ?? input["devices"])
            let enforcementSets = try XCTUnwrap(sets as? [JSONObject])
            XCTAssertEqual(observation["source"] as? String, accepted["source"] as? String)
            XCTAssertTrue(enforcementSets.contains { set in
                guard let setCredential = set["credential"] as? JSONObject else { return false }
                return observation["child_device_id"] as? String == set["child_device_id"] as? String
                    && observation["credential_kind"] as? String == setCredential["kind"] as? String
                    && observation["credential_id"] as? String == setCredential["id"] as? String
            })
            return
        }

        XCTAssertEqual(kind, "ledger_per_app_limit")
        let rule = try XCTUnwrap(input["reached_rule"] as? JSONObject)
        let credential = try XCTUnwrap(rule["credential"] as? JSONObject)
        XCTAssertEqual(observation["child_device_id"] as? String, rule["child_device_id"] as? String)
        XCTAssertEqual(observation["source"] as? String, rule["source"] as? String)
        XCTAssertEqual(observation["credential_kind"] as? String, credential["kind"] as? String)
        XCTAssertEqual(observation["credential_id"] as? String, credential["id"] as? String)
    }

    func testCanonicalVectorBackendByteParity() throws {
        let sourceURL = Self.sourceFixtureURL()
        let sourceData = try sourceFixtureData()
        let backendURL = Self.backendFixtureURL(from: sourceURL)
        if !FileManager.default.fileExists(atPath: backendURL.path),
           ProcessInfo.processInfo.environment["EVLIN_IOS_ONLY_CI"] == "1" {
            throw XCTSkip("backend fixture copy not present in iOS-only CI")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backendURL.path), "backend fixture missing at \(backendURL.path)")
        XCTAssertEqual(sourceData, try Data(contentsOf: backendURL), "iOS and backend canonical fixtures have drifted")
    }
}
