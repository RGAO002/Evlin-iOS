//
//  QuestionCardTests.swift
//  Evlin iOSTests
//
//  Strategy-agent Task 11.0a — verify Codable round-trip from the backend
//  question-card schema (yes_no + free_text styles).
//

import XCTest
@testable import Evlin_iOS

final class QuestionCardTests: XCTestCase {
    func testDecodesYesNo() throws {
        let json = #"""
        {
          "question_id": "q_test12345",
          "prompt": "Want to handle this now?",
          "style": "yes_no",
          "options": [
            {"value": "yes", "label": "Yes"},
            {"value": "no", "label": "No"}
          ],
          "free_text_allowed": false,
          "cancellable": true
        }
        """#.data(using: .utf8)!
        let card = try JSONDecoder().decode(QuestionCard.self, from: json)
        XCTAssertEqual(card.style, .yesNo)
        XCTAssertEqual(card.options.count, 2)
        XCTAssertTrue(card.cancellable)
    }
    func testDecodesFreeText() throws {
        let json = #"""
        {"question_id":"q_aaaaaaaa","prompt":"Anything to add?","style":"free_text",
         "options":[],"free_text_allowed":true,"cancellable":true}
        """#.data(using: .utf8)!
        let card = try JSONDecoder().decode(QuestionCard.self, from: json)
        XCTAssertEqual(card.style, .freeText)
        XCTAssertTrue(card.freeTextAllowed)
    }
}
