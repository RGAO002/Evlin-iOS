import SwiftUI

/// Feed-backed parent bell (notif spec §1.6 / Phase 3).
///
/// Styled to match the original Home `NotificationPanel` exactly —
/// `evSurfaceContainerLow` surface, Manrope/Inter type, a 46pt tinted tile with
/// a stroke ring, time + ✕ dismiss in the trailing column, hairline row
/// dividers, and the unread row tint. ONLY the data source differs: it renders
/// the real backend notification feed (every new notif type) instead of mock
/// data. Read/dismiss state is written back to the backend.
struct FeedNotificationPanel: View {
    @StateObject private var feed: NotificationFeedClient
    @Environment(FamilyStore.self) private var familyStore
    /// Optimistic read overlay so a tapped / mark-all row clears its dot now,
    /// not on the next refresh (matches the original panel's local @State).
    @State private var locallyRead: Set<String> = []
    var onClose: () -> Void
    /// Called with the event's `deep_link` dict (e.g. {"route":"deviceDetail",
    /// "device_id":"…"}). The caller maps it onto AppRoute.
    var onOpenDeepLink: ([String: String]) -> Void

    init(onClose: @escaping () -> Void,
         onOpenDeepLink: @escaping ([String: String]) -> Void) {
        _feed = StateObject(wrappedValue: NotificationFeedClient())
        self.onClose = onClose
        self.onOpenDeepLink = onOpenDeepLink
    }

    private func isUnread(_ n: FeedNotification) -> Bool {
        n.isUnread && !locallyRead.contains(n.id)
    }
    private var unread: Int { feed.items.filter(isUnread).count }

    var body: some View {
        VStack(spacing: 0) {
            customHeader
            content
        }
        .background(Color.evSurfaceContainerLow)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .task {
            await feed.refresh()
            feed.markOpened()  // opening the panel clears the bell's red dot
        }
        .refreshable { await feed.refresh() }
    }

    // MARK: - Custom header (matches original NotificationPanel)

    private var customHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onClose) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.evSurfaceContainerHigh)
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications")
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
                if unread > 0 {
                    Text("\(unread) unread")
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }
            .padding(.top, 4)

            Spacer()

            if unread > 0 {
                Button {
                    let ids = feed.items.filter(isUnread).map(\.id)
                    locallyRead.formUnion(ids)
                    Task { await feed.markAllRead() }
                } label: {
                    Text("Mark all read")
                        .font(.custom("Inter", size: 13).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(
            Color.evSurfaceContainerLow
                .ignoresSafeArea(edges: .top)
        )
    }

    @ViewBuilder
    private var content: some View {
        if feed.items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 40))
                Text("All caught up")
                    .font(.custom("Inter", size: 14))
            }
            .foregroundStyle(Color.evOnSurfaceVariant)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(feed.items) { n in
                        row(for: n)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func row(for n: FeedNotification) -> some View {
        let style = FeedNotificationStyle.of(n)
        let color = style.color
        let unreadRow = isUnread(n)
        Button {
            locallyRead.insert(n.id)
            Task { await feed.mark(n.id, action: "opened") }
            if let link = n.deepLink { onOpenDeepLink(link) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if unreadRow {
                    Circle().fill(color).frame(width: 6, height: 6).offset(y: 10)
                } else {
                    Color.clear.frame(width: 6, height: 6).offset(y: 10)
                }

                tile(for: n, color: color, symbol: style.symbol)

                VStack(alignment: .leading, spacing: 3) {
                    if let title = n.title {
                        Text(title)
                            .font(.custom("Manrope", size: 14).weight(.heavy))
                            .foregroundStyle(Color.evPrimary)
                    }
                    if let body = n.body {
                        Text(body)
                            .font(.custom("Inter", size: 12))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 10) {
                    Text(relativeTime(n.createdAt))
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOutline)
                    Button {
                        Task { await feed.dismiss(n.id) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .background(unreadRow ? color.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
            alignment: .bottom
        )
    }

    /// 46pt tinted tile: the kid's avatar for a child-scoped event, else the
    /// type's SF Symbol — both over the type tint with the original stroke ring.
    @ViewBuilder
    private func tile(for n: FeedNotification, color: Color, symbol: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(color.opacity(0.12))
            if let cid = n.childProfileId,
               let child = familyStore.childProfiles.first(where: { $0.id == cid }),
               let urlStr = child.avatarURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 16))
                            .foregroundStyle(color)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 46, height: 46)
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 1.5)
        )
    }

    private func relativeTime(_ iso: String?) -> String {
        guard let iso, let date = ISO8601DateFormatter.feed.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private extension ISO8601DateFormatter {
    static let feed: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// type (+ urgency) → bell row icon + tint.
struct FeedNotificationStyle {
    let symbol: String
    let color: Color

    static func of(_ n: FeedNotification) -> FeedNotificationStyle {
        switch n.type {
        case "command_applied":
            return n.urgency == "in_app_only"
                ? .init(symbol: "lock.fill", color: .green)
                : .init(symbol: "exclamationmark.triangle.fill", color: .red)
        case "command_delayed":
            return .init(symbol: "clock.fill", color: .orange)
        case "coparent_invite_approved":
            return .init(symbol: "person.crop.circle.badge.checkmark", color: .green)
        case "coparent_invite_declined":
            return .init(symbol: "person.crop.circle.badge.xmark", color: .secondary)
        case "coparent_invite_consumed":
            return .init(symbol: "envelope.fill", color: .blue)
        case "child_archived":
            return .init(symbol: "person.crop.circle.badge.minus", color: .secondary)
        case "pairing_done":
            return .init(symbol: "iphone.gen3", color: .blue)
        case "notifications_disabled":
            return .init(symbol: "bell.slash.fill", color: .orange)
        case "reflection_completed", "reflection_reworked", "kid_nudged_parent":
            return .init(symbol: "checkmark.seal.fill", color: .green)
        case "calendar_reminder":
            return .init(symbol: "calendar", color: .blue)
        case "device_offline":
            return .init(symbol: "wifi.slash", color: .orange)
        case "device_back_online":
            return .init(symbol: "wifi", color: .secondary)
        default:
            return .init(symbol: "bell.fill", color: .secondary)
        }
    }
}
