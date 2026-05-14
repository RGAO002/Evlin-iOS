import Foundation

// MARK: - Enums

enum BigKidTaskCategory: String, Codable, Equatable, Sendable {
    case chores = "Chores"
    case homework = "Homework"
    case selfCare = "Self-care"
}

enum BigKidTaskStatus: String, Codable, Equatable, Sendable {
    case todo, submitted, done, overdue
}

enum BigKidTaskPhase: String, Codable, Equatable, Sendable {
    case input, submitted, redo
}

enum BigKidBypassStatus: String, Codable, Equatable, Sendable {
    case pending, approved, denied, withdrawn
}

enum BigKidReflectionStatus: String, Codable, Equatable, Sendable {
    case pending, submitted, approved
}

enum BigKidReflectionStep: String, Codable, Equatable, Sendable {
    case video, quiz, writing
}

// MARK: - DTOs (snake_case <-> camelCase via JSONDecoder.bigKid)

struct BypassRequest: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let taskId: UUID
    let reason: String
    let status: BigKidBypassStatus
    let parentResponse: String?
    let createdAt: Date
    let respondedAt: Date?
}

struct BigKidTask: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let description: String
    let category: BigKidTaskCategory
    let due: String?
    let status: BigKidTaskStatus
    let phase: BigKidTaskPhase
    let redoReason: String?
    /// All evidence photos the kid submitted for this task. Order is
    /// preserved (first photo = primary). Empty when the task hasn't
    /// been submitted yet, or after the parent sends it back for redo.
    let evidencePhotoUrls: [URL]
    let evidenceNote: String?
    let bypass: BypassRequest?

    /// Back-compat helper for older call sites that expect a single URL.
    /// Prefer `evidencePhotoUrls` for new code.
    var evidencePhotoUrl: URL? { evidencePhotoUrls.first }
}

struct QuizQuestion: Codable, Equatable, Sendable {
    let q: String
    let options: [String]
}

/// Parent-only quiz question shape that carries both the correct-
/// answer index AND the option the kid actually selected. Decoded
/// from `GET /parent/reflection/{rid}` (see
/// `bigkid_parent.py :: get_reflection_for_parent`). Never served to
/// the child surface.
///
/// `selectedIndex` is nil when the kid hasn't answered this question
/// yet — the parent UI then renders only the correct-option highlight
/// without any wrong-answer markings.
struct QuizQuestionWithAnswer: Codable, Equatable, Sendable {
    let q: String
    let options: [String]
    let correctIndex: Int
    let selectedIndex: Int?
}

/// Parent-only reflection shape that exposes correct-answer indices
/// for every quiz question. Used by the Step-2 quiz preview so the
/// parent can see which option the child should have picked.
struct ReflectionRequestForParent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let reason: String
    let displayReason: String?
    /// AI-summarised ≤3-word category chip ("Sibling Conflict",
    /// "Screen Time Limit"). Drives the chat-card subtitle so a long
    /// `reason` doesn't crowd the header. Nil for older records or
    /// fixture-seeded reflections — iOS falls back to truncating
    /// `displayReason` (and then `reason`) when this is missing.
    let topicLabel: String?
    let videoId: String
    let videoTitle: String
    let writingPrompt: String
    let quiz: [QuizQuestionWithAnswer]
    let stepsCompleted: [BigKidReflectionStep]
    let quizScore: Int?
    let essayText: String?
    let status: BigKidReflectionStatus
    let parentNote: String?
    let submittedAt: Date?
    let approvedAt: Date?
    /// Mirrors the kid-side `ReflectionRequest.parentRedoNote`. Non-nil
    /// ⇒ parent already sent this reflection back at least once.
    let parentRedoNote: String?
    /// Mirrors `ReflectionRequest.lastNudgeAt`. iOS keeps a local
    /// "last acknowledged nudge" per child and injects a fresh nudge
    /// notification when this advances past it.
    let lastNudgeAt: Date?
}

struct ReflectionRequest: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let reason: String
    /// Gemini-rephrased, kid-appropriate second-person line for *this*
    /// incident. Also drives the Rick Roll reflection step headline via
    /// `ReflectionVideoDisplay` when `video_title` from the API is generic.
    let displayReason: String?
    /// AI-summarised ≤3-word category chip used by the parent chat
    /// card. See `ReflectionRequestForParent.topicLabel` doc.
    let topicLabel: String?
    let videoId: String
    let videoTitle: String
    let writingPrompt: String
    let quiz: [QuizQuestion]
    let stepsCompleted: [BigKidReflectionStep]
    let quizScore: Int?
    let essayText: String?
    let status: BigKidReflectionStatus
    let parentNote: String?
    let submittedAt: Date?
    let approvedAt: Date?
    /// Parent's "Request redo" feedback. Non-nil ⇒ parent has sent
    /// this reflection back at least once. Kid-side: surfaces under
    /// the lock screen + drives the "Rework Essay" CTA. Parent-side:
    /// drives the "reworked" notification copy on resubmission.
    let parentRedoNote: String?
    /// Timestamp of the kid's most recent "Give them a nudge" tap.
    /// Drives the parent's nudge-notification injection.
    let lastNudgeAt: Date?
}

struct ChildStateResponse: Codable, Equatable, Sendable {
    let childName: String
    let minutesLeft: Int
    let minutesMax: Int
    let tasks: [BigKidTask]
    let reflectionRequest: ReflectionRequest?
    let notifyParentCooldownEndsAt: Date?
    let dailyCompleteAcknowledged: Bool
    let screenTimeFinishedAcknowledged: Bool
}

// MARK: - Decoder configuration

