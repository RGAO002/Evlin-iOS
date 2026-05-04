import XCTest
@testable import Evlin_iOS

final class BigKidModelsTests: XCTestCase {
    func testDecodesChildStateResponse() throws {
        let json = """
        {
          "child_name": "Liam",
          "minutes_left": 45,
          "minutes_max": 120,
          "tasks": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "Make bed",
              "description": "Smooth covers",
              "category": "Chores",
              "due": "8:00 AM",
              "status": "todo",
              "phase": "input",
              "redo_reason": null,
              "evidence_photo_urls": [],
              "bypass": null
            }
          ],
          "reflection_request": null,
          "notify_parent_cooldown_ends_at": null,
          "daily_complete_acknowledged": false,
          "screen_time_finished_acknowledged": false
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder.bigKid
        let resp = try decoder.decode(ChildStateResponse.self, from: json)
        XCTAssertEqual(resp.childName, "Liam")
        XCTAssertEqual(resp.minutesLeft, 45)
        XCTAssertEqual(resp.tasks.count, 1)
        XCTAssertEqual(resp.tasks[0].title, "Make bed")
        XCTAssertEqual(resp.tasks[0].status, .todo)
    }

    func testAllTasksDoneWithApprovedBypass() throws {
        let task = BigKidTask.fixture(status: .todo, bypass: .fixture(status: .approved))
        let state = BigKidState(snapshot: ChildStateResponse.fixture(tasks: [task]))
        XCTAssertTrue(state.allTasksDone)
    }

    func testAllTasksDoneFalseWithPendingBypass() throws {
        let task = BigKidTask.fixture(status: .todo, bypass: .fixture(status: .pending))
        let state = BigKidState(snapshot: ChildStateResponse.fixture(tasks: [task]))
        XCTAssertFalse(state.allTasksDone)
    }
}
