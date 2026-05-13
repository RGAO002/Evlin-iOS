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
}
