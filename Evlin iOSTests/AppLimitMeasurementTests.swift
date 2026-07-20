import DeviceActivity
import XCTest
@testable import Evlin_iOS

/// Phase 2 — per-app usage-bar measurement: pure threshold + budget-packer logic.
/// Enforcement is unaffected (covered by AppLimitPlannerTests).
final class AppLimitMeasurementTests: XCTestCase {

    // MARK: - Quarter thresholds

    func test_measurementThresholds_quarters() {
        XCTAssertEqual(AppLimitPlanner.measurementThresholds(budgetMinutes: 60), [15, 30, 45])
        XCTAssertEqual(AppLimitPlanner.measurementThresholds(budgetMinutes: 20), [5, 10, 15])
        XCTAssertEqual(AppLimitPlanner.measurementThresholds(budgetMinutes: 100), [25, 50, 75])
    }

    func test_measurementThresholds_tinyBudgets() {
        XCTAssertEqual(AppLimitPlanner.measurementThresholds(budgetMinutes: 1), [])
        XCTAssertEqual(AppLimitPlanner.measurementThresholds(budgetMinutes: 2), [1])
    }

    func test_measurementThresholds_alwaysStrictlyInsideAndUnique() {
        for b in 1...240 {
            let t = AppLimitPlanner.measurementThresholds(budgetMinutes: b)
            XCTAssertTrue(t.allSatisfy { $0 > 0 && $0 < b }, "budget \(b): \(t) not in (0,\(b))")
            XCTAssertEqual(t, t.sorted(), "budget \(b) not ascending")
            XCTAssertEqual(t.count, Set(t).count, "budget \(b) has duplicate thresholds")
            XCTAssertLessThanOrEqual(t.count, 3, "quarters give at most 3 thresholds")
        }
    }

    // MARK: - Event name (prefix safety)

    func test_measurementEventName_prefixDistinctFromEnforcement() {
        let id = UUID()
        let m = AppLimitPlanner.measurementEventName(for: id, threshold: 15)
        XCTAssertTrue(m.hasPrefix("evlin.applimit."))
        // Must NOT match the extension's enforcement-shield prefix.
        XCTAssertFalse(m.hasPrefix("evlin.limit."),
                       "measurement event must never trigger applyLimitShield")
        XCTAssertTrue(m.hasSuffix(".t15"))
    }

    func test_v2EventFactoriesExplicitlyExcludePastActivity() {
        let armID = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000010")!
        let enforcement = AppLimitPlanner.makeV2Event(
            applications: [],
            thresholdMinutes: 60
        )
        let measurement = AppLimitPlanner.makeV2Event(
            applications: [],
            thresholdMinutes: 15
        )

        XCTAssertFalse(enforcement.includesPastActivity)
        XCTAssertFalse(measurement.includesPastActivity)
        XCTAssertEqual(
            AppLimitPlanner.v2EnforcementEventName(armID: armID),
            "evlin.limit.v2.\(armID.uuidString.lowercased()).budget"
        )
        XCTAssertEqual(
            AppLimitPlanner.v2MeasurementEventName(armID: armID, threshold: 15),
            "evlin.applimit.v2.\(armID.uuidString.lowercased()).t15"
        )
    }

    // MARK: - Budget packer

    func test_allocate_fitsWhenBudgetAllows() {
        let rules = (0..<3).map { _ in (id: UUID(), tokenCount: 1, budgetMinutes: 60) }
        let alloc = AppLimitPlanner.allocateMeasurement(
            rules: rules, reservedEvents: 3, reservedTokens: 3
        )
        XCTAssertEqual(alloc.dropped, [])
        for r in rules {
            XCTAssertEqual(alloc.perRule[r.id], [15, 30, 45])
        }
    }

    func test_allocate_dropsWhenTokenBudgetExceeded() {
        // Each rule costs 3 measurement token-copies (3 thresholds x 1 token).
        // reservedTokens=44 → 6 token budget left → exactly 2 rules fit, 3 dropped.
        let rules = (0..<5).map { _ in (id: UUID(), tokenCount: 1, budgetMinutes: 60) }
        let alloc = AppLimitPlanner.allocateMeasurement(
            rules: rules, reservedEvents: 5, reservedTokens: 44
        )
        XCTAssertEqual(alloc.perRule.count, 2, "only 2 fit in 6 remaining token budget")
        XCTAssertEqual(alloc.dropped.count, 3, "the other 3 keep enforcement, lose the bar")
    }

    func test_allocate_tinyBudgetIsNotADrop() {
        let r = (id: UUID(), tokenCount: 1, budgetMinutes: 1)
        let alloc = AppLimitPlanner.allocateMeasurement(
            rules: [r], reservedEvents: 1, reservedTokens: 1
        )
        XCTAssertTrue(alloc.perRule.isEmpty)
        XCTAssertTrue(alloc.dropped.isEmpty, "no measurable thresholds ≠ dropped")
    }

    func test_allocate_isDeterministicAcrossInputOrder() {
        let rules = (0..<5).map { _ in (id: UUID(), tokenCount: 1, budgetMinutes: 60) }
        let a = AppLimitPlanner.allocateMeasurement(rules: rules, reservedEvents: 5, reservedTokens: 44)
        let b = AppLimitPlanner.allocateMeasurement(rules: rules.shuffled(), reservedEvents: 5, reservedTokens: 44)
        XCTAssertEqual(Set(a.perRule.keys), Set(b.perRule.keys),
                       "same rules kept regardless of input order (stable sort)")
    }
}
