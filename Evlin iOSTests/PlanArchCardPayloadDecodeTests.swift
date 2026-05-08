//
//  PlanArchCardPayloadDecodeTests.swift
//  Evlin iOSTests
//
//  Task 21: verify backwards-compatible decoder (kind|legacy type) + source field.
//

import XCTest
@testable import Evlin_iOS

final class PlanArchCardPayloadDecodeTests: XCTestCase {

    func testDecodeNewWireFormatWithKindAndSource() throws {
        let json = """
        {
          "type": "duration_picker",
          "title": "Set duration",
          "plan_token": "tok123",
          "step_index": 0,
          "kind": "phone.missing_duration",
          "source": "plan",
          "detail": {"target_name": "IG"},
          "options": [],
          "danger": "low"
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(PlanArchCardPayload.self, from: json)
        XCTAssertEqual(payload.kind, "phone.missing_duration")
        XCTAssertEqual(payload.source, .plan)
        XCTAssertEqual(payload.type, .durationPicker)
    }

    func testDecodeLegacyWireFormatMapsToFamilyPrefixedKind() throws {
        // Old backend deploy — only `type`, no `kind` / `source`.
        let json = """
        {
          "type": "duration_picker",
          "title": "Set duration",
          "plan_token": "tok",
          "step_index": 0,
          "options": [],
          "danger": "low"
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(PlanArchCardPayload.self, from: json)
        XCTAssertEqual(payload.kind, "phone.missing_duration")     // mapped
        XCTAssertEqual(payload.source, .plan)                       // default
    }

    func testEveryLegacyTypeMapsToPhoneFamilyKind() throws {
        let pairs: [(String, String)] = [
            ("duration_picker",            "phone.missing_duration"),
            ("long_duration_confirm",      "phone.below_min_duration"),
            ("lazy_tag",                   "phone.alias_miss"),
            ("unlock_picker",              "phone.unlock_picker"),
            ("rejection_with_alternative", "phone.unsupported_exclusion"),
            ("split_command_request",      "phone.bulk_action_confirm"),
            ("danger_confirm",             "phone.danger_confirm"),
            ("block_intent_confirm",       "phone.proposal_confirm"),
        ]
        for (legacy, expected) in pairs {
            let json = """
            { "type": "\(legacy)", "title": "x", "plan_token": "t",
              "step_index": 0, "options": [], "danger": "low" }
            """.data(using: .utf8)!
            let payload = try JSONDecoder().decode(PlanArchCardPayload.self, from: json)
            XCTAssertEqual(payload.kind, expected, "\(legacy) → \(expected)")
            XCTAssertTrue(payload.kind.hasPrefix("phone."), "\(legacy) must produce phone.*")
        }
    }

    func testDecodeSourceEventDoesNotChangeKind() throws {
        let json = """
        { "type": "danger_confirm", "title": "x", "plan_token": "",
          "step_index": 0, "kind": "event.reflection_review_pending",
          "source": "event", "options": [], "danger": "low" }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(PlanArchCardPayload.self, from: json)
        XCTAssertEqual(payload.source, .event)
        XCTAssertEqual(payload.kind, "event.reflection_review_pending")
    }

    func testDecodeSourceQuery() throws {
        let json = """
        { "type": "rejection_with_alternative", "title": "x", "plan_token": "",
          "step_index": 0, "kind": "query.result_pending_submissions",
          "source": "query", "options": [], "danger": "low" }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(PlanArchCardPayload.self, from: json)
        XCTAssertEqual(payload.source, .query)
    }
}
