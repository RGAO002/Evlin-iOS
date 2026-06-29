import Foundation

enum ParentNotificationRoute: Equatable {
    case appRoute(AppRoute)
    case calendar
}

enum ParentNotificationRouteResolver {
    private static let reflectionTypes: Set<String> = [
        "reflection_completed",
        "reflection_reworked",
        "kid_nudged_parent",
    ]
    private static let taskTypes: Set<String> = [
        "task_submitted",
        "task_help_requested",
    ]

    static func route(
        for notification: FeedNotification,
        children: [ChildProfile]
    ) -> ParentNotificationRoute? {
        var link = notification.deepLink ?? [:]
        link["notification_type"] = link["notification_type"] ?? notification.type
        link["event_id"] = link["event_id"] ?? notification.eventId
        if let childProfileId = notification.childProfileId {
            link["child_profile_id"] = link["child_profile_id"] ?? childProfileId
        }
        return route(for: link, children: children)
    }

    static func route(
        for link: [String: String],
        children: [ChildProfile]
    ) -> ParentNotificationRoute? {
        switch link["route"] {
        case "calendarEvent", "calendar":
            return .calendar
        default:
            break
        }

        guard let child = child(from: link, children: children) else { return nil }

        if isReflectionRoute(link) {
            return .appRoute(.profileReflection(
                child,
                reflectionId: reflectionID(from: link)
            ))
        }

        if isTaskRoute(link), let taskID = taskID(from: link) {
            return .appRoute(.taskDetailByBackendID(
                child: child,
                backendTaskId: taskID
            ))
        }

        return .appRoute(.profile(child))
    }

    private static func child(
        from link: [String: String],
        children: [ChildProfile]
    ) -> ChildProfile? {
        guard let childProfileID = link["child_profile_id"], !childProfileID.isEmpty else {
            return nil
        }
        return children.first { $0.id == childProfileID }
    }

    private static func isReflectionRoute(_ link: [String: String]) -> Bool {
        if let type = link["notification_type"], reflectionTypes.contains(type) {
            return true
        }
        switch link["route"] {
        case "profileReflection", "reflection", "reflection_completed", "kid_nudged_parent":
            return true
        default:
            return false
        }
    }

    private static func isTaskRoute(_ link: [String: String]) -> Bool {
        if let type = link["notification_type"], taskTypes.contains(type) {
            return true
        }
        switch link["route"] {
        case "taskReview", "kidTaskDetail", "task":
            return true
        default:
            return false
        }
    }

    private static func taskID(from link: [String: String]) -> UUID? {
        let raw = link["task_id"] ?? link["taskId"]
        return raw.flatMap(UUID.init(uuidString:))
    }

    private static func reflectionID(from link: [String: String]) -> UUID {
        let raw = link["reflection_id"]
            ?? link["reflectionId"]
            ?? link["rid"]
            ?? link["event_id"]
        return raw.flatMap(UUID.init(uuidString:)) ?? UUID()
    }
}

struct PendingNotificationOpenStore {
    private static let key = "evlin.pendingNotificationOpenEventID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ eventID: String) {
        guard !eventID.isEmpty else { return }
        defaults.set(eventID, forKey: Self.key)
    }

    func consume() -> String? {
        guard let eventID = defaults.string(forKey: Self.key), !eventID.isEmpty else {
            return nil
        }
        defaults.removeObject(forKey: Self.key)
        return eventID
    }

    func clear(_ eventID: String) {
        guard defaults.string(forKey: Self.key) == eventID else { return }
        defaults.removeObject(forKey: Self.key)
    }
}
