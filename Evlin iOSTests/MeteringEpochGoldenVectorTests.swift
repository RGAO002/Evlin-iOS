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

    @discardableResult
    private func evaluateGenerationCases(_ suite: MeteringGoldenVectorSuite) -> [String] {
        for testCase in suite.generationCases {
            let actual = MeteringReferenceRules.evaluateGeneration(testCase.input)
            XCTAssertEqual(actual, testCase.expected, testCase.id)

            if testCase.input.kind == .generationReadinessReplacement {
                let reasons = actual.replacementReasons ?? []
                XCTAssertEqual(reasons.count, 7, testCase.id)
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
}
