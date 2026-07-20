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
}
