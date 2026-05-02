import SwiftUI

struct BigKidHomeReflectionView: View {
    enum SubState { case a, b }

    @Environment(BigKidState.self) private var state
    let subState: SubState
    var onStartReflection: () -> Void
    var onTaskTap: (BigKidTask) -> Void
    var onNudgeParent: () -> Void

    private var doneCount: Int {
        state.tasks.filter { $0.status == .done || $0.bypass?.status == .approved }.count
    }
    private var allDone: Bool { state.allTasksDone }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                greeting
                heroCard.padding(.bottom, 22)
                tasksHeader.padding(.bottom, 10)
                questPips.padding(.bottom, 14)
                taskList
            }
            .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
            .padding(.top, EvlinKidMetrics.Padding.screenTop)
            .padding(.bottom, 40)
        }
        .background(EvlinKidColors.Reflection.bgSurface.ignoresSafeArea())
    }

    private var greeting: some View {
        Text("Hi, \(state.childName.split(separator: " ").first ?? "there")")
            .font(.system(size: 22, weight: .heavy))
            .tracking(EvlinKidMetrics.Letter.mediumTitle)
            .foregroundStyle(EvlinKidColors.Reflection.titleText)
            .padding(.vertical, 8)
            .padding(.bottom, 10)
    }

    private var heroCard: some View {
        // home-reflection.jsx lines 117–163
        ZStack(alignment: .topLeading) {
            EvlinKidColors.Reflection.cardBg
            // decorative dot
            Circle().fill(EvlinKidColors.Reflection.cardAccent)
                .frame(width: 120, height: 120)
                .offset(x: 220, y: -30)
                .clipped()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(EvlinKidColors.Reflection.iconBg)
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(EvlinKidColors.Reflection.labelText)
                    }
                    .frame(width: 38, height: 38)
                    Text("SCREEN TIME LOCKED")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(EvlinKidColors.Reflection.labelText)
                }
                .padding(.bottom, 10)
                Text(headline)
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(EvlinKidColors.Reflection.titleText)
                    .padding(.bottom, 6)
                Text(bodyText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EvlinKidColors.Reflection.bodyText)
                    .padding(.bottom, 16)
                ctaButton
            }
            .padding(22)
        }
        .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card)
                .stroke(EvlinKidColors.Reflection.cardBorder, lineWidth: 1)
        )
    }

    private var headline: String {
        switch subState {
        case .a: return "Finish Reflection to unlock phone"
        case .b: return "You finished — nice work."
        }
    }

    private var bodyText: String {
        switch subState {
        case .a: return "Your screen time is paused until you complete a quick reflection."
        case .b: return "Your parent will take a look soon. Once they're happy with it, you'll get your screen time back."
        }
    }

    @ViewBuilder
    private var ctaButton: some View {
        switch subState {
        case .a:
            startButton(title: "Start Reflection", action: onStartReflection)
        case .b:
            nudgeButton
        }
    }

    private func startButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(0.2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(EvlinKidColors.Reflection.buttonBg, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var nudgeButton: some View {
        let endsAt = state.notifyParentCooldownEndsAt
        let now = Date()
        if let endsAt, endsAt > now {
            CooldownLabel(endsAt: endsAt)
        } else {
            startButton(title: "Give them a nudge", action: onNudgeParent)
        }
    }

    private var tasksHeader: some View {
        HStack {
            Text("Today's tasks")
                .font(.system(size: 20, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(EvlinKidColors.Reflection.titleText)
            Spacer()
            HStack(spacing: 5) {
                if allDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(EvlinKidColors.Reflection.labelText)
                }
                Text("\(doneCount) of \(state.tasks.count) done")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(allDone ? EvlinKidColors.Reflection.labelText : EvlinKidColors.Reflection.bodyText)
            }
        }
        .padding(.horizontal, 4)
    }

    private var questPips: some View {
        HStack(spacing: 5) {
            ForEach(state.tasks) { t in
                Capsule().fill(pipColor(for: t)).frame(height: EvlinKidMetrics.Size.segPip)
            }
        }
        .padding(.horizontal, 4)
    }

    private func pipColor(for t: BigKidTask) -> Color {
        if t.status == .done || t.bypass?.status == .approved { return EvlinKidColors.Reflection.pipDone }
        if t.status == .submitted { return EvlinKidColors.Reflection.pipSubmitted }
        return EvlinKidColors.Reflection.pipTodo
    }

    private var taskList: some View {
        VStack(spacing: EvlinKidMetrics.Padding.listGap) {
            ForEach(state.tasks) { t in
                EvKidTaskRow(task: t, palette: .brown) { onTaskTap(t) }
            }
        }
    }
}

private struct CooldownLabel: View {
    let endsAt: Date
    @State private var remaining: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Text("Just sent — try again in \(format(remaining))")
                .font(.system(size: 15, weight: .heavy))
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(EvlinKidColors.Reflection.buttonBg.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 14))
        .onAppear { remaining = max(0, endsAt.timeIntervalSinceNow) }
        .onReceive(timer) { _ in remaining = max(0, endsAt.timeIntervalSinceNow) }
    }

    private func format(_ s: TimeInterval) -> String {
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#if DEBUG
#Preview("State A") {
    BigKidHomeReflectionView(
        subState: .a,
        onStartReflection: {}, onTaskTap: { _ in }, onNudgeParent: {}
    )
    .environment(BigKidState(snapshot: .fixture(
        reflection: .fixture(stepsCompleted: [])
    )))
}
#Preview("State B (idle)") {
    BigKidHomeReflectionView(
        subState: .b,
        onStartReflection: {}, onTaskTap: { _ in }, onNudgeParent: {}
    )
    .environment(BigKidState(snapshot: .fixture(
        reflection: .fixture(status: .submitted, stepsCompleted: [.video, .quiz, .writing])
    )))
}
#Preview("State B (cooldown)") {
    let snap = ChildStateResponse(
        childName: "Liam", minutesLeft: 0, minutesMax: 120,
        tasks: [.fixture(status: .todo)],
        reflectionRequest: .fixture(status: .submitted, stepsCompleted: [.video, .quiz, .writing]),
        notifyParentCooldownEndsAt: Date().addingTimeInterval(3 * 60 + 14),
        dailyCompleteAcknowledged: false, screenTimeFinishedAcknowledged: false
    )
    return BigKidHomeReflectionView(
        subState: .b,
        onStartReflection: {}, onTaskTap: { _ in }, onNudgeParent: {}
    )
    .environment(BigKidState(snapshot: snap))
}
#endif
