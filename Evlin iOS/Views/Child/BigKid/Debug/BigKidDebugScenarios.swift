import Foundation
import SwiftUI

#if DEBUG
/// Single-device dev affordance: pick a `BigKidState` snapshot to override
/// what the poller would otherwise return. Lets you visit every screen
/// in the eleven-screen big-kid tree without driving the backend.
///
/// Selecting `.live` resumes the poller; any other scenario stops the
/// poller and applies a hand-tuned snapshot, so the screen stays parked
/// until you either pick another scenario or switch back to `.live`.
enum BigKidDebugScenario: String, CaseIterable, Identifiable {
    case live
    case homeAllTodo
    case homeOneSubmitted
    case homeOneRedo
    case reflectionStateA
    case reflectionStateB
    case reflectionApproved
    case dailyComplete
    case screenTimeFinished

    var id: String { rawValue }

    var label: String {
        switch self {
        case .live:               "Live (poller on)"
        case .homeAllTodo:        "Home — all todo"
        case .homeOneSubmitted:   "Home — one submitted"
        case .homeOneRedo:        "Home — redo task"
        case .reflectionStateA:   "Reflection — State A (in progress)"
        case .reflectionStateB:   "Reflection — State B (awaiting parent)"
        case .reflectionApproved: "Reflection — approved (Complete screen)"
        case .dailyComplete:      "Daily complete"
        case .screenTimeFinished: "Screen-time finished"
        }
    }

    /// Returns nil for `.live` (means: resume polling). Otherwise returns
    /// the snapshot to apply to the active `BigKidState`.
    func snapshot() -> ChildStateResponse? {
        switch self {
        case .live:
            return nil

        case .homeAllTodo:
            return .fixture()

        case .homeOneSubmitted:
            var tasks = ChildStateResponse.defaultFixtureTasks
            tasks[1] = .fixture(
                title: tasks[1].title, description: tasks[1].description,
                category: tasks[1].category, due: tasks[1].due,
                status: .submitted, phase: .submitted
            )
            return .fixture(tasks: tasks)

        case .homeOneRedo:
            var tasks = ChildStateResponse.defaultFixtureTasks
            let original = tasks[0]
            tasks[0] = BigKidTask(
                id: original.id, title: original.title, description: original.description,
                category: original.category, due: original.due,
                status: .todo, phase: .redo,
                redoReason: "Looks like the bed is still a bit messy — can you smooth out the covers and take another photo?",
                evidencePhotoUrls: [], evidenceNote: nil, bypass: nil
            )
            return .fixture(tasks: tasks)

        case .reflectionStateA:
            return .fixture(
                reflection: .fixture(status: .pending, stepsCompleted: [])
            )

        case .reflectionStateB:
            return .fixture(
                reflection: .fixture(
                    status: .submitted,
                    stepsCompleted: [.video, .quiz, .writing]
                )
            )

        case .reflectionApproved:
            let base = ReflectionRequest.fixture(
                status: .approved,
                stepsCompleted: [.video, .quiz, .writing]
            )
            let withScore = ReflectionRequest(
                id: base.id, reason: base.reason, displayReason: base.displayReason,
                videoId: base.videoId, videoTitle: base.videoTitle,
                writingPrompt: base.writingPrompt, quiz: base.quiz,
                stepsCompleted: base.stepsCompleted, quizScore: 5,
                essayText: "I felt tired and grumpy. Next time I'll go to bed when asked.",
                status: .approved,
                parentNote: "Thanks for being honest. Proud of you.",
                submittedAt: Date(), approvedAt: Date()
            )
            return .fixture(reflection: withScore)

        case .dailyComplete:
            let done = ChildStateResponse.defaultFixtureTasks.map { t in
                BigKidTask(
                    id: t.id, title: t.title, description: t.description,
                    category: t.category, due: t.due,
                    status: .done, phase: .submitted,
                    redoReason: nil, evidencePhotoUrls: [], evidenceNote: nil, bypass: nil
                )
            }
            return .fixture(tasks: done, minutesLeft: 95, minutesMax: 120,
                            dailyAck: false, timeAck: false)

        case .screenTimeFinished:
            let done = ChildStateResponse.defaultFixtureTasks.map { t in
                BigKidTask(
                    id: t.id, title: t.title, description: t.description,
                    category: t.category, due: t.due,
                    status: .done, phase: .submitted,
                    redoReason: nil, evidencePhotoUrls: [], evidenceNote: nil, bypass: nil
                )
            }
            return .fixture(tasks: done, minutesLeft: 0, minutesMax: 120,
                            dailyAck: true, timeAck: false)
        }
    }
}

/// Floating menu button (placed inside `BigKidRootView` overlay in DEBUG).
/// Tap → menu of scenario presets.
struct BigKidDebugScenarioMenu: View {
    @Binding var current: BigKidDebugScenario
    let onSelect: (BigKidDebugScenario) -> Void
    /// Optional handler for the "Reset tasks" action button. Hits the
    /// backend's `/parent/_debug/reset/{child_id}` endpoint and refreshes
    /// the poller so the kid sees fresh fixture tasks again.
    var onReset: (() -> Void)? = nil

    var body: some View {
        Menu {
            ForEach(BigKidDebugScenario.allCases) { s in
                Button {
                    current = s
                    onSelect(s)
                } label: {
                    if s == current {
                        Label(s.label, systemImage: "checkmark")
                    } else {
                        Text(s.label)
                    }
                }
            }
            if let onReset {
                Divider()
                Button(role: .destructive) { onReset() } label: {
                    Label("Reset tasks (server)", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(.thinMaterial)
                    .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                    Text(current.shortLabel)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
            }
            .frame(height: 32)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private extension BigKidDebugScenario {
    /// Compact label that fits on the floating pill.
    var shortLabel: String {
        switch self {
        case .live:               "Live"
        case .homeAllTodo:        "Home"
        case .homeOneSubmitted:   "Submitted"
        case .homeOneRedo:        "Redo"
        case .reflectionStateA:   "Refl A"
        case .reflectionStateB:   "Refl B"
        case .reflectionApproved: "Approved"
        case .dailyComplete:      "Daily ✓"
        case .screenTimeFinished: "Time out"
        }
    }
}
#endif
