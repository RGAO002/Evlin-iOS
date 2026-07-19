import Foundation
import Observation

/// Mirrors `GET /child/state` (spec §4 + §8.1). Routing reads from this
/// (spec §5). Swap an instance whenever a new snapshot arrives from the poller.
@Observable
final class BigKidState {
    // Server-mirrored
    var childName: String
    var minutesLeft: Int
    var minutesMax: Int
    var tasks: [BigKidTask]
    var reflectionRequest: ReflectionRequest?
    var notifyParentCooldownEndsAt: Date?
    var dailyCompleteAcknowledged: Bool
    var screenTimeFinishedAcknowledged: Bool

    // Local-only (UI navigation)
    var currentTaskId: UUID?

    init(snapshot: ChildStateResponse) {
        self.childName = snapshot.childName
        self.minutesLeft = snapshot.minutesLeft
        self.minutesMax = snapshot.minutesMax
        self.tasks = snapshot.tasks
        self.reflectionRequest = snapshot.reflectionRequest
        self.notifyParentCooldownEndsAt = snapshot.notifyParentCooldownEndsAt
        self.dailyCompleteAcknowledged = snapshot.dailyCompleteAcknowledged
        self.screenTimeFinishedAcknowledged = snapshot.screenTimeFinishedAcknowledged
    }

    nonisolated deinit {}

    /// Refresh from a new server snapshot. Preserves local-only UI nav fields.
    func apply(_ snapshot: ChildStateResponse) {
        childName = snapshot.childName
        minutesLeft = snapshot.minutesLeft
        minutesMax = snapshot.minutesMax
        tasks = snapshot.tasks
        reflectionRequest = snapshot.reflectionRequest
        notifyParentCooldownEndsAt = snapshot.notifyParentCooldownEndsAt
        dailyCompleteAcknowledged = snapshot.dailyCompleteAcknowledged
        screenTimeFinishedAcknowledged = snapshot.screenTimeFinishedAcknowledged
    }

    var allTasksDone: Bool {
        Self.usageCountingAllowed(for: tasks)
    }

    static func usageCountingAllowed(for tasks: [BigKidTask]) -> Bool {
        tasks.allSatisfy { task in
            task.status == .done || task.bypass?.status == .approved
        }
    }

    func task(id: UUID) -> BigKidTask? {
        tasks.first(where: { $0.id == id })
    }
}

extension ChildStateResponse {
    var effectiveUsageCountingAllowed: Bool {
        usageCountingAllowed
            ?? (BigKidState.usageCountingAllowed(for: tasks) && reflectionRequest == nil)
    }
}
