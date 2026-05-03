import SwiftUI

struct BigKidWritingView: View {
    let prompt: String
    var onSubmit: (String) async -> Void

    @State private var text: String = ""
    @State private var showTryAgain: Bool = false
    @State private var submitting: Bool = false

    private var sentenceCount: Int {
        text.split { ".!?".contains($0) }
            .filter { $0.trimmingCharacters(in: .whitespaces).count > 3 }
            .count
    }
    private var minMet: Bool {
        sentenceCount >= 3 && text.trimmingCharacters(in: .whitespaces).count >= 40
    }
    private var uniqueWords: Int {
        Set(text.split { !$0.isLetter }.map { $0.lowercased() }).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepLabel.padding(.bottom, 16)
            promptCard.padding(.bottom, 16)
            editor
            countersRow.padding(.top, 10).padding(.bottom, 12)
            if showTryAgain { tryAgainHint.padding(.bottom, 12) }
            submitButton
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.top, 20).padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private var stepLabel: some View {
        Text("STEP 3 OF 3 — REFLECTION TIME")
            .font(.system(size: 12, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(EvlinKidColors.green500)
    }

    private var promptCard: some View {
        EvKidCard(tone: .amber, padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("EVLIN ASKS")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(EvlinKidColors.green700)
                Text(prompt)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(EvlinKidColors.ink)
                    .lineSpacing(3)
            }
        }
    }

    private var editor: some View {
        TextField("Take your time. Write at least 3 sentences...",
                  text: $text, axis: .vertical)
            .lineLimit(8...50)
            .font(.system(size: 16))
            .foregroundStyle(EvlinKidColors.ink)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(EvlinKidColors.line, lineWidth: 1.5)
            )
    }

    private var countersRow: some View {
        HStack {
            Text("\(sentenceCount) of 3 sentences")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink3)
            Spacer()
            HStack(spacing: 6) {
                if minMet {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(EvlinKidColors.green600)
                }
                Text(minMet ? "Minimum met" : "Keep going")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(minMet ? EvlinKidColors.green600 : EvlinKidColors.ink3)
            }
        }
    }

    private var tryAgainHint: some View {
        EvKidCard(tone: .amber, padding: 14) {
            Text("Thanks for writing — can you add a bit more about how you felt? A longer answer helps you more than me.")
                .font(.system(size: 13))
                .foregroundStyle(EvlinKidColors.green700)
                .lineSpacing(2)
        }
    }

    private var submitButton: some View {
        EvKidBigButton(isDisabled: !minMet || submitting, action: submit) {
            Text(submitting ? "Submitting…" : "Submit reflection")
        }
    }

    private func submit() {
        if uniqueWords < 12 { showTryAgain = true; return }
        submitting = true
        Task { await onSubmit(text); submitting = false }
    }
}

#if DEBUG
#Preview {
    BigKidWritingView(prompt: "What were you feeling, and what could you do differently tomorrow?",
                      onSubmit: { _ in })
}
#endif
