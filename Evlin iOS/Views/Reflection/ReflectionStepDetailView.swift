import SwiftUI

/// Per-step parent preview for a reflection.
///
/// The three steps render very different UI:
///  - **Video (step 1)** embeds the kid-side YouTube player so the
///    parent sees the exact clip the child watches. Back navigation
///    works at any point.
///  - **Quiz (step 2)** lists every question with the correct option
///    highlighted (parent visibility — opposite of the kid surface).
///  - **Writing (step 3)** shows Evlin's prompt + the child's essay
///    (if submitted). When essay is present + state is finished, the
///    Approve / Request redo controls render at the bottom. When the
///    child hasn't written yet, no action buttons and no "needs
///    review" pill render.
///
/// Shell colors track the reference HTML: green step labels, warm
/// reflection palette tokens are inherited from `ReflectionPalette`.
struct ReflectionStepDetailView: View {
    let reflectionId: UUID
    let stepId: UUID
    var onBack: (() -> Void)? = nil

    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @State private var activeAlert: WritingActionAlert?

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
            GlassmorphicHeader(title: "Reflection step", kicker: "Parent preview", onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let summary, let step, let stepIndex {
                        stepContent(step, summary: summary, index: stepIndex)
                    } else {
                        missingState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 80)
            }
        }
        .background(Color.evSurfaceContainerLow.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private func stepContent(
        _ step: ParentReflectionStepArtifact,
        summary: ParentReflectionSummary,
        index: Int
    ) -> some View {
        switch step.kind {
        case .video:
            VideoStepBody(step: step, index: index, total: summary.steps.count, childName: summary.childName)
        case .quiz:
            QuizStepBody(step: step, index: index, total: summary.steps.count, childName: summary.childName)
        case .writing:
            WritingStepBody(
                step: step,
                index: index,
                total: summary.steps.count,
                summary: summary,
                onApprove: { activeAlert = .approved(summary.childName) },
                onRedo: { activeAlert = .redoRequested(summary.childName) }
            )
        }
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
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StepPalette.warmSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StepPalette.border, lineWidth: 1)
        )
    }
}

// MARK: - Step 1: Video

private struct VideoStepBody: View {
    let step: ParentReflectionStepArtifact
    let index: Int
    let total: Int
    let childName: String

    @StateObject private var bridge = VideoBridge()
    @State private var playbackPercent: Double = 0
    @State private var ended: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepLabel(index: index, total: total, suffix: "Video preview")

            Text(step.title)
                .font(.custom("Manrope", size: 19).weight(.heavy))
                .tracking(-0.3)
                .foregroundStyle(StepPalette.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            videoPlayer

            if let video = step.video {
                lockRule(video.lockRule)
            }

            footerNote(
                "This is exactly what \(childName) watches before unlocking."
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var videoPlayer: some View {
        // Compact preview — height matches the reference HTML (200pt).
        // The kid-side player ships with a tall layout (progress bar +
        // demo skip + primary button) that's irrelevant for the parent
        // preview: parents just need to see the clip the kid sees.
        if let video = step.video {
            ZStack {
                VideoEmbedView(
                    videoId: video.youtubeId,
                    bridge: bridge,
                    onProgress: { playbackPercent = min(100, $0) },
                    onEnded: { ended = true }
                )

                // Top-left duration chip — matches the reference HTML.
                VStack {
                    HStack {
                        Text(video.duration)
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .foregroundStyle(GreenPalette.deep)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Color.white.opacity(0.85))
                            )
                        Spacer()
                    }
                    Spacer()
                }
                .padding(10)
                .allowsHitTesting(false)
            }
            .frame(height: 200)
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
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            // No video metadata — render the same gradient block but
            // without an embed (no media loaded for this fixture).
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
                .frame(height: 200)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(GreenPalette.deep)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.white.opacity(0.85)))
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
    let index: Int
    let total: Int
    let childName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                stepLabel(index: index, total: total, suffix: "Quiz preview")

                Text("What \(childName) is asked")
                    .font(.custom("Manrope", size: 19).weight(.heavy))
                    .tracking(-0.3)
                    .foregroundStyle(StepPalette.ink)

