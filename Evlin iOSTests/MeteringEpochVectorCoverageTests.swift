import Foundation
import XCTest

final class MeteringEpochVectorCoverageTests: XCTestCase {
    private typealias JSONObject = [String: Any]

    private struct AttributedObservation: Hashable, Equatable {
        let kind: String
        let childDeviceID: String
        let source: String
        let credentialKind: String
        let credentialID: String
    }

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
        let phase3Cases: [VectorCase]
        let phase4Cases: [VectorCase]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case generationCases = "generation_cases"
            case callbackCases = "callback_cases"
            case gateCases = "gate_cases"
            case ledgerCases = "ledger_cases"
            case manualCases = "manual_cases"
            case protocolCases = "protocol_cases"
            case perAppOrderingCases = "per_app_ordering_cases"
            case phase3Cases = "phase3_cases"
            case phase4Cases = "phase4_cases"
        }

        var allCases: [VectorCase] {
            generationCases + callbackCases + gateCases + ledgerCases + manualCases
                + protocolCases + perAppOrderingCases
                + phase3Cases
                + phase4Cases
        }
    }

    private static let expectedGroupIDs: [(String, [String])] = [
        ("generation_cases", ["V01", "V02", "V03", "V07"]),
        ("callback_cases", ["V04", "V05", "V06", "V08", "V13"]),
        ("gate_cases", ["V09", "V10", "V11", "V12", "V21", "V22"]),
        ("ledger_cases", ["V14", "V15", "V16", "V17"]),
        ("manual_cases", ["V18"]),
        ("protocol_cases", ["V19", "V20"]),
        ("per_app_ordering_cases", ["V23"]),
        ("phase3_cases", (24...39).map { String(format: "V%02d", $0) }),
        ("phase4_cases", (1...20).map { String(format: "P4V%02d", $0) })
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
        "V23": "per_app_ordering",
        "V24": "phase3_eight_date_horizon", "V25": "phase3_coverage_exhaustion",
        "V26": "phase3_excessive_activities", "V27": "phase3_route_rejection",
        "V28": "phase3_install_claim_race", "V29": "phase3_recovery_envelopes",
        "V30": "phase3_v30_real_route", "V31": "phase3_task_pause_cas",
        "V32": "phase3_authoritative_base_correction", "V33": "phase3_install_lease",
        "V34": "phase3_retry_schedule", "V35": "phase3_tombstone_retention",
        "V36": "phase3_all_source_merge", "V37": "phase3_gate_resume_conservative",
        "V38": "phase3_legacy_migration", "V39": "phase3_v30_artifact_contract",
        "P4V01": "newer_set", "P4V02": "older_set", "P4V03": "newer_clear",
        "P4V04": "old_set_after_clear", "P4V05": "equal_applied_set",
        "P4V06": "equal_applied_clear", "P4V07": "equal_nse_pending",
        "P4V08": "equal_token_conflict", "P4V09": "convergent_ingest",
        "P4V10": "progress_stable", "P4V11": "no_past_activity",
        "P4V12": "impossible_callback", "P4V13": "delayed_callback",
        "P4V14": "late_callback", "P4V15": "paused_callback",
        "P4V16": "conservative_resume", "P4V17": "restart_preserves_ignored",
        "P4V18": "readback_current", "P4V19": "wrong_provenance",
        "P4V20": "per_app_exhaustion"
    ]

    private static let effectKeys: Set<String> = [
        "local_estimate_mutations", "retry_enqueues", "network_dispatches",
        "backend_sample_rows", "ledger_mutations", "notifications",
        "shield_mutations", "monitor_starts", "monitor_stops", "epoch_replacements"
    ]

    private static let phase3EffectKeys = effectKeys.union([
        "route_state_mutations", "coverage_mutations", "queue_mutations",
        "bank_mutations", "lock_ledger_mutations", "retry_order_mutations"
    ])

    private static let phase4EffectKeys: Set<String> = [
        "local_accepted_estimate_mutations", "retry_queue_mutations", "network_requests",
        "backend_sample_rows", "backend_ledger_mutations", "per_app_ledger_mutations",
        "device_total_ledger_mutations", "shared_pool_ledger_mutations", "notifications",
        "shield_source_mutations", "schedule_arms", "schedule_stops", "command_work_mutations",
        "tombstone_mutations", "applied_receipt_mutations"
    ]

    private static let observationKeys: Set<String> = [
        "kind", "child_device_id", "source", "credential_kind", "credential_id"
    ]

    private static let rootKeys: Set<String> = [
        "schema_version", "generation_cases", "callback_cases", "gate_cases",
        "ledger_cases", "manual_cases", "protocol_cases", "per_app_ordering_cases", "phase3_cases",
        "phase4_cases"
    ]

    private static let caseKeys: Set<String> = ["id", "description", "input", "expected"]

    // Canonical order: kind, child device, source, credential kind, credential ID.
    private static let allowedObservationKinds: Set<String> = ["ledger", "receipt", "shield"]
    private static let observationSortFields = [
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
        XCTAssertEqual(
            allIDs,
            ((1...39).map { String(format: "V%02d", $0) }
                + (1...20).map { String(format: "P4V%02d", $0) }).sorted()
        )
        XCTAssertEqual(Set(allIDs).count, 59)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: sourceData) as? JSONObject)
        XCTAssertEqual(Set(root.keys), Self.rootKeys, "fixture root keys")
        for (group, expectedIDs) in Self.expectedGroupIDs {
            let cases = try XCTUnwrap(root[group] as? [JSONObject], "missing \(group)")
            XCTAssertEqual(cases.map { $0["id"] as? String }, expectedIDs, "\(group) IDs")
            for vector in cases {
                XCTAssertEqual(Set(vector.keys), Self.caseKeys, "\(group) case keys")
                let id = try XCTUnwrap(vector["id"] as? String)
                let input = try XCTUnwrap(vector["input"] as? JSONObject, "\(id) input")
                XCTAssertEqual(input["kind"] as? String, Self.expectedInputKinds[id], "\(id) input.kind")
                let expected = try XCTUnwrap(vector["expected"] as? JSONObject, "\(id) expected")
                let effects = try XCTUnwrap(expected["effects"] as? JSONObject, "\(id) effects")
                XCTAssertEqual(
                    Set(effects.keys),
                    group == "phase3_cases" ? Self.phase3EffectKeys
                        : group == "phase4_cases" ? Self.phase4EffectKeys : Self.effectKeys,
                    "\(id) effects keys"
                )
            }
        }

        let ledgerCases = try XCTUnwrap(root["ledger_cases"] as? [JSONObject])
        for vector in ledgerCases {
            let id = try XCTUnwrap(vector["id"] as? String)
            let expected = try XCTUnwrap(vector["expected"] as? JSONObject)
            let observations = try XCTUnwrap(expected["attributed_observations"] as? [JSONObject], "\(id) observations")
            XCTAssertFalse(observations.isEmpty, "\(id) observations")
            XCTAssertEqual(expected["attributed_observations_sort"] as? [String], Self.observationSortFields, "\(id) attributed_observations_sort fields")
            let actual = try observations.map { try observation(from: $0, vectorID: id) }
            XCTAssertTrue(actual.allSatisfy { Self.allowedObservationKinds.contains($0.kind) }, "\(id) allowed observation kinds")
            XCTAssertEqual(Set(actual).count, actual.count, "\(id) duplicate observations")
            XCTAssertEqual(actual, sortObservations(actual), "\(id) attributed_observations_sort")

            let derived = try observationsDerivedSolelyFromTypedInput(vector, vectorID: id)
            XCTAssertEqual(actual.count, derived.count, "\(id) attributed observation count")
            XCTAssertEqual(actual, derived, "\(id) attributed observation membership")
        }
    }

    private func observation(from value: JSONObject, vectorID: String) throws -> AttributedObservation {
        XCTAssertEqual(Set(value.keys), Self.observationKeys, "\(vectorID) observation keys")
        return AttributedObservation(
            kind: try XCTUnwrap(value["kind"] as? String, "\(vectorID) observation.kind"),
            childDeviceID: try XCTUnwrap(value["child_device_id"] as? String, "\(vectorID) observation.child_device_id"),
            source: try XCTUnwrap(value["source"] as? String, "\(vectorID) observation.source"),
            credentialKind: try XCTUnwrap(value["credential_kind"] as? String, "\(vectorID) observation.credential_kind"),
            credentialID: try XCTUnwrap(value["credential_id"] as? String, "\(vectorID) observation.credential_id")
        )
    }

    private func observationsDerivedSolelyFromTypedInput(_ vector: JSONObject, vectorID: String) throws -> [AttributedObservation] {
        let input = try XCTUnwrap(vector["input"] as? JSONObject)
        let kind = try XCTUnwrap(input["kind"] as? String)

        switch kind {
        case "ledger_device_attribution":
            let accepted = try XCTUnwrap(input["accepted"] as? JSONObject)
            _ = try XCTUnwrap(input["sibling_child_device_id"] as? String, "\(vectorID) sibling_child_device_id")
            return sortObservations([try ledgerObservation(from: accepted, vectorID: vectorID)])

        case "ledger_device_cap":
            let accepted = try XCTUnwrap(input["accepted"] as? JSONObject)
            let enforcementSets = try XCTUnwrap(input["enforcement_sets"] as? [JSONObject], "\(vectorID) enforcement_sets")
            let acceptedChildDeviceID = try XCTUnwrap(accepted["child_device_id"] as? String, "\(vectorID) accepted.child_device_id")
            let matchingSets = enforcementSets.filter { $0["child_device_id"] as? String == acceptedChildDeviceID }
            XCTAssertEqual(matchingSets.count, 1, "\(vectorID) accepted enforcement set")
            let enforcementSet = try XCTUnwrap(matchingSets.first, "\(vectorID) accepted enforcement set")
            let setObservation = try enforcementSetObservation(from: enforcementSet, source: accepted["source"] as? String, vectorID: vectorID)
            return sortObservations([
                try ledgerObservation(from: accepted, vectorID: vectorID),
                observation(kind: "receipt", from: setObservation),
                observation(kind: "shield", from: setObservation)
            ])

        case "ledger_shared_exhaustion":
            let accepted = try XCTUnwrap(input["accepted"] as? JSONObject)
            let devices = try XCTUnwrap(input["devices"] as? [JSONObject], "\(vectorID) devices")
            XCTAssertEqual(devices.count, 2, "\(vectorID) exhaustion devices")
            let source = try XCTUnwrap(accepted["source"] as? String, "\(vectorID) accepted.source")
            let setObservations = try devices.map { try enforcementSetObservation(from: $0, source: source, vectorID: vectorID) }
            var derived = [try ledgerObservation(from: accepted, vectorID: vectorID)]
            for setObservation in setObservations {
                derived.append(observation(kind: "receipt", from: setObservation))
                derived.append(observation(kind: "shield", from: setObservation))
            }
            return sortObservations(derived)

        case "ledger_per_app_limit":
            let rule = try XCTUnwrap(input["reached_rule"] as? JSONObject, "\(vectorID) reached_rule")
            _ = try XCTUnwrap(input["unrelated_rules"] as? [JSONObject], "\(vectorID) unrelated_rules")
            let ruleObservation = try appLimitRuleObservation(from: rule, vectorID: vectorID)
            return sortObservations([
                observation(kind: "ledger", from: ruleObservation),
                observation(kind: "receipt", from: ruleObservation),
                observation(kind: "shield", from: ruleObservation)
            ])

        default:
            XCTFail("\(vectorID) unsupported ledger input.kind \(kind)")
            return []
        }
    }

    private func ledgerObservation(from accepted: JSONObject, vectorID: String) throws -> AttributedObservation {
        let credential = try XCTUnwrap(accepted["credential"] as? JSONObject, "\(vectorID) accepted.credential")
        let credentialKind = try XCTUnwrap(credential["kind"] as? String, "\(vectorID) accepted.credential.kind")
        XCTAssertEqual(credentialKind, "epoch", "\(vectorID) accepted credential kind")
        let source = try XCTUnwrap(accepted["source"] as? String, "\(vectorID) accepted.source")
        XCTAssertEqual(source, "earned_time", "\(vectorID) accepted source")
        return AttributedObservation(
            kind: "ledger",
            childDeviceID: try XCTUnwrap(accepted["child_device_id"] as? String, "\(vectorID) accepted.child_device_id"),
            source: source,
            credentialKind: credentialKind,
            credentialID: try XCTUnwrap(credential["id"] as? String, "\(vectorID) accepted.credential.id")
        )
    }

    private func enforcementSetObservation(from set: JSONObject, source: String?, vectorID: String) throws -> AttributedObservation {
        let credential = try XCTUnwrap(set["credential"] as? JSONObject, "\(vectorID) enforcement set credential")
        let credentialKind = try XCTUnwrap(credential["kind"] as? String, "\(vectorID) enforcement set credential.kind")
        XCTAssertEqual(credentialKind, "enforcement_set", "\(vectorID) enforcement set credential kind")
        return AttributedObservation(
            kind: "enforcement_set",
            childDeviceID: try XCTUnwrap(set["child_device_id"] as? String, "\(vectorID) enforcement set child_device_id"),
            source: try XCTUnwrap(source, "\(vectorID) accepted.source"),
            credentialKind: credentialKind,
            credentialID: try XCTUnwrap(credential["id"] as? String, "\(vectorID) enforcement set credential.id")
        )
    }

    private func appLimitRuleObservation(from rule: JSONObject, vectorID: String) throws -> AttributedObservation {
        let credential = try XCTUnwrap(rule["credential"] as? JSONObject, "\(vectorID) rule credential")
        let credentialKind = try XCTUnwrap(credential["kind"] as? String, "\(vectorID) rule credential.kind")
        XCTAssertEqual(credentialKind, "app_limit_rule", "\(vectorID) rule credential kind")
        let source = try XCTUnwrap(rule["source"] as? String, "\(vectorID) rule source")
        XCTAssertEqual(source, "limit", "\(vectorID) rule source")
        return AttributedObservation(
            kind: "app_limit_rule",
            childDeviceID: try XCTUnwrap(rule["child_device_id"] as? String, "\(vectorID) rule child_device_id"),
            source: source,
            credentialKind: credentialKind,
            credentialID: try XCTUnwrap(credential["id"] as? String, "\(vectorID) rule credential.id")
        )
    }

    private func observation(kind: String, from identity: AttributedObservation) -> AttributedObservation {
        AttributedObservation(
            kind: kind,
            childDeviceID: identity.childDeviceID,
            source: identity.source,
            credentialKind: identity.credentialKind,
            credentialID: identity.credentialID
        )
    }

    private func sortObservations(_ observations: [AttributedObservation]) -> [AttributedObservation] {
        observations.sorted {
            [$0.kind, $0.childDeviceID, $0.source, $0.credentialKind, $0.credentialID]
                .lexicographicallyPrecedes([$1.kind, $1.childDeviceID, $1.source, $1.credentialKind, $1.credentialID])
        }
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
