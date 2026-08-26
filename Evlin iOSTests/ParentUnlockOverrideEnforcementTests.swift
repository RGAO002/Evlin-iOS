import Foundation
import XCTest
@testable import Evlin_iOS

final class ParentUnlockOverrideEnforcementTests: XCTestCase {
    private let ownerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_777_255_200)

    func testReflectionRecordAndEffectiveShieldSurviveOverride() {
        let selectedKey = "savedList:BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let reflectionKey = "all:reflection:CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        let selected = makeShield(
            key: selectedKey,
            tier: .savedList,
            sources: [.manual, .earnedTime, .taskPause, .limit]
        )
        let reflection = makeShield(
            key: reflectionKey,
            tier: .allApps,
            appliesToAll: true,
            sources: [.manual]
        )

        let projected = ParentUnlockOverridePolicy.project(
            shields: [selectedKey: selected, reflectionKey: reflection],
            blocks: [:],
            snapshot: activeSnapshot(),
            reflectionActive: true
        )

        XCTAssertNil(projected.shields[selectedKey])
        XCTAssertEqual(projected.shields[reflectionKey], reflection)
        XCTAssertEqual(
            ActiveShieldProjection.make(records: Array(projected.shields.values)).applications,
            .all
        )
    }

    func testOverrideRemovesManualEarnedTaskAndLimitEffects() {
        let manual = makeShield(key: "manual", tier: .exactApp, sources: [.manual])
        let earned = makeShield(key: "earned", tier: .savedList, sources: [.earnedTime])
        let task = makeShield(key: "task", tier: .category, sources: [.taskPause])
        let limit = makeShield(key: "limit", tier: .exactApp, sources: [.limit])
        let future = makeShield(
            key: "future",
            tier: .exactApp,
            sources: [ShieldSource(rawValue: "future-source")]
        )
        let block = makeBlock(bundleID: "com.example.blocked")

        let projected = ParentUnlockOverridePolicy.project(
            shields: [
                manual.recordKey: manual,
                earned.recordKey: earned,
                task.recordKey: task,
                limit.recordKey: limit,
                future.recordKey: future,
            ],
            blocks: [block.bundleID: block],
            snapshot: activeSnapshot(),
            reflectionActive: false
        )

        XCTAssertNil(projected.shields[manual.recordKey])
        XCTAssertNil(projected.shields[earned.recordKey])
        XCTAssertNil(projected.shields[task.recordKey])
        XCTAssertNil(projected.shields[limit.recordKey])
        XCTAssertEqual(projected.shields[future.recordKey], future)
        XCTAssertTrue(projected.blocks.isEmpty)
    }

    func testNoSnapshotLeavesProjectionUnchanged() {
        let shield = makeShield(
            key: "mixed",
            tier: .savedList,
            sources: [.manual, .earnedTime, .taskPause, .limit]
        )
        let block = makeBlock(bundleID: "com.example.blocked")
        let originalShields = [shield.recordKey: shield]
        let originalBlocks = [block.bundleID: block]

        let projected = ParentUnlockOverridePolicy.project(
            shields: originalShields,
            blocks: originalBlocks,
            snapshot: nil,
            reflectionActive: false
        )

        XCTAssertEqual(projected.shields, originalShields)
        XCTAssertEqual(projected.blocks, originalBlocks)
    }

    func testOverrideFiltersEachScopeIndependently() {
        let key = "mixed"
        let record = makeShield(
            key: key,
            tier: .savedList,
            sources: [.manual, .earnedTime, .taskPause, .limit]
        )

        let cases: [(name: String, scope: ParentUnlockOverrideScope, expectedSources: Set<ShieldSource>)] = [
            ("manual", .manual, [.earnedTime, .taskPause, .limit]),
            ("earned_time", .earnedTime, [.manual, .taskPause, .limit]),
            ("task_pause", .taskPause, [.manual, .earnedTime, .limit]),
            ("device_limit", .deviceLimit, [.manual, .earnedTime, .taskPause]),
            ("per_app_limit", .perAppLimit, [.manual, .earnedTime, .taskPause]),
        ]

        for testCase in cases {
            let projected = ParentUnlockOverridePolicy.project(
                shields: [key: record],
                blocks: [:],
                snapshot: activeSnapshot(scopes: [testCase.scope]),
                reflectionActive: false
            )

            XCTAssertEqual(
                projected.shields[key]?.sources,
                testCase.expectedSources,
                testCase.name
            )
        }
    }

    func testEarnedTimeSuppressionDoesNotRequireManualSource() {
        let key = "earned-and-task"
        let record = makeShield(
            key: key,
            tier: .savedList,
            sources: [.earnedTime, .taskPause]
        )

        let projected = ParentUnlockOverridePolicy.project(
            shields: [key: record],
            blocks: [:],
            snapshot: activeSnapshot(scopes: [.earnedTime]),
            reflectionActive: false
        )

        XCTAssertEqual(projected.shields[key]?.sources, [.taskPause])
    }

    func testCancelledAndExpiredSnapshotsLeaveProjectionUnchanged() {
        let shield = makeShield(key: "manual", tier: .exactApp, sources: [.manual])
        let block = makeBlock(bundleID: "com.example.blocked")
        let originalShields = [shield.recordKey: shield]
        let originalBlocks = [block.bundleID: block]

        for status in [
            ParentUnlockOverrideSnapshot.Status.cancelled,
            ParentUnlockOverrideSnapshot.Status.expired,
        ] {
            let snapshot = ParentUnlockOverrideSnapshot(
                envelope: envelope(cancelled: status == .cancelled),
                status: status
            )
            let projected = ParentUnlockOverridePolicy.project(
                shields: originalShields,
                blocks: originalBlocks,
                snapshot: snapshot,
                reflectionActive: false
            )

            XCTAssertEqual(projected.shields, originalShields, "\(status)")
            XCTAssertEqual(projected.blocks, originalBlocks, "\(status)")
        }
    }

    private func activeSnapshot(
        scopes: Set<ParentUnlockOverrideScope> = [
            .manual,
            .earnedTime,
            .taskPause,
            .deviceLimit,
            .perAppLimit,
        ]
    ) -> ParentUnlockOverrideSnapshot {
        ParentUnlockOverrideSnapshot(
            envelope: envelope(scopes: scopes),
            status: .active
        )
    }

    private func envelope(
        scopes: Set<ParentUnlockOverrideScope> = [
            .manual,
            .earnedTime,
            .taskPause,
            .deviceLimit,
            .perAppLimit,
        ],
        cancelled: Bool = false
    ) -> ParentUnlockOverrideEnvelope {
        ParentUnlockOverrideEnvelope(
            revision: 1,
            childDeviceID: ownerID,
            usageDate: "2026-04-26",
            startedAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            operationID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            scopes: scopes,
            cancelled: cancelled
        )
    }

    private func makeShield(
        key: String,
        tier: ShieldTier,
        appliesToAll: Bool = false,
        sources: Set<ShieldSource>
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: key,
            tier: tier,
            targetKey: key,
            displayName: key,
            lastCommandID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: appliesToAll,
            issuedAt: now,
            expiresAt: nil,
            originalRequest: key,
            targetChildID: ownerID,
            sources: sources
        )
    }

    private func makeBlock(bundleID: String) -> BlockRecord {
        BlockRecord(
            bundleID: bundleID,
            displayName: bundleID,
            blockedAt: now,
            lastCommandID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            originalRequest: bundleID,
            targetChildID: ownerID
        )
    }
}
