import XCTest
@testable import Evlin_iOS

/// The rule is one comparison — `used >= budget` — evaluated on every command
/// that can change either side. These tests pin that it holds in BOTH directions
/// and for BOTH operations, because the defect they replace was direction- and
/// path-specific: lowering worked, raising silently did nothing.
final class AppLimitEnforcementConvergerTests: XCTestCase {

    private let bundleID = "com.toyopagroup.picaboo"

    private func rule(id: UUID = UUID(), budget: Int) -> AppLimitRule {
        AppLimitRule(
            id: id,
            appTokens: [],
            bundleID: bundleID,
            displayName: "Snapchat",
            budgetMinutes: budget,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1440,
                repeats: true,
                timezone: "America/New_York"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )
    }

    private func envelope(
        kind: AppLimitCommandKind,
        rule: AppLimitRule?,
        usedToday: Int?,
        ruleID: UUID = UUID()
    ) -> AppLimitCommandEnvelope {
        AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: rule?.id ?? ruleID,
            orderingToken: 1,
            kind: kind,
            payloadDigest: "d",
            receivedAt: Date(timeIntervalSince1970: 1_000),
            source: .notificationServiceExtension,
            rule: rule,
            authoritativeUsedTodayMinutes: usedToday
        )
    }

    // MARK: The reported bug

    /// Fred, 2026-07-25: Snapchat used 20 min on a 20 min budget (shielded), the
    /// parent raised it to 2 h, and nothing unlocked. The old backend decided on
    /// a TRANSITION and had to guess the prior state; raising went down the
    /// create path, which assumed "was not exhausted", concluded nothing had
    /// changed, and emitted no command at all while the device stayed locked.
    func testRaisingTheBudgetAboveTodaysUsageReleases() {
        let raised = rule(budget: 120)
        let decision = AppLimitEnforcementConverger.decide(
            for: envelope(kind: .set, rule: raised, usedToday: 20),
            bundleID: bundleID
        )
        XCTAssertEqual(
            decision,
            .release(ruleID: raised.id, recordKey: "exactApp:\(bundleID)"),
            "20 of 120 minutes is not exhausted — the shield must be released"
        )
    }

    /// The mirror case, which always worked and must keep working.
    func testLoweringTheBudgetBelowTodaysUsageShields() {
        let lowered = rule(budget: 1)
        let decision = AppLimitEnforcementConverger.decide(
            for: envelope(kind: .set, rule: lowered, usedToday: 20),
            bundleID: bundleID
        )
        XCTAssertEqual(decision, .shield(rule: lowered, usedTodayMinutes: 20))
    }

    /// A NEW rule id every edit is normal (the parent app clears and re-creates),
    /// so the decision may not depend on the id matching anything previous.
    func testDecisionIgnoresRuleIdentityChurn() {
        let first = rule(id: UUID(), budget: 20)
        let second = rule(id: UUID(), budget: 120)
        XCTAssertEqual(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .set, rule: first, usedToday: 20),
                bundleID: bundleID
            ),
            .shield(rule: first, usedTodayMinutes: 20)
        )
        XCTAssertEqual(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .set, rule: second, usedToday: 20),
                bundleID: bundleID
            ),
            .release(ruleID: second.id, recordKey: "exactApp:\(bundleID)"),
            "a fresh rule id must still find the shield the previous rule installed"
        )
    }

    // MARK: Boundaries

    func testExactlyAtBudgetShields() {
        let r = rule(budget: 20)
        XCTAssertEqual(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .set, rule: r, usedToday: 20),
                bundleID: bundleID
            ),
            .shield(rule: r, usedTodayMinutes: 20),
            "the budget is a ceiling the child has reached, not one still to reach"
        )
    }

    func testOneMinuteBelowBudgetReleases() {
        let r = rule(budget: 20)
        XCTAssertEqual(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .set, rule: r, usedToday: 19),
                bundleID: bundleID
            ),
            .release(ruleID: r.id, recordKey: "exactApp:\(bundleID)")
        )
    }

    func testZeroBudgetShieldsEvenWithNoUsage() {
        let r = rule(budget: 0)
        XCTAssertEqual(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .set, rule: r, usedToday: 0),
                bundleID: bundleID
            ),
            .shield(rule: r, usedTodayMinutes: 0),
            "zero minutes allowed is not unlimited"
        )
    }

    // MARK: The toggle — same path, same rule

    func testClearingTheLimitReleases() {
        let ruleID = UUID()
        XCTAssertEqual(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .clear, rule: nil, usedToday: nil, ruleID: ruleID),
                bundleID: bundleID
            ),
            .release(ruleID: ruleID, recordKey: "exactApp:\(bundleID)"),
            "a shield may not outlive the limit that created it"
        )
    }

    /// The toggle and an edit are the same operation to this type: both arrive as
    /// commands and both converge. Clearing releases even when the child is over
    /// budget — the limit that justified the shield no longer exists.
    func testClearingReleasesEvenWhenOverBudget() {
        let ruleID = UUID()
        XCTAssertEqual(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .clear, rule: nil, usedToday: 999, ruleID: ruleID),
                bundleID: bundleID
            ),
            .release(ruleID: ruleID, recordKey: "exactApp:\(bundleID)")
        )
    }

    // MARK: Missing information is never guessed

    /// A `set` with no authoritative usage figure must NOT be read as zero: that
    /// would release a shield the child genuinely earned.
    func testMissingUsageDefersInsteadOfReleasing() {
        let r = rule(budget: 120)
        XCTAssertEqual(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .set, rule: r, usedToday: nil),
                bundleID: bundleID
            ),
            .defer_(reason: "no_authoritative_usage")
        )
    }

    func testClearWithoutBundleDefers() {
        XCTAssertEqual(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .clear, rule: nil, usedToday: nil),
                bundleID: nil
            ),
            .defer_(reason: "clear_without_bundle")
        )
    }

    // MARK: Convergence into the shield map

    func testShieldThenReleaseRoundTrips() {
        let now = Date(timeIntervalSince1970: 5_000)
        let atBudget = rule(budget: 20)
        var shields: [String: ShieldRecord] = [:]

        shields = AppLimitEnforcementConverger.converge(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .set, rule: atBudget, usedToday: 20),
                bundleID: bundleID
            ),
            into: shields,
            now: now
        )
        XCTAssertEqual(shields.count, 1)
        XCTAssertEqual(shields["exactApp:\(bundleID)"]?.sources, [.limit])

        let raised = rule(budget: 120)
        shields = AppLimitEnforcementConverger.converge(
            AppLimitEnforcementConverger.decide(
                for: envelope(kind: .set, rule: raised, usedToday: 20),
                bundleID: bundleID
            ),
            into: shields,
            now: now
        )
        XCTAssertTrue(shields.isEmpty, "raising the budget must leave no limit shield behind")
    }

    /// Applying the same command twice is the normal case (push retries, poller
    /// re-delivery), so it has to be a no-op rather than a double effect.
    func testConvergingTwiceIsIdempotent() {
        let now = Date(timeIntervalSince1970: 5_000)
        let r = rule(budget: 20)
        let decision = AppLimitEnforcementConverger.decide(
            for: envelope(kind: .set, rule: r, usedToday: 20),
            bundleID: bundleID
        )
        let once = AppLimitEnforcementConverger.converge(decision, into: [:], now: now)
        let twice = AppLimitEnforcementConverger.converge(decision, into: once, now: now)
        XCTAssertEqual(once.count, 1)
        XCTAssertEqual(twice.count, 1)
        XCTAssertEqual(once.keys, twice.keys)
    }

    /// Releasing the limit must not free an app a parent locked by hand, or one
    /// the earned-time pool is holding — only the `.limit` hold is ours to drop.
    func testReleaseKeepsOtherSourcesHolding() {
        let now = Date(timeIntervalSince1970: 5_000)
        let key = "exactApp:\(bundleID)"
        let mixed = ShieldRecord(
            recordKey: key,
            tier: .exactApp,
            targetKey: bundleID,
            displayName: "Snapchat",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: now,
            expiresAt: nil,
            originalRequest: "manual + limit",
            targetChildID: UUID(),
            sources: [.limit, .manual],
            limitRuleIDs: []
        )
        let out = AppLimitEnforcementConverger.converge(
            .release(ruleID: UUID(), recordKey: key),
            into: [key: mixed],
            now: now
        )
        XCTAssertEqual(out[key]?.sources, [.manual], "the manual lock must survive")
    }

    /// Builds before the NSE convergence path emitted a second ordinary
    /// `shield` command for an exhausted limit. Exact-app provenance was
    /// accidentally dropped by the backend, so the resulting durable record
    /// decoded as `.manual` even though its request text proves it came from
    /// the app-limit subsystem. A later raised budget must retire that specific
    /// historical shape without touching genuine parent-authored manual locks.
    func testReleaseCleansLegacyMisclassifiedLimitShield() {
        let now = Date(timeIntervalSince1970: 5_000)
        let key = "exactApp:\(bundleID)"
        let legacy = ShieldRecord(
            recordKey: key,
            tier: .exactApp,
            targetKey: bundleID,
            displayName: "Snapchat",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: now,
            expiresAt: nil,
            originalRequest: "app limit exhausted: 20/20 min",
            targetChildID: UUID(),
            sources: [.manual],
            limitRuleIDs: []
        )

        let out = AppLimitEnforcementConverger.converge(
            .release(ruleID: UUID(), recordKey: key),
            into: [key: legacy],
            now: now
        )

        XCTAssertTrue(out.isEmpty)
    }

    func testReleaseDoesNotCleanRealManualShieldWithSimilarTarget() {
        let now = Date(timeIntervalSince1970: 5_000)
        let key = "exactApp:\(bundleID)"
        let manual = ShieldRecord(
            recordKey: key,
            tier: .exactApp,
            targetKey: bundleID,
            displayName: "Snapchat",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: now,
            expiresAt: nil,
            originalRequest: "parent locked Snapchat",
            targetChildID: UUID(),
            sources: [.manual],
            limitRuleIDs: []
        )

        let out = AppLimitEnforcementConverger.converge(
            .release(ruleID: UUID(), recordKey: key),
            into: [key: manual],
            now: now
        )

        XCTAssertEqual(out[key], manual)
    }

    func testDeferChangesNothing() {
        let now = Date(timeIntervalSince1970: 5_000)
        let key = "exactApp:\(bundleID)"
        let existing = LimitShieldLogic.applyingLimit(
            to: [:],
            rule: rule(budget: 20),
            now: now
        )
        let out = AppLimitEnforcementConverger.converge(
            .defer_(reason: "no_authoritative_usage"),
            into: existing,
            now: now
        )
        XCTAssertEqual(out[key]?.sources, [.limit])
    }
}
