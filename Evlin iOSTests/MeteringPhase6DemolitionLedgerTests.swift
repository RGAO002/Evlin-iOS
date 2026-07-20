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

    func testT6PendingOneRelease() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == "T6" })

        XCTAssertEqual(row["status"] as? String, "PENDING_ONE_RELEASE")
        XCTAssertEqual(
            try XCTUnwrap(row["replacement_commits"] as? [[String: String]]),
            [
                ["repository": "backend", "sha": "2406a4e080a21996afc242505164954134df8e5e"],
                ["repository": "ios", "sha": "b219eb732a3ef783ef59b8a027513a743fe03c76"],
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(row["vectors"] as? [String]),
            [
                "T6V01-missing-active",
                "T6V02-known-disabled",
                "T6V03-unknown-active",
                "T6V04-protocol1-active",
                "T6V05-v2-observe-no-mutation",
                "T6V06-late-chunk-noop",
                "T6V07-active-disabled-active",
                "T6V08-v2-recovery-independent",
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(row["evidence"] as? [[String: String]]),
            [
                [
                    "path": "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/.superpowers/evidence/metering-phase6/T6-backend-observation.log",
                    "sha256": "3ed7a1f1bbc9e73fbbaf559005c5aa3638c421665bb082ca747d25505627cf2e",
                ],
                [
                    "path": "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/.superpowers/evidence/metering-phase6/T6-ios-observation.log",
                    "sha256": "dde4fac269dcae62ec3201369ee1b8487e0ea8da4ece40cbeb4d37847b1c31a7",
                ],
            ]
        )
        XCTAssertTrue(row["demolition_commit"] is NSNull)
        XCTAssertTrue(row["revert_command"] is NSNull)

        let observation = try XCTUnwrap(row["release_observation"] as? [String: Any])
        for key in [
            "release_id", "started_at", "ended_at", "eligible_devices",
            "legacy_callbacks_after_disable", "earned_runtime_failures", "evidence_sha256",
        ] {
            XCTAssertTrue(observation[key] is NSNull, key)
        }
    }

    func testT7Attestation() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == "T7" })

        XCTAssertEqual(row["status"] as? String, "REMOVED")
        XCTAssertEqual(
            Set(try XCTUnwrap(row["vectors"] as? [String])),
            Set(["V06", "V10", "V11", "V12", "V33", "V34", "V37"])
        )
        XCTAssertEqual(
            try XCTUnwrap(row["replacement_commits"] as? [[String: String]]),
            [
                ["repository": "ios", "sha": "04d2beb09feae0a8546963b157c439f71075ba5f"],
                ["repository": "ios", "sha": "bbf83a7eb096fde2a3a7bbd81507a8f81e2d6084"],
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(row["evidence"] as? [[String: String]]),
            [[
                "path": "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/.superpowers/evidence/metering-phase6/T7-focused.log",
                "sha256": "78a21a0189cf350361e1ba916d477427f7e5726d2d77eb187930dfa05da4972d",
            ]]
        )
        let demolition = try XCTUnwrap(row["demolition_commit"] as? [String: String])
        XCTAssertEqual(demolition, [
            "repository": "ios",
            "sha": "21269f5bb83b5a990decef60402e653fb7d91464",
        ])
        XCTAssertEqual(
            row["revert_command"] as? String,
            "git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS revert 21269f5bb83b5a990decef60402e653fb7d91464"
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(row["forbidden_symbols"] as? [String])),
            Set([
                ["counter", "Recovery", "Required"].joined(),
                ["pending", "Uncounted", "Reconciliation"].joined(),
                ["requires", "Counter", "Recovery"].joined(),
                ["allow", "Same", "Day", "Decrease"].joined(),
                ["rearm", "Usage", "Counters", "Result"].joined(),
            ])
        )
    }
}
