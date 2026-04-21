import SwiftUI

struct RuleItem: Identifiable, Hashable {
    let id: String
    let iconSystemName: String
    let title: String
    let detail: String
    var on: Bool
    let tone: RuleRow.Tone
}

struct ProfileEvent: Identifiable, Hashable {
    let id = UUID()
    let time: String
    let title: String
    let location: String?
}

struct DeviceItem: Identifiable, Hashable {
    let id = UUID()
    let iconSystemName: String
    let name: String
    let detail: String
    let locked: Bool
}

enum ProfileMockData {
    static func rules(for childId: String) -> [RuleItem] {
        [
            .init(id: "screen", iconSystemName: "display",
                  title: "Daily Screen Time", detail: "1h limit per day",
                  on: true, tone: .primary),
            .init(id: "bed", iconSystemName: "moon",
                  title: "Bedtime", detail: "8:00 PM Sharp",
                  on: true, tone: .tertiary),
            .init(id: "chores", iconSystemName: "sun.max",
                  title: "Morning Chores", detail: "Mandatory sequence",
                  on: false, tone: .neutral),
        ]
    }

    static func tasks(for childId: String) -> [TaskItem] {
        [
            .init(id: 1, title: "Clean Table", state: .done, iconSystemName: "checkmark"),
            .init(id: 2, title: "Science Project", state: .review, iconSystemName: "camera"),
            .init(id: 3, title: "Math Practice", state: .pending, iconSystemName: nil),
            .init(id: 4, title: "Walk Dog", state: .overdue, iconSystemName: nil),
        ]
    }

    static func events(for childId: String) -> [ProfileEvent] {
        switch childId {
        case "liam":
            return [
                .init(time: "8:00 AM", title: "Clean Table", location: "Kitchen"),
                .init(time: "1:30 PM", title: "Math Practice", location: "Study Room"),
                .init(time: "4:00 PM", title: "Soccer Practice", location: "City Park"),
            ]
        case "maya":
            return [
                .init(time: "10:00 AM", title: "Piano Practice", location: "Living Room"),
                .init(time: "3:30 PM", title: "Art Class", location: "Art Studio"),
            ]
        default:
            return [
                .init(time: "2:00 PM", title: "Reading Time", location: "Bedroom"),
                .init(time: "7:30 PM", title: "Story Time", location: "Bedroom"),
            ]
        }
    }

    static func devices(for childId: String) -> [DeviceItem] {
        [
            .init(iconSystemName: "iphone", name: "iPhone 13", detail: "Primary device", locked: false),
            .init(iconSystemName: "ipad", name: "iPad", detail: "Homework only", locked: true),
            .init(iconSystemName: "laptopcomputer", name: "MacBook Air", detail: "School hours 9-3", locked: false),
        ]
    }
}
