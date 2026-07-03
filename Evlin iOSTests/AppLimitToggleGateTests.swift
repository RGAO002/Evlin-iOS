import XCTest
@testable import Evlin_iOS

/// Phantom-toggle hardening (Layer 3) — pure unit tests for the diff-gate
/// decision used by `DeviceAppRow.handleToggle` before it forwards a
/// `Toggle(isOn:)` change to the network-backed `toggleLimit`. See
/// `DeviceAppsSheet.swift` header comment for the incident this hardens
/// against: a phantom clear_limit/set_limit pair for an app the parent
/// never touched, suspected to originate from unstable row/control identity.
final class AppLimitToggleGateTests: XCTestCase {

    func test_neverSeeded_alwaysFires() {
        // `lastApplied == nil` means the row hasn't appeared yet (or this is
        // its very first observed value) — nothing to diff against, so the
        // gate must not silently swallow a legitimate first toggle.
        XCTAssertEqual(AppLimitToggleGate.decide(lastApplied: nil, incoming: true), .fire)
        XCTAssertEqual(AppLimitToggleGate.decide(lastApplied: nil, incoming: false), .fire)
    }

    func test_incomingDiffersFromLastApplied_fires() {
        XCTAssertEqual(AppLimitToggleGate.decide(lastApplied: false, incoming: true), .fire)
        XCTAssertEqual(AppLimitToggleGate.decide(lastApplied: true, incoming: false), .fire)
    }

    func test_incomingMatchesLastApplied_suppressed() {
        // This is the phantom-toggle case: SwiftUI re-invokes the Toggle's
        // `set` closure with the SAME value the row already applied (e.g.
        // from unrelated re-render churn). The gate must suppress it so no
        // redundant clear_limit/set_limit pair reaches the network.
        XCTAssertEqual(AppLimitToggleGate.decide(lastApplied: true, incoming: true), .suppress)
        XCTAssertEqual(AppLimitToggleGate.decide(lastApplied: false, incoming: false), .suppress)
    }
}
