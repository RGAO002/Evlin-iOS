import SwiftUI

struct BigKidQuizView: View {
    let request: ReflectionRequest
    var onAnswer: (Int, Int) async -> QuizAnswerOutcome
    var onComplete: () async -> Void
    var onRetry: () -> Void

    @State private var currentIndex: Int = 0
    @State private var selected: Int? = nil
    @State private var answers: [Int] = []
    @State private var score: Int = 0
    @State private var showResults: Bool = false
    @State private var submitting: Bool = false

    var body: some View {
        Group {
            if showResults { resultsView } else { questionView }
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.top, 20).padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private var questionView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 20)
            Text(request.quiz[currentIndex].q)
                .font(.system(size: 24, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(EvlinKidColors.ink)
                .lineSpacing(4)
                .padding(.top, 8).padding(.bottom, 24)
            options.padding(.bottom, 20)
            Spacer(minLength: 0)
            confirmButton
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STEP 2 OF 3 — QUESTION \(currentIndex + 1) OF \(request.quiz.count)")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(EvlinKidColors.green500)
            EvKidProgressBar(value: Double(currentIndex + 1),
                             max: Double(request.quiz.count),
                             tone: .primary, height: 4)
        }
    }

    private var options: some View {
        VStack(spacing: 10) {
            ForEach(Array(request.quiz[currentIndex].options.enumerated()), id: \.offset) { idx, text in
                Button { selected = idx } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .stroke(selected == idx ? EvlinKidColors.green500 : EvlinKidColors.line,
                                        lineWidth: 2)
                                .background(
                                    Circle().fill(selected == idx ? EvlinKidColors.green500 : .clear)
                                )
                            if selected == idx {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 26, height: 26)
                        Text(text)
                            .font(.system(size: 16, weight: .semibold))
                            .tracking(-0.1)
                            .foregroundStyle(EvlinKidColors.ink)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(18)
                    .background(selected == idx ? EvlinKidColors.green50 : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(selected == idx ? EvlinKidColors.green500 : EvlinKidColors.line,
                                    lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var confirmButton: some View {
        EvKidBigButton(isDisabled: selected == nil || submitting,
                       action: confirm) {
            Text(submitting ? "Checking…" : "Confirm answer")
        }
    }

    private func confirm() {
        guard let s = selected else { return }
        submitting = true
        Task {
            let outcome = await onAnswer(currentIndex, s)
            answers.append(s)
            selected = nil
            score = outcome.score
            submitting = false
            if currentIndex == request.quiz.count - 1 {
                showResults = true
            } else {
                currentIndex += 1
            }
        }
    }

    private var resultsView: some View {
        let passed = score >= 4
        return VStack(spacing: 0) {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(passed ? EvlinKidColors.green100 : EvlinKidColors.surface2)
                        .overlay(Circle().stroke(passed ? EvlinKidColors.green300 : EvlinKidColors.line, lineWidth: 2))
                    Image(systemName: passed ? "checkmark" : "questionmark")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(passed ? EvlinKidColors.green500 : EvlinKidColors.ink2)
                }
                .frame(width: 84, height: 84)
                .padding(.top, 40)
                Text(passed ? "Nice work." : "Almost there.")
                    .font(.system(size: 28, weight: .heavy))
                    .tracking(-0.8)
                    .foregroundStyle(EvlinKidColors.ink)
                Text(passed ? "You understood what matters. One more step to go."
                            : "Have another go — you need 4 out of 5.")
                    .font(.system(size: 15))
                    .foregroundStyle(EvlinKidColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .lineSpacing(2)
            }
            VStack(spacing: 8) {
                Text("YOUR SCORE")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(passed ? EvlinKidColors.green700 : EvlinKidColors.ink3)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(score)")
                        .font(.system(size: 72, weight: .heavy))
                        .tracking(-3)
                        .foregroundStyle(passed ? EvlinKidColors.green500 : EvlinKidColors.ink2)
                        .monospacedDigit()
                    Text("/ \(request.quiz.count)")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(EvlinKidColors.ink3)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(passed ? EvlinKidColors.green50 : EvlinKidColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(passed ? EvlinKidColors.green200 : EvlinKidColors.line, lineWidth: 1)
            )
            .padding(.top, 28)
            Spacer(minLength: 0)
            EvKidBigButton(action: {
                if passed {
                    continueAction()
                } else {
                    retryAction()
                }
            }) {
                Text(passed ? "Continue" : "Retry quiz")
            }
            .padding(.top, 24)
        }
    }

    private func continueAction() {
        Task { await onComplete() }
    }
    private func retryAction() {
        currentIndex = 0; selected = nil; answers = []; score = 0; showResults = false
        onRetry()
    }
}

#if DEBUG
#Preview {
    BigKidQuizView(request: .fixture(),
                   onAnswer: { _, _ in QuizAnswerOutcome(correct: true, allCorrect: false, score: 5) },
                   onComplete: {}, onRetry: {})
}
#endif
