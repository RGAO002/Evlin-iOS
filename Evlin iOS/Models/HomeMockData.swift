import SwiftUI

struct HomeNotification: Identifiable, Hashable {
    let id: Int
    let childId: String      // "liam" / "maya" / "emma" / "family"
    let iconSystemName: String
    let title: String
    let body: String
    let time: String
    var unread: Bool
}

enum HomeMockData {
    static let notifications: [HomeNotification] = [
        .init(id: 1, childId: "liam", iconSystemName: "checkmark.circle",
              title: "Homework Complete",
              body: "Liam finished his Science Project and submitted it for review.",
              time: "2m ago", unread: true),
        .init(id: 2, childId: "maya", iconSystemName: "music.note",
              title: "Piano Practice Done",
              body: "Maya completed her 45-min piano session.",
              time: "18m ago", unread: true),
        .init(id: 3, childId: "liam", iconSystemName: "figure.soccer",
              title: "Soccer Practice",
              body: "Liam's session starts in 30 minutes at City Park.",
              time: "1h ago", unread: false),
        .init(id: 4, childId: "emma", iconSystemName: "book",
              title: "Reading Goal Reached",
              body: "Emma read for 60 minutes today — new personal best!",
              time: "2h ago", unread: false),
        .init(id: 5, childId: "family", iconSystemName: "fork.knife",
              title: "Family Dinner Reminder",
              body: "Family dinner is in 1 hour. Everyone to the dining room.",
              time: "3h ago", unread: false),
    ]

    static func childColor(_ id: String) -> Color {
        switch id {
        case "liam": return .evChildLiam
        case "maya": return .evChildMaya
        case "emma": return .evChildEmma
        default: return .evPrimary
        }
    }

    static func avatarURL(_ id: String) -> String? {
        ChildProfile.all.first(where: { $0.id == id })?.avatarURL
    }
}
