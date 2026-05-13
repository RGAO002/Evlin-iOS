import SwiftUI

/// "Reflection Assignment" page — one card with the 3 step rows,
/// state pill (PENDING / FINISHED), and a Cancel reflection footer.
///
/// Mirrors the listing view in `Evlin Parent Dashboard (1).html`
/// (lines 1513-1599): single warm-cream card with a lock-icon header,
/// a 3-step list (each tappable, each with a status pill on the
/// right), and a Cancel reflection action at the bottom. The prompt,
/// child words, quiz, and takeaway cards that used to live here are
/// gone — that content surfaces inside the per-step detail pages
/// where the design places it.
///
/// Both pending and finished states render the same shell; only the
/// state pill, step row pills, and Step 3's inline approve/redo row
/// change.
struct ReflectionArtifactView: View {
    /// The reflection to render. Resolved by caller (Pending route
    /// hands in the child's current summary; Artifact route hands in
    /// the explicit reflection id).
    let reflectionId: UUID
    var onBack: (() -> Void)? = nil

    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @State private var activeAlert: ReflectionArtifactAlert?

    private var summary: ParentReflectionSummary? {
        reflectionStore.summary(reflectionId: reflectionId)
    }

    private var isFinished: Bool {
        summary?.state == .completedReady
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Reflection", kicker: "Parent review", onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let summary {
                        sectionHeader(state: summary.state)
                        assignmentCard(summary)
                    } else {
                        missingState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 60)
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

    // MARK: - Section header

    private func sectionHeader(state: ParentReflectionState) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Reflection Assignment")
                .font(.custom("Manrope", size: 16).weight(.heavy))
                .tracking(-0.1)
                .foregroundStyle(Color.evOnSurface)

            Spacer(minLength: 0)

