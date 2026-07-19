import Foundation
import XCTest
@testable import Evlin_iOS

struct MeteringGoldenVectorCase<Input: Decodable, Observation: Decodable>: Decodable {
    let id: String
    let description: String
    let input: Input
    let expected: Observation
}

struct MeteringManualFixtureInput: Decodable {
    struct Command: Decodable {
        let at: Int
        let manual: ManualSourceAction
    }

    let kind: String
    let meteringStateBytesBase64: String
    let commands: [Command]
}

struct MeteringManualFixtureObservation: Decodable, Equatable {
    let manualStates: [String]
    let meteringStateBytesBase64: String
    let effects: MeteringEffects
}

typealias MeteringManualFixtureCase = MeteringGoldenVectorCase<
    MeteringManualFixtureInput,
    MeteringManualFixtureObservation
>

struct MeteringGoldenVectorSuite: Decodable {
    let schemaVersion: Int
    let generationCases: [MeteringGoldenVectorCase<GenerationInput, GenerationObservation>]
    let callbackCases: [MeteringGoldenVectorCase<CallbackVectorInput, CallbackObservation>]
    let gateCases: [MeteringGoldenVectorCase<GateInput, GateObservation>]
    let ledgerCases: [MeteringGoldenVectorCase<LedgerInput, LedgerObservation>]
    let manualCases: [MeteringManualFixtureCase]
    let protocolCases: [MeteringGoldenVectorCase<ProtocolInput, ProtocolObservation>]
    let perAppOrderingCases: [MeteringGoldenVectorCase<PerAppOrderingInput, PerAppOrderingObservation>]
    let phase3Cases: [MeteringGoldenVectorCase<MeteringPhase3Input, MeteringPhase3Observation>]
    let phase4Cases: [MeteringGoldenVectorCase<AppLimitVectorInput, AppLimitVectorObservation>]

    static func load() throws -> MeteringGoldenVectorSuite {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/metering_epoch_vectors.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: Data(contentsOf: fixtureURL))
    }
}

final class MeteringEpochGoldenVectorTests: XCTestCase {
    private typealias JSONObject = [String: Any]

    private static let manualRuleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000018")!
    private static let manualGenerationID = UUID(uuidString: "99999999-0000-0000-0000-000000000018")!
    private static let manualEpochID = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000018")!
    private static let manualRetryID = UUID(uuidString: "abababab-0000-0000-0000-000000000018")!
    private static let ledgerDeviceA = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    private static let ledgerDeviceB = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000002")!
    private static let ledgerEpochID = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000099")!
    private static let ledgerSetID = UUID(uuidString: "cccccccc-0000-0000-0000-000000000099")!
    private static let ledgerSiblingSetID = UUID(uuidString: "cccccccc-0000-0000-0000-000000000199")!
    private static let ledgerRuleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000099")!

    private func loadSuite() throws -> MeteringGoldenVectorSuite {
        try MeteringGoldenVectorSuite.load()
    }

    func testGenerationVectors() throws {
        _ = evaluateGenerationCases(try loadSuite())
    }

    func testCallbackVectors() throws {
        _ = evaluateCallbackCases(try loadSuite())
    }

    func testGateVectors() throws {
        _ = evaluateGateCases(try loadSuite())
    }

    func testLedgerVectors() throws {
        _ = evaluateLedgerCases(try loadSuite())
    }

    func testManualVectors() throws {
        _ = try evaluateManualCases(try loadSuite())
    }

    func testProtocolVectors() throws {
        _ = evaluateProtocolCases(try loadSuite())
    }

    func testPerAppOrderingVectors() throws {
        _ = evaluatePerAppOrderingCases(try loadSuite())
    }

    func testPhase4Vectors() throws {
        _ = evaluatePhase4Cases(try loadSuite())
    }

