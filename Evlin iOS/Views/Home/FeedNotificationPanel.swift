import SwiftUI

/// Feed-backed parent bell (notif spec §1.6 / Phase 3). Renders the real
/// backend notification feed in the existing panel style and routes taps to the
/// app's deep links. Read/dismiss state is written back to the backend.
struct FeedNotificationPanel: View {
    @StateObject private var feed: NotificationFeedClient
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

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .task {
            await feed.refresh()
            feed.markOpened()  // opening the panel clears the bell's red dot
        }
        .refreshable { await feed.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onClose) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications")
                    .font(.system(size: 22, weight: .heavy))
                if feed.unreadCount > 0 {
                    Text("\(feed.unreadCount) unread")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.top, 4)

            Spacer()

            if feed.unreadCount > 0 {
                Button {
                    Task { await feed.markAllRead() }
                } label: {
                    Text("Mark all read")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var content: some View {
        if feed.items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "bell.slash").font(.system(size: 40))
                Text("All caught up").font(.system(size: 14))
            }
            .foregroundStyle(Color.secondary)
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

    private func row(for n: FeedNotification) -> some View {
        let style = FeedNotificationStyle.of(n)
        return Button {
            Task { await feed.mark(n.id, action: "opened") }
            if let link = n.deepLink { onOpenDeepLink(link) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(n.isUnread ? style.color : Color.clear)
                    .frame(width: 6, height: 6).offset(y: 10)

                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(style.color.opacity(0.14))
                    Image(systemName: style.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(style.color)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    if let title = n.title {
                        Text(title)
                            .font(.system(size: 14, weight: n.isUnread ? .semibold : .regular))
                            .foregroundStyle(n.isUnread ? Color.primary : Color.secondary)
                    }
                    if let body = n.body {
                        Text(body).font(.system(size: 13)).foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        Text(relativeTime(n.createdAt))
                            .font(.system(size: 11)).foregroundStyle(Color.secondary)
                        if n.urgency != "in_app_only" {
                            Text("pushed").font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(Capsule().fill(Color.blue.opacity(0.14)))
                                .foregroundStyle(Color.blue)
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13))
                    .foregroundStyle(Color.secondary).padding(.top, 6)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