            statePill(state: state)
        }
    }

    private func statePill(state: ParentReflectionState) -> some View {
        let descriptor = statePillDescriptor(for: state)
        return Text(descriptor.label)
            .font(.custom("Inter", size: 10).weight(.heavy))
            .tracking(1.4)
            .foregroundStyle(descriptor.fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(descriptor.bg))
            .overlay(Capsule().stroke(descriptor.border, lineWidth: 1))
    }

    private func statePillDescriptor(for state: ParentReflectionState) -> StatePillDescriptor {
        switch state {
        case .completedReady:
            return StatePillDescriptor(
                label: "FINISHED",
                fg:    Color(red: 0xB9 / 255, green: 0x1C / 255, blue: 0x1C / 255),
                bg:    Color(red: 0xFF / 255, green: 0xE4 / 255, blue: 0xE6 / 255),
                border: Color(red: 0xFC / 255, green: 0xA5 / 255, blue: 0xA5 / 255)
            )
        case .assignedPending, .none:
            return StatePillDescriptor(
                label: "PENDING",
                fg:    ReflectionPalette.badgeFg,
                bg:    ReflectionPalette.badgeBg,
                border: ReflectionPalette.border
            )
        }
    }

    // MARK: - Assignment card

    private func assignmentCard(_ summary: ParentReflectionSummary) -> some View {
        VStack(spacing: 0) {
            assignmentHeader(summary)
            stepsList(summary)
            cancelFooter
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ReflectionPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ReflectionPalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func assignmentHeader(_ summary: ParentReflectionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(ReflectionPalette.lockFg)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(ReflectionPalette.border)
                    )

                Text("SCREEN TIME LOCKED")
                    .font(.custom("Inter", size: 11).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(ReflectionPalette.lockFg)
            }
            .padding(.bottom, 2)

            Text("\(summary.childName) must finish a 3-step reflection")
                .font(.custom("Manrope", size: 18).weight(.heavy))
                .tracking(-0.2)
                .foregroundStyle(ReflectionPalette.nameFg)
                .fixedSize(horizontal: false, vertical: true)

            Text(summary.reason)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(ReflectionPalette.badgeFg)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func stepsList(_ summary: ParentReflectionSummary) -> some View {
        if summary.steps.isEmpty {
            // Defensive — fixtures always provide 3 steps now, but if a
            // backend reflection ever ships without them, fail soft.
            Rectangle()
                .fill(ReflectionPalette.divider)
                .frame(height: 1)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(summary.steps.enumerated()), id: \.element.id) { idx, step in
                    if idx > 0 {
                        Rectangle()
                            .fill(ReflectionPalette.divider)
                            .frame(height: 1)
                    }
                    stepRow(step, index: idx, total: summary.steps.count, summary: summary)
                }
            }
        }
    }

    private func stepRow(
        _ step: ParentReflectionStepArtifact,
        index: Int,
        total: Int,
        summary: ParentReflectionSummary
    ) -> some View {
        NavigationLink(
            value: AppRoute.reflectionStepDetail(
                reflectionId: summary.id,
                stepId: step.id
            )
        ) {
            HStack(alignment: .center, spacing: 14) {
                stepIconBubble(step.kind)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Step \(index + 1) of \(total) — \(stepDisplayTitle(step.kind))")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .tracking(-0.1)
                        .foregroundStyle(ReflectionPalette.nameFg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text(step.subtitle)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(ReflectionPalette.badgeFg)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                stepRightPill(for: step, summary: summary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(ReflectionPalette.chevron)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stepIconBubble(_ kind: ParentReflectionStepKind) -> some View {
        Image(systemName: stepIconSF(kind))
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(ReflectionPalette.badgeFg)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(ReflectionPalette.divider, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func stepRightPill(
        for step: ParentReflectionStepArtifact,
        summary: ParentReflectionSummary
    ) -> some View {
        if step.kind == .writing, summary.state == .completedReady,
           let essay = summary.essayText,
           !essay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Writing step + essay in + parent hasn't acted → match the
            // reference HTML's "Needs review" tan pill (lines 1555-1558).
            // Prototype state is fixture-only so the pill doesn't flip
            // to Approved/Redo persistently when the parent taps an
            // action — that's expected for this iteration.
            Text("NEEDS REVIEW")
                .font(.custom("Inter", size: 9).weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(ReflectionPalette.badgeFg)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white))
                .overlay(
                    Capsule().stroke(ReflectionPalette.border, lineWidth: 1)
                )
        } else {
            EmptyView()
        }
    }

    private var cancelFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(ReflectionPalette.divider)
                .frame(height: 1)

            Button {
                activeAlert = .cancelConfirmed(summary?.childName ?? "your child")
            } label: {
                Text("Cancel reflection")
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(ReflectionPalette.badgeFg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ReflectionPalette.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Missing state

    private var missingState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(ReflectionPalette.badgeFg)
                .frame(width: 58, height: 58)
                .background(
                    Circle().fill(ReflectionPalette.badgeBg)
                )

            Text("Reflection unavailable")
                .font(.custom("Manrope", size: 22).weight(.heavy))
                .tracking(-0.3)
                .foregroundStyle(ReflectionPalette.nameFg)

            Text("This reflection could not be found. It may have been cancelled or expired.")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(ReflectionPalette.badgeFg)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ReflectionPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ReflectionPalette.border, lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func stepDisplayTitle(_ kind: ParentReflectionStepKind) -> String {
        switch kind {
        case .video:   return "Watch the video"
        case .quiz:    return "Quiz preview"
        case .writing: return "Written reflection"
        }
    }

    private func stepIconSF(_ kind: ParentReflectionStepKind) -> String {
        switch kind {
        case .video:   return "play.fill"
        case .quiz:    return "checklist"
        case .writing: return "pencil.line"
        }
    }
}

private struct StatePillDescriptor {
    let label: String
    let fg: Color
    let bg: Color
    let border: Color
}

private enum ReflectionPalette {
    static let surface = Color(red: 0xF4 / 255, green: 0xE8 / 255, blue: 0xD6 / 255)
    static let border  = Color(red: 0xB7 / 255, green: 0x93 / 255, blue: 0x5E / 255)
    static let badgeBg = Color(red: 0xEA / 255, green: 0xD7 / 255, blue: 0xB4 / 255)
    static let badgeFg = Color(red: 0x6E / 255, green: 0x4F / 255, blue: 0x26 / 255)
    static let nameFg  = Color(red: 0x2E / 255, green: 0x1F / 255, blue: 0x08 / 255)
    static let lockFg  = Color(red: 0x4A / 255, green: 0x32 / 255, blue: 0x15 / 255)
    static let divider = Color(red: 0xDD / 255, green: 0xC5 / 255, blue: 0x9B / 255).opacity(0.6)
    static let chevron = Color(red: 0x9A / 255, green: 0x73 / 255, blue: 0x40 / 255)
}

private enum ReflectionArtifactAlert: Identifiable {
    case cancelConfirmed(String)

    var id: String {
        switch self {
        case .cancelConfirmed:
            return "cancelConfirmed"
        }
    }

    var title: String {
        switch self {
        case .cancelConfirmed:
            return "Cancel reflection"
        }
    }

    var message: String {
        switch self {
        case .cancelConfirmed(let childName):
            return "Prototype only: \(childName)'s reflection would be cancelled."
        }
    }
}

private enum ReflectionArtifactPreviewData {
    static var completedStore: ParentReflectionFixtureStore {
        let store = ParentReflectionFixtureStore()
        store.simulateCompletion(childId: ChildProfile.liam.id)
        return store
    }

    static var pendingStore: ParentReflectionFixtureStore {
        let store = ParentReflectionFixtureStore()
        store.simulateAssignment(childId: ChildProfile.liam.id)
        return store
    }

    static var completedSummaryId: UUID? {
        completedStore.summary(for: .liam)?.id
    }

    static var pendingSummaryId: UUID? {
        pendingStore.summary(for: .liam)?.id
    }
}

#Preview("Reflection Artifact — Finished") {
    if let id = ReflectionArtifactPreviewData.completedSummaryId {
        NavigationStack {
            ReflectionArtifactView(reflectionId: id, onBack: {})
        }
        .environment(ReflectionArtifactPreviewData.completedStore)
    } else {
        Text("Missing fixture")
    }
}

#Preview("Reflection Artifact — Pending") {
    if let id = ReflectionArtifactPreviewData.pendingSummaryId {
        NavigationStack {
            ReflectionArtifactView(reflectionId: id, onBack: {})
        }
        .environment(ReflectionArtifactPreviewData.pendingStore)
    } else {
        Text("Missing fixture")
    }
}
