import Combine
import SwiftUI

struct BigKidHomeReflectionView: View {
    enum SubState { case a, b }

    @Environment(BigKidState.self) private var state
    let subState: SubState
    var onStartReflection: () -> Void
    var onTaskTap: (BigKidTask) -> Void
    var onNudgeParent: () -> Void
    /// Optional refresh hook: pull-to-refresh on the scroll view + an
    /// auto-tick every 10s while in State B (waiting for parent
    /// approval) call this. Default no-op so State A doesn't get
    /// affected if the host doesn't supply one.
    var onRefresh: () async -> Void = {}

    private var doneCount: Int {
        state.tasks.filter { $0.status == .done || $0.bypass?.status == .approved }.count
    }
    private var allDone: Bool { state.allTasksDone }

    /// 10-second poll cadence while waiting for parent approval —
    /// faster than the global 60s loop so the Complete screen
    /// surfaces within ~10s of an approve.
    private let stateBPollTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

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
        .refreshable {
            await onRefresh()
        }
        .onReceive(stateBPollTimer) { _ in
            guard subState == .b else { return }
            Task { await onRefresh() }
        }
    }

    private var displayChildName: String {
        let server = state.childName.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = (UserDefaults.standard.string(forKey: "evlin.childProfileName") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen: String
        if !server.isEmpty && server.caseInsensitiveCompare("Liam") != .orderedSame {
            chosen = server
        } else {
            chosen = local.isEmpty ? server : local
        }
        return chosen.split(separator: " ").first.map(String.init) ?? "there"
    }

    private var greeting: some View {
        Text("Hi, \(displayChildName)")
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

    /// Non-nil ⇒ the parent has sent the reflection back. Drives the
    /// rework variant of the State A headline / body / CTA.
    private var redoNote: String? {
        let trimmed = state.reflectionRequest?.parentRedoNote?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return nil
    }

    private var headline: String {
        switch subState {
        case .a:
            return redoNote != nil
                ? "Rework your essay"
                : "Finish Reflection to unlock phone"
        case .b:
            return "You finished — nice work."
        }
    }

    private var bodyText: String {
        switch subState {
        case .a:
            if let redoNote {
                return "Your parent sent it back: \u{201C}\(redoNote)\u{201D}"
            }
            return "Your screen time is paused until you complete a quick reflection."
        case .b:
            return "Your parent will take a look soon. Once they're happy with it, you'll get your screen time back."
        }
    }

    @ViewBuilder
    private var ctaButton: some View {
        switch subState {
        case .a:
            VStack(spacing: 12) {
                startButton(
                    title: redoNote != nil ? "Rework Essay" : "Start Reflection",
                    action: onStartReflection
                )
                stuckButton
            }
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

    /// State-A "I'm stuck" affordance. While all apps are shielded the kid
    /// can't text/call, so this pings the parent (same nudge mechanism as
    /// State B). Flips to a confirmation once the cooldown is armed, so the
    /// tap has visible feedback instead of looking dead.
    @ViewBuilder
    private var stuckButton: some View {
        if let endsAt = state.notifyParentCooldownEndsAt, endsAt > Date() {
            Text("Sent — your parent has been notified")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Button("Tell your parent you're stuck", action: onNudgeParent)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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

    private var submittedAwaitingReviewCount: Int {
        state.tasks.filter { $0.status == .submitted }.count
    }

    private var questPips: some View {
        HStack(spacing: 5) {
            ForEach(0..<state.tasks.count, id: \.self) { index in
                Capsule()
                    .fill(questPipColor(at: index))
                    .frame(height: EvlinKidMetrics.Size.segPip)
            }
        }
        .padding(.horizontal, 4)
    }

    private func questPipColor(at index: Int) -> Color {
        if index < doneCount { return EvlinKidColors.Reflection.pipDone }
        if index < doneCount + submittedAwaitingReviewCount { return EvlinKidColors.Reflection.pipSubmitted }
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
        dailyCompleteAcknowledged: false, screenTimeFinishedAcknowledged: false,
        lastResolvedReflection: nil
    )
    return BigKidHomeReflectionView(
        subState: .b,
        onStartReflection: {}, onTaskTap: { _ in }, onNudgeParent: {}
    )
    .environment(BigKidState(snapshot: snap))
}
#endif
