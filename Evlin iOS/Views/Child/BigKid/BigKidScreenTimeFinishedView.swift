import SwiftUI

struct BigKidScreenTimeFinishedView: View {
    @Environment(BigKidState.self) private var state
    var onAck: () async -> Void

    @State private var ackInFlight: Bool = false

    private var doneCount: Int {
        state.tasks.filter { $0.status == .done || $0.bypass?.status == .approved }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(EvlinKidColors.green600)
                    .padding(.top, 40)
                Text("That's your screen time for today")
                    .font(.system(size: 28, weight: .heavy))
                    .tracking(-0.7)
                    .foregroundStyle(EvlinKidColors.ink)
                    .multilineTextAlignment(.center)
                Text("Nice work sticking with it. Go do something off-screen — we'll see you tomorrow.")
                    .font(.system(size: 15))
                    .foregroundStyle(EvlinKidColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .lineSpacing(3)
            }
            EvKidCard(padding: 20) {
                VStack(spacing: 18) {
                    statRow("Tasks completed today", "\(doneCount) of \(state.tasks.count)")
                    Divider()
                    statRow("Screen time used", "\(state.minutesMax) min")
                    Divider()
                    statRow("Devices unlock", "Tomorrow, 7:00 AM")
                }
            }
            .padding(.top, 28)
            Spacer(minLength: 0)
            EvKidBigButton(isDisabled: ackInFlight, action: ack) {
                Text(ackInFlight ? "OK" : "OK")
            }
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink2)
            Spacer()
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(EvlinKidColors.ink)
        }
    }

    private func ack() { ackInFlight = true; Task { await onAck(); ackInFlight = false } }
}

#if DEBUG
#Preview {
    BigKidScreenTimeFinishedView(onAck: {})
        .environment(BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done), .fixture(status: .done)],
            minutesLeft: 0
        )))
}
#endif