                Text("Correct answers are shown for parent visibility — kids need 4 of 5 to pass.")
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            if step.quiz.isEmpty {
                Text("Quiz questions are not available for this reflection yet.")
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(20)
            } else {
                ForEach(Array(step.quiz.enumerated()), id: \.element.id) { qi, question in
                    if qi > 0 {
                        Rectangle()
                            .fill(Color.evOutlineVariant)
                            .frame(height: 1)
                    }
                    questionBlock(question, number: qi + 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func questionBlock(_ question: ParentReflectionQuizQuestion, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.custom("Manrope", size: 11).weight(.heavy))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.evSurfaceContainerHigh)
                    )

                Text(question.q)
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .tracking(-0.1)
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { oi, option in
                    optionRow(text: option, isCorrect: oi == question.correctIndex)
                }
            }
            .padding(.leading, 30)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func optionRow(text: String, isCorrect: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(isCorrect ? GreenPalette.green : Color.evOutline, lineWidth: 1.5)
                    .background(Circle().fill(isCorrect ? GreenPalette.green : Color.clear))

                if isCorrect {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 18, height: 18)

            Text(text)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(isCorrect ? GreenPalette.deep : Color.evOnSurface)
                .fontWeight(isCorrect ? .semibold : .regular)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCorrect ? GreenPalette.tint50 : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isCorrect ? GreenPalette.tint200 : Color.evOutlineVariant, lineWidth: 1)
        )
    }
}

// MARK: - Step 3: Writing

private struct WritingStepBody: View {
    let step: ParentReflectionStepArtifact
    let index: Int
    let total: Int
    let summary: ParentReflectionSummary
    let onApprove: () -> Void
    let onRedo: () -> Void

    private var essay: String? {
        let trimmed = summary.essayText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canReview: Bool {
        summary.state == .completedReady && essay != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                stepLabel(
                    index: index, total: total,
                    suffix: "\(summary.childName)'s reflection"
                )

                Text("Review what \(summary.childName) wrote")
                    .font(.custom("Manrope", size: 19).weight(.heavy))
                    .tracking(-0.3)
                    .foregroundStyle(StepPalette.ink)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 14) {
                promptCard
                essayCard
                if essay != nil {
                    statsRow
                }
            }
            .padding(.horizontal, 20)

            if canReview {
                Rectangle()
                    .fill(Color.evOutlineVariant)
                    .frame(height: 1)
                    .padding(.top, 18)

                HStack(spacing: 10) {
                    Button(action: onApprove) {
                        Text("Approve")
                            .font(.custom("Manrope", size: 14).weight(.heavy))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(GreenPalette.green)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onRedo) {
                        Text("Request redo")
                            .font(.custom("Manrope", size: 14).weight(.heavy))
                            .foregroundStyle(Color.evOnSurface)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            } else {
                Spacer(minLength: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EVLIN ASKS")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(GreenPalette.deep)

            Text(summary.prompt)
                .font(.custom("Manrope", size: 15).weight(.heavy))
                .tracking(-0.1)
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
        if let essay {
            Text(essay)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
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
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.top, 1)
                Text("\(summary.childName) hasn't submitted a reflection yet. When they do, the written response will appear here and you'll be able to approve or request a redo.")
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 1)
            )
        }
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

// MARK: - Shared helpers

private func stepLabel(index: Int, total: Int, suffix: String) -> some View {
    Text("STEP \(index + 1) OF \(total) — \(suffix.uppercased())")
        .font(.custom("Inter", size: 11).weight(.heavy))
        .tracking(1.4)
        .foregroundStyle(GreenPalette.green)
}

private func footerNote(_ text: String) -> some View {
    Text(text)
        .font(.custom("Inter", size: 11))
        .foregroundStyle(Color.evOnSurfaceVariant)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// Step-label / correct-option accent (`#22C55E`).
    static let green    = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)
    /// Approve-button deep green (`#15803D`).
    static let deep     = Color(red: 0x15 / 255, green: 0x80 / 255, blue: 0x3D / 255)
    /// Prompt-card surface (`#DCFCE7`).
    static let tint50   = Color(red: 0xDC / 255, green: 0xFC / 255, blue: 0xE7 / 255)
    /// Prompt-card border (`#86EFAC`).
    static let tint200  = Color(red: 0x86 / 255, green: 0xEF / 255, blue: 0xAC / 255)
    /// Video gradient middle stop (`#86EFAC`).
    static let tint300  = Color(red: 0x86 / 255, green: 0xEF / 255, blue: 0xAC / 255)
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
            return "Prototype only: \(name)'s reflection would be marked approved."
        case .redoRequested(let name):
            return "Prototype only: \(name) would be asked to write again."
        }
    }
}

// MARK: - Previews

private enum ReflectionStepDetailPreviewData {
    static var finishedStore: ParentReflectionFixtureStore {
        let s = ParentReflectionFixtureStore()
        s.simulateCompletion(childId: ChildProfile.liam.id)
        return s
    }

    static var pendingStore: ParentReflectionFixtureStore {
        let s = ParentReflectionFixtureStore()
        s.simulateAssignment(childId: ChildProfile.liam.id)
        return s
    }

    static var finishedSummary: ParentReflectionSummary? {
        finishedStore.summary(for: .liam)
    }

    static var pendingSummary: ParentReflectionSummary? {
        pendingStore.summary(for: .liam)
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
