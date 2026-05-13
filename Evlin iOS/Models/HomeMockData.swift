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
    /// Notifications array. Task entries deep-link to TaskDetail; reflection
    /// entries deep-link to the parent reflection artifact; the rest are informational.
    static let notifications: [HomeNotification] = [
        .init(id: 1, childId: "liam",   iconSystemName: "checkmark.circle",
              title: "Science Project — needs review",
              body: "Liam submitted his Science Project. Tap to review and approve.",
              time: "2m ago", unread: true, kind: "task", taskId: 2),
        .init(id: 2, childId: "maya",   iconSystemName: "music.note",
              title: "Piano Practice — needs review",
              body: "Maya finished her 45-min piano session and uploaded a clip.",
              time: "18m ago", unread: true, kind: "task", taskId: 2),
        .init(id: 6, childId: "liam",   iconSystemName: "exclamationmark.circle",
              title: "Walk Dog — overdue",
              body: "Liam hasn't checked off Walk Dog from yesterday.",
              time: "12h ago", unread: true, kind: "task", taskId: 4),
        .init(id: 7, childId: "liam",   iconSystemName: "clock",
              title: "Math Practice — due soon",
              body: "Math Practice is due at 6:00 PM today.",
              time: "30m ago", unread: false, kind: "task", taskId: 3),
        .init(id: 8, childId: "liam",   iconSystemName: "hand.raised",
              title: "Bypass requested — Read for 20 minutes",
              body: "\"I had football practice and got home too late. Can I do double tomorrow instead?\"",
              time: "5m ago", unread: true, kind: "task", taskId: 5),
        .init(id: 3, childId: "liam",   iconSystemName: "figure.soccer",
              title: "Soccer Practice",
              body: "Liam's session starts in 30 minutes at City Park.",
              time: "1h ago", unread: false),
        .init(id: 4, childId: "emma",   iconSystemName: "book",
              title: "Reading Goal Reached",
              body: "Emma read for 60 minutes today — new personal best!",
              time: "2h ago", unread: false),
        .init(id: 5, childId: "family", iconSystemName: "fork.knife",
              title: "Family Dinner Reminder",
              body: "Family dinner is in 1 hour. Everyone to the dining room.",
              time: "3h ago", unread: false),
    ]

    static func notifications(includingCompletedReflection reflectionId: UUID?) -> [HomeNotification] {
        guard let reflectionId else { return notifications }
        return [
            .init(id: 9, childId: "liam", iconSystemName: "text.book.closed.fill",
                  title: "Liam completed reflection",
                  body: "Liam finished his reflection and it's ready for your review.",
                  time: "Just now", unread: true, kind: "reflection",
                  reflectionId: reflectionId)
        ] + notifications
    }

    static func childColor(_ id: String) -> Color {
        switch id {
        case "liam": return .evChildLiam
        case "maya": return .evChildMaya
        case "emma": return .evChildEmma
        default:     return .evPrimary
        }
    }

    static func avatarURL(_ id: String) -> String? {
        ChildProfile.all.first(where: { $0.id == id })?.avatarURL
    }
}
