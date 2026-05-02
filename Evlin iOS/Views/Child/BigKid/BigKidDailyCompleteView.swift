import SwiftUI

struct BigKidDailyCompleteView: View {
    @Environment(BigKidState.self) private var state
    var onContinue: () async -> Void

    @State private var ackInFlight: Bool = false

    private var earned: Int { Swift.max(0, Swift.min(state.minutesMax, state.minutesLeft)) }
    private var hours: Int { earned / 60 }
    private var mins: Int { earned % 60 }
    private var pct: Double { Double(earned) / Double(state.minutesMax) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Image(systemName: "sparkles")
                    .font(.system(size: 56))
                    .foregroundStyle(EvlinKidColors.green500)
                    .padding(.top, 32)
                Text("Great job today")
                    .font(.system(size: 28, weight: .heavy))
                    .tracking(-0.7)
                    .foregroundStyle(EvlinKidColors.ink)
                Text("All tasks done. Here's the screen time you've earned.")
                    .font(.system(size: 15))
                    .foregroundStyle(EvlinKidColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .lineSpacing(3)
            }
            EvKidCard(tone: .green, padding: 22) {
                VStack(spacing: 14) {
                    HStack {
                        Text("YOU'VE EARNED")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(EvlinKidColors.green700)
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if hours > 0 {
                                Text("\(hours)").font(.system(size: 32, weight: .heavy))
                                    .tracking(-1).foregroundStyle(EvlinKidColors.green700)
                                    .monospacedDigit()
                                Text("h").font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(EvlinKidColors.green700)
                            }
                            Text("\(mins)").font(.system(size: 32, weight: .heavy))
                                .tracking(-1).foregroundStyle(EvlinKidColors.green700)
                                .monospacedDigit()
                                .padding(.leading, hours > 0 ? 4 : 0)
                            Text("m").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(EvlinKidColors.green700)
                        }
                    }
                    EvKidProgressBar(value: Double(earned), max: Double(state.minutesMax),
                                     tone: .primary, height: 14)
                    HStack {
                        Text("\(Int(pct * 100))% OF TODAY")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(EvlinKidColors.green700)
                        Spacer()
                        Text("\(state.minutesMax) MIN CAP")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(EvlinKidColors.green700.opacity(0.7))
                    }
                }
            }
            .padding(.top, 24)
            EvKidCard(padding: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("TODAY YOU DID")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(EvlinKidColors.ink3)
                    ForEach(state.tasks) { t in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(EvlinKidColors.green500)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 22, height: 22)
                            Text(t.title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(EvlinKidColors.ink)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.top, 16)
            Spacer(minLength: 0)
            EvKidBigButton(isDisabled: ackInFlight, action: continueAction) {
                Text(ackInFlight ? "Heading home…" : "Continue")
            }
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private func continueAction() {
        ackInFlight = true
        Task { await onContinue(); ackInFlight = false }
    }
}

#if DEBUG
#Preview {
    BigKidDailyCompleteView(onContinue: {})
        .environment(BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done), .fixture(status: .done), .fixture(status: .done)],
            minutesLeft: 95,
            minutesMax: 120
        )))
}
#endif
