import SwiftUI

/// Per-step parent preview for a reflection.
///
/// Mirrors `Evlin Parent Dashboard (1).html` lines 1080-1212 exactly:
///  - Single sticky top bar (back button + "Step N of 3 — {Video|Quiz|
///    Written response}" — no kicker, no subtitle).
///  - Page background is white. NO outer card wrappers; each step body
///    is rendered directly on the page with its own padding rhythm.
///  - **Video (step 1)** — full-bleed gradient block (~320pt+) with
///    the kid-side YouTube embed and a duration chip overlay. Below
///    it: title (Manrope 22) + lock-rule box + italic footer note.
///  - **Quiz (step 2)** — single "Correct answers shown for parent
///    visibility · {Name} needs 4 of 5 to pass." line, then numbered
///    questions with correct options highlighted in green.
///  - **Writing (step 3)** — optional review-state pill, prompt card
///    (green), reflection text card (white outline), stats row, then
///    either Approve/Request-redo buttons or a done-state strip.
struct ReflectionStepDetailView: View {
    let reflectionId: UUID
    let stepId: UUID
    var onBack: (() -> Void)? = nil

    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @EnvironmentObject private var apiClient: APIClient
    @State private var activeAlert: WritingActionAlert?
    /// Local mutation + navigation pop is deferred until the user
    /// dismisses the success alert; otherwise the underlying view
    /// instantly re-renders the missing/empty state behind the open
    /// alert, which reads as broken. Set in `handleApprove` /
    /// `handleRedo` right before the alert opens; consumed in
    /// `applyPendingCleanup()` when OK is tapped.
    @State private var pendingCleanup: PendingCleanup? = nil

    private var summary: ParentReflectionSummary? {
        reflectionStore.summary(reflectionId: reflectionId)
    }

    private var step: ParentReflectionStepArtifact? {
        reflectionStore.step(reflectionId: reflectionId, stepId: stepId)
    }

    private var stepIndex: Int? {
        summary?.steps.firstIndex { $0.id == stepId }
    }

