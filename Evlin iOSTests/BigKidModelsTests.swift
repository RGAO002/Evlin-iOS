import XCTest
@testable import Evlin_iOS

final class BigKidModelsTests: XCTestCase {
    func test_childState_decodesAuthoritativeGateAndRuntime() throws {
        let data = Data(#"{"child_name":"Giannis","minutes_left":0,"minutes_max":0,"tasks":[],"reflection_request":null,"notify_parent_cooldown_ends_at":null,"daily_complete_acknowledged":false,"screen_time_finished_acknowledged":false,"last_resolved_reflection":null,"usage_counting_allowed":false,"earned_time_runtime":{"usage_date":"2026-07-10","timezone":"America/New_York","daily_pool_minutes":120,"device_cap_minutes":90,"remaining_minutes":75,"estimated_minutes":15}}"#.utf8)
        let state = try JSONDecoder.bigKid.decode(ChildStateResponse.self, from: data)

        XCTAssertEqual(state.usageCountingAllowed, false)
        XCTAssertEqual(state.earnedTimeRuntime?.usageDate, "2026-07-10")
        XCTAssertEqual(state.earnedTimeRuntime?.dailyPoolMinutes, 120)
        XCTAssertEqual(state.effectiveUsageCountingAllowed, false)
    }

    func test_childState_legacySnapshotsUseCompatibilityGate() throws {
        func decode(tasks: String, reflectionRequest: String = "null") throws -> ChildStateResponse {
            let data = Data("""
            {
              "child_name": "Giannis",
              "minutes_left": 0,
              "minutes_max": 0,
              "tasks": \(tasks),
              "reflection_request": \(reflectionRequest),
              "notify_parent_cooldown_ends_at": null,
              "daily_complete_acknowledged": false,
              "screen_time_finished_acknowledged": false,
              "last_resolved_reflection": null
            }
            """.utf8)
            return try JSONDecoder.bigKid.decode(ChildStateResponse.self, from: data)
        }

        let unfinishedTaskJSON = #"[{"id":"11111111-1111-1111-1111-111111111111","title":"Make bed","description":"Smooth covers","category":"Chores","due":null,"status":"todo","phase":"input","redo_reason":null,"evidence_photo_urls":[],"evidence_note":null,"bypass":null}]"#
        let activeReflectionJSON = #"{"id":"22222222-2222-2222-2222-222222222222","reason":"Test","display_reason":null,"topic_label":null,"video_id":"video","video_title":"Title","writing_prompt":"Prompt","quiz":[],"steps_completed":[],"quiz_score":null,"essay_text":null,"status":"pending","parent_note":null,"submitted_at":null,"approved_at":null,"parent_redo_note":null,"last_nudge_at":null,"reflection_lock_cap_expires_at":null,"lock_applied_at":null}"#
        let noTasksNoReflection = try decode(tasks: "[]")
        let unfinishedTask = try decode(tasks: unfinishedTaskJSON)
        let activeReflection = try decode(tasks: "[]", reflectionRequest: activeReflectionJSON)

        XCTAssertTrue(noTasksNoReflection.effectiveUsageCountingAllowed)
        XCTAssertFalse(unfinishedTask.effectiveUsageCountingAllowed)
        XCTAssertFalse(activeReflection.effectiveUsageCountingAllowed)
        XCTAssertNil(noTasksNoReflection.earnedTimeRuntime)
    }

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
            screenTimeFinishedAcknowledged: false,
            lastResolvedReflection: nil
        )
        let state = BigKidState(snapshot: snapshot)
        XCTAssertTrue(state.allTasksDone)
    }

    func testRickRollIgnoresStaleServerTitleUsesDisplayReason() {
        let r = ReflectionRequest(
            id: UUID(),
            reason: "called sister mean names",
            displayReason: "You used words that hurt your sister's feelings.",
            topicLabel: nil,
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
            approvedAt: nil,
            parentRedoNote: nil,
            lastNudgeAt: nil,
            reflectionLockCapExpiresAt: nil,
            lockAppliedAt: nil
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
            topicLabel: nil,
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
            approvedAt: nil,
            parentRedoNote: nil,
            lastNudgeAt: nil,
            reflectionLockCapExpiresAt: nil,
            lockAppliedAt: nil
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
            topicLabel: nil,
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
            approvedAt: nil,
            parentRedoNote: nil,
            lastNudgeAt: nil,
            reflectionLockCapExpiresAt: nil,
            lockAppliedAt: nil
        )
        XCTAssertEqual(ReflectionVideoDisplay.cardTitle(for: r), "Authentic server title")
    }

    func testDecodesReflectionLockCapAndLastResolved() throws {
        let json = """
        { "child_name":"Liam","minutes_left":0,"minutes_max":120,"tasks":[],
          "reflection_request": null,
          "notify_parent_cooldown_ends_at": null,
          "daily_complete_acknowledged": false,
          "screen_time_finished_acknowledged": false,
          "last_resolved_reflection": { "rid": "11111111-1111-1111-1111-111111111111", "resolution": "cancelled" }
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder.bigKid.decode(ChildStateResponse.self, from: json)
        XCTAssertEqual(resp.lastResolvedReflection?.resolution, .cancelled)
        XCTAssertEqual(resp.lastResolvedReflection?.rid,
                       UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    func testReflectionRequestBackwardCompatNoCapField() throws {
        // Older snapshot without the cap field must still decode (nil).
        let req = ReflectionRequest.fixture()
        XCTAssertNil(req.reflectionLockCapExpiresAt)
    }

    func testTaskDetailAllowsBypassDuringRedo() {
        XCTAssertTrue(BigKidTaskDetailView.canRequestBypass(for: .fixture(status: .todo, phase: .input)))
        XCTAssertTrue(BigKidTaskDetailView.canRequestBypass(for: .fixture(status: .todo, phase: .redo)))
        XCTAssertFalse(BigKidTaskDetailView.canRequestBypass(for: .fixture(status: .submitted, phase: .submitted)))
        XCTAssertFalse(BigKidTaskDetailView.canRequestBypass(for: .fixture(status: .done, phase: .submitted)))
    }
}
