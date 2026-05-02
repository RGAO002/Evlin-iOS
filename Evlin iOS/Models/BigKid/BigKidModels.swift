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
    let evidencePhotoURL: URL?
    let bypass: BypassRequest?
}

struct QuizQuestion: Codable, Equatable, Sendable {
    let q: String
    let options: [String]
}

struct ReflectionRequest: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let reason: String
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
        d.dateDecodingStrategy = .iso8601
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
            evidencePhotoURL: nil, bypass: bypass
        )
    }
}

extension ReflectionRequest {
    static func fixture(
        status: BigKidReflectionStatus = .pending,
        stepsCompleted: [BigKidReflectionStep] = []
    ) -> ReflectionRequest {
        ReflectionRequest(
            id: UUID(), reason: "stayed up too late",
            videoId: "dQw4w9WgXcQ",
            videoTitle: "Why rest time matters",
            writingPrompt: "What were you feeling, and what could you do differently tomorrow?",
            quiz: (0..<5).map { i in
                QuizQuestion(q: "Q\(i+1)?", options: ["A", "B", "C", "D"])
            },
            stepsCompleted: stepsCompleted, quizScore: nil, essayText: nil,
            status: status, parentNote: nil, submittedAt: nil, approvedAt: nil
        )
    }
}

extension ChildStateResponse {
    static func fixture(
        tasks: [BigKidTask] = [.fixture()],
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
