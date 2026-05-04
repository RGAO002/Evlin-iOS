import SwiftUI

struct BigKidLockedView: View {
    @Environment(BigKidState.self) private var state
    var onTapStep: (BigKidReflectionStep) -> Void
    var onUnlock: () -> Void

    #if DEBUG
    @EnvironmentObject private var client: BigKidAPIClient
    @EnvironmentObject private var poller: BigKidStatePoller
    @State private var debugRunning: Bool = false
    @State private var debugStatus: String = ""
    #endif

    private var progress: Int {
        state.reflectionRequest?.stepsCompleted.count ?? 0
    }
    private var allDone: Bool { progress >= 3 }
    private var firstName: String {
        String(state.childName.split(separator: " ").first ?? "there")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topChipRow.padding(.top, 2).padding(.bottom, 18)
            segmentedBar.padding(.bottom, 28)
            headlineBlock.padding(.bottom, 24)
            stepsList
            Spacer(minLength: 24)
            primaryButton
            disclaimer.padding(.top, 14)
            #if DEBUG
            debugSkipButton.padding(.top, 12)
            #endif
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.top, 20)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private var topChipRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: allDone ? "checkmark" : "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(allDone ? EvlinKidColors.green500 : EvlinKidColors.ink2)
                Text(allDone ? "READY TO UNLOCK" : "DEVICES LOCKED")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(allDone ? EvlinKidColors.green700 : EvlinKidColors.ink2)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(allDone ? EvlinKidColors.green100 : EvlinKidColors.surface2,
                        in: Capsule())
            .overlay(Capsule()
                .stroke(allDone ? EvlinKidColors.green300 : EvlinKidColors.line, lineWidth: 1))
            Spacer()
            Text("\(progress) / 3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EvlinKidColors.ink3)
        }
    }

    private var segmentedBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(i < progress ? EvlinKidColors.green500 : EvlinKidColors.line)
                    .frame(height: 4)
            }
        }
    }

    /// Body copy under the "Hey <name>" headline.
    ///
    /// Three branches:
    /// 1. All three reflection steps done → celebratory copy.
    /// 2. `displayReason` present (Gemini rephrased the parent's reason
    ///    into a kid-readable sentence) → use it verbatim and append
    ///    the canonical "Work through these three steps…" suffix.
    /// 3. Fallback (fixture path / Gemini failed) → generic neutral
    ///    sentence so the kid never sees raw parent input that might
    ///    be a fragment or contain rude wording.
    private var messageBody: String {
        if allDone {
            return "You did the work. Tap below to finish up and get your devices back."
        }
        let suffix = "Work through these three steps and your devices will unlock."
        if let display = state.reflectionRequest?.displayReason?
            .trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            // displayReason is a complete sentence; just append the suffix.
            let needsPeriod = !display.hasSuffix(".") && !display.hasSuffix("。")
                && !display.hasSuffix("!") && !display.hasSuffix("?")
            return needsPeriod ? "\(display). \(suffix)" : "\(display) \(suffix)"
        }
        return "Your devices are locked for a bit. \(suffix)"
    }

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("REFLECTION TIME")
                .font(.system(size: 12, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(EvlinKidColors.green500)
            Text("Hey \(firstName).")
                .font(.system(size: 38, weight: .heavy))
                .tracking(-1)
                .foregroundStyle(EvlinKidColors.ink)
            Text(messageBody)
                .font(.system(size: 16))
                .foregroundStyle(EvlinKidColors.ink2)
                .lineSpacing(3)
                .frame(maxWidth: 340, alignment: .leading)
        }
    }

    private var stepsList: some View {
        VStack(spacing: 10) {
            stepRow(.video,   index: 0, title: "Watch the video",     sub: "2 min")
            stepRow(.quiz,    index: 1, title: "Answer the quiz",     sub: "5 questions")
            stepRow(.writing, index: 2, title: "Write a reflection",  sub: "3 sentences")
        }
    }

    private func stepRow(_ step: BigKidReflectionStep, index: Int, title: String, sub: String) -> some View {
        let done = (state.reflectionRequest?.stepsCompleted ?? []).contains(step)
        let active = index == progress && !done
        let locked = index > progress && !done

        let bg: Color   = done ? EvlinKidColors.green50  : .white
        let border = done ? EvlinKidColors.green200
                         : (active ? EvlinKidColors.green500 : EvlinKidColors.line)
        let borderW: CGFloat = active ? 1.5 : 1
        let iconBg = done || active ? EvlinKidColors.green500 : EvlinKidColors.surface2
        let iconFg: Color = done || active ? .white : EvlinKidColors.ink4
        let titleC = done ? EvlinKidColors.green700 : (active ? EvlinKidColors.ink : EvlinKidColors.ink3)
        let subC   = done ? EvlinKidColors.green600 : (active ? EvlinKidColors.ink2 : EvlinKidColors.ink4)

        return Button(action: { if active { onTapStep(step) } }) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(iconBg)
                    Image(systemName: done ? "checkmark"
                                          : (locked ? "lock.fill" : iconName(for: step)))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconFg)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(title)")
                        .font(.system(size: 16, weight: .bold))
                        .tracking(EvlinKidMetrics.Letter.body)
                        .foregroundStyle(titleC)
                    Text(done ? "Complete" : (active ? sub : "Locked"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(subC)
                }
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(EvlinKidColors.green500)
                } else if done {
                    Text("DONE")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(EvlinKidColors.green500)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.row))
            .overlay(
                RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.row)
                    .stroke(border, lineWidth: borderW)
            )
            .shadow(color: active ? EvlinKidColors.green500.opacity(0.12) : .clear,
                    radius: 10, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!active)
    }

    private func iconName(for step: BigKidReflectionStep) -> String {
        switch step { case .video: "video.fill"; case .quiz: "list.bullet.clipboard"; case .writing: "pencil" }
    }

    private var primaryButton: some View {
        Button(action: allDone ? onUnlock : { onTapStep(nextStep) }) {
            Text(allDone ? "Unlock my devices" : nextLabel)
                .font(.system(size: 17, weight: .bold))
                .tracking(EvlinKidMetrics.Letter.body)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: EvlinKidMetrics.Size.buttonHeightLg)
                .background(EvlinKidColors.green500)
                .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.button))
                .shadow(color: EvlinKidColors.green500.opacity(0.24), radius: 12, y: 10)
        }
        .buttonStyle(.plain)
    }

    private var nextStep: BigKidReflectionStep {
        let steps: [BigKidReflectionStep] = [.video, .quiz, .writing]
        return steps[min(progress, 2)]
    }

    private var nextLabel: String {
        switch progress {
        case 0: "Start the video"
        case 1: "Start the quiz"
        case 2: "Start writing"
        default: "Continue"
        }
    }

    private var disclaimer: some View {
        Text("You can't leave this screen until you're done")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(EvlinKidColors.ink3)
            .frame(maxWidth: .infinity)
    }

    #if DEBUG
    /// Fast-forwards the reflection through video → quiz → essay-submitted
    /// so the kid screen lands at "awaiting parent approval" without
    /// actually playing the video, answering the quiz, or typing an essay.
    /// Stops short of approval — that's the parent's side, exercise it
    /// from chat ("approve his reflection") or the parent debug menu.
    private var debugSkipButton: some View {
        VStack(spacing: 6) {
            Button(action: runDebugSkip) {
                HStack(spacing: 6) {
                    if debugRunning { ProgressView().controlSize(.small) }
                    Image(systemName: "forward.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(debugRunning ? "Skipping…" : "DEBUG: Skip to essay-submitted")
                        .font(.system(size: 11, weight: .semibold).monospaced())
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(.orange.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(debugRunning)
            if !debugStatus.isEmpty {
                Text(debugStatus)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.orange.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func runDebugSkip() {
        guard let rid = state.reflectionRequest?.id else { return }
        debugRunning = true
        debugStatus = ""
        Task {
            do {
                // Video step.
                _ = try await client.reflectionStepComplete(rid: rid, step: .video)
                // Quiz step. The store's submit_essay() looks for `quiz` in
                // stepsCompleted directly; the per-question quiz-answer
                // endpoint is what the real UI uses but is optional for
                // moving stepsCompleted forward — step-complete is enough.
                _ = try await client.reflectionStepComplete(rid: rid, step: .quiz)
                // Essay submission flips the request to .submitted (all
                // three steps now satisfied) which is exactly the
                // "awaiting parent approval" state the user asked for.
                _ = try await client.reflectionEssay(
                    rid: rid,
                    text: "DEBUG: auto-completed via skip button. Real essay would describe what I'd do differently next time."
                )
                await MainActor.run { debugStatus = "✅ submitted, awaiting parent approval" }
                await poller.refreshNow()
            } catch {
                await MainActor.run { debugStatus = "⚠️ \(error.localizedDescription)" }
            }
            await MainActor.run { debugRunning = false }
        }
    }
    #endif
}

#if DEBUG
#Preview("0/3") {
    BigKidLockedView(onTapStep: { _ in }, onUnlock: {})
        .environment(BigKidState(snapshot: .fixture(reflection: .fixture())))
}
#Preview("2/3") {
    BigKidLockedView(onTapStep: { _ in }, onUnlock: {})
        .environment(BigKidState(snapshot: .fixture(
            reflection: .fixture(stepsCompleted: [.video, .quiz])
        )))
}
#Preview("3/3") {
    BigKidLockedView(onTapStep: { _ in }, onUnlock: {})
        .environment(BigKidState(snapshot: .fixture(
            reflection: .fixture(stepsCompleted: [.video, .quiz, .writing])
        )))
}
#endif