    func testPhase4TypedInputsRejectMissingRequiredFields() throws {
        let mutations: [(String, [String])] = [
            ("P4V01", ["command"]),
            ("P4V02", ["command"]),
            ("P4V02", ["slot"]),
            ("P4V02", ["slot", "latest_ordering_token"]),
            ("P4V02", ["slot", "latest_kind"]),
            ("P4V02", ["slot", "latest_payload_digest"]),
            ("P4V02", ["slot", "active_rule_present"]),
            ("P4V03", ["command"]),
            ("P4V04", ["slot", "clear_tombstone_present"]),
            ("P4V05", ["slot", "applied_receipt_present"]),
            ("P4V06", ["slot", "latest_kind"]),
            ("P4V07", ["slot", "latest_ordering_token"]),
            ("P4V07", ["slot", "latest_payload_digest"]),
            ("P4V08", ["slot"]),
            ("P4V09", ["command"]),
            ("P4V09", ["permutations"]),
            ("P4V09", ["rule_ids"]),
            ("P4V09", ["work_ids"]),
            ("P4V12", ["physical_time"]),
            ("P4V12", ["physical_time", "raw_threshold_minutes"]),
            ("P4V13", ["physical_time", "started_at"]),
            ("P4V14", ["physical_time", "observed_at"]),
            ("P4V15", ["physical_time", "ignored_while_paused_minutes"]),
            ("P4V15", ["physical_time", "paused"]),
            ("P4V16", ["physical_time"]),
            ("P4V16", ["physical_time", "ignored_while_paused_minutes"]),
            ("P4V17", ["physical_time"]),
            ("P4V18", ["command"]),
            ("P4V18", ["slot"]),
            ("P4V18", ["slot", "latest_ordering_token"]),
            ("P4V18", ["slot", "latest_kind"]),
            ("P4V18", ["slot", "latest_payload_digest"]),
            ("P4V18", ["slot", "active_rule_present"]),
            ("P4V18", ["slot", "applied_receipt_present"]),
            ("P4V18", ["provenance"]),
            ("P4V18", ["provenance", "rule_revision"]),
            ("P4V18", ["provenance", "arm_id"]),
            ("P4V18", ["receipt"]),
            ("P4V18", ["receipt", "rule_id"]),
            ("P4V18", ["receipt", "ordering_token"]),
            ("P4V18", ["receipt", "arm_id"]),
            ("P4V18", ["receipt", "source"]),
            ("P4V19", ["command"]),
            ("P4V19", ["provenance"]),
            ("P4V19", ["provenance", "rule_id"]),
            ("P4V19", ["provenance", "activity_name"]),
            ("P4V19", ["provenance", "event_name"]),
            ("P4V19", ["provenance", "usage_date"]),
            ("P4V19", ["provenance", "ordering_token"]),
            ("P4V20", ["rule_ids"])
        ]

        for (vectorID, path) in mutations {
            let data = try fixtureDataRemovingPhase4InputValue(vectorID: vectorID, path: path)
            XCTAssertThrowsError(
                try decodeFixtureData(data) as MeteringGoldenVectorSuite,
                "\(vectorID) must require input.\(path.joined(separator: "."))"
            )
        }
    }

    func testPhase4WrongProvenanceSeparatesEventAndOrderingTokenValidity() throws {
        let canonicalJSON = try phase4InputJSONObject(vectorID: "P4V19")
        let canonical: AppLimitVectorInput = try decodeFixtureJSONObject(canonicalJSON)

        XCTAssertEqual(canonical.provenance?.orderingToken, 19)
        XCTAssertFalse(MeteringReferenceRules.isAppLimitProvenanceValid(canonical))

        var correctedEventJSON = canonicalJSON
        var correctedProvenance = try XCTUnwrap(correctedEventJSON["provenance"] as? JSONObject)
        correctedProvenance["event_name"] = "evlin.limit.t5"
        correctedEventJSON["provenance"] = correctedProvenance
        let correctedEvent: AppLimitVectorInput = try decodeFixtureJSONObject(correctedEventJSON)
        XCTAssertTrue(MeteringReferenceRules.isAppLimitProvenanceValid(correctedEvent))

        correctedProvenance["ordering_token"] = 20
        correctedEventJSON["provenance"] = correctedProvenance
        let changedToken: AppLimitVectorInput = try decodeFixtureJSONObject(correctedEventJSON)
        XCTAssertFalse(MeteringReferenceRules.isAppLimitProvenanceValid(changedToken))

        correctedProvenance.removeValue(forKey: "ordering_token")
        correctedEventJSON["provenance"] = correctedProvenance
        XCTAssertThrowsError(try decodeFixtureJSONObject(correctedEventJSON) as AppLimitVectorInput)
    }

