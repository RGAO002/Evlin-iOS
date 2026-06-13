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
                    ForEach(groupedRows(feed.items)) { bellRow in
                        switch bellRow {
                        case .single(let n): row(for: n)
                        case .group(let g):  groupRow(for: g)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Multi-app grouping (lock/block receipts applied together)
    //
    // The kid acks each command separately, so blocking N apps in one action
    // emits N single-app `command_applied` receipts. Rather than N bell rows,
    // collapse a run of success receipts that share verb + device and land
    // within a short window into ONE multi-app tile (matches the redesign's
    // stacked-icon notification). Failures and non-app kinds never group.

    private static let groupWindow: TimeInterval = 90

    private func groupedRows(_ items: [FeedNotification]) -> [BellRow] {
        var rows: [BellRow] = []
        var i = 0
        while i < items.count {
            let n = items[i]
            if isGroupableAppLock(n), var last = parsedDate(n.createdAt) {
                var members = [n]
                var j = i + 1
                while j < items.count {
                    let m = items[j]
                    guard isGroupableAppLock(m), sameGroupKey(n, m),
                          let md = parsedDate(m.createdAt),
                          last.timeIntervalSince(md) <= Self.groupWindow  // newest-first ⇒ last ≥ md
                    else { break }
                    members.append(m); last = md; j += 1
                }
                if members.count >= 2 {
                    rows.append(.group(makeGroup(members)))
                    i = j
                    continue
                }
            }
            rows.append(.single(n))
            i += 1
        }
        return rows
    }

    private func isGroupableAppLock(_ n: FeedNotification) -> Bool {
        n.type == "command_applied"
            && n.renderArgs?["kind"] == "app"
            && n.urgency == "in_app_only"   // success receipts only — failures stay individual
    }

    private func sameGroupKey(_ a: FeedNotification, _ b: FeedNotification) -> Bool {
        (a.renderArgs?["verb"] ?? "") == (b.renderArgs?["verb"] ?? "")
            && (a.renderArgs?["device_label"] ?? "") == (b.renderArgs?["device_label"] ?? "")
            && a.childProfileId == b.childProfileId
    }

    private func makeGroup(_ members: [FeedNotification]) -> AppLockGroup {
        let first = members[0]
        var seen = Set<String>(); var apps: [String] = []
        for m in members {
            let name = m.renderArgs?["name"] ?? ""
            if !name.isEmpty, seen.insert(name).inserted { apps.append(name) }
        }
        var link = first.deepLink ?? [:]
        link["event_id"] = link["event_id"] ?? first.eventId
        link["notification_type"] = link["notification_type"] ?? first.type
        if let cid = first.childProfileId { link["child_profile_id"] = cid }
        return AppLockGroup(
            id: first.id,
            verb: first.renderArgs?["verb"] ?? "locked",
            deviceLabel: first.renderArgs?["device_label"] ?? "their device",
            deepLink: link, apps: apps, members: members,
            latestCreatedAt: first.createdAt)
    }

    private func parsedDate(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return ISO8601DateFormatter.feed.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    @ViewBuilder
    private func row(for n: FeedNotification) -> some View {
        let style = FeedNotificationStyle.of(n)
        let color = style.color
        let unreadRow = isUnread(n)
        Button {
            locallyRead.insert(n.id)
            Task { await feed.mark(n.id, action: "opened") }
            var link = n.deepLink ?? [:]
            link["event_id"] = link["event_id"] ?? n.eventId
            link["notification_type"] = link["notification_type"] ?? n.type
            if let cid = n.childProfileId { link["child_profile_id"] = cid }
            onOpenDeepLink(link)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if unreadRow {
                    Circle().fill(color).frame(width: 6, height: 6).offset(y: 10)
                } else {
                    Color.clear.frame(width: 6, height: 6).offset(y: 10)
                }

                tile(for: n, style: style)

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

    /// A collapsed run of single-app lock/block receipts → one multi-app tile.
    @ViewBuilder
    private func groupRow(for g: AppLockGroup) -> some View {
        let color: Color = g.verb == "blocked" ? .orange : .green
        let unreadRow = g.members.contains(where: isUnread)
        let multi = g.apps.count >= 2
        let title = multi ? "\(g.apps.count) apps \(g.verb)"
                          : "\(g.apps.first ?? "App") \(g.verb)"
        let subtitle = multi ? "\(g.apps.joined(separator: ", ")) · \(g.deviceLabel)"
                             : g.deviceLabel
        Button {
            for m in g.members { locallyRead.insert(m.id) }
            Task { for m in g.members { await feed.mark(m.id, action: "opened") } }
            onOpenDeepLink(g.deepLink ?? [:])
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if unreadRow {
                    Circle().fill(color).frame(width: 6, height: 6).offset(y: 10)
                } else {
                    Color.clear.frame(width: 6, height: 6).offset(y: 10)
                }

                badged(badge: g.verb == "blocked" ? "nosign" : "lock.fill", color: color) {
                    if multi { MultiAppTile(names: g.apps) }
                    else { LockAppIcon(name: g.apps.first ?? "") }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                    Text(subtitle)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 10) {
                    Text(relativeTime(g.latestCreatedAt))
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOutline)
                    Button {
                        Task { for m in g.members { await feed.dismiss(m.id) } }
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

    /// Lock receipt → app artwork / all-grid / category symbol / list (+ a
    /// lock/block/failed corner badge). Kid-scoped event → the kid's avatar
    /// (initial fallback, like Home) + a type badge. Else → a tinted SF Symbol.
    @ViewBuilder
    private func tile(for n: FeedNotification, style: FeedNotificationStyle) -> some View {
        if n.type == "command_applied", let kind = n.renderArgs?["kind"] {
            let failed = n.urgency != "in_app_only"
            let verb = n.renderArgs?["verb"] ?? "locked"
            badged(badge: failed ? "exclamationmark.triangle.fill"
                              : (verb == "blocked" ? "nosign" : "lock.fill"),
                   color: failed ? .red : (verb == "blocked" ? .orange : .green)) {
                lockBase(kind: kind, name: n.renderArgs?["name"] ?? "", color: style.color)
            }
        } else if let cid = n.childProfileId,
                  let child = familyStore.childProfiles.first(where: { $0.id == cid }) {
            badged(badge: style.symbol, color: style.color) {
                EvlinAvatarView(url: child.avatarURL, name: child.name, size: 46)
            }
        } else {
            symbolTile(symbol: style.symbol, color: style.color)
        }
    }

    @ViewBuilder
    private func lockBase(kind: String, name: String, color: Color) -> some View {
        switch kind {
        case "app":      LockAppIcon(name: name)
        case "all":      AllAppsTile()
        case "category": symbolTile(symbol: FeedNotificationPanel.categorySymbol(name), color: color)
        default:         symbolTile(symbol: "list.bullet.rectangle.fill", color: color)
        }
    }

    private func symbolTile(symbol: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(color.opacity(0.12))
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(color)
        }
        .frame(width: 46, height: 46)
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(color.opacity(0.25), lineWidth: 1.5))
    }

    /// 46pt content with a punched-out corner badge (bottom-trailing).
    @ViewBuilder
    private func badged<Content: View>(badge: String, color: Color,
                                       @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .bottomTrailing) {
            content().frame(width: 46, height: 46)
            ZStack {
                Circle().fill(Color.evSurfaceContainerLow).frame(width: 19, height: 19)
                Circle().fill(color).frame(width: 16, height: 16)
                Image(systemName: badge).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
            }
            .offset(x: 3, y: 3)
        }
        .frame(width: 46, height: 46)
    }

    /// Evlin's 5 reserved categories → a distinct SF Symbol (vs the all-apps grid).
    static func categorySymbol(_ name: String) -> String {
        switch name.lowercased() {
        case "social":        return "bubble.left.and.bubble.right.fill"
        case "games":         return "gamecontroller.fill"
        case "entertainment": return "play.tv.fill"
        case "education":     return "graduationcap.fill"
        case "productivity":  return "briefcase.fill"
        default:              return "square.grid.2x2.fill"
        }
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

/// 46pt App Store artwork for a locked app, resolved by name (same source the
/// chat uses — AppArtworkResolver / iTunes lookup, cached). Falls back to a
/// generic app glyph while loading or when no artwork is found.
private struct LockAppIcon: View {
    let name: String
    @State private var artURL: URL?

    var body: some View {
        content
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.5), lineWidth: 0.5))
            .task(id: name) { artURL = await AppArtworkResolver.shared.artwork(forName: name) }
    }

    @ViewBuilder private var content: some View {
        if let artURL {
            AsyncImage(url: artURL) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { placeholder }
            }
        } else { placeholder }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.evSurfaceContainerHigh)
            .overlay(Image(systemName: "app.fill").font(.system(size: 18)).foregroundStyle(Color.evOutline))
    }
}

/// 46pt "all apps" tile — a 2×2 grid, visually distinct from a single app icon.
private struct AllAppsTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.evSurfaceContainerHigh)
            .frame(width: 46, height: 46)
            .overlay(
                VStack(spacing: 3) {
                    HStack(spacing: 3) { dot(.pink); dot(.blue) }
                    HStack(spacing: 3) { dot(.green); dot(.orange) }
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.5), lineWidth: 0.5))
    }

    private func dot(_ c: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(c.opacity(0.85)).frame(width: 13, height: 13)
    }
}