extension JSONDecoder {
    static let bigKid: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        // Pydantic v2 serializes datetime with microseconds:
        // `2026-05-02T16:23:45.123456+00:00`. Swift's default `.iso8601`
        // formatter is strict and rejects fractional seconds. Try the
        // fractional-seconds variant first, fall back to plain.
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: str) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO 8601 date, got \(str)"
            )
        }
        return d
    }()
}

extension JSONEncoder {
    static let bigKid: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

// MARK: - Fixtures (DEBUG only — used by previews + tests)

#if DEBUG
extension BypassRequest {
    static func fixture(
        id: UUID = UUID(),
        taskId: UUID = UUID(),
        reason: String = "I had football practice",
        status: BigKidBypassStatus = .pending
    ) -> BypassRequest {
        BypassRequest(
            id: id, taskId: taskId, reason: reason, status: status,
            parentResponse: nil, createdAt: Date(), respondedAt: nil
        )
    }
}

extension BigKidTask {
    static func fixture(
        id: UUID = UUID(),
        title: String = "Make bed",
        description: String = "Smooth the covers and fluff the pillow.",
        category: BigKidTaskCategory = .chores,
        due: String? = "8:00 AM",
        status: BigKidTaskStatus = .todo,
        phase: BigKidTaskPhase = .input,
        bypass: BypassRequest? = nil
    ) -> BigKidTask {
        BigKidTask(
            id: id, title: title, description: description, category: category,
            due: due, status: status, phase: phase, redoReason: nil,
            evidencePhotoUrls: [], evidenceNote: nil, bypass: bypass
        )
    }
}

extension ReflectionRequest {
    /// Realistic fixture quiz — mirrors `bigkid_reflection_seed.json` so
    /// DEBUG / scenario mode (no live backend) renders the same content
    /// the real backend would seed.
    static let defaultFixtureQuiz: [QuizQuestion] = [
        QuizQuestion(
            q: "Why does your body need rest time away from screens?",
            options: [
                "So your eyes and brain can recover and focus better",
                "Because screens run out of battery",
                "So adults can use the TV",
                "It doesn't really matter",
            ]
        ),
        QuizQuestion(
            q: "What is a healthy thing to do when your screen time ends?",
            options: [
                "Hide another device under the bed",
                "Find something fun offline — draw, read, go outside",
                "Argue until you get more time",
                "Wait quietly doing nothing",
            ]
        ),
        QuizQuestion(
            q: "How does not sticking to limits make others feel?",
            options: [
                "Proud of you",
                "Nothing at all",
                "Worried, because agreements matter",
                "Happy you broke the rule",
            ]
        ),
        QuizQuestion(
            q: "What is the best way to earn trust back?",
            options: [
                "Pretend it didn't happen",
                "Keep to the limit and be honest next time",
                "Complain",
                "Change the password",
            ]
        ),
        QuizQuestion(
            q: "If you feel an urge to keep scrolling, a good move is to...",
            options: [
                "Just do it anyway",
                "Pause, take three breaths, and pick an offline thing",
                "Hide from a parent",
                "Start a new game",
            ]
        ),
    ]

    static func fixture(
        status: BigKidReflectionStatus = .pending,
        stepsCompleted: [BigKidReflectionStep] = []
    ) -> ReflectionRequest {
        ReflectionRequest(
            id: UUID(),
            reason: "stayed up past bedtime",
            displayReason: "You stayed up past your bedtime on your tablet.",
            topicLabel: "Late Bedtime",
            videoId: "dQw4w9WgXcQ",
            // Stub JSON field — headline comes from Gemini `videoLessonTitle` via API (`ReflectionVideoDisplay` handles stale placeholders).
            videoTitle: "A clip about calming down together (fixture)",
            writingPrompt: "What were you feeling when time ran out, and what could you do differently tomorrow?",
            quiz: ReflectionRequest.defaultFixtureQuiz,
            stepsCompleted: stepsCompleted, quizScore: nil, essayText: nil,
            status: status, parentNote: nil, submittedAt: nil, approvedAt: nil,
            parentRedoNote: nil, lastNudgeAt: nil
        )
    }
}

extension ChildStateResponse {
    /// Default fallback fixture used when the backend is unreachable.
    /// Mirrors the backend seed in `bigkid_store.py :: seed_default()` so
    /// debug builds without a live server still show realistic content.
    static let defaultFixtureTasks: [BigKidTask] = [
        .fixture(
            title: "Make bed",
            description: "Smooth the covers and fluff the pillow.",
            category: .chores, due: "8:00 AM"
        ),
        .fixture(
            title: "Math homework",
            description: "Page 42, problems 1–10. Show your work.",
            category: .homework, due: "6:00 PM"
        ),
        .fixture(
            title: "Brush teeth",
            description: "Two minutes, top and bottom.",
            category: .selfCare, due: "9:00 PM"
        ),
        .fixture(
            title: "Walk the dog",
            description: "Around the block — bring water and a poop bag.",
            category: .chores, due: "5:00 PM"
        ),
        .fixture(
            title: "Read for 20 min",
            description: "Pick a book you like. No screens during reading time.",
            category: .selfCare, due: "8:30 PM"
        ),
    ]

    static func fixture(
        tasks: [BigKidTask] = ChildStateResponse.defaultFixtureTasks,
        reflection: ReflectionRequest? = nil,
        minutesLeft: Int = 0,
        minutesMax: Int = 120,
        dailyAck: Bool = false,
        timeAck: Bool = false
    ) -> ChildStateResponse {
        ChildStateResponse(
            childName: "Liam",
            minutesLeft: minutesLeft, minutesMax: minutesMax,
            tasks: tasks, reflectionRequest: reflection,
            notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: dailyAck,
            screenTimeFinishedAcknowledged: timeAck
        )
    }
}
#endif
