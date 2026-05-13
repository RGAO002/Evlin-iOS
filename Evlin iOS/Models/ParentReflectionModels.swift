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
    /// Populated only when `kind == .video`. Drives the YouTube preview
    /// on Step 1; for the prototype the kid-side and parent-side share
    /// the same fixture video.
    var video: ParentReflectionVideoFixture? = nil
    /// Populated only when `kind == .quiz`. Lets Step 2 list every
    /// question with the correct answer highlighted for the parent.
    var quiz: [ParentReflectionQuizQuestion] = []
}

struct ParentReflectionVideoFixture: Codable, Hashable {
    let youtubeId: String
    let duration: String
    let lockRule: String
}

struct ParentReflectionQuizQuestion: Identifiable, Codable, Hashable {
    let id: UUID
    let q: String
    let options: [String]
    let correctIndex: Int
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
    /// Belt-and-suspenders observation counter. SwiftUI's `@Observable`
    /// tracking on dictionary subscript mutations doesn't always
    /// invalidate views that are not currently topmost in a
    /// NavigationStack (Home below pushed Profile is the canonical
    /// case). Bumping a simple Int property on every mutation gives
    /// child views a guaranteed observation hook — they read
    /// `revision` in their body to register a dependency, and SwiftUI
    /// reliably re-evaluates them when this Int changes.
    private(set) var revision: Int = 0

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
        revision &+= 1
    }

    func simulateAssignment(childId: String) {
        guard childId == ChildProfile.liam.id else { return }
        summariesByChildId[childId] = Self.liamPendingSummary
        revision &+= 1
    }

    func clear(childId: String) {
        summariesByChildId[childId] = nil
        revision &+= 1
    }

    func resetToPending(childId: String) {
        simulateAssignment(childId: childId)
    }

    func syncBackendReflection(for child: ChildProfile, request: ReflectionRequest?) {
        guard let request else {
            summariesByChildId[child.id] = nil
            revision &+= 1
            return
        }

        let mappedState = Self.parentState(for: request.status)
        // .approved on the backend → .none on the parent surface.
        // Drop the row entirely so Home / Profile fall back to the
        // normal child card; otherwise a stale summary with state=.none
        // would still take up a row in the store.
        guard mappedState != .none else {
            summariesByChildId[child.id] = nil
            revision &+= 1
            return
        }

        let existing = summariesByChildId[child.id]
        summariesByChildId[child.id] = ParentReflectionSummary(
            id: request.id,
            childId: child.id,
            childName: child.name,
            state: mappedState,
            reason: request.displayReason ?? request.reason,
            assignedAt: existing?.id == request.id ? existing?.assignedAt ?? Self.nowString() : Self.nowString(),
            submittedAt: request.submittedAt.map(Self.string(from:)),
            parentNote: request.parentNote,
            prompt: request.writingPrompt,
            essayText: request.essayText,
            takeaway: Self.takeaway(for: request),
            steps: Self.steps(for: request)
        )
        revision &+= 1
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
            // Pending shows the same three steps so the parent can preview
            // exactly what the kid will see. Step 3 will render the
            // prompt without an essay until the kid submits.
            steps: standardCompletedSteps
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
                title: "Choosing Better Words",
                subtitle: "Short coaching video",
                body: "A brief lesson about pausing before responding when emotions spike.",
                video: ParentReflectionVideoFixture(
                    youtubeId: "dQw4w9WgXcQ",
                    duration: "2:14",
                    lockRule: "Watch the whole video — no skipping."
                )
            ),
            ParentReflectionStepArtifact(
                id: UUID(uuidString: "B0D69D4A-CE58-43D6-A108-5C81BA8E9638")!,
                kind: .quiz,
                title: "Check Understanding",
                subtitle: "Need 4 of 5 to pass",
                body: "Reflection quiz on repair, tone, and how to ask for space.",
                quiz: standardCompletedQuiz
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

    /// Mirrors `BigKidModels.ReflectionRequest.defaultFixtureQuiz` but with
    /// the correct-answer index pinned so Step 2 can highlight it for the
    /// parent. (Kid-side hides correctness; parent-side surfaces it.)
    static let standardCompletedQuiz: [ParentReflectionQuizQuestion] = [
        ParentReflectionQuizQuestion(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!,
            q: "Why does your body need rest time away from screens?",
            options: [
                "So your eyes and brain can recover and focus better",
                "Because screens run out of battery",
                "So adults can use the TV",
                "It doesn't really matter"
            ],
            correctIndex: 0
        ),
        ParentReflectionQuizQuestion(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000002")!,
            q: "What is a healthy thing to do when your screen time ends?",
            options: [
                "Hide another device under the bed",
                "Find something fun offline — draw, read, go outside",
                "Argue until you get more time",
                "Wait quietly doing nothing"
            ],
            correctIndex: 1
        ),
        ParentReflectionQuizQuestion(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000003")!,
            q: "How does not sticking to limits make others feel?",
            options: [
                "Proud of you",
                "Nothing at all",
                "Worried, because agreements matter",
                "Happy you broke the rule"
            ],
            correctIndex: 2
        ),
        ParentReflectionQuizQuestion(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000004")!,
            q: "What is the best way to earn trust back?",
            options: [
                "Pretend it didn't happen",
                "Keep to the limit and be honest next time",
                "Complain",
                "Change the password"
            ],
            correctIndex: 1
        ),
        ParentReflectionQuizQuestion(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000005")!,
            q: "If you feel an urge to keep scrolling, a good move is to...",
            options: [
                "Just do it anyway",
                "Pause, take three breaths, and pick an offline thing",
                "Hide from a parent",
                "Start a new game"
            ],
            correctIndex: 1
        )
    ]

    static func initialSummariesByChildId() -> [String: ParentReflectionSummary] {
        [:]
    }

    static func parentState(for status: BigKidReflectionStatus) -> ParentReflectionState {
        switch status {
        case .pending:
            return .assignedPending
        case .submitted:
            return .completedReady
        case .approved:
            // Parent already approved → reflection is done. The Home
            // and Profile screens should drop back to their normal
            // (non-reflection) presentation, so report .none. Chat
            // history still keeps the resolved review bubble.
            return .none
        }
    }

    static func steps(for request: ReflectionRequest) -> [ParentReflectionStepArtifact] {
        // Both pending and completed reflections expose the three steps —
        // pending so the parent can preview, completed so they can review.
        // The Writing step omits `essayText` (it lives on the summary).
        let mappedQuiz: [ParentReflectionQuizQuestion]
        if request.quiz.isEmpty {
            mappedQuiz = standardCompletedQuiz
        } else {
            // The backend `QuizQuestion` doesn't carry a correct-answer
            // index — the kid-side grades via a server roundtrip. For
            // the parent preview, look up the index by matching the
            // question text against the canonical seed
            // (`standardCompletedQuiz`, which mirrors
            // `bigkid_reflection_seed.json`). If a backend question
            // doesn't match (e.g. a future Gemini-generated quiz),
            // mark `correctIndex` as -1 so the renderer can hide the
            // green highlight rather than mark a random option correct.
            mappedQuiz = request.quiz.map { q in
                let standardCorrect = standardCompletedQuiz
                    .first { $0.q == q.q }?
                    .correctIndex ?? -1
                return ParentReflectionQuizQuestion(
                    id: UUID(),
                    q: q.q,
                    options: q.options,
                    correctIndex: standardCorrect
                )
            }
        }
        return [
            ParentReflectionStepArtifact(
                id: UUID(uuidString: "1E3DD820-7AB7-4B0A-84EE-366A472E8616")!,
                kind: .video,
                title: request.videoTitle.isEmpty ? "Watch the coaching video" : request.videoTitle,
                subtitle: "Short coaching video",
                body: "The reflection started with a short video lesson about the assigned situation.",
                video: ParentReflectionVideoFixture(
                    youtubeId: request.videoId,
                    duration: "2:14",
                    lockRule: "Watch the whole video — no skipping."
                )
            ),
            ParentReflectionStepArtifact(
                id: UUID(uuidString: "B0D69D4A-CE58-43D6-A108-5C81BA8E9638")!,
                kind: .quiz,
                title: "Check Understanding",
                subtitle: "Need 4 of 5 to pass",
                body: request.quizScore.map { "Score: \($0)/\(max(request.quiz.count, 1))" }
                    ?? "The quiz checks that the reflection lesson made sense.",
                quiz: mappedQuiz
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