// MARK: - Multi-app grouping models + tile

/// One displayed bell entry: a lone notification, or a collapsed cluster of
/// single-app lock/block receipts applied together.
private enum BellRow: Identifiable {
    case single(FeedNotification)
    case group(AppLockGroup)
    var id: String {
        switch self {
        case .single(let n): return n.id
        case .group(let g):  return "grp:\(g.id)"
        }
    }
}

/// A run of `command_applied` (kind=app, success) receipts that share verb +
/// device and landed in the same short window — rendered as one multi-app tile.
private struct AppLockGroup {
    let id: String                 // stable: newest member's recipient id
    let verb: String               // "blocked" | "locked"
    let deviceLabel: String
    let deepLink: [String: String]?
    let apps: [String]             // unique app names, newest-first
    let members: [FeedNotification]
    let latestCreatedAt: String?
}

/// 46pt multi-app tile — up to 3 real App Store artworks fanned in a diagonal
/// stack (newest on top). A distinct silhouette from the 2×2 grid used by the
/// "all apps" tile, so "3 apps locked" never reads as "everything locked". The
/// exact count + names live in the row's title/subtitle, so the stack only needs
/// to convey "a bundle of apps".
private struct MultiAppTile: View {
    let names: [String]

    var body: some View {
        let shown = Array(names.prefix(3))
        let count = shown.count
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.offset) { idx, name in
                let d = (CGFloat(idx) - CGFloat(count - 1) / 2) * 6.5
                MiniAppArtwork(name: name, size: 27)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.evSurfaceContainerLow, lineWidth: 2))
                    .offset(x: d, y: d)
                    .zIndex(Double(count - idx))   // idx 0 (newest) on top
            }
        }
        .frame(width: 46, height: 46)
    }
}

/// App Store artwork resolved by name (same source as `LockAppIcon`), sized for
/// the stacked multi-app tile.
private struct MiniAppArtwork: View {
    let name: String
    var size: CGFloat = 18
    @State private var artURL: URL?

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .task(id: name) { artURL = await AppArtworkResolver.shared.artwork(forName: name) }
    }

    @ViewBuilder private var content: some View {
        if let artURL {
            AsyncImage(url: artURL) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { placeholder }
            }
        } else { placeholder }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Color.evSurfaceContainerHigh)
            .overlay(Image(systemName: "app.fill").font(.system(size: size * 0.45)).foregroundStyle(Color.evOutline))
    }
}
