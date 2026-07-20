import Foundation
import XCTest

final class MeteringPhase6DemolitionLedgerTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var ledgerURL: URL {
        repositoryRoot.appendingPathComponent(
            "docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-demolition.json"
        )
    }

    private var verifierURL: URL {
        repositoryRoot.appendingPathComponent("scripts/verify_metering_phase6_demolition.py")
    }

    func testSeedLedgerContainsEveryRegisteredDemolitionExactlyOnce() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let ids = try rows.map { try XCTUnwrap($0["id"] as? String) }

        XCTAssertEqual(ids.count, 11)
        XCTAssertEqual(Set(ids), Set((1...11).map { "T\($0)" }))
    }

    func testAutomationCannotPreApproveT6OrT10() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: try rows.map {
            (try XCTUnwrap($0["id"] as? String), $0)
        })

        XCTAssertEqual(byID["T6"]?["status"] as? String, "PENDING_ONE_RELEASE")
        XCTAssertEqual(byID["T10"]?["status"] as? String, "PENDING_FRED_APPROVAL")
        XCTAssertTrue(byID["T6"]?["demolition_commit"] is NSNull)
        XCTAssertTrue(byID["T10"]?["demolition_commit"] is NSNull)
        XCTAssertTrue(byID["T6"]?["fred_approval"] is NSNull)
        XCTAssertTrue(byID["T10"]?["fred_approval"] is NSNull)
    }

    func testOtherRowsBeginUnattestedRatherThanClaimingCompletion() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])

        for row in rows where !["T6", "T10"].contains(row["id"] as? String) {
            XCTAssertEqual(row["status"] as? String, "UNATTESTED", row["id"] as? String ?? "missing")
        }
    }

    func testVerifierExposesExecutableFailClosedSelfTest() throws {
        let source = try String(contentsOf: verifierURL, encoding: .utf8)
        for marker in [
            "--allow-unattested", "--final", "--self-test",
            "T6_requires_one_release", "T10_requires_Fred_written_approval",
            "replacement_commit_after_demolition", "forbidden_symbol_present",
        ] {
            XCTAssertTrue(source.contains(marker), marker)
        }
    }

    func testT1Attestation() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == "T1" })

        XCTAssertEqual(row["status"] as? String, "REMOVED")
        XCTAssertEqual(
            Set(try XCTUnwrap(row["vectors"] as? [String])),
            Set(["V01", "V02", "V03", "V06", "V07", "V24", "P3T1-121"])
        )
        let demolition = try XCTUnwrap(row["demolition_commit"] as? [String: String])
        XCTAssertEqual(demolition["repository"], "ios")
        XCTAssertEqual(demolition["sha"]?.count, 40)
        XCTAssertEqual(
            Set(try XCTUnwrap(row["forbidden_symbols"] as? [String])),
            Set([
                ["arm", "Signature"].joined(),
                ["make", "Arm", "Signature"].joined(),
                ["should", "Start", "Monitoring"].joined(),
                ["selection", "Fingerprint"].joined(),
            ])
        )
    }

    func testT2Attestation() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == "T2" })

        XCTAssertEqual(row["status"] as? String, "REMOVED")
        XCTAssertEqual(
            Set(try XCTUnwrap(row["vectors"] as? [String])),
            Set(["V04", "V05", "V08", "V13", "V27"])
        )
        let demolition = try XCTUnwrap(row["demolition_commit"] as? [String: String])
        XCTAssertEqual(demolition["repository"], "ios")
        XCTAssertEqual(demolition["sha"]?.count, 40)
        XCTAssertEqual(
            try XCTUnwrap(row["forbidden_symbols"] as? [String]),
            [["stale", "_ladder", "_drop"].joined()]
        )
    }

    func testT3Attestation() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == "T3" })

        XCTAssertEqual(row["status"] as? String, "REMOVED")
        XCTAssertEqual(
            Set(try XCTUnwrap(row["vectors"] as? [String])),
            Set(["V04", "V05", "V10", "V12", "P3V01"])
        )
        let demolition = try XCTUnwrap(row["demolition_commit"] as? [String: String])
        XCTAssertEqual(demolition["repository"], "ios")
        XCTAssertEqual(demolition["sha"]?.count, 40)
        XCTAssertEqual(
            try XCTUnwrap(row["forbidden_symbols"] as? [String]),
            [["should", "Apply", "Earned", "Shield", "Fresh"].joined()]
        )
    }

    func testT4Attestation() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == "T4" })

        XCTAssertEqual(row["status"] as? String, "REMOVED")
        XCTAssertEqual(
            Set(try XCTUnwrap(row["vectors"] as? [String])),
            Set(["V15", "V16", "P3V01", "P3V02", "P5V08", "P5V09", "P5V10", "P5V12"])
        )
        let replacements = try XCTUnwrap(row["replacement_commits"] as? [[String: String]])
        XCTAssertEqual(replacements.count, 2)
        XCTAssertTrue(replacements.allSatisfy { $0["repository"] == "ios" && $0["sha"]?.count == 40 })
        let demolition = try XCTUnwrap(row["demolition_commit"] as? [String: String])
        XCTAssertEqual(demolition["repository"], "ios")
        XCTAssertEqual(demolition["sha"]?.count, 40)
        XCTAssertEqual(
            try XCTUnwrap(row["forbidden_symbols"] as? [String]),
            [["backend", "Vetoes", "Self", "Lock"].joined()]
        )
    }

    func testT5AndT11Attestation() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let t5 = try XCTUnwrap(rows.first { $0["id"] as? String == "T5" })
        let t11 = try XCTUnwrap(rows.first { $0["id"] as? String == "T11" })

        let expectedVectors = Set(["V04", "V05", "V19", "V30"])
        XCTAssertEqual(t5["status"] as? String, "REMOVED")
        XCTAssertEqual(Set(try XCTUnwrap(t5["vectors"] as? [String])), expectedVectors)
        let t5Demolition = try XCTUnwrap(t5["demolition_commit"] as? [String: String])
        XCTAssertEqual(t5Demolition["repository"], "backend")
        XCTAssertEqual(t5Demolition["sha"], "ff1436de90b7afa9c502bbf64924072d84a85c4c")
        XCTAssertEqual(
            try XCTUnwrap(t5["forbidden_symbols"] as? [String]),
            [["_sample", "_is", "_plausible"].joined()]
        )

        XCTAssertEqual(t11["status"] as? String, "REMOVED")
        XCTAssertEqual(Set(try XCTUnwrap(t11["vectors"] as? [String])), expectedVectors)
        let t11Demolition = try XCTUnwrap(t11["demolition_commit"] as? [String: String])
        XCTAssertEqual(t11Demolition["repository"], "ios")
        XCTAssertEqual(t11Demolition["sha"]?.count, 40)
        XCTAssertEqual(
            Set(try XCTUnwrap(t11["forbidden_symbols"] as? [String])),
            Set([
                ["Earned", "Threshold", "Plausibility"].joined(),
                ["tolerance", "Minutes"].joined(),
            ])
        )
    }
}
