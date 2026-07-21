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

    private var completionReportURL: URL {
        repositoryRoot.appendingPathComponent(
            "docs/superpowers/reports/2026-07-17-metering-epoch-phase-6-completion.md"
        )
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

    func testRowsUseOnlyAttestedOrExplicitlyPendingStates() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])

        for row in rows where !["T6", "T10"].contains(row["id"] as? String) {
            XCTAssertEqual(row["status"] as? String, "REMOVED", row["id"] as? String ?? "missing")
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

    func testT8Attestation() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == "T8" })

        XCTAssertEqual(row["status"] as? String, "REMOVED")
        XCTAssertEqual(
            Set(try XCTUnwrap(row["vectors"] as? [String])),
            Set(["V01", "V08", "V09", "V13", "V21", "V22", "V28", "V36", "V37", "V38"])
        )
        XCTAssertEqual(
            try XCTUnwrap(row["replacement_commits"] as? [[String: String]]),
            [
                ["repository": "ios", "sha": "32010ce010109b582086b67e3e46ce6288b3c96b"],
                ["repository": "ios", "sha": "5d86ef956f1d251d4ee229fc0b37f93751ec2698"],
                ["repository": "ios", "sha": "e0ee6a2aedaa7f7bd3e6b0c03c3e6eb0912f09ee"],
                ["repository": "ios", "sha": "fcb669d3f8677936646bc753a2cdd0028be65cf8"],
                ["repository": "ios", "sha": "b2eb3a41940c8b166d66fdb0a8918c91a0ffee53"],
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(row["evidence"] as? [[String: String]]),
            [[
                "path": "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/.superpowers/evidence/metering-phase6/T8-focused.log",
                "sha256": "0dc558fbac641a9acf2f8069c2be52f273c16ee8f057be866cf514e3af09c846",
            ]]
        )
        XCTAssertEqual(
            try XCTUnwrap(row["demolition_commit"] as? [String: String]),
            [
                "repository": "ios",
                "sha": "ad1e6394d08b6d95ead893589770f16ea67e586c",
            ]
        )
        XCTAssertEqual(
            row["revert_command"] as? String,
            "git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS revert ad1e6394d08b6d95ead893589770f16ea67e586c"
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(row["forbidden_symbols"] as? [String])),
            Set([
                ["Earned", "Activity", "Generation"].joined(),
                ["evlin", "earned", "activityLifecycle"].joined(separator: "."),
                ["evlin", "earned", "activityBreadcrumbs"].joined(separator: "."),
                ["evlin", "earned", "activeActivityName"].joined(separator: "."),
            ])
        )
    }

    func testT9Attestation() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == "T9" })

        XCTAssertEqual(row["status"] as? String, "REMOVED")
        XCTAssertEqual(
            Set(try XCTUnwrap(row["vectors"] as? [String])),
            Set([
                "P3V01", "P3V02", "T9-locked-set-coverage",
                "T9-default-group-authority", "T9-active-lock-source-cas",
                "T9-action-rollback",
            ])
        )
        XCTAssertEqual(
            try XCTUnwrap(row["replacement_commits"] as? [[String: String]]),
            [
                ["repository": "ios", "sha": "45c197c326eb0189161b43ce118e18c4d5ca9b4f"],
                ["repository": "ios", "sha": "8b1f842bbcde393c56f49448dba602243fa6cbc1"],
                ["repository": "ios", "sha": "e1046aacbcc4d654aa062db7c1849ce6bfb60257"],
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(row["evidence"] as? [[String: String]]),
            [[
                "path": "/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS/.superpowers/evidence/metering-phase6/T9-focused.log",
                "sha256": "ef2e836c0037e16feee5fca784c6b1bfdcc12a2349f4764c4f989b8578629972",
            ]]
        )
        XCTAssertEqual(
            try XCTUnwrap(row["demolition_commit"] as? [String: String]),
            [
                "repository": "ios",
                "sha": "2a94762f5088748ae335b4fbbd282693b96e97ad",
            ]
        )
        XCTAssertEqual(
            row["revert_command"] as? String,
            "git -C /Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS revert 2a94762f5088748ae335b4fbbd282693b96e97ad"
        )
        XCTAssertEqual(
            try XCTUnwrap(row["forbidden_symbols"] as? [String]),
            [["locked", "Set", "Token", "Data"].joined()]
        )
    }

    func testFinalReconciliation() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["demolitions"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: try rows.map {
            (try XCTUnwrap($0["id"] as? String), $0)
        })

        for id in ["T1", "T2", "T3", "T4", "T5", "T7", "T8", "T9", "T11"] {
            XCTAssertEqual(byID[id]?["status"] as? String, "REMOVED", id)
        }
        XCTAssertEqual(byID["T6"]?["status"] as? String, "PENDING_ONE_RELEASE")

        let t10 = try XCTUnwrap(byID["T10"])
        XCTAssertEqual(t10["status"] as? String, "PENDING_FRED_APPROVAL")
        XCTAssertEqual(
            Set(try XCTUnwrap(t10["vectors"] as? [String])),
            Set([
                "T10-manual-only-selected-set", "T10-earned-source-survives-manual-unlock",
                "T10-task-reflection-limit-sources-survive", "T10-separate-earned-override",
                "T10-profile-manual-CTA", "T10-C3-home-single-writer",
            ])
        )
        XCTAssertEqual(try XCTUnwrap(t10["evidence"] as? [[String: String]]).count, 2)
        XCTAssertTrue(t10["demolition_commit"] is NSNull)
        XCTAssertTrue(t10["revert_command"] is NSNull)
        XCTAssertTrue(t10["fred_approval"] is NSNull)

        let inventory = try XCTUnwrap(object["earned_guard_inventory"] as? [[String: String]])
        XCTAssertEqual(Set(inventory.compactMap { $0["category"] }), Set([
            "identity_match", "physical_trust", "gate_state",
        ]))
        XCTAssertEqual(Set(inventory.compactMap { $0["symbol"] }), Set([
            "authorizedEarnedGeneration", "physical_threshold_is_trustworthy",
            "usageCountingAllowed", "usage_counting_allowed",
        ]))

        let report = try String(contentsOf: completionReportURL, encoding: .utf8)
        XCTAssertTrue(report.contains(
            "AUTOMATED DEMOLITION READY; T6/T10 PENDING; PHASE 6 INCOMPLETE; NOT RELEASABLE"
        ))
        XCTAssertEqual(report.components(separatedBy: "status_code:").count - 1, 1)
        XCTAssertEqual(report.components(separatedBy: "phase_complete:").count - 1, 1)
        XCTAssertEqual(report.components(separatedBy: "releasable:").count - 1, 1)
        XCTAssertTrue(report.contains("status_code: AUTOMATED_DEMOLITION_READY_PENDING"))
        XCTAssertTrue(report.contains("phase_complete: false"))
        XCTAssertTrue(report.contains("releasable: false"))
    }
}
