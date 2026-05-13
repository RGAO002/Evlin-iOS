import SwiftUI

struct ReflectionArtifactView: View {
    let reflectionId: UUID
    var onBack: (() -> Void)? = nil

    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @State private var parentMessage = ""
    @State private var activeAlert: ReflectionArtifactAlert?

    private var summary: ParentReflectionSummary? {
        reflectionStore.summary(reflectionId: reflectionId)
    }

    private var child: ChildProfile? {
        guard let childId = summary?.childId else { return nil }
        return ChildProfile.all.first { $0.id == childId }
    }

    private var displayName: String {
        summary?.childName ?? child?.name ?? "your child"
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Reflection", kicker: "Parent review", onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if let summary, summary.state == .completedReady {
                        completedContent(summary)
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xxl)
                .padding(.bottom, Spacing.page)
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

    private func completedContent(_ summary: ParentReflectionSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            heroCard(summary)
            assignmentCard(summary)
            promptCard(summary)
            childWordsCard(summary)
            quizCard(summary)
            stepsCard(summary)
            takeawayCard(summary)
            actionsCard(summary)
        }
    }

    private func heroCard(_ summary: ParentReflectionSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            HStack(alignment: .top, spacing: Spacing.xl) {
                reflectionAvatar(systemImage: "checkmark")

                VStack(alignment: .leading, spacing: Spacing.md) {
                    badge("Ready to review", systemImage: "checkmark.seal.fill")

                    Text("\(displayName)'s reflection is ready")
                        .font(.custom("Manrope", size: 30).weight(.heavy))
                        .tracking(-0.7)
                        .foregroundStyle(Color.evPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Review the prompt, written response, learning steps, and Evlin's takeaway before choosing what happens next.")
                        .font(.evBodyMedium)
                        .lineSpacing(3)
                        .foregroundStyle(Color.evOnReflectionBadge)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let submittedAt = summary.submittedAt {
                Text("Submitted \(formattedDate(submittedAt))")
                    .font(.evCaption)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(reflectionSurfaceGradient)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                .stroke(Color.evReflectionBorder.opacity(0.68), lineWidth: 1)
        )
        .shadow(color: Color.evReflectionBorder.opacity(0.14), radius: 22, x: 0, y: 12)
    }

    private func assignmentCard(_ summary: ParentReflectionSummary) -> some View {
        sectionCard(title: "Assignment summary") {
            VStack(spacing: 0) {
                detailRow(label: "Child", value: summary.childName)
                detailDivider
                detailRow(label: "Reason", value: summary.reason)
                detailDivider
                detailRow(label: "Assigned", value: formattedDate(summary.assignedAt))
            }
            .background(Color.evSurfaceContainerLowest.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                    .stroke(Color.evReflectionBorder.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private func promptCard(_ summary: ParentReflectionSummary) -> some View {
        sectionCard(title: "Evlin prompt") {
            artifactText(summary.prompt)
        }
    }

    private func childWordsCard(_ summary: ParentReflectionSummary) -> some View {
        sectionCard(title: "Child written words") {
            artifactText(summary.essayText ?? "No written response was included in this fixture.")
        }
    }

    private func quizCard(_ summary: ParentReflectionSummary) -> some View {
        sectionCard(title: "Quiz result") {
            artifactText(
                summary.steps.first { $0.kind == .quiz }?.body
                    ?? "No quiz result was included in this fixture."
            )
        }
    }

    private func stepsCard(_ summary: ParentReflectionSummary) -> some View {
        sectionCard(title: "Reflection steps") {
            VStack(spacing: Spacing.md) {
                ForEach(Array(summary.steps.enumerated()), id: \.element.id) { index, step in
                    NavigationLink(
                        value: AppRoute.reflectionStepDetail(
                            reflectionId: summary.id,
                            stepId: step.id
                        )
                    ) {
                        stepRow(step, index: index, total: summary.steps.count)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func takeawayCard(_ summary: ParentReflectionSummary) -> some View {
        sectionCard(title: "Evlin takeaway") {
            artifactText(summary.takeaway ?? "Evlin has not generated a takeaway for this reflection yet.")
        }
    }

    private func actionsCard(_ summary: ParentReflectionSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Parent actions")
                .font(.evLabelMedium)
                .foregroundStyle(Color.evOnReflectionBadge)
                .evLabelStyle()

            VStack(spacing: Spacing.md) {
                Button {
                    // TODO: wire to backend reflection approve endpoint when available.
                    activeAlert = .approved(displayName)
                } label: {
                    actionLabel(title: "Approve reflection", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)

                Button {
                    // TODO: wire to backend reflection redo endpoint when available.
                    activeAlert = .redoRequested(displayName)
                } label: {
                    actionLabel(title: "Request redo", systemImage: "arrow.counterclockwise.circle.fill")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Message to \(summary.childName)")
                    .font(.evLabelSmall)
                    .foregroundStyle(Color.evOnReflectionBadge.opacity(0.86))
                    .evLabelStyle()

                if let parentNote = summary.parentNote, !parentNote.isEmpty {
                    Text(parentNote)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineSpacing(2)
                }

                ZStack(alignment: .topLeading) {
                    if parentMessage.isEmpty {
                        Text("Write a short note before approving or asking for a redo.")
                            .font(.evBodyMedium)
                            .foregroundStyle(Color.evOutline)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, 10)
                    }

                    TextEditor(text: $parentMessage)
                        .font(.evBodyMedium)
                        .foregroundStyle(Color.evPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 104)
                        .padding(Spacing.sm)
                }
                .background(Color.evSurfaceContainerLowest.opacity(0.76))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                        .stroke(Color.evReflectionBorder.opacity(0.45), lineWidth: 1)
                )

                Button {
                    // TODO: persist parent note through backend once reflection messaging exists.
                    activeAlert = .noteSubmitted(displayName)
                } label: {
                    actionLabel(title: "Submit note", systemImage: "paperplane.fill")
                }
                .buttonStyle(.plain)
            }
            .padding(.top, Spacing.sm)
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.7), lineWidth: 1)
        )
        .evShadow(.premium)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            reflectionAvatar(systemImage: "text.book.closed.fill")

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Reflection is not ready yet")
                    .font(.custom("Manrope", size: 28).weight(.heavy))
                    .tracking(-0.5)
                    .foregroundStyle(Color.evPrimary)

                Text("This reflection could not be found, or it has not been completed yet. Once \(displayName) finishes, the review artifact will appear here.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineSpacing(3)
            }

            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "chevron.backward")
                        Text("Back")
                    }
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evPrimary)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.lg)
                    .background(Color.evSurfaceContainerLowest.opacity(0.8))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.evReflectionBorder.opacity(0.65), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.xxxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(reflectionSurfaceGradient)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                .stroke(Color.evReflectionBorder.opacity(0.6), lineWidth: 1)
        )
    }

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(title)
                .font(.evLabelMedium)
                .foregroundStyle(Color.evOnReflectionBadge)
                .evLabelStyle()

            content()
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evReflectionSurface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                .stroke(Color.evReflectionBorder.opacity(0.5), lineWidth: 1)
        )
    }

    private func stepRow(
        _ step: ParentReflectionStepArtifact,
        index: Int,
        total: Int
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            Image(systemName: stepIcon(step.kind))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.evOnReflectionBadge)
                .frame(width: 36, height: 36)
                .background(Color.evReflectionBadge.opacity(0.95))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Step \(index + 1) of \(total)")
                    .font(.evLabelSmall)
                    .foregroundStyle(Color.evOnReflectionBadge.opacity(0.86))
                    .evLabelStyle()

                Text(step.title)
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evPrimary)

                Text(step.subtitle)
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }

            Spacer(minLength: Spacing.sm)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.evReflectionBorder)
                .padding(.top, 12)
        }
        .padding(Spacing.lg)
        .background(Color.evSurfaceContainerLowest.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                .stroke(Color.evReflectionBorder.opacity(0.32), lineWidth: 1)
        )
    }

    private func artifactText(_ value: String) -> some View {
        Text(value)
            .font(.evBodyMedium)
            .foregroundStyle(Color.evPrimary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.evSurfaceContainerLowest.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                    .stroke(Color.evReflectionBorder.opacity(0.35), lineWidth: 1)
            )
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(label)
                .font(.evLabelSmall)
                .foregroundStyle(Color.evOnReflectionBadge.opacity(0.82))
                .evLabelStyle()

            Text(value)
                .font(.evBodyMedium)
                .foregroundStyle(Color.evPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailDivider: some View {
        Rectangle()
            .fill(Color.evReflectionBorder.opacity(0.18))
            .frame(height: 1)
            .padding(.horizontal, Spacing.xl)
    }

    private func actionLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))

            Text(title)
                .font(.custom("Inter", size: 14).weight(.heavy))
                .tracking(0.5)

            Spacer()
        }
        .foregroundStyle(Color.evPrimary)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .background(Color.evReflectionSurface.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                .stroke(Color.evReflectionBorder.opacity(0.55), lineWidth: 1)
        )
    }

    private func badge(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .heavy))

            Text(title)
                .font(.evLabelSmall)
                .evLabelStyle()
        }
        .foregroundStyle(Color.evOnReflectionBadge)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 8)
        .background(Color.evReflectionBadge.opacity(0.9))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.evReflectionBorder.opacity(0.38), lineWidth: 1)
        )
    }

    private func reflectionAvatar(systemImage: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let child {
                EvlinAvatarView(
                    url: child.avatarURL,
                    name: child.name,
                    size: 68,
                    ring: true,
                    ringColor: Color.evReflectionBorder
                )
            } else {
                Text(String(displayName.prefix(1)).uppercased())
                    .font(.custom("Manrope", size: 26).weight(.heavy))
                    .foregroundStyle(Color.evOnReflectionBadge)
                    .frame(width: 68, height: 68)
                    .background(Color.evReflectionBadge)
                    .clipShape(Circle())
            }

            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Color.evOnReflectionBadge)
                .frame(width: 27, height: 27)
                .background(Color.evReflectionBadge)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.evSurfaceContainerLowest, lineWidth: 2))
                .offset(x: 3, y: 3)
        }
        .frame(width: 72, height: 72)
    }

    private var reflectionSurfaceGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.evReflectionSurface,
                Color.evReflectionSurface.opacity(0.84),
                Color.evSurfaceContainerLowest.opacity(0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func stepIcon(_ kind: ParentReflectionStepKind) -> String {
        switch kind {
        case .video:
            return "play.rectangle.fill"
        case .quiz:
            return "checklist"
        case .writing:
            return "pencil.line"
        }
    }

    private func formattedDate(_ isoString: String) -> String {
        guard let date = Self.isoFormatter.date(from: isoString) else {
            return isoString
        }

        return date.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .year()
                .hour()
                .minute()
        )
    }

    private static let isoFormatter = ISO8601DateFormatter()
}

