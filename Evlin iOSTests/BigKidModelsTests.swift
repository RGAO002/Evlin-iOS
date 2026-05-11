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
        let bypass = BypassRequest(
            id: UUID(),
            taskId: UUID(),
            reason: "test bypass",
            status: .approved,
            parentResponse: nil,
            createdAt: Date(),
            respondedAt: nil
        )
        let task = BigKidTask(
            id: UUID(),
            title: "Chore",
            description: "",
            category: .chores,
            due: nil,
            status: .todo,
            phase: .input,
            redoReason: nil,
            evidencePhotoUrls: [],
            evidenceNote: nil,
            bypass: bypass
        )
        let snapshot = ChildStateResponse(
            childName: "Test",
            minutesLeft: 0,
            minutesMax: 120,
            tasks: [task],
            reflectionRequest: nil,
            notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: false,
            screenTimeFinishedAcknowledged: false
        )
        let state = BigKidState(snapshot: snapshot)
        XCTAssertTrue(state.allTasksDone)
    }

    func testRickRollIgnoresStaleServerTitleUsesDisplayReason() {
        let r = ReflectionRequest(
            id: UUID(),
            reason: "called sister mean names",
            displayReason: "You used words that hurt your sister's feelings.",
            videoId: ReflectionVideoDisplay.rickRollVideoId,
            videoTitle: "Why rest time matters for your brain",
            writingPrompt: "—",
            quiz: [],
            stepsCompleted: [],
            quizScore: nil,
            essayText: nil,
            status: .pending,
            parentNote: nil,
            submittedAt: nil,
            approvedAt: nil
        )
        let title = ReflectionVideoDisplay.cardTitle(for: r)
        XCTAssertFalse(title.lowercased().contains("brain"))
        XCTAssertTrue(title.localizedCaseInsensitiveContains("sister"))
    }

    func testRickRollUsesFreshServerLessonTitleFromBackend() {
        let r = ReflectionRequest(
            id: UUID(),
            reason: "yelled at dad",
            displayReason: "You raised your voice at dinner.",
            videoId: ReflectionVideoDisplay.rickRollVideoId,
            videoTitle: "Cooling down when frustration shows up.",
            writingPrompt: "—",
            quiz: [],
            stepsCompleted: [],
            quizScore: nil,
            essayText: nil,
            status: .pending,
            parentNote: nil,
            submittedAt: nil,
            approvedAt: nil
        )
        XCTAssertEqual(
            ReflectionVideoDisplay.cardTitle(for: r),
            "Cooling down when frustration shows up"
        )
    }

    func testNonPlaceholderVideoUsesServerVideoTitle() {
        let r = ReflectionRequest(
            id: UUID(),
            reason: "x",
            displayReason: "You did something.",
            videoId: "abc123notrick",
            videoTitle: "Authentic server title",
            writingPrompt: "—",
            quiz: [],
            stepsCompleted: [],
            quizScore: nil,
            essayText: nil,
            status: .pending,
            parentNote: nil,
            submittedAt: nil,
            approvedAt: nil
        )
        XCTAssertEqual(ReflectionVideoDisplay.cardTitle(for: r), "Authentic server title")
    }
}
