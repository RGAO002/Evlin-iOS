#if DEBUG
import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringDaemonDiagnosticJournalTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MeteringDaemonDiagnosticJournalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testJournalKeepsNewestEntriesInSequenceOrder() throws {
        let journal = MeteringDaemonDiagnosticJournal(
            defaults: defaults,
            maximumEntries: 3
        )

        for activity in ["one", "two", "three", "four"] {
            journal.append(fixture(activityName: "evlin.limit.v2.\(activity)"))
        }

        let entries = journal.read()
        XCTAssertEqual(entries.map(\.sequence), [2, 3, 4])
        XCTAssertEqual(entries.map(\.activityName), [
            "evlin.limit.v2.two",
            "evlin.limit.v2.three",
            "evlin.limit.v2.four",
        ])
    }

    func testJournalPersistsAcrossInstancesAndClearRemovesOnlyJournal() {
        defaults.set("keep", forKey: "unrelated")
        MeteringDaemonDiagnosticJournal(defaults: defaults).append(
            fixture(activityName: "evlin.limit.v2.persisted")
        )

        let reopened = MeteringDaemonDiagnosticJournal(defaults: defaults)
        XCTAssertEqual(reopened.read().map(\.activityName), [
            "evlin.limit.v2.persisted",
        ])

        reopened.clear()
        XCTAssertTrue(reopened.read().isEmpty)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }

    func testJournalExportCannotContainRawOpaqueTokenData() throws {
        let journal = MeteringDaemonDiagnosticJournal(defaults: defaults)
        journal.append(fixture(
            activityName: "evlin.limit.v2.privacy",
            message: "apps=1 digest=4f6f"
        ))

        let exported = try XCTUnwrap(String(
            data: journal.exportData(),
            encoding: .utf8
        ))
        XCTAssertFalse(exported.contains("raw-token-fixture"))
        XCTAssertTrue(exported.contains("digest=4f6f"))
    }

    func testConcurrentAppendsAllocateUniqueMonotonicSequences() async {
        let journal = MeteringDaemonDiagnosticJournal(
            defaults: defaults,
            maximumEntries: 100
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    journal.append(self.fixture(
                        activityName: "evlin.limit.v2.\(index)"
                    ))
                }
            }
        }

        let sequences = journal.read().map(\.sequence)
        XCTAssertEqual(sequences, Array(1...40).map(UInt64.init))
        XCTAssertEqual(Set(sequences).count, 40)
    }

    private func fixture(
        activityName: String,
        message: String? = nil
    ) -> MeteringDaemonDiagnosticEntry.Draft {
        MeteringDaemonDiagnosticEntry.Draft(
            timestamp: Date(timeIntervalSince1970: 1_721_600_000),
            process: "app",
            operation: .start,
            activityName: activityName,
            namespace: "per_app_v2",
            armID: nil,
            expected: nil,
            actual: nil,
            result: .success,
            mismatchReasons: [],
            message: message
        )
    }
}
#endif
