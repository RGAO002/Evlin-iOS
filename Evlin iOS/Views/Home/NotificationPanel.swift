import SwiftUI

/// HP-13: durable read/dismiss state for Home notifications.
///
/// `ParentRootView.homeNotifications` regenerates the list (with
/// `unread: true`) on every body evaluation, and the panel only mutated a
/// per-presentation `@State` copy — so "Mark all read" and dismissals
/// silently undid themselves on the next open. This helper persists two
/// small key-sets in `UserDefaults`: ContentView filters freshly generated
/// entries through `applying(to:)`, and the panel's actions write through
/// `markRead` / `markDismissed`.
///
/// `HomeNotification.id` is an enumeration index (9000+idx completions,
/// 9100+idx nudges) and is NOT stable across regenerations, so the
/// persisted key is derived from stable content identity instead:
/// kind band + childId + reflectionId + title. Including the title means a
/// rework of the same reflection ("…has reworked the reflection essay")
/// re-surfaces as a fresh unread entry even if the original completion was
/// read or dismissed.
enum HomeNotificationAckStore {
    static let readDefaultsKey = "evlin.home.readNotificationKeys"
    static let dismissedDefaultsKey = "evlin.home.dismissedNotificationKeys"

    static func stableKey(for n: HomeNotification) -> String {
        let band: String
        switch n.id {
        case 9000..<9100: band = "completion"
        case 9100..<9200: band = "nudge"
        default:          band = "base-\(n.id)"
        }
        return [band, n.childId, n.reflectionId?.uuidString ?? "-", n.title]
            .joined(separator: "|")
    }

    static var readKeys: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: readDefaultsKey) ?? [])
    }

    static var dismissedKeys: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: dismissedDefaultsKey) ?? [])
    }

    static func markRead(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        UserDefaults.standard.set(
            Array(readKeys.union(keys)), forKey: readDefaultsKey)
    }

    static func markDismissed(_ key: String) {
        UserDefaults.standard.set(
            Array(dismissedKeys.union([key])), forKey: dismissedDefaultsKey)
    }

    /// Apply persisted state to freshly generated entries: drop dismissed
    /// ones, clear `unread` on read ones.
    static func applying(to notifications: [HomeNotification]) -> [HomeNotification] {
        let read = readKeys
        let dismissed = dismissedKeys
        return notifications.compactMap { n in
            let key = stableKey(for: n)
            guard !dismissed.contains(key) else { return nil }
            var copy = n
            if read.contains(key) { copy.unread = false }
            return copy
        }
    }
}

struct NotificationPanel: View {
    var onClose: () -> Void
    /// Open a task directly. Replaces the older two-step
    /// `onOpenProfile(childId, taskId?)` flow — task notifications now
    /// push straight to TaskDetail through the parent navigation stack.
    var onOpenTask: (String, Int) -> Void = { _, _ in }
    /// Open the parent reflection-review surface for a specific
    /// (child, reflection). The caller routes this to the profile-
    /// with-reflection-sub-tab destination so the parent lands on the
    /// Step 1/2/3 listing inline. First arg is childId
    /// (`ChildProfile.id`), second is the reflection UUID.
    var onOpenReflection: (String, UUID) -> Void = { _, _ in }
    @Environment(FamilyStore.self) private var familyStore
    @State private var notifs: [HomeNotification]

    init(
        onClose: @escaping () -> Void,
        notifications: [HomeNotification] = HomeMockData.notifications,
        onOpenTask: @escaping (String, Int) -> Void = { _, _ in },
        onOpenReflection: @escaping (String, UUID) -> Void = { _, _ in }
    ) {
        self.onClose = onClose
        self.onOpenTask = onOpenTask
        self.onOpenReflection = onOpenReflection
        _notifs = State(initialValue: notifications)
    }

    private var unread: Int { notifs.filter(\.unread).count }

    var body: some View {
        VStack(spacing: 0) {
            customHeader
            content
        }
        .background(Color.evSurfaceContainerLow)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
    }

    // MARK: - Custom header (per screenshot)

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
                    // HP-13: persist before mutating the local copy so the
                    // badge stays cleared after the panel closes.
                    HomeNotificationAckStore.markRead(
                        notifs.map(HomeNotificationAckStore.stableKey(for:)))
                    withAnimation { notifs = notifs.map { var n = $0; n.unread = false; return n } }
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
        if notifs.isEmpty {
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
                    ForEach(notifs) { n in
                        row(for: n)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func row(for n: HomeNotification) -> some View {
        let color = HomeMockData.childColor(n.childId)
        Button {
            // HP-13: tapping a row marks it read durably, not just in the
            // local @State copy.
            HomeNotificationAckStore.markRead([HomeNotificationAckStore.stableKey(for: n)])
            withAnimation {
                if let idx = notifs.firstIndex(where: { $0.id == n.id }) {
                    notifs[idx].unread = false
                }
            }
            // Deep-link: task notifications push TaskDetail on the same
            // navigation stack we're already inside (Home or Insights).
            // No more close-then-reopen dance.
            if n.kind == "task", n.childId != "family", let tid = n.taskId {
                onOpenTask(n.childId, tid)
            } else if n.kind == "reflection", let reflectionId = n.reflectionId {
                onOpenReflection(n.childId, reflectionId)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if n.unread {
                    Circle().fill(color).frame(width: 6, height: 6).offset(y: 10)
                } else {
                    Color.clear.frame(width: 6, height: 6).offset(y: 10)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(color.opacity(0.12))
                    if let url = HomeMockData.avatarURL(n.childId, in: familyStore.childProfiles), let u = URL(string: url) {
                        AsyncImage(url: u) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Image(systemName: n.iconSystemName)
                                    .font(.system(size: 16))
                                    .foregroundStyle(color)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    } else {
                        Image(systemName: n.iconSystemName)
                            .font(.system(size: 18))
                            .foregroundStyle(color)
                    }
                }
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(color.opacity(0.25), lineWidth: 1.5)
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(n.title)
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                    Text(n.body)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 10) {
                    Text(n.time)
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOutline)
                    Button {
                        // HP-13: dismissals persist — ContentView filters
                        // this key out of every future regeneration.
                        HomeNotificationAckStore.markDismissed(
                            HomeNotificationAckStore.stableKey(for: n))
                        withAnimation { notifs.removeAll { $0.id == n.id } }
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
            .background(n.unread ? color.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
            alignment: .bottom
        )
    }
}

#Preview {
    NavigationStack {
        NotificationPanel(onClose: {})
    }
}
