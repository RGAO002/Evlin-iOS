import Foundation
import Observation

enum ParentReflectionState: String, Codable, Hashable {
    case none
    case assignedPending
    case completedReady
}

enum ParentReflectionStepKind: String, Codable, Hashable {
    case video
    case quiz
    case writing
}

struct ParentReflectionStepArtifact: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: ParentReflectionStepKind
    let title: String
    let subtitle: String
    let body: String
}

struct ParentReflectionSummary: Identifiable, Codable, Hashable {
    let id: UUID
    let childId: String
    let childName: String
    var state: ParentReflectionState
    let reason: String
    let assignedAt: String
    var submittedAt: String?
    var parentNote: String?
    let prompt: String
    var essayText: String?
    var takeaway: String?
    var steps: [ParentReflectionStepArtifact]
}

@Observable
final class ParentReflectionFixtureStore {
    private var summariesByChildId: [String: ParentReflectionSummary]

    init() {
        self.summariesByChildId = Self.initialSummariesByChildId()
    }

    func summary(for child: ChildProfile) -> ParentReflectionSummary? {
        summary(childId: child.id)
    }

    func summary(childId: String) -> ParentReflectionSummary? {
        summariesByChildId[childId]
    }

    func completedReflectionId(childId: String) -> UUID? {
        guard let summary = summariesByChildId[childId],
              summary.state == .completedReady else {
            return nil
        }
        return summary.id
    }

    func summary(reflectionId: UUID) -> ParentReflectionSummary? {
        summariesByChildId.values.first { $0.id == reflectionId }
            ?? Self.completedNotificationSummariesById[reflectionId]
    }

    func step(reflectionId: UUID, stepId: UUID) -> ParentReflectionStepArtifact? {
        summary(reflectionId: reflectionId)?.steps.first { $0.id == stepId }
    }

    func simulateCompletion(childId: String) {
        if summariesByChildId[childId] == nil {
            simulateAssignment(childId: childId)
        }

        guard var summary = summariesByChildId[childId] else {
            return
        }

        summary.state = .completedReady
        summary.submittedAt = Self.completedSubmittedAt
        summary.essayText = Self.completedEssayText
        summary.takeaway = Self.completedTakeaway
        summary.steps = Self.standardCompletedSteps
        summariesByChildId[childId] = summary
    }

    func simulateAssignment(childId: String) {
        guard childId == ChildProfile.liam.id else { return }
        summariesByChildId[childId] = Self.liamPendingSummary
    }

    func clear(childId: String) {
        summariesByChildId[childId] = nil
    }

    func resetToPending(childId: String) {
        simulateAssignment(childId: childId)
    }

    func syncBackendReflection(for child: ChildProfile, request: ReflectionRequest?) {
        guard let request else {
            summariesByChildId[child.id] = nil
            return
        }

        let existing = summariesByChildId[child.id]
        summariesByChildId[child.id] = ParentReflectionSummary(
            id: request.id,
            childId: child.id,
            childName: child.name,
            state: Self.parentState(for: request.status),
            reason: request.displayReason ?? request.reason,
            assignedAt: existing?.id == request.id ? existing?.assignedAt ?? Self.nowString() : Self.nowString(),
            submittedAt: request.submittedAt.map(Self.string(from:)),
            parentNote: request.parentNote,
            prompt: request.writingPrompt,
            essayText: request.essayText,
            takeaway: Self.takeaway(for: request),
            steps: Self.steps(for: request)
        )
    }
}

private extension ParentReflectionFixtureStore {
    static let completedSubmittedAt = "2026-05-13T20:45:00Z"

    static let completedEssayText = """
    I learned that walking away for a minute can help me choose better words. \
    Next time I feel annoyed, I can say I need a break instead of saying \
    something mean.
    """

    static let completedTakeaway = "Liam identified a concrete pause-and-repair strategy."

    static var liamPendingSummary: ParentReflectionSummary {
        ParentReflectionSummary(
            id: UUID(uuidString: "AAE163C8-35B4-4B4E-A7B1-5D58AD477E28")!,
            childId: ChildProfile.liam.id,
            childName: ChildProfile.liam.name,
            state: .assignedPending,
            reason: "Used hurtful words during a sibling disagreement.",
            assignedAt: "2026-05-13T19:30:00Z",
            submittedAt: nil,
            parentNote: "Take a breath and think about how your words landed.",
            prompt: "What happened, how did it affect someone else, and what can you try next time?",
            essayText: nil,
            takeaway: nil,
            steps: []
        )
    }