    func testPhase4ConvergentIngestRequiresCanonicalPermutationSources() throws {
        var inputJSON = try phase4InputJSONObject(vectorID: "P4V09")
        inputJSON["permutations"] = [
            ["source": "poll"],
            ["source": "wake_recovery"],
            ["source": "notification_service_extension"]
        ]

        XCTAssertThrowsError(try decodeFixtureJSONObject(inputJSON) as AppLimitVectorInput)
    }

    func testAllCanonicalVectorIDsExecute() throws {
        let suite = try loadSuite()
        var executedIDs: [String] = []
        executedIDs += evaluateGenerationCases(suite)
        executedIDs += evaluateCallbackCases(suite)
        executedIDs += evaluateGateCases(suite)
        executedIDs += evaluateLedgerCases(suite)
        executedIDs += try evaluateManualCases(suite)
        executedIDs += evaluateProtocolCases(suite)
        executedIDs += evaluatePerAppOrderingCases(suite)
        executedIDs += evaluatePhase4Cases(suite)
        executedIDs += suite.phase3Cases.map { vector in
            XCTAssertEqual(MeteringReferenceRules.evaluatePhase3(vector.input), vector.expected, vector.id)
            return vector.id
        }

        XCTAssertEqual(suite.schemaVersion, 1)
        XCTAssertEqual(
            executedIDs.sorted(),
            ((1...39).map { String(format: "V%02d", $0) }
                + (1...20).map { String(format: "P4V%02d", $0) }).sorted()
        )
    }

    func testProductionEvaluatorsExposeTypedInputOnly() throws {
        let _: (GenerationInput) -> GenerationObservation = MeteringReferenceRules.evaluateGeneration
        let _: (CallbackVectorInput) -> CallbackObservation = MeteringReferenceRules.evaluateCallback
        let _: (GateInput) -> GateObservation = MeteringReferenceRules.evaluateGate
        let _: (LedgerInput) -> LedgerObservation = MeteringReferenceRules.evaluateLedger
        let _: (ManualInput) -> ManualObservation = MeteringReferenceRules.evaluateManual
        let _: (ProtocolInput) -> ProtocolObservation = MeteringReferenceRules.evaluateProtocol
        let _: (PerAppOrderingInput) -> PerAppOrderingObservation = MeteringReferenceRules.evaluatePerAppOrdering
        let _: (MeteringPhase3Input) -> MeteringPhase3Observation = MeteringReferenceRules.evaluatePhase3
        let _: (AppLimitVectorInput) -> AppLimitVectorObservation = MeteringReferenceRules.evaluateAppLimitVector

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Evlin iOS/Services/MeteringEpochContract.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for forbidden in [
            "MeteringGoldenVectorSuite", "MeteringGoldenVectorCase", "FixtureObservation",
            "expected:", "\"V01\"", "\"V39\"", "metering_epoch_vectors.json"
        ] {
            XCTAssertFalse(source.contains(forbidden), "production source contains test-only token \(forbidden)")
        }
    }

