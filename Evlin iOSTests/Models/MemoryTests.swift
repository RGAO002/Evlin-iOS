//
//  MemoryTests.swift
//  Evlin iOSTests
//
//  Strategy-agent Task 11.1a — verify Codable round-trip for a parent
//  memory row.
//

import XCTest
@testable import Evlin_iOS

final class MemoryTests: XCTestCase {
    func testDecode() throws {
        let json = #"""
        {"id":"00000000-0000-0000-0000-000000000001",
         "family_id":"00000000-0000-0000-0000-000000000002",
         "child_id":null,
         "category":"preference",
         "text":"Parent prefers warning before consequence.",
         "source":"user_added",
         "created_at":"2026-05-09T12:00:00Z",
         "last_seen_at":"2026-05-09T12:00:00Z",
         "user_locked":true,
         "confidence":"medium"}
        """#.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let m = try dec.decode(Memory.self, from: json)
        XCTAssertEqual(m.category, .preference)
        XCTAssertTrue(m.userLocked)
    }
}
