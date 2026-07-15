import Foundation

nonisolated enum AutomaticLockNoticeAction: Equatable, Sendable {
    case overrideEarnedTime(usageDate: String)
}

nonisolated struct AutomaticLockNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case earnedTime
        case taskPause
    }

    let kind: Kind
    let systemImage: String
    let message: String
    let actionTitle: String?
    let action: AutomaticLockNoticeAction?

    static func make(
        coveringSources: [String],
        exhausted: Bool,
        overrideActive: Bool,
        usageDate: String?
    ) -> AutomaticLockNotice? {
        let sources = Set(coveringSources.map(normalize))

        let earnedSources: Set<String> = [
            "earnedtime", "earnedpool", "devicepool", "devicecap"
        ]
        if exhausted || !sources.isDisjoint(with: earnedSources) {
            if overrideActive {
                return .init(
                    kind: .earnedTime,
                    systemImage: "hourglass.bottomhalf.filled",
                    message: "Screen time override is applying.",
                    actionTitle: nil,
                    action: nil
                )
            }
            let action = usageDate.map(AutomaticLockNoticeAction.overrideEarnedTime)
            return .init(
                kind: .earnedTime,
                systemImage: "hourglass.bottomhalf.filled",
                message: exhausted
                    ? "Screen time is used up for today."
                    : "A screen time limit is keeping apps locked.",
                actionTitle: action == nil ? nil : "Override today",
                action: action
            )
        }

        if sources.contains("taskpause") {
            return .init(
                kind: .taskPause,
                systemImage: "checklist",
                message: "Today's tasks are keeping apps locked. Review tasks below.",
                actionTitle: nil,
                action: nil
            )
        }

        return nil
    }

    static func completeCoveringSources(
        expectedDeviceCount: Int,
        coveringSources: [[String]?]
    ) -> [String]? {
        guard expectedDeviceCount > 0,
              coveringSources.count == expectedDeviceCount,
              coveringSources.allSatisfy({ $0 != nil })
        else { return nil }
        return coveringSources.compactMap { $0 }.flatMap { $0 }
    }

    private static func normalize(_ source: String) -> String {
        source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}

@MainActor
enum AutomaticLockActionRunner {
    static func run(
        action: AutomaticLockNoticeAction,
        childProfileID: UUID,
        unlockOverride: (UUID, String) async throws -> Void
    ) async throws {
        switch action {
        case .overrideEarnedTime(let usageDate):
            try await unlockOverride(childProfileID, usageDate)
        }
    }
}