    func testPauseResumeCountsOnlyBucketsWhollyOutsidePauseWindow() throws {
        let input: GateInput = try decodeFixtureJSON(
            #"""
            {
              "kind": "gate_pause_resume",
              "pause_at": 100,
              "resume_at": 200,
              "app_process_event": false,
              "buckets": [
                { "start_at": 0, "end_at": 90 },
                { "start_at": 90, "end_at": 100 },
                { "start_at": 100, "end_at": 150 },
                { "start_at": 90, "end_at": 110 },
                { "start_at": 150, "end_at": 210 },
                { "start_at": 200, "end_at": 260 },
                { "start_at": 210, "end_at": 220 },
                { "start_at": 100, "end_at": 200 }
              ]
            }
            """#
        )

        let actual = MeteringReferenceRules.evaluateGate(input)

        XCTAssertEqual(
            actual.countedBuckets,
            [true, true, false, false, false, true, true, false]
        )
        XCTAssertEqual(
            actual.effects,
            MeteringEffects(
                localEstimateMutations: 4,
                networkDispatches: 4,
                backendSampleRows: 4
            )
        )
    }

    func testDeviceCapFansOutOnlyForPositiveBeforeToZeroAfterTransition() {
        let leavesPositive = MeteringReferenceRules.evaluateLedger(
            deviceCapInput(ownRemainingBefore: 5, earnedMinutes: 4)
        )
        let startsAtZero = MeteringReferenceRules.evaluateLedger(
            deviceCapInput(ownRemainingBefore: 0, earnedMinutes: 1)
        )

        for observation in [leavesPositive, startsAtZero] {
            XCTAssertEqual(observation.attributedObservations.map(\.kind), [.ledger])
            XCTAssertEqual(observation.effects.ledgerMutations, 1)
            XCTAssertEqual(observation.effects.notifications, 0)
            XCTAssertEqual(observation.effects.shieldMutations, 0)
        }

        let reachesZero = MeteringReferenceRules.evaluateLedger(
            deviceCapInput(ownRemainingBefore: 5, earnedMinutes: 5)
        )
        XCTAssertEqual(
            reachesZero.attributedObservations.map(\.kind),
            [.ledger, .receipt, .shield]
        )
        XCTAssertEqual(reachesZero.effects.notifications, 1)
        XCTAssertEqual(reachesZero.effects.shieldMutations, 1)

        let negativeUsage = MeteringReferenceRules.evaluateLedger(
            deviceCapInput(ownRemainingBefore: 5, earnedMinutes: -1)
        )
        XCTAssertTrue(negativeUsage.attributedObservations.isEmpty)
        XCTAssertEqual(negativeUsage.effects, MeteringEffects())
    }

    func testCanonicalTimezoneReplacementRejectsSameDateOldEpochCallback() throws {
        let input: GateInput = try decodeFixtureJSON(
            #"""
            {
              "kind": "gate_canonical_timezone_replacement",
              "device_timezone": "Asia/Tokyo",
              "old_canonical_timezone": "UTC",
              "new_canonical_timezone": "America/New_York",
              "at": 1784217600,
              "old_date_bypass_markers": ["2026-07-16"],
              "old_date_override_markers": ["2026-07-16"],
              "old_callback_date": "2026-07-16"
            }
            """#
        )

        let actual = MeteringReferenceRules.evaluateGate(input)

        XCTAssertEqual(actual.projectedCanonicalDate, "2026-07-16")
        XCTAssertEqual(actual.retiredEpochCount, 1)
        XCTAssertEqual(actual.createdEpochCount, 1)
        XCTAssertEqual(actual.oldCallbackAccepted, false)
        XCTAssertEqual(actual.effects.epochReplacements, 1)
        XCTAssertEqual(actual.effects.backendSampleRows, 0)
        XCTAssertEqual(actual.effects.ledgerMutations, 0)
    }

    func testLedgerProjectionClampsNegativeUsageAndSaturatesTotals() {
        let isolated = MeteringEpochContract.projectLedger(
            pool: 10,
            acceptedByDevice: [Self.ledgerDeviceA: -7, Self.ledgerDeviceB: 6],
            caps: [Self.ledgerDeviceA: 10, Self.ledgerDeviceB: 10]
        )
        XCTAssertEqual(isolated.sharedRemainingMinutes, 4)
        XCTAssertEqual(
            isolated.ownRemainingMinutes,
            [Self.ledgerDeviceA: 10, Self.ledgerDeviceB: 4]
        )

        let saturated = MeteringEpochContract.projectLedger(
            pool: .max,
            acceptedByDevice: [Self.ledgerDeviceA: .max, Self.ledgerDeviceB: .max],
            caps: [Self.ledgerDeviceA: .max, Self.ledgerDeviceB: .max]
        )
        XCTAssertEqual(saturated.sharedRemainingMinutes, 0)
        XCTAssertEqual(
            saturated.ownRemainingMinutes,
            [Self.ledgerDeviceA: 0, Self.ledgerDeviceB: 0]
        )
    }

    func testLedgerEvaluatorsRejectNegativeMinutesWithoutOverflowOrFanout() {
        let attribution = MeteringReferenceRules.evaluateLedger(
            LedgerInput(
                kind: .ledgerDeviceAttribution,
                poolMinutes: .max,
                accepted: acceptedUsage(earnedMinutes: -1),
                siblingChildDeviceID: Self.ledgerDeviceB,
                enforcementSets: nil,
                sharedRemainingBeforeMinutes: nil,
                devices: nil,
                reachedRule: nil,
                unrelatedRules: nil
            )
        )
        XCTAssertEqual(attribution.sharedRemainingMinutes, .max)
        XCTAssertEqual(
            attribution.ownRemainingMinutes,
            [Self.ledgerDeviceA: .max, Self.ledgerDeviceB: .max]
        )
        XCTAssertTrue(attribution.attributedObservations.isEmpty)
        XCTAssertEqual(attribution.effects, MeteringEffects())

        let exhaustion = MeteringReferenceRules.evaluateLedger(
            LedgerInput(
                kind: .ledgerSharedExhaustion,
                poolMinutes: nil,
                accepted: acceptedUsage(earnedMinutes: -1),
                siblingChildDeviceID: nil,
                enforcementSets: nil,
                sharedRemainingBeforeMinutes: .max,
                devices: [enforcementTarget()],
                reachedRule: nil,
                unrelatedRules: nil
            )
        )
        XCTAssertEqual(exhaustion.sharedRemainingMinutes, .max)
        XCTAssertTrue(exhaustion.attributedObservations.isEmpty)
        XCTAssertEqual(exhaustion.effects, MeteringEffects())

        let extremeFanout = MeteringReferenceRules.evaluateLedger(
            LedgerInput(
                kind: .ledgerSharedExhaustion,
                poolMinutes: nil,
                accepted: acceptedUsage(earnedMinutes: .max),
                siblingChildDeviceID: nil,
                enforcementSets: nil,
                sharedRemainingBeforeMinutes: .max,
                devices: [
                    enforcementTarget(),
                    enforcementTarget(
                        childDeviceID: Self.ledgerDeviceB,
                        credentialID: Self.ledgerSiblingSetID
                    )
                ],
                reachedRule: nil,
                unrelatedRules: nil
            )
        )
        XCTAssertEqual(extremeFanout.sharedRemainingMinutes, 0)
        XCTAssertEqual(extremeFanout.attributedObservations.count, 5)
        XCTAssertEqual(extremeFanout.effects.ledgerMutations, 1)
        XCTAssertEqual(extremeFanout.effects.notifications, 2)
        XCTAssertEqual(extremeFanout.effects.shieldMutations, 2)

        let negativePerApp = MeteringReferenceRules.evaluateLedger(
            LedgerInput(
                kind: .ledgerPerAppLimit,
                poolMinutes: nil,
                accepted: nil,
                siblingChildDeviceID: nil,
                enforcementSets: nil,
                sharedRemainingBeforeMinutes: nil,
                devices: nil,
                reachedRule: MeteringAppLimitRuleInput(
                    childDeviceID: Self.ledgerDeviceA,
                    source: "limit",
                    credential: MeteringCredentialReference(
                        kind: .appLimitRule,
                        id: Self.ledgerRuleID
                    ),
                    bundleID: "com.example.focus",
                    remainingMinutesBefore: .max,
                    consumedMinutes: -1
                ),
                unrelatedRules: []
            )
        )
        XCTAssertTrue(negativePerApp.attributedObservations.isEmpty)
        XCTAssertEqual(negativePerApp.effects, MeteringEffects())
    }

    func testLedgerObservationRejectsUUIDKeyCaseCollisions() {
        let lower = Self.ledgerDeviceA.uuidString.lowercased()
        let upper = Self.ledgerDeviceA.uuidString.uppercased()
        let json = #"""
        {
          "own_remaining_minutes": { "\#(lower)": 1, "\#(upper)": 2 },
          "attributed_observations_sort": [],
          "attributed_observations": [],
          "effects": {
            "local_estimate_mutations": 0,
            "retry_enqueues": 0,
            "network_dispatches": 0,
            "backend_sample_rows": 0,
            "ledger_mutations": 0,
            "notifications": 0,
            "shield_mutations": 0,
            "monitor_starts": 0,
            "monitor_stops": 0,
            "epoch_replacements": 0
          }
        }
        """#

        XCTAssertThrowsError(try decodeFixtureJSON(json) as LedgerObservation) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
        }
    }

    @discardableResult
    private func evaluateGenerationCases(_ suite: MeteringGoldenVectorSuite) -> [String] {
        for testCase in suite.generationCases {
            let actual = MeteringReferenceRules.evaluateGeneration(testCase.input)
            XCTAssertEqual(actual, testCase.expected, testCase.id)

            if testCase.input.kind == .generationReadinessReplacement {
                let reasons = actual.replacementReasons ?? []
                XCTAssertEqual(reasons.count, 8, testCase.id)
                XCTAssertEqual(
                    Set(reasons),
                    Set(MeteringEpochReplacementReason.allCases.map(\.rawValue)),
                    testCase.id
                )
                XCTAssertThrowsError(
                    try JSONDecoder().decode(
                        MeteringEpochReplacementReason.self,
                        from: Data(#""poll_refresh""#.utf8)
                    )
                )
            }
        }
        return suite.generationCases.map(\.id)
    }

    @discardableResult
    private func evaluateCallbackCases(_ suite: MeteringGoldenVectorSuite) -> [String] {
        for testCase in suite.callbackCases {
            let actual = MeteringReferenceRules.evaluateCallback(testCase.input)
            XCTAssertEqual(actual, testCase.expected, testCase.id)
            if ["V04", "V08", "V13"].contains(testCase.id) {
                XCTAssertEqual(actual.effects, MeteringEffects(), "\(testCase.id) rejected effects")
            }
        }
        return suite.callbackCases.map(\.id)
    }

    @discardableResult
    private func evaluateGateCases(_ suite: MeteringGoldenVectorSuite) -> [String] {
        for testCase in suite.gateCases {
            XCTAssertEqual(
                MeteringReferenceRules.evaluateGate(testCase.input),
                testCase.expected,
                testCase.id
            )
        }
        return suite.gateCases.map(\.id)
    }

    @discardableResult
    private func evaluateLedgerCases(_ suite: MeteringGoldenVectorSuite) -> [String] {
        for testCase in suite.ledgerCases {
            let actual = MeteringReferenceRules.evaluateLedger(testCase.input)
            XCTAssertEqual(actual, testCase.expected, testCase.id)
            XCTAssertEqual(
                actual.attributedObservations,
                testCase.expected.attributedObservations,
                "\(testCase.id) full device/source/credential attribution"
            )
        }
        return suite.ledgerCases.map(\.id)
    }

    @discardableResult
    private func evaluateManualCases(_ suite: MeteringGoldenVectorSuite) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for testCase in suite.manualCases {
            let seed = try XCTUnwrap(Data(base64Encoded: testCase.input.meteringStateBytesBase64))
            XCTAssertFalse(seed.isEmpty, testCase.id)
            var sourceSets = [Self.manualRuleID: Set<String>()]
            let meteringState = MeteringStateSnapshot(
                generationID: Self.manualGenerationID,
                epochID: Self.manualEpochID,
                usageDate: "1970-01-01",
                baseAcceptedMinutes: Int(seed[0]),
                localEstimateMinutes: Int(seed[1]),
                latestRawThresholdMinutes: Int(seed[2]),
                excludedRawMinutes: Int(seed[3]),
                pendingRetryIDs: [Self.manualRetryID],
                monitorArmed: seed[4].isMultiple(of: 2)
            )
            let meteringBytesBefore = try encoder.encode(meteringState)
            var manualStates: [String] = []

            for command in testCase.input.commands {
                _ = command.at
                let input = ManualInput(
                    sourceSets: sourceSets,
                    meteringState: meteringState,
                    action: command.manual
                )
                let actual = MeteringReferenceRules.evaluateManual(input)
                XCTAssertEqual(
                    try encoder.encode(actual.meteringState),
                    meteringBytesBefore,
                    "\(testCase.id) metering snapshot bytes"
                )
                sourceSets = actual.sourceSets
                manualStates.append(
                    sourceSets[Self.manualRuleID, default: []].contains("manual")
                        ? "locked"
                        : "unlocked"
                )
            }

            let actual = MeteringManualFixtureObservation(
                manualStates: manualStates,
                meteringStateBytesBase64: testCase.input.meteringStateBytesBase64,
                effects: MeteringEffects()
            )
            XCTAssertEqual(actual, testCase.expected, testCase.id)
        }
        return suite.manualCases.map(\.id)
    }

    @discardableResult
    private func evaluateProtocolCases(_ suite: MeteringGoldenVectorSuite) -> [String] {
        for testCase in suite.protocolCases {
            XCTAssertEqual(
                MeteringReferenceRules.evaluateProtocol(testCase.input),
                testCase.expected,
                testCase.id
            )
        }
        return suite.protocolCases.map(\.id)
    }

    @discardableResult
    private func evaluatePerAppOrderingCases(_ suite: MeteringGoldenVectorSuite) -> [String] {
        for testCase in suite.perAppOrderingCases {
            let actual = MeteringReferenceRules.evaluatePerAppOrdering(testCase.input)
            XCTAssertEqual(actual, testCase.expected, testCase.id)
            XCTAssertNil(actual.activeRuleID, testCase.id)
            XCTAssertEqual(actual.tombstoneOrderingToken, 3, testCase.id)
        }
        return suite.perAppOrderingCases.map(\.id)
    }

    private func evaluatePhase4Cases(_ suite: MeteringGoldenVectorSuite) -> [String] {
        for testCase in suite.phase4Cases {
            XCTAssertEqual(
                MeteringReferenceRules.evaluateAppLimitVector(testCase.input),
                testCase.expected,
                testCase.id
            )
        }
        return suite.phase4Cases.map(\.id)
    }

    private func decodeFixtureJSON<Value: Decodable>(_ json: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Value.self, from: Data(json.utf8))
    }

    private func decodeFixtureData<Value: Decodable>(_ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Value.self, from: data)
    }

    private func decodeFixtureJSONObject<Value: Decodable>(_ object: JSONObject) throws -> Value {
        try decodeFixtureData(JSONSerialization.data(withJSONObject: object))
    }

    private func phase4InputJSONObject(vectorID: String) throws -> JSONObject {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData()) as? JSONObject
        )
        let cases = try XCTUnwrap(root["phase4_cases"] as? [JSONObject])
        let vector = try XCTUnwrap(cases.first { $0["id"] as? String == vectorID })
        return try XCTUnwrap(vector["input"] as? JSONObject)
    }

    private func fixtureDataRemovingPhase4InputValue(
        vectorID: String,
        path: [String]
    ) throws -> Data {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData()) as? JSONObject
        )
        var cases = try XCTUnwrap(root["phase4_cases"] as? [JSONObject])
        let index = try XCTUnwrap(cases.firstIndex { $0["id"] as? String == vectorID })
        var vector = cases[index]
        let input = try XCTUnwrap(vector["input"] as? JSONObject)
        vector["input"] = removingValue(at: path, from: input)
        cases[index] = vector
        root["phase4_cases"] = cases
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func removingValue(at path: [String], from object: JSONObject) -> JSONObject {
        precondition(!path.isEmpty)
        var result = object
        if path.count == 1 {
            result.removeValue(forKey: path[0])
            return result
        }

        guard var nested = result[path[0]] as? JSONObject else {
            preconditionFailure("missing nested object at \(path[0])")
        }
        nested = removingValue(at: Array(path.dropFirst()), from: nested)
        result[path[0]] = nested
        return result
    }

    private func fixtureData() throws -> Data {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/metering_epoch_vectors.json")
        return try Data(contentsOf: fixtureURL)
    }

    private func acceptedUsage(earnedMinutes: Int) -> MeteringAcceptedUsageInput {
        MeteringAcceptedUsageInput(
            childDeviceID: Self.ledgerDeviceA,
            source: "earned_time",
            credential: MeteringCredentialReference(kind: .epoch, id: Self.ledgerEpochID),
            earnedMinutes: earnedMinutes,
            ownRemainingBeforeMinutes: nil
        )
    }

    private func enforcementTarget(
        childDeviceID: UUID = MeteringEpochGoldenVectorTests.ledgerDeviceA,
        credentialID: UUID = MeteringEpochGoldenVectorTests.ledgerSetID
    ) -> MeteringEnforcementTargetInput {
        MeteringEnforcementTargetInput(
            childDeviceID: childDeviceID,
            credential: MeteringCredentialReference(
                kind: .enforcementSet,
                id: credentialID
            )
        )
    }

    private func deviceCapInput(
        ownRemainingBefore: Int,
        earnedMinutes: Int
    ) -> LedgerInput {
        LedgerInput(
            kind: .ledgerDeviceCap,
            poolMinutes: nil,
            accepted: MeteringAcceptedUsageInput(
                childDeviceID: Self.ledgerDeviceA,
                source: "earned_time",
                credential: MeteringCredentialReference(
                    kind: .epoch,
                    id: Self.ledgerEpochID
                ),
                earnedMinutes: earnedMinutes,
                ownRemainingBeforeMinutes: ownRemainingBefore
            ),
            siblingChildDeviceID: nil,
            enforcementSets: [enforcementTarget()],
            sharedRemainingBeforeMinutes: nil,
            devices: nil,
            reachedRule: nil,
            unrelatedRules: nil
        )
    }
}
