import Foundation
import XCTest
@testable import Evlin_iOS

private struct MeteringGoldenVectorCase<Input: Decodable, Observation: Decodable>: Decodable {
    let id: String
    let description: String
    let input: Input
    let expected: Observation
}

private struct MeteringManualFixtureInput: Decodable {
    struct Command: Decodable {
        let at: Int
        let manual: ManualSourceAction
    }

    let kind: String
    let meteringStateBytesBase64: String
    let commands: [Command]
}

private struct MeteringManualFixtureObservation: Decodable, Equatable {
    let manualStates: [String]
    let meteringStateBytesBase64: String
    let effects: MeteringEffects
}

private typealias MeteringManualFixtureCase = MeteringGoldenVectorCase<
    MeteringManualFixtureInput,
    MeteringManualFixtureObservation
>

private struct MeteringGoldenVectorSuite: Decodable {
    let schemaVersion: Int
    let generationCases: [MeteringGoldenVectorCase<GenerationInput, GenerationObservation>]
    let callbackCases: [MeteringGoldenVectorCase<CallbackVectorInput, CallbackObservation>]
    let gateCases: [MeteringGoldenVectorCase<GateInput, GateObservation>]
    let ledgerCases: [MeteringGoldenVectorCase<LedgerInput, LedgerObservation>]
    let manualCases: [MeteringManualFixtureCase]
    let protocolCases: [MeteringGoldenVectorCase<ProtocolInput, ProtocolObservation>]
    let perAppOrderingCases: [MeteringGoldenVectorCase<PerAppOrderingInput, PerAppOrderingObservation>]
}

final class MeteringEpochGoldenVectorTests: XCTestCase {
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
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/metering_epoch_vectors.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            MeteringGoldenVectorSuite.self,
            from: Data(contentsOf: fixtureURL)
        )
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

        XCTAssertEqual(suite.schemaVersion, 1)
        XCTAssertEqual(
            executedIDs.sorted(),
            (1...23).map { String(format: "V%02d", $0) }
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

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Evlin iOS/Services/MeteringEpochContract.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for forbidden in [
            "MeteringGoldenVectorSuite", "MeteringGoldenVectorCase", "FixtureObservation",
            "expected:", "\"V01\"", "\"V23\"", "metering_epoch_vectors.json"
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

    private func decodeFixtureJSON<Value: Decodable>(_ json: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Value.self, from: Data(json.utf8))
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
