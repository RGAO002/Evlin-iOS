import SwiftUI

struct HomeNotification: Identifiable, Hashable {
    let id: Int
    let childId: String              // "liam" / "maya" / "emma" / "family"
    let iconSystemName: String
    let title: String
    let body: String
    let time: String
    var unread: Bool

    /// "task" → tap opens TaskDetail for taskId.
    /// "reflection" → tap opens ReflectionArtifactView for reflectionId.
    /// nil → tap only marks as read (legacy behavior).
    /// See HTML 220-228.
    var kind: String? = nil
    var taskId: Int? = nil
    var reflectionId: UUID? = nil
}

enum HomeMockData {
    /// Notification baseline. Empty for the public beta — the 8 fabricated
    /// liam/maya/emma entries misled testers more than an honest empty state
    /// (spec decision A). Real entries are appended by the combiner below from
    /// live reflection polling (ContentView.homeNotifications). A real
    /// notification feed is deferred to P2.
    static let notifications: [HomeNotification] = []

    /// One completion descriptor per child that has just finished a
    /// reflection. The caller (ContentView) collects these by walking
    /// the parent-side reflection store for every child in
    /// `ChildProfile.all`, so the parent sees a separate notification
    /// per kid (not just Liam).
    struct ReflectionCompletion {
        let childId: String
        let childName: String
        let reflectionId: UUID
        /// True when the kid is resubmitting after the parent sent
        /// the reflection back ("Liam has reworked..."); false on
        /// the first-time submission ("Liam completed reflection").
        let isRework: Bool
    }

    /// One nudge descriptor per child whose latest "Give them a
    /// nudge" tap on the kid side hasn't been seen by the parent
    /// yet. ContentView feeds these so the parent gets an extra
    /// notification distinct from the completion entry.
    struct ReflectionNudge {
        let childId: String
        let childName: String
        let reflectionId: UUID
    }

    static func notifications(
        completedReflections: [ReflectionCompletion] = [],
        pendingNudges: [ReflectionNudge] = []
    ) -> [HomeNotification] {
        guard !completedReflections.isEmpty || !pendingNudges.isEmpty else {
            return notifications
        }
        // Stable IDs split across the 9000s (completions) and 9100s
        // (nudges) so they don't collide with the baseline mock
        // entries (1-8) or each other. One slot per child per kind.
        let completionEntries: [HomeNotification] = completedReflections
            .enumerated()
            .map { idx, c in
                HomeNotification(
                    id: 9000 + idx,
                    childId: c.childId,
                    iconSystemName: "text.book.closed.fill",
                    title: c.isRework
                        ? "\(c.childName) has reworked the reflection essay"
                        : "\(c.childName) completed reflection",
                    body: c.isRework
                        ? "\(c.childName) revised their reflection — ready for your review again."
                        : "\(c.childName) finished their reflection and it's ready for your review.",
                    time: "Just now",
                    unread: true,
                    kind: "reflection",
                    reflectionId: c.reflectionId
                )
            }
        let nudgeEntries: [HomeNotification] = pendingNudges
            .enumerated()
            .map { idx, n in
                HomeNotification(
                    id: 9100 + idx,
                    childId: n.childId,
                    iconSystemName: "hand.point.up.left.fill",
                    title: "\(n.childName) nudged you — Please review the reflection",
                    body: "\(n.childName) is waiting on your review.",
                    time: "Just now",
                    unread: true,
                    kind: "reflection",
                    reflectionId: n.reflectionId
                )
            }
        // Nudge entries first (more urgent / time-sensitive), then
        // completion entries, then the baseline mock noise.
        return nudgeEntries + completionEntries + notifications
    }

    /// Back-compat shim — older single-child call sites kept working
    /// during the multi-child rollout. Prefer the
    /// `completedReflections:` form for new code.
    static func notifications(
        includingCompletedReflection reflectionId: UUID?
    ) -> [HomeNotification] {
        guard let reflectionId else { return notifications }
        return notifications(completedReflections: [
            ReflectionCompletion(
                childId: "liam",
                childName: "Liam",
                reflectionId: reflectionId,
                isRework: false
            )
        ])
    }

    static func childColor(_ id: String) -> Color {
        switch id {
        case "liam": return .evChildLiam
        case "maya": return .evChildMaya
        case "emma": return .evChildEmma
        default:     return .evPrimary
        }
    }

    /// Look up a child's avatar URL among an injected list (real
    /// `FamilyStore.childProfiles`). No longer reads the retired
    /// `ChildProfile.all` global — the host passes the live children in.
    static func avatarURL(_ id: String, in children: [ChildProfile]) -> String? {
        children.first(where: { $0.id == id })?.avatarURL
    }
}
