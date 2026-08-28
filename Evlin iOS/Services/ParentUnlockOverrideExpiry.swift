import DeviceActivity
import Foundation

/// Owns the durable expiry activity for a parent unlock override.
///
/// The override mirror is authoritative. DeviceActivity is only a wake-up leg:
/// every caller can safely rebuild or expire the one named activity from the
/// persisted server deadline after a force quit.
nonisolated enum ParentUnlockOverrideExpiry {
    static let activityPrefix = "evlin.parent-unlock-expiry."

    struct Plan: Equatable, Sendable {
        let ownerID: UUID
        let revision: Int64
        let startedAt: Date
        let deadline: Date

        var activityName: String {
            ParentUnlockOverrideExpiry.activityName(ownerID: ownerID, revision: revision)
        }
    }

    enum Reduction: Equatable, Sendable {
        case arm(Plan, replacing: [String])
        case disarm(activityNames: [String])
        case expire(revision: Int64, activityNames: [String])
        case unchanged
    }

    enum Result: Equatable, Sendable {
        case armed(revision: Int64, deadline: Date)
        case expired(revision: Int64)
        case ownerMismatch
        case unchanged
    }

    enum ExpiryError: Error, Equatable, Sendable {
        case gatewayUnavailable
        case daemonRejectedSchedule
    }

    static func activityName(ownerID: UUID, revision: Int64) -> String {
        "\(activityPrefix)\(ownerID.uuidString.lowercased()).\(revision)"
    }

    static func reduce(
        snapshot: ParentUnlockOverrideSnapshot?,
        now: Date,
        expectedOwner: UUID,
        monitoredActivityNames: Set<String>
    ) -> Reduction {
        let ownedNames = monitoredActivityNames
            .filter { $0.hasPrefix(activityPrefix) }
            .sorted()

        guard let snapshot else {
            return ownedNames.isEmpty ? .unchanged : .disarm(activityNames: ownedNames)
        }
        guard snapshot.childDeviceID == expectedOwner else {
            return ownedNames.isEmpty ? .unchanged : .disarm(activityNames: ownedNames)
        }
        guard snapshot.status == .active, !snapshot.envelope.cancelled else {
            return ownedNames.isEmpty ? .unchanged : .disarm(activityNames: ownedNames)
        }
        guard now < snapshot.expiresAt else {
            return .expire(revision: snapshot.revision, activityNames: ownedNames)
        }

        let plan = Plan(
            ownerID: snapshot.childDeviceID,
            revision: snapshot.revision,
            startedAt: snapshot.startedAt,
            deadline: snapshot.expiresAt
        )
        let desiredName = plan.activityName
        let staleNames = ownedNames.filter { $0 != desiredName }
        return monitoredActivityNames.contains(desiredName)
            ? (staleNames.isEmpty ? .unchanged : .arm(plan, replacing: staleNames))
            : .arm(plan, replacing: staleNames)
    }

    @discardableResult
    static func arm(
        snapshot: ParentUnlockOverrideSnapshot,
        now: Date,
        scheduler: any DeviceActivityScheduling,
        calendar: Calendar = .current
    ) async throws -> Result {
        let names = try await liveActivityNames(scheduler)
        let reduction = reduce(
            snapshot: snapshot,
            now: now,
            expectedOwner: snapshot.childDeviceID,
            monitoredActivityNames: names
        )
        switch reduction {
        case .arm(let plan, let replacing):
            if !replacing.isEmpty {
                try await stop(replacing, scheduler: scheduler)
            }
            if !names.contains(plan.activityName) {
                try await start(plan, scheduler: scheduler, calendar: calendar)
            }
            return .armed(revision: plan.revision, deadline: plan.deadline)
        case .expire(let revision, let activityNames):
            if !activityNames.isEmpty {
                try await stop(activityNames, scheduler: scheduler)
            }
            return .expired(revision: revision)
        case .disarm(let activityNames):
            try await stop(activityNames, scheduler: scheduler)
            return .unchanged
        case .unchanged:
            return .unchanged
        }
    }

    @discardableResult
    static func reconcile(
        now: Date,
        expectedOwner: UUID,
        store: ParentUnlockOverrideStore = .shared,
        scheduler: any DeviceActivityScheduling,
        calendar: Calendar = .current
    ) async throws -> Result {
        let monitoredNames = try await liveActivityNames(scheduler)
        let expiryNames = monitoredNames.filter { $0.hasPrefix(activityPrefix) }.sorted()
        let snapshot: ParentUnlockOverrideSnapshot?
        do {
            snapshot = try store.read(expectedOwner: expectedOwner)
        } catch ParentUnlockOverrideStoreError.ownerMismatch {
            if !expiryNames.isEmpty {
                try await stop(expiryNames, scheduler: scheduler)
            }
            return .ownerMismatch
        }

        guard let snapshot else {
            if !expiryNames.isEmpty {
                try await stop(expiryNames, scheduler: scheduler)
            }
            return .unchanged
        }

        let reduction = reduce(
            snapshot: snapshot,
            now: now,
            expectedOwner: expectedOwner,
            monitoredActivityNames: monitoredNames
        )
        switch reduction {
        case .expire(let revision, let activityNames):
            if try store.expireIfNeeded(expectedOwner: expectedOwner, now: now) {
                if !activityNames.isEmpty {
                    try await stop(activityNames, scheduler: scheduler)
                }
                return .expired(revision: revision)
            }
            return .unchanged
        case .disarm(let activityNames):
            try await stop(activityNames, scheduler: scheduler)
            return .unchanged
        case .arm(let plan, let replacing):
            if !replacing.isEmpty {
                try await stop(replacing, scheduler: scheduler)
            }
            if !monitoredNames.contains(plan.activityName) {
                try await start(plan, scheduler: scheduler, calendar: calendar)
            }
            return .armed(revision: plan.revision, deadline: plan.deadline)
        case .unchanged:
            return .unchanged
        }
    }

    @discardableResult
    static func reconcileAndProject(
        now: Date,
        expectedOwner: UUID,
        store: ParentUnlockOverrideStore = .shared,
        scheduler: any DeviceActivityScheduling,
        calendar: Calendar = .current,
        project: () async -> Void
    ) async throws -> Result {
        let result = try await reconcile(
            now: now,
            expectedOwner: expectedOwner,
            store: store,
            scheduler: scheduler,
            calendar: calendar
        )
        if case .expired = result {
            await project()
        }
        return result
    }

    /// DeviceActivity already ended this exact one-shot activity. Expire the
    /// matching durable mirror without consulting the daemon again so the
    /// synchronous extension callback never waits on XPC.
    static func expireFromActivityCallback(
        activityName: String,
        now: Date,
        expectedOwner: UUID,
        store: ParentUnlockOverrideStore = .shared
    ) throws -> Result {
        guard let identity = callbackIdentity(activityName),
              identity.ownerID == expectedOwner,
              let snapshot = try store.read(expectedOwner: expectedOwner),
              snapshot.revision == identity.revision,
              now >= snapshot.expiresAt,
              try store.expireIfNeeded(expectedOwner: expectedOwner, now: now)
        else {
            return .unchanged
        }
        return .expired(revision: identity.revision)
    }

    /// Cheap callback-entry recovery: every DAM callback can close an elapsed
    /// override even if iOS delays or drops the dedicated one-shot intervalEnd.
    /// This performs only the small App Group mirror transaction; it never
    /// consults DeviceActivityCenter or the network.
    static func expireElapsedMirrorIfNeeded(
        now: Date,
        expectedOwner: UUID,
        store: ParentUnlockOverrideStore = .shared
    ) throws -> Result {
        guard let snapshot = try store.read(expectedOwner: expectedOwner),
              snapshot.status == .active,
              now >= snapshot.expiresAt,
              try store.expireIfNeeded(expectedOwner: expectedOwner, now: now)
        else {
            return .unchanged
        }
        return .expired(revision: snapshot.revision)
    }

    static func clearForIdentityTeardown(
        store: ParentUnlockOverrideStore = .shared,
        scheduler: any DeviceActivityScheduling
    ) async throws {
        try store.clearForIdentityTeardown()
        let names = try await liveActivityNames(scheduler)
            .filter { $0.hasPrefix(activityPrefix) }
            .sorted()
        try await stop(names, scheduler: scheduler)
    }

    static func clearForIdentityTeardown() {
        try? ParentUnlockOverrideStore.shared.clearForIdentityTeardown()
        Task {
            try? await clearForIdentityTeardown(
                store: .shared,
                scheduler: DeviceActivityCenterScheduler()
            )
        }
    }

    private static func liveActivityNames(
        _ scheduler: any DeviceActivityScheduling
    ) async throws -> Set<String> {
        guard let names = await MeteringDeviceActivityGateway.performCritical("parentUnlockExpiry.activities", {
            Set(scheduler.monitoredActivities().map(\.rawValue))
        }) else {
            throw ExpiryError.gatewayUnavailable
        }
        return names
    }

    private static func callbackIdentity(
        _ activityName: String
    ) -> (ownerID: UUID, revision: Int64)? {
        guard activityName.hasPrefix(activityPrefix) else { return nil }
        let suffix = activityName.dropFirst(activityPrefix.count)
        guard let separator = suffix.lastIndex(of: "."),
              let ownerID = UUID(uuidString: String(suffix[..<separator])),
              let revision = Int64(suffix[suffix.index(after: separator)...])
        else { return nil }
        return (ownerID, revision)
    }

    private static func stop(
        _ activityNames: [String],
        scheduler: any DeviceActivityScheduling
    ) async throws {
        guard !activityNames.isEmpty else { return }
        guard await MeteringDeviceActivityGateway.performCritical("parentUnlockExpiry.stop", {
            scheduler.stopMonitoring(activityNames.map { DeviceActivityName($0) })
            return true
        }) != nil else {
            throw ExpiryError.gatewayUnavailable
        }
    }

    private static func start(
        _ plan: Plan,
        scheduler: any DeviceActivityScheduling,
        calendar: Calendar
    ) async throws {
        let didStart = await MeteringDeviceActivityGateway.performCritical("parentUnlockExpiry.start", {
            do {
                try scheduler.startMonitoring(
                    DeviceActivityName(plan.activityName),
                    during: scheduleForTesting(
                        start: plan.startedAt,
                        end: plan.deadline,
                        calendar: calendar
                    )
                )
                return true
            } catch {
                return false
            }
        })
        guard let didStart else { throw ExpiryError.gatewayUnavailable }
        guard didStart else { throw ExpiryError.daemonRejectedSchedule }
    }

    static func scheduleForTesting(
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> DeviceActivitySchedule {
        let components: Set<Calendar.Component> = [
            .calendar, .timeZone, .year, .month, .day, .hour, .minute, .second,
        ]
        return DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(components, from: start),
            intervalEnd: calendar.dateComponents(components, from: end),
            repeats: false
        )
    }
}

nonisolated struct ParentUnlockOverrideChildPresentation: Equatable, Sendable {
    let remainingMinutes: Int
    let label: String

    static func active(
        snapshot: ParentUnlockOverrideSnapshot?,
        now: Date,
        expectedOwner: UUID
    ) -> Self? {
        guard let snapshot,
              snapshot.childDeviceID == expectedOwner,
              snapshot.status == .active,
              !snapshot.envelope.cancelled,
              now < snapshot.expiresAt
        else { return nil }

        return Self(
            remainingMinutes: max(1, Int(ceil(snapshot.expiresAt.timeIntervalSince(now) / 60))),
            label: "Unlocked by parent"
        )
    }

    static func shouldShowTimeUp(
        allTasksDone: Bool,
        minutesLeft: Int,
        activeOverride: Self?
    ) -> Bool {
        allTasksDone && minutesLeft <= 0 && activeOverride == nil
    }
}
