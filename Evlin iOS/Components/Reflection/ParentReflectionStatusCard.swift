import SwiftUI

enum ParentReflectionStatusCardLayout {
    case homeCard
    case profileHeader
}

struct ParentReflectionStatusCard: View {
    let child: ChildProfile
    let summary: ParentReflectionSummary
    let layout: ParentReflectionStatusCardLayout
    let onViewReflection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.verticalSpacing) {
            HStack(alignment: .top, spacing: metrics.headerSpacing) {
                reflectionAvatar

                VStack(alignment: .leading, spacing: Spacing.md) {
                    badge

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(title)
                            .font(.custom("Manrope", size: metrics.titleSize).weight(.heavy))
                            .tracking(-0.3)
                            .foregroundStyle(Color.evPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)

                        Text(summary.reason)
                            .font(.custom("Inter", size: metrics.bodySize).weight(.medium))
                            .foregroundStyle(Color.evOnReflectionBadge)
                            .lineSpacing(2)
                            .lineLimit(metrics.reasonLineLimit)
                    }
                }

                Spacer(minLength: Spacing.sm)
            }

            Button(action: onViewReflection) {
                HStack(spacing: Spacing.md) {
                    Text("View reflection")
                        .font(.custom("Inter", size: 14).weight(.heavy))
                        .tracking(0.6)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .heavy))
                }
                .foregroundStyle(Color.evPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, metrics.ctaVerticalPadding)
                .background(Color.evSurfaceContainerLowest.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                        .stroke(Color.evReflectionBorder.opacity(0.85), lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(child.name)'s reflection")
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color.evReflectionSurface,
                    Color.evReflectionSurface.opacity(0.82),
                    Color.evSurfaceContainerLowest.opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                .stroke(Color.evReflectionBorder.opacity(0.68), lineWidth: 1)
        )
        .shadow(color: Color.evReflectionBorder.opacity(0.14), radius: 18, x: 0, y: 10)
    }

    private var reflectionAvatar: some View {
        ZStack(alignment: .bottomTrailing) {
            EvlinAvatarView(
                url: child.avatarURL,
                name: child.name,
                size: metrics.avatarSize,
                ring: true,
                ringColor: Color.evReflectionBorder
            )

            Image(systemName: "text.book.closed.fill")
                .font(.system(size: metrics.iconSize, weight: .heavy))
                .foregroundStyle(Color.evOnReflectionBadge)
                .frame(width: metrics.iconContainerSize, height: metrics.iconContainerSize)
                .background(Color.evReflectionBadge)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.evSurfaceContainerLowest, lineWidth: 2))
                .offset(x: 3, y: 3)
        }
        .frame(width: metrics.avatarSize, height: metrics.avatarSize)
    }

    private var badge: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 10, weight: .heavy))

            Text("Under reflection")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.5)
                .textCase(.uppercase)
        }
        .foregroundStyle(Color.evOnReflectionBadge)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 7)
        .background(Color.evReflectionBadge.opacity(0.9))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.evReflectionBorder.opacity(0.38), lineWidth: 1)
        )
    }

    private var title: String {
        switch summary.state {
        case .completedReady:
            return "\(child.name)'s reflection is ready"
        case .assignedPending, .none:
            return "\(child.name) has a reflection assigned"
        }
    }

    private var metrics: Metrics {
        switch layout {
        case .homeCard:
            return Metrics(
                padding: 18,
                verticalSpacing: Spacing.lg,
                headerSpacing: Spacing.xl,
                avatarSize: 56,
                iconContainerSize: 24,
                iconSize: 11,
                titleSize: 17,
                bodySize: 12,
                reasonLineLimit: 2,
                ctaVerticalPadding: Spacing.lg
            )
        case .profileHeader:
            return Metrics(
                padding: Spacing.xxl,
                verticalSpacing: Spacing.xl,
                headerSpacing: Spacing.xl,
                avatarSize: 72,
                iconContainerSize: 28,
                iconSize: 13,
                titleSize: 22,
                bodySize: 14,
                reasonLineLimit: 3,
                ctaVerticalPadding: Spacing.lg
            )
        }
    }
}

private struct Metrics {
    let padding: CGFloat
    let verticalSpacing: CGFloat
    let headerSpacing: CGFloat
    let avatarSize: CGFloat
    let iconContainerSize: CGFloat
    let iconSize: CGFloat
    let titleSize: CGFloat
    let bodySize: CGFloat
    let reasonLineLimit: Int
    let ctaVerticalPadding: CGFloat
}

private enum ParentReflectionStatusCardPreviewData {
    static var pendingSummary: ParentReflectionSummary {
        ParentReflectionFixtureStore().summary(for: .liam)!
    }

    static var completedSummary: ParentReflectionSummary {
        let store = ParentReflectionFixtureStore()
        store.simulateCompletion(childId: ChildProfile.liam.id)
        return store.summary(for: .liam)!
    }
}

#Preview("Reflection Status - Home Card") {
    ParentReflectionStatusCard(
        child: .liam,
        summary: ParentReflectionStatusCardPreviewData.pendingSummary,
        layout: .homeCard,
        onViewReflection: {}
    )
    .padding()
    .background(Color.evSurface)
}

#Preview("Reflection Status - Profile Header") {
    ParentReflectionStatusCard(
        child: .liam,
        summary: ParentReflectionStatusCardPreviewData.completedSummary,
        layout: .profileHeader,
        onViewReflection: {}
    )
    .padding()
    .background(Color.evSurface)
}
