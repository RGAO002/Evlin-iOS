import Foundation
import XCTest
@testable import Evlin_iOS

/// The recorder must not erase its own evidence.
///
/// Field evidence (iPhone, 2026-07-25): three install work items each re-recorded
/// `installer.install deferred:registrationRequired` every ~3 s — ~6 lines a
/// second — and filled all 2000 ring-buffer slots in 5.5 minutes. The
/// day-rollover yield and the tombstoning of a healthy route were pushed out
/// before anyone could read them.
final class MeteringFlightRecorderSuppressionTests: XCTestCase {

    private let window: TimeInterval = 60
    private let start = Date(timeIntervalSince1970: 1_784_937_600)

    private func makeSuppressor() -> MeteringFlightRecorderSuppressor {
        MeteringFlightRecorderSuppressor(window: window)
    }

    /// The exact observed line, so the test tracks the real payload shape.
    private func deferredInstall(
        work: String = "87A3142D",
        attempts: Int = 0,
        corrID: UUID
    ) -> ScreenTimeEvent {
        ScreenTimeEvent(
            ts: ISO8601DateFormatter().string(from: start),
            emitter: .kidExtension,
            deviceID: nil,
            dayKey: nil,
            kind: .meteringWork,
            source: .earnedPool,
            app: "installer.install work=\(work) attempts=\(attempts)",
            reason: "deferred:registrationRequired",
            nums: ScreenTimeEvent.Nums(count: attempts),
            transition: nil,
            policyGen: nil,
            corrID: corrID.uuidString
        )
    }

    // MARK: - The flood

    /// 6 lines/second for 6 minutes is what filled the buffer. The same traffic
    /// must now cost a handful of lines, and the first one must still be
    /// immediate — a loop that is suppressed from its very first occurrence is
    /// invisible.
    func testASixMinuteFloodCostsAHandfulOfLinesNotTwoThousand() {
        let suppressor = makeSuppressor()
        let corrID = UUID()
        var written: [ScreenTimeEvent] = []

        // 6 minutes at ~6 events/second, the observed rate.
        for tick in 0..<2160 {
            let now = start.addingTimeInterval(Double(tick) / 6.0)
            written += suppressor.admit(deferredInstall(corrID: corrID), now: now)
        }

        XCTAssertEqual(written.count, 6, "one line per 60-second window")
        XCTAssertLessThan(
            written.count, ScreenTimeEventLog.cap / 100,
            "a single stuck loop must not be able to reach the buffer cap"
        )
        // First occurrence: verbatim, no annotation.
        XCTAssertEqual(written.first?.app?.contains("repeat="), false)
        // Every later line accounts for what it stands for.
        XCTAssertEqual(written.dropFirst().allSatisfy {
            $0.app?.contains("repeat=") == true
        }, true)
    }