    var body: some View {
        VStack(spacing: 0) {
            stickyHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let summary, let step, let stepIndex {
                        stepContent(step, summary: summary, index: stepIndex)
                    } else {
                        missingState
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.white.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    applyPendingCleanup()
                }
            )
        }
    }

    /// Drains `pendingCleanup` once the user dismisses the success
    /// alert. Mutates the local store (clear / apply-redo) and pops
    /// back to Profile so the parent doesn't end up staring at the
    /// now-empty Step view.
    @MainActor
    private func applyPendingCleanup() {
        let cleanup = pendingCleanup
        pendingCleanup = nil
        switch cleanup {
        case .approve(let childId):
            reflectionStore.clear(childId: childId)
        case .redo(let childId, let note):
            reflectionStore.applyParentRedoLocally(childId: childId, redoNote: note)
        case nil:
            break
        }
        onBack?()
    }

    /// Top chrome — matches reference HTML lines 1083-1091: small back
    /// button on the left + step label (no kicker, no subtitle). Solid
    /// near-white background with a 1pt bottom border. SwiftUI keeps
    /// this header pinned because it sits in the parent VStack above
    /// the ScrollView (not inside it).
    private var stickyHeader: some View {
        HStack(spacing: 8) {
            Button(action: { onBack?() }) {
                Image(systemName: "arrow.backward")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text(stepHeaderTitle)
                .font(.custom("Manrope", size: 16).weight(.heavy))
                .tracking(-0.16)
                .foregroundStyle(Color.evPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0xFC / 255, green: 0xFC / 255, blue: 0xFD / 255))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.evOutlineVariant)
                .frame(height: 1)
        }
    }

    /// "Step N of 3 — {Video | Quiz | Written response}". Falls back
    /// to "Reflection" if the step / summary couldn't be resolved.
    private var stepHeaderTitle: String {
        guard let step, let summary, let stepIndex else {
            return "Reflection"
        }
        let suffix: String
        switch step.kind {
        case .video:   suffix = "Video"
        case .quiz:    suffix = "Quiz"
        case .writing: suffix = "Written response"
        }
        return "Step \(stepIndex + 1) of \(summary.steps.count) — \(suffix)"
    }

    @ViewBuilder
    private func stepContent(
        _ step: ParentReflectionStepArtifact,
        summary: ParentReflectionSummary,
        index: Int
    ) -> some View {
        switch step.kind {
        case .video:
            VideoStepBody(step: step, childName: summary.childName)
        case .quiz:
            QuizStepBody(step: step, childName: summary.childName)
        case .writing:
            WritingStepBody(
                step: step,
                summary: summary,
                onApprove: { trimmedNote in
                    let note = trimmedNote ?? ReflectionParentNoteFallback.thanksHonest
                    Task { await handleApprove(reflectionId: summary.id, childId: summary.childId, note: note) }
                },
                onRedo: { trimmedNote in
                    let note = trimmedNote ?? ReflectionParentNoteFallback.redoTakeAnotherLook
                    Task { await handleRedo(reflectionId: summary.id, childId: summary.childId, note: note) }
                }
            )
        }
    }

    /// Approve a submitted reflection from Step 3. Fires the
    /// backend approve POST best-effort, captures the local cleanup
    /// (store clear + nav pop) into `pendingCleanup`, and opens the
    /// success alert. Cleanup runs when the user taps OK — by that
    /// point the alert is closed and the view pops cleanly back to
    /// Profile without the user seeing an empty Step Detail behind.
    @MainActor
    private func handleApprove(reflectionId: UUID, childId: String, note: String) async {
        do {
            try await apiClient.approveChildReflectionSubmission(
                reflectionId: reflectionId, parentNote: note
            )
        } catch {
            // Best-effort — fixture/DEBUG mode + offline both
            // intentionally fail here. The local cleanup queued
            // below still surfaces the right UX on OK.
        }
        let name = summary?.childName ?? "your child"
        pendingCleanup = .approve(childId: childId)
        activeAlert = .approved(name)
    }

    /// Request a redo from Step 3. Same deferred-cleanup pattern as
    /// `handleApprove`: fires backend POST first, queues the local
    /// store apply + pop until the user dismisses the success alert.
    @MainActor
    private func handleRedo(reflectionId: UUID, childId: String, note: String) async {
        do {
            try await apiClient.requestRedoChildReflection(
                reflectionId: reflectionId, redoNote: note
            )
        } catch {
            // Best-effort — see handleApprove note.
        }
        let name = summary?.childName ?? "your child"
        pendingCleanup = .redo(childId: childId, redoNote: note)
        activeAlert = .redoRequested(name)
    }

    private var missingState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(StepPalette.brown)
                .frame(width: 58, height: 58)
                .background(Circle().fill(StepPalette.badgeBg))

            Text("Step unavailable")
                .font(.custom("Manrope", size: 22).weight(.heavy))
                .tracking(-0.3)
                .foregroundStyle(StepPalette.ink)

            Text("This step could not be found. The reflection may have been cancelled or the fixture data has changed.")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(StepPalette.brown)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Step 1: Video

private struct VideoStepBody: View {
    let step: ParentReflectionStepArtifact
    let childName: String

    @StateObject private var bridge = VideoBridge()
    @State private var playbackPercent: Double = 0
    @State private var ended: Bool = false

