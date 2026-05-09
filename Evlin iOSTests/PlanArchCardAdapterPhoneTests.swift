//
//  PlanArchCardAdapterPhoneTests.swift
//  Evlin iOSTests
//
//  Task 23 + 24: Tests for top-level dispatch and all 11 phone.* kinds.
//

import XCTest
@testable import Evlin_iOS

final class PlanArchCardAdapterPhoneTests: XCTestCase {

    fileprivate func payload(kind: String, detail: [String: Any] = [:]) -> PlanArchCardPayload {
        // Use legacy `type` to satisfy the strict CardPayload schema, then
        // override `kind` so the new family-prefixed dispatch runs.
        let body: [String: Any] = [
            "type": "duration_picker",
            "title": "test",
            "plan_token": "x",
            "step_index": 0,
            "kind": kind,
            "source": "plan",
            "detail": detail,
            "options": [],
            "danger": "low",
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return try! JSONDecoder().decode(PlanArchCardPayload.self, from: data)
    }

    func testAdaptUnknownPrefixReturnsNil() {
        let card = payload(kind: "future.kind")
        XCTAssertNil(PlanArchCardAdapter.adapt(card, childName: "Liam"))
    }

    func testAdaptReflectionPrefixDispatchesIn2B() {
        // Phase 2B: reflection.confirm_propose now routes to .A1 via ReflectionCardAdapter.
        // (Was nil in 2A — updated when ReflectionCardAdapter was filled in.)
        let card = payload(kind: "reflection.confirm_propose")
        let model = PlanArchCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model, "reflection.confirm_propose must produce A1 in Phase 2B")
        XCTAssertEqual(model?.cardID, .A1)
    }
}

extension PlanArchCardAdapterPhoneTests {
    fileprivate struct PhoneCase {
        let kind: String
        let detail: [String: Any]
        let expectedCardID: CardID
    }

    func testAllPhoneKindsAdapt() throws {
        let cases: [PhoneCase] = [
            .init(kind: "phone.missing_duration",
                  detail: ["target_name": "IG"], expectedCardID: .D1),
            .init(kind: "phone.below_min_duration",
                  detail: ["target_name": "IG", "requested_minutes": 5],
                  expectedCardID: .D1),
            .init(kind: "phone.alias_miss",
                  detail: ["raw_name": "instagram"],
                  expectedCardID: .E3),
            .init(kind: "phone.unlock_picker",
                  detail: ["active_shields": ["IG", "TikTok"]],
                  expectedCardID: .U1),
            .init(kind: "phone.unsupported_exclusion",
                  detail: ["excluded_target": "IG"],
                  expectedCardID: .D2),
            .init(kind: "phone.replace_mode_required",
                  detail: ["target_name": "IG", "existing_mode": "max"],
                  expectedCardID: .B1),
            .init(kind: "phone.bulk_action_confirm",
                  detail: ["targets": ["IG", "TikTok"]],
                  expectedCardID: .A3),
            .init(kind: "phone.danger_confirm",
                  detail: ["action_summary": "Block all apps permanently"],
                  expectedCardID: .A1),
            .init(kind: "phone.proposal_confirm",
                  detail: ["action_summary": "Lock IG for 30 min"],
                  expectedCardID: .A1),
            .init(kind: "phone.unsupported_in_mode",
                  detail: ["target_name": "IG", "mode": "max"],
                  expectedCardID: .E1),
            .init(kind: "phone.list_suggestion",
                  detail: ["suggestions": ["social", "games"]],
                  expectedCardID: .F1),
        ]
        for c in cases {
            let body: [String: Any] = [
                "type": "duration_picker",
                "title": "test",
                "plan_token": "x",
                "step_index": 0,
                "kind": c.kind,
                "source": "plan",
                "detail": c.detail,
                "options": [],
                "danger": "low",
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            let card = try JSONDecoder().decode(PlanArchCardPayload.self, from: data)
            let model = PlanArchCardAdapter.adapt(card, childName: "Liam")
            XCTAssertNotNil(model, "expected adapt to succeed for \(c.kind)")
            XCTAssertEqual(model?.cardID, c.expectedCardID,
                           "wrong CardID for \(c.kind)")
        }
    }
}