    /// The counts must be honest: everything collapsed is accounted for.
    func testCollapsedOccurrencesAreCountedExactly() {
        let suppressor = makeSuppressor()
        let corrID = UUID()
        var written: [ScreenTimeEvent] = []

        // 1 immediate + 9 collapsed inside the window.
        for tick in 0..<10 {
            written += suppressor.admit(
                deferredInstall(corrID: corrID),
                now: start.addingTimeInterval(Double(tick))
            )
        }
        XCTAssertEqual(written.count, 1)

        // The occurrence that closes the window stands for all 10 of them.
        written += suppressor.admit(
            deferredInstall(corrID: corrID),
            now: start.addingTimeInterval(window)
        )
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written.last?.app?.contains("repeat=10"), true)
    }

    /// A burst that simply stops must still have its tail counted, not silently
    /// dropped, as soon as anything else is recorded.
    func testATailSummaryIsWrittenWhenTheBurstStops() {
        let suppressor = makeSuppressor()
        let noisy = UUID()
        var written: [ScreenTimeEvent] = []

        for tick in 0..<5 {
            written += suppressor.admit(
                deferredInstall(corrID: noisy),
                now: start.addingTimeInterval(Double(tick))
            )
        }
        XCTAssertEqual(written.count, 1)

        // The burst has stopped; an unrelated event arrives after the window.
        written += suppressor.admit(
            deferredInstall(corrID: UUID()),
            now: start.addingTimeInterval(window + 1)
        )
        XCTAssertEqual(written.count, 3, "the tail summary plus the new line")
        XCTAssertEqual(
            written.contains { $0.app?.contains("repeat=4") == true }, true,
            "the four collapsed occurrences must be accounted for"
        )
    }

    // MARK: - What must never be suppressed

    /// Errors explain failures. Losing the tenth identical error because of the
    /// first nine is exactly the trade this must not make.
    func testErrorEventsAreNeverSuppressed() {
        let suppressor = makeSuppressor()
        let corrID = UUID()
        var written: [ScreenTimeEvent] = []
        for tick in 0..<50 {
            var event = deferredInstall(corrID: corrID)
            event.kind = .meteringError
            written += suppressor.admit(event, now: start.addingTimeInterval(Double(tick)))
        }
        XCTAssertEqual(written.count, 50)
    }

    /// A state jump is by definition news, however often the same jump recurs.
    func testEventsCarryingATransitionAreNeverSuppressed() {
        let suppressor = makeSuppressor()
        let corrID = UUID()
        var written: [ScreenTimeEvent] = []
        for tick in 0..<50 {
            var event = deferredInstall(corrID: corrID)
            event.transition = ScreenTimeEvent.Transition(before: "a", after: "b")
            written += suppressor.admit(event, now: start.addingTimeInterval(Double(tick)))
        }
        XCTAssertEqual(written.count, 50)
    }

    /// Content that changes is content worth keeping — an attempt counter
    /// ticking up is the difference between "stuck" and "progressing".
    func testChangedContentIsAlwaysWrittenImmediately() {
        let suppressor = makeSuppressor()
        let corrID = UUID()
        var written: [ScreenTimeEvent] = []
        for attempts in 0..<20 {
            written += suppressor.admit(
                deferredInstall(attempts: attempts, corrID: corrID),
                now: start.addingTimeInterval(Double(attempts))
            )
        }
        XCTAssertEqual(written.count, 20)
    }

    /// The observed flood was three work items interleaved. Treating them as one
    /// stream would have suppressed nothing at all (each event differs from the
    /// last), so runs must be tracked per content, not as a single slot.
    func testInterleavedWorkItemsAreSuppressedIndependently() {
        let suppressor = makeSuppressor()
        let corrIDs = [UUID(), UUID(), UUID()]
        var written: [ScreenTimeEvent] = []

        for tick in 0..<300 {
            let now = start.addingTimeInterval(Double(tick) / 3.0)
            written += suppressor.admit(
                deferredInstall(corrID: corrIDs[tick % 3]),
                now: now
            )
        }
        // 100 seconds of traffic: one immediate line each, plus one
        // window-closing line each.
        XCTAssertEqual(written.count, 6)
        for corrID in corrIDs {
            XCTAssertEqual(
                written.filter { $0.corrID == corrID.uuidString }.count, 2,
                "each work item keeps its own run"
            )
        }
    }

    /// Bookkeeping is bounded — a pathological producer of unique lines must not
    /// grow the tracking table without limit (and never suppresses anyway).
    func testUniqueEventsAreAllWrittenAndDoNotGrowTheTableUnbounded() {
        let suppressor = makeSuppressor()
        var written: [ScreenTimeEvent] = []
        let count = MeteringFlightRecorderSuppressor.maxTrackedRuns * 4
        for tick in 0..<count {
            written += suppressor.admit(
                deferredInstall(work: "W\(tick)", corrID: UUID()),
                now: start.addingTimeInterval(Double(tick))
            )
        }
        XCTAssertEqual(written.count, count, "unique content is never collapsed")
    }
}