    var body: some View {
        // Reference HTML lines 1093-1119: full-bleed gradient block at
        // the top (flex: 1, minHeight: 320), then padded section below.
        // No card wrappers — the page itself is the body.
        VStack(alignment: .leading, spacing: 0) {
            videoPlayer

            VStack(alignment: .leading, spacing: 14) {
                Text(step.title)
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.22)
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let video = step.video {
                    lockRule(video.lockRule)
                }

                Text("This is exactly what \(childName) watches before unlocking.")
                    .font(.custom("Inter", size: 12))
                    .italic()
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private var videoPlayer: some View {
        // Full-bleed (no horizontal padding), height ~360pt — matches
        // the design's flex: 1 / minHeight: 320 hero area while leaving
        // room for title + lock rule + footer below on common iPhone
        // sizes. Green gradient behind the embed lets the letterbox
        // edges blend in with the design palette.
        if let video = step.video {
            ZStack {
                VideoEmbedView(
                    videoId: video.youtubeId,
                    bridge: bridge,
                    onProgress: { playbackPercent = min(100, $0) },
                    onEnded: { ended = true }
                )

                // Top-left duration chip — matches reference HTML 1103-1105:
                // padding 6/12, radius 999, white 0.85 bg, Inter 12/700,
                // color #15803D, content "0:00 / {duration}".
                VStack {
                    HStack {
                        Text("0:00 / \(video.duration)")
                            .font(.custom("Inter", size: 12).weight(.heavy))
                            .foregroundStyle(GreenPalette.deep)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.white.opacity(0.85))
                            )
                        Spacer()
                    }
                    Spacer()
                }
                .padding(16)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            .background(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: GreenPalette.tint50,  location: 0.0),
                        .init(color: GreenPalette.tint300, location: 0.6),
                        .init(color: GreenPalette.green,   location: 1.0)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            // No fixture video — same gradient block with a static
            // 84pt play glyph (matches reference HTML 1100-1102).
            Rectangle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            GreenPalette.tint50,
                            GreenPalette.tint300,
                            GreenPalette.green
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 360)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 36, weight: .heavy))
                        .foregroundStyle(GreenPalette.deep)
                        .frame(width: 84, height: 84)
                        .background(Circle().fill(Color.white.opacity(0.85)))
                        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 6)
                )
        }
    }

    private func lockRule(_ rule: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text(rule)
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.evSurfaceContainerLow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
    }
}

// MARK: - Step 2: Quiz

private struct QuizStepBody: View {
    let step: ParentReflectionStepArtifact
    let childName: String

