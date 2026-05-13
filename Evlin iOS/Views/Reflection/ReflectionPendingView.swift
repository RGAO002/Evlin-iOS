import SwiftUI

struct ReflectionPendingView: View {
    let childId: String
    var onBack: (() -> Void)? = nil

    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @State private var activeAlert: PendingReflectionAlert?

    private var child: ChildProfile? {
        ChildProfile.all.first { $0.id == childId }
    }

    private var summary: ParentReflectionSummary? {
        reflectionStore.summary(childId: childId)
    }

    private var displayName: String {
        summary?.childName ?? child?.name ?? "your child"
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Reflection", kicker: "Parent status", onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if let summary {
                        pendingContent(summary)
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

    private func pendingContent(_ summary: ParentReflectionSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            statusHero(summary)
            detailsCard(summary)
            actionCard
        }
    }

    private func statusHero(_ summary: ParentReflectionSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            HStack(alignment: .top, spacing: Spacing.xl) {
                reflectionAvatar

                VStack(alignment: .leading, spacing: Spacing.md) {
                    statusBadge

                    Text("Reflection in progress")
                        .font(.custom("Manrope", size: 30).weight(.heavy))
                        .tracking(-0.7)
                        .foregroundStyle(Color.evPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(displayName) hasn't finished this reflection yet. You'll get notified when it's ready to review.")
                        .font(.evBodyMedium)
                        .lineSpacing(3)
                        .foregroundStyle(Color.evOnReflectionBadge)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if summary.state != .assignedPending {
                Text("This prototype page is optimized for assigned reflections that are still waiting on the child.")
                    .font(.evCaption)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.top, Spacing.sm)
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

    private func detailsCard(_ summary: ParentReflectionSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Assignment")
                .font(.evLabelMedium)
                .foregroundStyle(Color.evOnReflectionBadge)
                .evLabelStyle()

            VStack(spacing: 0) {
                detailRow(label: "Child", value: summary.childName)
                detailDivider
                detailRow(label: "Status", value: "Under reflection")
                detailDivider
                detailRow(label: "Assigned", value: formattedDate(summary.assignedAt))
                detailDivider
                detailRow(label: "Reason", value: summary.reason)
                detailDivider
                detailRow(label: "Prompt", value: summary.prompt)

                if let parentNote = summary.parentNote, !parentNote.isEmpty {
                    detailDivider
                    detailRow(label: "Parent note", value: parentNote)
                }
            }
            .background(Color.evSurfaceContainerLowest.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                    .stroke(Color.evReflectionBorder.opacity(0.35), lineWidth: 1)
            )
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

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Prototype actions")
                .font(.evLabelMedium)
                .foregroundStyle(Color.evOnReflectionBadge)
                .evLabelStyle()

            Text("These controls are local stubs until reflection management endpoints are available.")
                .font(.evBodySmall)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(2)

            VStack(spacing: Spacing.md) {
                Button {
                    // TODO: wire to backend reflection reminder endpoint when available.
                    activeAlert = .reminderQueued(displayName)
                } label: {
                    actionLabel(title: "Send reminder", systemImage: "bell.badge")
                }
                .buttonStyle(.plain)

                Button {
                    // TODO: wire to backend reflection cancel endpoint when available.
                    activeAlert = .cancelConfirmed(displayName)
                } label: {
                    actionLabel(title: "Cancel reflection", systemImage: "xmark.circle")
                }
                .buttonStyle(.plain)
            }
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
            Image(systemName: "text.book.closed")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.evOnReflectionBadge)
                .frame(width: 62, height: 62)
                .background(Color.evReflectionBadge.opacity(0.9))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("No reflection assigned")
                    .font(.custom("Manrope", size: 28).weight(.heavy))
                    .tracking(-0.5)
                    .foregroundStyle(Color.evPrimary)

                Text("There isn't an active reflection for \(displayName) right now. When one is assigned, its status and details will appear here.")
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

    private var reflectionAvatar: some View {
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

            Image(systemName: "hourglass")
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

    private var statusBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 10, weight: .heavy))

            Text("Under reflection")
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

private enum PendingReflectionAlert: Identifiable {
    case reminderQueued(String)
    case cancelConfirmed(String)

    var id: String {
        switch self {
        case .reminderQueued:
            return "reminderQueued"
        case .cancelConfirmed:
            return "cancelConfirmed"
        }
    }

    var title: String {
        switch self {
        case .reminderQueued:
            return "Reminder queued"
        case .cancelConfirmed:
            return "Reflection cancellation queued"
        }
    }

    var message: String {
        switch self {
        case .reminderQueued(let childName):
            return "Prototype only: a reminder would be sent to \(childName)."
        case .cancelConfirmed(let childName):
            return "Prototype only: \(childName)'s reflection would be canceled."
        }
    }
}

#Preview("Pending Reflection") {
    NavigationStack {
        ReflectionPendingView(childId: ChildProfile.liam.id, onBack: {})
    }
    .environment(ParentReflectionFixtureStore())
}

#Preview("Pending Reflection Empty") {
    NavigationStack {
        ReflectionPendingView(childId: ChildProfile.maya.id, onBack: {})
    }
    .environment(ParentReflectionFixtureStore())
}
