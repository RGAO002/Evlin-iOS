import Foundation

/// Projects the durable lock records into the effective enforcement set while
/// a parent unlock override is active. The policy is pure: it never changes
/// the durable records, their expiry schedules, or metering state.
nonisolated enum ParentUnlockOverridePolicy {
    struct Projection: Equatable, Sendable {
        let shields: [String: ShieldRecord]
        let blocks: [String: BlockRecord]
    }

    static func project(
        shields: [String: ShieldRecord],
        blocks: [String: BlockRecord],
        snapshot: ParentUnlockOverrideSnapshot?,
        reflectionActive: Bool
    ) -> Projection {
        guard let snapshot,
              snapshot.status == .active,
              !snapshot.envelope.cancelled
        else {
            return Projection(shields: shields, blocks: blocks)
        }

        let suppressedSources = shieldSources(for: snapshot.scopes)
        var projectedShields: [String: ShieldRecord] = [:]
        projectedShields.reserveCapacity(shields.count)

        for (key, record) in shields {
            if reflectionActive && isReflectionRecord(record) {
                projectedShields[key] = record
                continue
            }

            var projected = record
            projected.sources.subtract(suppressedSources)
            if !projected.sources.isEmpty {
                projectedShields[key] = projected
            }
        }

        let projectedBlocks = snapshot.scopes.contains(.manual) ? [:] : blocks
        return Projection(shields: projectedShields, blocks: projectedBlocks)
    }

    private static func shieldSources(
        for scopes: Set<ParentUnlockOverrideScope>
    ) -> Set<ShieldSource> {
        var sources: Set<ShieldSource> = []
        if scopes.contains(.manual) {
            sources.insert(.manual)
        }
        if scopes.contains(.earnedTime) {
            sources.insert(.earnedTime)
        }
        if scopes.contains(.taskPause) {
            sources.insert(.taskPause)
        }
        if scopes.contains(.deviceLimit) || scopes.contains(.perAppLimit) {
            sources.insert(.limit)
        }
        return sources
    }

    private static func isReflectionRecord(_ record: ShieldRecord) -> Bool {
        record.recordKey.hasPrefix("all:reflection:")
    }
}

nonisolated enum ParentUnlockOverrideProjectionApplication {
    static func project(
        shields: [String: ShieldRecord],
        blocks: [String: BlockRecord],
        snapshot: ParentUnlockOverrideSnapshot?
    ) -> ParentUnlockOverridePolicy.Projection {
        ParentUnlockOverridePolicy.project(
            shields: shields,
            blocks: blocks,
            snapshot: snapshot,
            reflectionActive: shields.values.contains {
                $0.recordKey.hasPrefix("all:reflection:")
            }
        )
    }

    static func project(
        shields: [String: ShieldRecord],
        blocks: [String: BlockRecord],
        expectedOwner: UUID?,
        store: ParentUnlockOverrideStore = .shared
    ) -> ParentUnlockOverridePolicy.Projection {
        let snapshot = expectedOwner.flatMap { try? store.read(expectedOwner: $0) }
        return project(shields: shields, blocks: blocks, snapshot: snapshot)
    }
}

nonisolated enum ParentUnlockOverrideCommandApplicationError: Error, Equatable {
    case malformedCommand
}

nonisolated enum ParentUnlockOverrideAck {
    static func verb(for action: CommandAction) -> String {
        switch action {
        case .parentMasterLock:
            return "shield"
        case .parentMasterUnlock:
            return "unshield"
        case .parentUnlockOverride:
            return "unshield_all"
        case .parentUnlockOverrideCancel:
            return "reconcile"
        default:
            return action.rawValue
        }
    }
}

nonisolated enum ParentUnlockOverrideCommandApplication {
    static func apply(
        envelope: ParentUnlockOverrideEnvelope,
        expectedOwner: UUID,
        now: Date,
        store: ParentUnlockOverrideStore = .shared,
        project: () async throws -> Void
    ) async throws -> ParentUnlockOverrideDisposition {
        let disposition = try store.ingest(
            envelope,
            expectedOwner: expectedOwner,
            now: now
        )
        switch disposition {
        case .applied, .replayed:
            try await project()
        case .superseded, .rejectedIdentity:
            break
        }
        return disposition
    }

    static func apply(
        command: LockCommand,
        expectedOwner: UUID,
        now: Date,
        store: ParentUnlockOverrideStore = .shared,
        project: () async throws -> Void
    ) async throws -> ParentUnlockOverrideDisposition {
        guard let envelope = command.parentUnlockOverride,
              command.target.targetChildID == nil
                || command.target.targetChildID == expectedOwner,
              (command.action == .parentUnlockOverride && !envelope.cancelled)
                || (command.action == .parentUnlockOverrideCancel && envelope.cancelled)
        else {
            throw ParentUnlockOverrideCommandApplicationError.malformedCommand
        }
        return try await apply(
            envelope: envelope,
            expectedOwner: expectedOwner,
            now: now,
            store: store,
            project: project
        )
    }
}

nonisolated enum ParentUnlockOverrideNSEApplication {
    static func apply(
        command: LockCommand,
        expectedOwner: UUID,
        now: Date = Date(),
        store: ParentUnlockOverrideStore = .shared,
        expiryScheduler: (any DeviceActivityScheduling)? = nil,
        project: () async throws -> Void
    ) async throws -> ParentUnlockOverrideDisposition {
        try await ParentUnlockOverrideCommandApplication.apply(
            command: command,
            expectedOwner: expectedOwner,
            now: now,
            store: store,
            project: {
                if let expiryScheduler {
                    _ = try await ParentUnlockOverrideExpiry.reconcile(
                        now: now,
                        expectedOwner: expectedOwner,
                        store: store,
                        scheduler: expiryScheduler
                    )
                }
                try await project()
            }
        )
    }
}

nonisolated enum ParentMasterControlCommandApplication {
    struct PreparedMutation: Equatable {
        let disposition: ParentUnlockOverrideDisposition
        let desiredLocked: Bool?
    }

    static func prepare(
        command: LockCommand,
        expectedOwner: UUID,
        now: Date,
        store: ParentUnlockOverrideStore = .shared
    ) throws -> PreparedMutation {
        guard let envelope = command.parentUnlockOverride,
              command.target.targetChildID == nil
                || command.target.targetChildID == expectedOwner,
              envelope.cancelled,
              command.action == .parentMasterLock
                || command.action == .parentMasterUnlock
        else {
            throw ParentUnlockOverrideCommandApplicationError.malformedCommand
        }

        let disposition = try store.ingest(
            envelope,
            expectedOwner: expectedOwner,
            now: now
        )
        let desiredLocked: Bool?
        switch disposition {
        case .applied, .replayed:
            desiredLocked = command.action == .parentMasterLock
        case .superseded, .rejectedIdentity:
            desiredLocked = nil
        }
        return PreparedMutation(
            disposition: disposition,
            desiredLocked: desiredLocked
        )
    }
}