    var body: some View {
        // Reference HTML lines 1122-1153: padded section with a single
        // intro line, then numbered questions on the page background.
        // NO outer card.
        VStack(alignment: .leading, spacing: 0) {
            Text("Correct answers shown for parent visibility · \(childName) needs 4 of 5 to pass.")
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            if step.quiz.isEmpty {
                Text("Quiz questions are not available for this reflection yet.")
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            } else {
                ForEach(Array(step.quiz.enumerated()), id: \.element.id) { qi, question in
                    questionBlock(question, number: qi + 1)
                        .padding(.bottom, qi == step.quiz.count - 1 ? 0 : 22)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 30)
    }

    private func questionBlock(_ question: ParentReflectionQuizQuestion, number: Int) -> some View {
        // Per-question grading state — drives both the right-side pill
        // and the per-option markings below.
        let grading = QuestionGrading(question: question)

        return VStack(alignment: .leading, spacing: 0) {
            // Number chip + question + grading pill (right side)
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.custom("Manrope", size: 12).weight(.heavy))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.evSurfaceContainerHigh)
                    )
                    .padding(.top, 1)

                Text(question.q)
                    .font(.custom("Manrope", size: 15).weight(.bold))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                gradingPill(grading)
                    .padding(.top, 2)
            }
            .padding(.bottom, 10)

            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { oi, option in
                    optionRow(
                        text: option,
                        state: grading.optionState(at: oi)
                    )
                }
            }
            .padding(.leading, 34)
        }
    }

    @ViewBuilder
    private func gradingPill(_ grading: QuestionGrading) -> some View {
        switch grading.outcome {
        case .unanswered:
            EmptyView()
        case .right:
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                Text("Correct")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(0.4)
            }
            .foregroundStyle(GreenPalette.deep)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(GreenPalette.tint50))
            .overlay(Capsule().stroke(GreenPalette.tint200, lineWidth: 1))
        case .wrong:
            HStack(spacing: 3) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                Text("Wrong")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(0.4)
            }
            .foregroundStyle(RedPalette.deep)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(RedPalette.tint50))
            .overlay(Capsule().stroke(RedPalette.tint200, lineWidth: 1))
        }
    }

    private func optionRow(text: String, state: QuizOptionState) -> some View {
        HStack(spacing: 10) {
            optionMarker(state)
            Text(text)
                .font(.custom("Inter", size: 13.5))
                .foregroundStyle(optionTextColor(state))
                .fontWeight(state == .neutral ? .regular : .semibold)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(optionBackground(state))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(optionBorder(state), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func optionMarker(_ state: QuizOptionState) -> some View {
        switch state {
        case .correct:
            ZStack {
                Circle()
                    .fill(GreenPalette.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
        case .kidWrong:
            ZStack {
                Circle()
                    .fill(RedPalette.bright)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
        case .neutral:
            Circle()
                .stroke(Color.evOutline, lineWidth: 1.5)
                .frame(width: 18, height: 18)
        }
    }

    private func optionTextColor(_ state: QuizOptionState) -> Color {
        switch state {
        case .correct:  return GreenPalette.deep
        case .kidWrong: return RedPalette.deep
        case .neutral:  return Color.evOnSurface
        }
    }

    private func optionBackground(_ state: QuizOptionState) -> Color {
        switch state {
        case .correct:  return GreenPalette.tint50
        case .kidWrong: return RedPalette.tint50
        case .neutral:  return Color.white
        }
    }

    private func optionBorder(_ state: QuizOptionState) -> Color {
        switch state {
        case .correct:  return GreenPalette.tint200
        case .kidWrong: return RedPalette.tint200
        case .neutral:  return Color.evOutlineVariant
        }
    }
}

// MARK: - Quiz grading helpers

/// Per-option visual state when rendering the parent's Step 2 review.
private enum QuizOptionState {
    /// Always highlight the correct option in green (with ✓).
    case correct
    /// The kid picked this option, but it's wrong. Highlight in red
    /// (with ✗) so the parent can see what the kid actually chose.
    case kidWrong
    /// Plain unanswered or other-incorrect option.
    case neutral
}

/// Per-question grading outcome — drives the right-side pill.
private enum QuestionOutcome {
    case unanswered
    case right
    case wrong
}

private struct QuestionGrading {
    let question: ParentReflectionQuizQuestion

    var outcome: QuestionOutcome {
        guard let selected = question.selectedIndex else { return .unanswered }
        return selected == question.correctIndex ? .right : .wrong
    }

    func optionState(at index: Int) -> QuizOptionState {
        if index == question.correctIndex { return .correct }
        // Only mark the kid's *wrong* pick if they actually answered
        // AND their pick is different from the correct option.
        if let selected = question.selectedIndex,
           selected != question.correctIndex,
           index == selected {
            return .kidWrong
        }
        return .neutral
    }
}

// MARK: - Step 3: Writing

private struct WritingStepBody: View {
    let step: ParentReflectionStepArtifact
    let summary: ParentReflectionSummary
    /// Both callbacks receive the trimmed parent message (`nil` when
    /// the input is blank). The caller substitutes defaults
    /// (`ReflectionParentNoteFallback`) so the kid surface always
    /// sees a non-empty string from the parent.
    let onApprove: (String?) -> Void
    let onRedo: (String?) -> Void

    @State private var parentMessage: String = ""

    private var essay: String? {
        let trimmed = summary.essayText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canReview: Bool {
        summary.state == .completedReady && essay != nil
    }

    private var trimmedMessage: String? {
        let t = parentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var body: some View {
        // Reference HTML lines 1156-1210, plus the new optional
        // message editor above the action row. The editor only shows
        // when the parent can actually act (reflection submitted and
        // essay present); otherwise we skip it to avoid clutter on
        // pending/empty previews.
        VStack(alignment: .leading, spacing: 0) {
            promptCard
                .padding(.bottom, 14)

            essayCard
                .padding(.bottom, 10)

            statsRow
                .padding(.bottom, 18)

            if canReview {
                messageEditor
                    .padding(.bottom, 14)
            }

            actionRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Message for \(summary.childName)")
                    .font(.custom("Inter", size: 11).weight(.heavy))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Text("Optional")
                    .font(.custom("Inter", size: 10).weight(.semibold))
                    .foregroundStyle(Color.evOutline)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.evSurfaceContainerHigh)
                    )
            }

            // Plain background TextEditor wrapped in our own outline
            // so it matches the design's input rhythm rather than
            // SwiftUI's default white-card-on-grey-bg look.
            ZStack(alignment: .topLeading) {
                if parentMessage.isEmpty {
                    Text("Add a note for \(summary.childName)…")
                        .font(.custom("Inter", size: 13))
                        .foregroundStyle(Color.evOutline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                TextEditor(text: $parentMessage)
                    .font(.custom("Inter", size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minHeight: 72)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 1)
            )
        }
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EVLIN ASKS")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(GreenPalette.deep)

            Text(summary.prompt)
                .font(.custom("Manrope", size: 15).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(GreenPalette.tint50)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GreenPalette.tint200, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var essayCard: some View {
        Text(essay ?? "\(summary.childName) hasn't submitted a reflection yet.")
            .font(.custom("Inter", size: 14))
            .foregroundStyle(essay == nil ? Color.evOnSurfaceVariant : Color.evOnSurface)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 1)
            )
    }

    private var statsRow: some View {
        HStack {
            Text(essayStats)
                .font(.custom("Inter", size: 11))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Spacer()
            Text("Submitted via reflection flow")
                .font(.custom("Inter", size: 11))
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if canReview {
            HStack(spacing: 10) {
                Button { onApprove(trimmedMessage) } label: {
                    Text("Approve")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(GreenPalette.green)
                        )
                }
                .buttonStyle(.plain)

                Button { onRedo(trimmedMessage) } label: {
                    Text("Request redo")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .foregroundStyle(Color.evOnSurface)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.evOutlineVariant, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        } else {
            EmptyView()
        }
    }

    private var essayStats: String {
        guard let essay else { return "—" }
        let sentences = essay
            .split { ".!?".contains($0) }
            .filter { $0.trimmingCharacters(in: .whitespaces).count > 3 }
            .count
        let words = essay.split { !$0.isLetter && !$0.isNumber }.count
        return "\(sentences) sentences · \(words) words"
    }
}

// MARK: - Palettes

private enum StepPalette {
    static let warmSurface = Color(red: 0xF4 / 255, green: 0xE8 / 255, blue: 0xD6 / 255)
    static let border      = Color(red: 0xB7 / 255, green: 0x93 / 255, blue: 0x5E / 255)
    static let badgeBg     = Color(red: 0xEA / 255, green: 0xD7 / 255, blue: 0xB4 / 255)
    static let brown       = Color(red: 0x6E / 255, green: 0x4F / 255, blue: 0x26 / 255)
    static let ink         = Color(red: 0x2E / 255, green: 0x1F / 255, blue: 0x08 / 255)
}

private enum GreenPalette {
    /// Correct-option accent (`#22C55E`).
    static let green    = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)
    /// Deep green for chip text / Evlin-asks label (`#15803D`).
    static let deep     = Color(red: 0x15 / 255, green: 0x80 / 255, blue: 0x3D / 255)
    /// Prompt-card surface (`#DCFCE7`).
    static let tint50   = Color(red: 0xDC / 255, green: 0xFC / 255, blue: 0xE7 / 255)
    /// Prompt-card border (`#86EFAC`).
    static let tint200  = Color(red: 0x86 / 255, green: 0xEF / 255, blue: 0xAC / 255)
    /// Video gradient middle stop (`#86EFAC`).
    static let tint300  = Color(red: 0x86 / 255, green: 0xEF / 255, blue: 0xAC / 255)
}

private enum RedPalette {
    /// Bright red for the kid's wrong-pick marker (`#EF4444`).
    static let bright   = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
    /// Deep red for "Wrong" pill text + wrong-option text
    /// (`#B91C1C` — matches the design's redo-state palette).
    static let deep     = Color(red: 0xB9 / 255, green: 0x1C / 255, blue: 0x1C / 255)
    /// Wrong-option surface — same family as the redo pill bg
    /// (`#FEE2E2`, slightly less saturated than the redo `#FFE4E6`).
    static let tint50   = Color(red: 0xFE / 255, green: 0xE2 / 255, blue: 0xE2 / 255)
    /// Wrong-option border (`#FCA5A5`).
    static let tint200  = Color(red: 0xFC / 255, green: 0xA5 / 255, blue: 0xA5 / 255)
}

/// Captures the cleanup we want to run after the parent dismisses
/// the post-action success alert. Keeping the store mutation and
/// the navigation pop on the alert's OK button avoids the
/// "Step unavailable" flash that would otherwise show behind the
/// open alert when the store entry is cleared mid-flight.
private enum PendingCleanup {
    case approve(childId: String)
    case redo(childId: String, redoNote: String)
}

private enum WritingActionAlert: Identifiable {
    case approved(String)
    case redoRequested(String)

    var id: String {
        switch self {
        case .approved:       return "approved"
        case .redoRequested:  return "redo"
        }
    }

    var title: String {
        switch self {
        case .approved:       return "Reflection approved"
        case .redoRequested:  return "Redo requested"
        }
    }

    var message: String {
        switch self {
        case .approved(let name):
            return "\(name)'s reflection is approved."
        case .redoRequested(let name):
            return "\(name) will be asked to rework their reflection."
        }
    }
}

// MARK: - Previews

private enum ReflectionStepDetailPreviewData {
    static var finishedStore: ParentReflectionFixtureStore {
        let s = ParentReflectionFixtureStore()
        s.simulateCompletion(childId: ChildProfile.previewLiam.id)
        return s
    }

    static var pendingStore: ParentReflectionFixtureStore {
        let s = ParentReflectionFixtureStore()
        s.simulateAssignment(childId: ChildProfile.previewLiam.id)
        return s
    }

    static var finishedSummary: ParentReflectionSummary? {
        finishedStore.summary(for: .previewLiam)
    }

    static var pendingSummary: ParentReflectionSummary? {
        pendingStore.summary(for: .previewLiam)
    }
}

#Preview("Step 1 — Video") {
    if let s = ReflectionStepDetailPreviewData.finishedSummary,
       let video = s.steps.first(where: { $0.kind == .video }) {
        NavigationStack {
            ReflectionStepDetailView(reflectionId: s.id, stepId: video.id, onBack: {})
        }
        .environment(ReflectionStepDetailPreviewData.finishedStore)
    } else {
        Text("Missing fixture")
    }
}

#Preview("Step 2 — Quiz") {
    if let s = ReflectionStepDetailPreviewData.finishedSummary,
       let quiz = s.steps.first(where: { $0.kind == .quiz }) {
        NavigationStack {
            ReflectionStepDetailView(reflectionId: s.id, stepId: quiz.id, onBack: {})
        }
        .environment(ReflectionStepDetailPreviewData.finishedStore)
    } else {
        Text("Missing fixture")
    }
}

#Preview("Step 3 — Writing (finished)") {
    if let s = ReflectionStepDetailPreviewData.finishedSummary,
       let writing = s.steps.first(where: { $0.kind == .writing }) {
        NavigationStack {
            ReflectionStepDetailView(reflectionId: s.id, stepId: writing.id, onBack: {})
        }
        .environment(ReflectionStepDetailPreviewData.finishedStore)
    } else {
        Text("Missing fixture")
    }
}

#Preview("Step 3 — Writing (pending)") {
    if let s = ReflectionStepDetailPreviewData.pendingSummary,
       let writing = s.steps.first(where: { $0.kind == .writing }) {
        NavigationStack {
            ReflectionStepDetailView(reflectionId: s.id, stepId: writing.id, onBack: {})
        }
        .environment(ReflectionStepDetailPreviewData.pendingStore)
    } else {
        Text("Missing fixture")
    }
}
