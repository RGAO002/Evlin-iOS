import SwiftUI

struct BigKidCompleteView: View {
    let request: ReflectionRequest
    var onContinue: () async -> Void

    @State private var ackInFlight: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(EvlinKidColors.green100)
                        .overlay(Circle().stroke(EvlinKidColors.green300, lineWidth: 2))
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(EvlinKidColors.green500)
                }
                .frame(width: 84, height: 84)
                .padding(.top, 40)
                Text("Welcome back")
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.8)
                    .foregroundStyle(EvlinKidColors.ink)
                if let note = request.parentNote, !note.isEmpty {
                    Text("\u{201C}\(note)\u{201D}")
                        .font(.system(size: 16))
                        .italic()
                        .foregroundStyle(EvlinKidColors.ink2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .lineSpacing(3)
                } else {
                    Text("Thanks for taking the time to think it through. Tomorrow's a fresh start.")
                        .font(.system(size: 16))
                        .foregroundStyle(EvlinKidColors.ink2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .lineSpacing(3)
                }
            }
            EvKidCard(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("YOU COMPLETED")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(EvlinKidColors.ink3)
                    summaryRow(icon: "video.fill", label: "Video watched", detail: "2 min")
                    summaryRow(icon: "list.bullet.clipboard", label: "Quiz passed",
                               detail: "\(request.quizScore ?? 4) / \(request.quiz.count) correct")
                    summaryRow(icon: "pencil", label: "Reflection submitted", detail: "3+ sentences")
                }
            }
            .padding(.top, 28)
            Spacer(minLength: 24)
            EvKidBigButton(isDisabled: ackInFlight, action: ack) {
                Text(ackInFlight ? "Heading home…" : "Back to home")
            }
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private func summaryRow(icon: String, label: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(EvlinKidColors.green100)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(EvlinKidColors.green600)
            }
            .frame(width: 36, height: 36)
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(EvlinKidColors.ink)
            Spacer(minLength: 0)
            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink3)
        }
    }

    private func ack() {
        ackInFlight = true
        Task { await onContinue(); ackInFlight = false }
    }
}

#if DEBUG
private func _previewRequest() -> ReflectionRequest {
    let base = ReflectionRequest.fixture(
        status: .approved,
        stepsCompleted: [.video, .quiz, .writing]
    )
    return ReflectionRequest(
        id: base.id, reason: base.reason, displayReason: base.displayReason,
        videoId: base.videoId, videoTitle: base.videoTitle,
        writingPrompt: base.writingPrompt, quiz: base.quiz,
        stepsCompleted: base.stepsCompleted, quizScore: 5, essayText: "ok",
        status: .approved,
        parentNote: "Thanks for being honest. Proud of you.",
        submittedAt: Date(), approvedAt: Date()
    )
}

#Preview {
    BigKidCompleteView(request: _previewRequest(), onContinue: {})
}
#endif