private enum ReflectionArtifactAlert: Identifiable {
    case approved(String)
    case redoRequested(String)
    case noteSubmitted(String)

    var id: String {
        switch self {
        case .approved:
            return "approved"
        case .redoRequested:
            return "redoRequested"
        case .noteSubmitted:
            return "noteSubmitted"
        }
    }

    var title: String {
        switch self {
        case .approved:
            return "Reflection approved"
        case .redoRequested:
            return "Redo requested"
        case .noteSubmitted:
            return "Note submitted"
        }
    }

    var message: String {
        switch self {
        case .approved(let childName):
            return "Prototype only: \(childName)'s reflection would be approved."
        case .redoRequested(let childName):
            return "Prototype only: \(childName) would be asked to redo the reflection."
        case .noteSubmitted(let childName):
            return "Prototype only: this note would be sent to \(childName)."
        }
    }
}

private enum ReflectionArtifactPreviewData {
    static let reflectionId = UUID(uuidString: "AAE163C8-35B4-4B4E-A7B1-5D58AD477E28")!

    static var completedStore: ParentReflectionFixtureStore {
        let store = ParentReflectionFixtureStore()
        store.simulateCompletion(childId: ChildProfile.liam.id)
        return store
    }
}

#Preview("Completed Reflection Artifact") {
    NavigationStack {
        ReflectionArtifactView(
            reflectionId: ReflectionArtifactPreviewData.reflectionId,
            onBack: {}
        )
    }
    .environment(ReflectionArtifactPreviewData.completedStore)
}

#Preview("Reflection Artifact Empty") {
    NavigationStack {
        ReflectionArtifactView(
            reflectionId: UUID(uuidString: "D9DD6338-6AA1-4A40-80F5-D3B4F79917B7")!,
            onBack: {}
        )
    }
    .environment(ParentReflectionFixtureStore())
}