    static var liamCompletedNotificationSummary: ParentReflectionSummary {
        ParentReflectionSummary(
            id: UUID(uuidString: "936E3E6A-D651-490C-9110-7B73BDA4EA26")!,
            childId: ChildProfile.liam.id,
            childName: ChildProfile.liam.name,
            state: .completedReady,
            reason: "Used hurtful words during a sibling disagreement.",
            assignedAt: "2026-05-13T19:30:00Z",
            submittedAt: completedSubmittedAt,
            parentNote: "Take a breath and think about how your words landed.",
            prompt: "What happened, how did it affect someone else, and what can you try next time?",
            essayText: completedEssayText,
            takeaway: completedTakeaway,
            steps: standardCompletedSteps
        )
    }

    static var completedNotificationSummariesById: [UUID: ParentReflectionSummary] {
        [
            liamCompletedNotificationSummary.id: liamCompletedNotificationSummary
        ]
    }

    static var standardCompletedSteps: [ParentReflectionStepArtifact] {
        [
            ParentReflectionStepArtifact(
                id: UUID(uuidString: "1E3DD820-7AB7-4B0A-84EE-366A472E8616")!,
                kind: .video,
                title: "Watch: Choosing Better Words",
                subtitle: "Short coaching video",
                body: "Liam watched a brief lesson about pausing before responding when emotions spike."
            ),
            ParentReflectionStepArtifact(
                id: UUID(uuidString: "B0D69D4A-CE58-43D6-A108-5C81BA8E9638")!,
                kind: .quiz,
                title: "Check Understanding",
                subtitle: "Reflection quiz",
                body: "Liam answered questions about repair, tone, and how to ask for space respectfully."
            ),
            ParentReflectionStepArtifact(
                id: UUID(uuidString: "F56C8D81-C7D8-4477-9E2B-B2C0E426903C")!,
                kind: .writing,
                title: "Written Reflection",
                subtitle: "Parent-ready response",
                body: completedEssayText
            )
        ]
    }

    static func initialSummariesByChildId() -> [String: ParentReflectionSummary] {
        [:]
    }

    static func parentState(for status: BigKidReflectionStatus) -> ParentReflectionState {
        switch status {
        case .pending:
            return .assignedPending
        case .submitted, .approved:
            return .completedReady
        }
    }

    static func steps(for request: ReflectionRequest) -> [ParentReflectionStepArtifact] {
        guard request.status != .pending else { return [] }

        return [
            ParentReflectionStepArtifact(
                id: UUID(uuidString: "1E3DD820-7AB7-4B0A-84EE-366A472E8616")!,
                kind: .video,
                title: request.videoTitle.isEmpty ? "Watch the coaching video" : request.videoTitle,
                subtitle: "Short coaching video",
                body: "The reflection started with a short video lesson about the assigned situation."
            ),
            ParentReflectionStepArtifact(
                id: UUID(uuidString: "B0D69D4A-CE58-43D6-A108-5C81BA8E9638")!,
                kind: .quiz,
                title: "Check Understanding",
                subtitle: "\(request.quiz.count) reflection questions",
                body: request.quizScore.map { "Score: \($0)/\(max(request.quiz.count, 1))" }
                    ?? "The quiz checks that the reflection lesson made sense."
            ),
            ParentReflectionStepArtifact(
                id: UUID(uuidString: "F56C8D81-C7D8-4477-9E2B-B2C0E426903C")!,
                kind: .writing,
                title: "Written Reflection",
                subtitle: "Parent-ready response",
                body: request.essayText ?? request.writingPrompt
            )
        ]
    }

    static func takeaway(for request: ReflectionRequest) -> String? {
        guard request.status != .pending else { return nil }
        return request.essayText.map { _ in
            "\(request.displayReason ?? request.reason) was completed and is ready for parent review."
        }
    }

    static func nowString() -> String {
        string(from: Date())
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
