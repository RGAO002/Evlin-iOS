import XCTest
@testable import Evlin_iOS

@MainActor
final class AutomaticLockNoticeTests: XCTestCase {
    func test_manualOnly_hasNoAutomaticNotice() {
        XCTAssertNil(AutomaticLockNotice.make(
            coveringSources: ["manual"],
            exhausted: false,
            overrideActive: false,
            usageDate: nil
        ))
    }

    func test_exhausted_hasSeparateOverrideAction_evenBeforeLockReceiptArrives() {
        XCTAssertEqual(
            AutomaticLockNotice.make(
                coveringSources: [],
                exhausted: true,
                overrideActive: false,
                usageDate: "2026-07-15"
            ),
            AutomaticLockNotice(
                kind: .earnedTime,
                systemImage: "hourglass.bottomhalf.filled",
                message: "Screen time is used up for today.",
                actionTitle: "Override today",
                action: .overrideEarnedTime(usageDate: "2026-07-15")
            )
        )
    }

    func test_automaticSourceAliases_mapWithoutAffectingManualState() {
        XCTAssertEqual(
            AutomaticLockNotice.make(
                coveringSources: ["manual", "task_pause"],
                exhausted: false,
                overrideActive: false,
                usageDate: nil
            )?.kind,
            .taskPause
        )
        XCTAssertEqual(
            AutomaticLockNotice.make(
                coveringSources: ["earnedTime", "earned_pool", "device_cap"],
                exhausted: false,
                overrideActive: false,
                usageDate: nil
            )?.kind,
            .earnedTime
        )

        XCTAssertEqual(
            AutomaticLockNotice.make(
                coveringSources: ["task_pause"],
                exhausted: false,
                overrideActive: false,
                usageDate: nil
            )?.message,
            "Today's tasks are keeping apps locked. Review tasks below."
        )
    }

    func test_overrideAlreadyActive_hasNoSecondAction() {
        let notice = AutomaticLockNotice.make(
            coveringSources: ["earned_time"],
            exhausted: true,
            overrideActive: true,
            usageDate: "2026-07-15"
        )
        XCTAssertEqual(notice?.message, "Screen time override is applying.")
        XCTAssertNil(notice?.action)
    }

    func test_completeCoveringSources_preservesPriorStateUntilEveryDeviceReplies() {
        XCTAssertNil(AutomaticLockNotice.completeCoveringSources(
            expectedDeviceCount: 2,
            coveringSources: [["earned_time"], nil]
        ))
        XCTAssertEqual(
            AutomaticLockNotice.completeCoveringSources(
                expectedDeviceCount: 2,
                coveringSources: [["manual"], ["task_pause"]]
            ),
            ["manual", "task_pause"]
        )
    }

    func test_actionRunner_callsOnlyDedicatedOverrideClosure() async throws {
        let childID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let spy = OverrideCallSpy()

        try await AutomaticLockActionRunner.run(
            action: .overrideEarnedTime(usageDate: "2026-07-15"),
            childProfileID: childID
        ) { id, usageDate in
            await spy.record(id: id, usageDate: usageDate)
        }

        let calls = await spy.calls
        XCTAssertEqual(calls, [.init(childID: childID, usageDate: "2026-07-15")])
    }
}

private actor OverrideCallSpy {
    struct Call: Equatable { let childID: UUID; let usageDate: String }
    private(set) var calls: [Call] = []
    func record(id: UUID, usageDate: String) {
        calls.append(.init(childID: id, usageDate: usageDate))
    }
}
