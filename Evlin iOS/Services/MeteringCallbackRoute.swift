import Foundation

nonisolated struct ParsedMeteringRouteName: Equatable, Sendable {
    let routeID: UUID
    let thresholdMinutes: Int
}

nonisolated enum MeteringRouteNamespace {
    static let prefix = "evlin.earned.v2."

    static func activityName(routeID: UUID) -> String {
        prefix + routeID.uuidString.lowercased()
    }

    static func eventName(routeID: UUID, thresholdMinutes: Int) -> String {
        precondition(thresholdMinutes > 0, "Metering event threshold must be positive")
        return "\(activityName(routeID: routeID)).t\(thresholdMinutes)"
    }

    static func parse(activityName: String, eventName: String) -> ParsedMeteringRouteName? {
        guard let routeID = parseRouteID(activityName),
              eventName.hasPrefix(activityName + ".t")
        else {
            return nil
        }

        let thresholdText = String(eventName.dropFirst(activityName.count + 2))
        guard !thresholdText.isEmpty,
              thresholdText.first != "0",
              thresholdText.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let thresholdMinutes = Int(thresholdText),
              thresholdMinutes > 0
        else {
            return nil
        }
        return ParsedMeteringRouteName(routeID: routeID, thresholdMinutes: thresholdMinutes)
    }

    private static func parseRouteID(_ activityName: String) -> UUID? {
        guard activityName.hasPrefix(prefix) else { return nil }
        let routeText = String(activityName.dropFirst(prefix.count))
        guard let routeID = UUID(uuidString: routeText),
              routeID.uuidString.lowercased() == routeText
        else {
            return nil
        }
        return routeID
    }
}
