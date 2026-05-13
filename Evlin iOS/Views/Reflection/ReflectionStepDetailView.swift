import SwiftUI

struct ReflectionStepDetailView: View {
    let reflectionId: UUID
    let stepId: UUID
    var onBack: (() -> Void)? = nil

    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore

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
            GlassmorphicHeader(title: "Reflection step", kicker: "Parent review", onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if let summary, let step, let stepIndex {
                        stepContent(step, summary: summary, index: stepIndex)
                    } else {
                        missingState
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
    }

    private func stepContent(
        _ step: ParentReflectionStepArtifact,
        summary: ParentReflectionSummary,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            heroCard(step, summary: summary, index: index)
            detailCard(step)
        }
    }

    private func heroCard(
        _ step: ParentReflectionStepArtifact,
        summary: ParentReflectionSummary,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            HStack(alignment: .top, spacing: Spacing.xl) {
                Image(systemName: stepIcon(step.kind))
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(Color.evOnReflectionBadge)
                    .frame(width: 64, height: 64)
                    .background(Color.evReflectionBadge.opacity(0.95))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.evSurfaceContainerLowest, lineWidth: 3)
                    )

                VStack(alignment: .leading, spacing: Spacing.md) {
                    badge("Step \(index + 1) of \(summary.steps.count)", systemImage: "text.book.closed.fill")

                    Text(step.title)
                        .font(.custom("Manrope", size: 30).weight(.heavy))
                        .tracking(-0.7)
                        .foregroundStyle(Color.evPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(step.subtitle)
                        .font(.evBodyMedium)
                        .lineSpacing(3)
                        .foregroundStyle(Color.evOnReflectionBadge)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Reflection for \(summary.childName)")
                .font(.evCaption)
                .foregroundStyle(Color.evOnSurfaceVariant)
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

    @ViewBuilder
    private func detailCard(_ step: ParentReflectionStepArtifact) -> some View {
        switch step.kind {
        case .video:
            sectionCard(title: "Video step") {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    HStack(alignment: .center, spacing: Spacing.lg) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(Color.evOnReflectionBadge)
                            .frame(width: 48, height: 48)
                            .background(Color.evReflectionBadge.opacity(0.9))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Prototype video summary")
                                .font(.evLabelSmall)
                                .foregroundStyle(Color.evOnReflectionBadge.opacity(0.82))
                                .evLabelStyle()

                            Text("No media loads on this fixture page.")
                                .font(.evBodySmall)
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                    }

                    bodyText(step.body)
                }
            }
        case .quiz:
            sectionCard(title: "Quiz step") {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    bodyText(step.body)
                    callout("Quiz answers are represented by fixture summary text in this prototype.")
                }
            }
        case .writing:
            sectionCard(title: "Written reflection") {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    bodyText(step.body)
                    callout("This matches the parent-ready written response stored with the fixture.")
                }
            }
        }
    }

    private var missingState: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.evOnReflectionBadge)
                .frame(width: 62, height: 62)
                .background(Color.evReflectionBadge.opacity(0.9))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Reflection step unavailable")
                    .font(.custom("Manrope", size: 28).weight(.heavy))
                    .tracking(-0.5)
                    .foregroundStyle(Color.evPrimary)

                Text("This step could not be found. It may belong to a reflection that is not ready yet, or the fixture data may have changed.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func bodyText(_ value: String) -> some View {
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

    private func callout(_ value: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.evReflectionBorder)
                .padding(.top, 1)

            Text(value)
                .font(.evBodySmall)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLowest.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                .stroke(Color.evReflectionBorder.opacity(0.28), lineWidth: 1)
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
}

private enum ReflectionStepDetailPreviewData {
    static let reflectionId = UUID(uuidString: "AAE163C8-35B4-4B4E-A7B1-5D58AD477E28")!
    static let quizStepId = UUID(uuidString: "B0D69D4A-CE58-43D6-A108-5C81BA8E9638")!

    static var completedStore: ParentReflectionFixtureStore {
        let store = ParentReflectionFixtureStore()
        store.simulateCompletion(childId: ChildProfile.liam.id)
        return store
    }
}

#Preview("Reflection Step Detail") {
    NavigationStack {
        ReflectionStepDetailView(
            reflectionId: ReflectionStepDetailPreviewData.reflectionId,
            stepId: ReflectionStepDetailPreviewData.quizStepId,
            onBack: {}
        )
    }
    .environment(ReflectionStepDetailPreviewData.completedStore)
}
