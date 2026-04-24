import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import CryptoKit

/// Translates LockCommand into ActiveLockStore mutations.
/// See spec §6 for dispatcher logic and §3.4 for merge rules.
final class ActionExecutor: @unchecked Sendable {
    static let shared = ActionExecutor()

    private let activityCenter = DeviceActivityCenter()

    /// iOS DeviceActivitySchedule hard minimum.
    static let minScheduleMinutes: Int = 15

    func execute(_ cmd: LockCommand, blob: Data? = nil) async -> AckResult {
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            return .failed(.notAuthorized)
        }

        switch cmd.action {
        case .shield:
            return await executeShield(cmd: cmd, blob: blob)
        case .block:
            return await executeBlock(cmd: cmd)
        case .unshield:
            return await executeUnshield(cmd: cmd)
        case .unblock:
            return await executeUnblock(cmd: cmd)
        case .unshieldAll:
            let cleared = await ActiveLockStore.shared.unshieldAll()
            cancelAllScheduled()
            return .confirmedExact(verb: .unshieldAll, displayName: "\(cleared.count) shield(s) cleared", effectiveState: nil)
        case .unblockAll:
            let cleared = await ActiveLockStore.shared.unblockAll()
            return .confirmedExact(verb: .unblockAll, displayName: "\(cleared.count) block(s) cleared", effectiveState: nil)
        case .expandLibrary:
            return .failed(.execution("expand_library handled in UI"))
        }
    }

    // MARK: - Shield

    private func executeShield(cmd: LockCommand, blob: Data?) async -> AckResult {
        do {
            let record = try buildShieldRecord(from: cmd, blob: blob)
            let force = cmd.target.forceDowngrade
            let result = await ActiveLockStore.shared.addShield(record, force: force)
            switch result {
            case .added, .upgradedToPermanent, .extendedTimed:
                if let expiresAt = record.expiresAt {
                    try? scheduleRelock(recordKey: record.recordKey, expiresAt: expiresAt)
                }
                let eff = await currentEffectiveState(forShieldRecord: record, cmd: cmd)
                return buildConfirmReceipt(verb: .shield, cmd: cmd, record: record, effectiveState: eff)
            case .noOpShorterThanExisting, .noOpAlreadyPermanent:
                let eff = await currentEffectiveState(forShieldRecord: record, cmd: cmd)
                return .confirmedExact(verb: .shield, displayName: "\(record.displayName) already covered", effectiveState: eff)
            case .needsConfirmation(let reason):
                let context: [String: String]
                switch reason {
                case .downgradePermanentToTimed(let existingKey, let newExpiry):
                    context = [
                        "card_id": "B1",
                        "target_display": record.displayName,
                        "target_request": cmd.target.originalRequest,
                        "existing_record_key": existingKey,
                        "requested_expiry_iso": ISO8601DateFormatter().string(from: newExpiry),
                        "requested_duration_minutes": String(cmd.durationMinutes ?? 0),
                        "existing_mode": "permanent",
                    ]
                }
                return .pendingConfirmation(cardID: "B1", context: context)
            }
        } catch let err as ExecuteError {
            return .failed(err.ackFailure)
        } catch {
            return .failed(.execution(error.localizedDescription))
        }
    }

    private func buildConfirmReceipt(
        verb: AckVerb,
        cmd: LockCommand,
        record: ShieldRecord,
        effectiveState: AckEffectiveState?
    ) -> AckResult {
        switch cmd.tier {
        case .category:
            return .confirmedFallback(
                verb: verb,
                displayName: record.displayName,
                category: cmd.target.categoryHint ?? "unknown",
                origRequest: cmd.target.originalRequest,
                effectiveState: effectiveState
            )
        default:
            return .confirmedExact(verb: verb, displayName: record.displayName, effectiveState: effectiveState)
        }
    }

    private func currentEffectiveState(forShieldRecord record: ShieldRecord, cmd: LockCommand) async -> AckEffectiveState? {
        let query: AppQuery
        if let bid = cmd.target.bundleID {
            query = AppQuery(bundleID: bid, categoryHint: cmd.target.categoryHint?.lowercased())
        } else {
            query = AppQuery(bundleID: nil, categoryHint: cmd.target.categoryHint?.lowercased())
        }
        let state = await ActiveLockStore.shared.effectiveState(for: query)
        return AckEffectiveState(
            isBlocked: state.blockedAfter,
            shieldsCovering: state.stillCovered.map {
                .init(displayName: $0.displayName,
                      expiresAtISO: $0.expiresAt.map { ISO8601DateFormatter().string(from: $0) },
                      tier: $0.tier.rawValue)
            },
            possibleSavedListCoverage: state.possibleSavedListCoverage
        )
    }

    private func effectiveStateFrom(_ stillCovered: [ShieldRecord], isBlocked: Bool, possibleSavedList: Bool) -> AckEffectiveState {
        AckEffectiveState(
            isBlocked: isBlocked,
            shieldsCovering: stillCovered.map {
                .init(displayName: $0.displayName,
                      expiresAtISO: $0.expiresAt.map { ISO8601DateFormatter().string(from: $0) },
                      tier: $0.tier.rawValue)
            },
            possibleSavedListCoverage: possibleSavedList
        )
    }

    private func buildShieldRecord(from cmd: LockCommand, blob: Data?) throws -> ShieldRecord {
        let tier = cmd.tier ?? .category
        let targetKey: String
        var appTokens: Set<ApplicationToken> = []
        var categoryTokens: Set<ActivityCategoryToken> = []
        var webDomainTokens: Set<WebDomainToken> = []
        var appliesToAll = false
        var displayName = cmd.target.targetDisplay ?? "Unknown"

        switch tier {
        case .exactApp:
            // GAP: No token source is wired in MVP. See plan Phase 3 Task 3.1.
            throw ExecuteError.notImplemented(
                "exactApp shield requires Phase 5 token mapping — this path should be unreachable"
            )
        case .savedList:
            let sel: FamilyActivitySelection
            if let blob = blob,
               let decoded = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: blob) {
                sel = decoded
            } else if let name = cmd.target.listName,
                      let local = LocalAliasStore.shared.savedList(named: name) {
                sel = local
            } else {
                throw ExecuteError.listNotFound(cmd.target.listName ?? "(unnamed)")
            }
            appTokens = sel.applicationTokens
            categoryTokens = sel.categoryTokens
            webDomainTokens = sel.webDomainTokens
            if let id = cmd.target.listID {
                targetKey = id.uuidString
            } else {
                throw ExecuteError.malformed
            }
            displayName = cmd.target.listName ?? "saved list"
        case .category:
            guard let hint = cmd.target.categoryHint,
                  let tok = LocalAliasStore.shared.categoryToken(forName: hint)
            else {
                throw ExecuteError.categoryNotConfigured(cmd.target.categoryHint ?? "unknown")
            }
            categoryTokens = [tok]
            targetKey = hint.lowercased()
            displayName = hint.capitalized
        case .all:
            targetKey = "all"
            appliesToAll = true
            displayName = "All Apps"
        }

        let recordKey = ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey)
        var expiresAt = cmd.expiresAt
        if let exp = expiresAt, exp.timeIntervalSinceNow < TimeInterval(Self.minScheduleMinutes * 60) {
            expiresAt = Date().addingTimeInterval(TimeInterval(Self.minScheduleMinutes * 60))
        }

        return ShieldRecord(
            recordKey: recordKey,
            tier: tier,
            targetKey: targetKey,
            displayName: displayName,
            lastCommandID: cmd.id,
            appTokens: appTokens,
            categoryTokens: categoryTokens,
            webDomainTokens: webDomainTokens,
            appliesToAll: appliesToAll,
            issuedAt: cmd.issuedAt,
            expiresAt: expiresAt,
            originalRequest: cmd.target.originalRequest,
            targetChildID: cmd.target.targetChildID ?? UUID()
        )
    }

    // MARK: - Block

    private func executeBlock(cmd: LockCommand) async -> AckResult {
        guard let bundleID = cmd.target.bundleID else {
            return .failed(.malformed)
        }
        let record = BlockRecord(
            bundleID: bundleID,
            displayName: cmd.target.targetDisplay ?? bundleID,
            blockedAt: cmd.issuedAt,
            lastCommandID: cmd.id,
            originalRequest: cmd.target.originalRequest,
            targetChildID: cmd.target.targetChildID ?? UUID()
        )
        let result = await ActiveLockStore.shared.addBlock(record)
        let query = AppQuery(bundleID: bundleID, categoryHint: nil)
        let state = await ActiveLockStore.shared.effectiveState(for: query)
        let eff = effectiveStateFrom(state.stillCovered, isBlocked: true, possibleSavedList: state.possibleSavedListCoverage)
        switch result {
        case .added:
            return .confirmedExact(verb: .block, displayName: record.displayName, effectiveState: eff)
        case .alreadyBlocked:
            return .confirmedExact(verb: .block, displayName: "\(record.displayName) already blocked", effectiveState: eff)
        }
    }

    // MARK: - Unshield — spec §4.4

    private func executeUnshield(cmd: LockCommand) async -> AckResult {
        guard let tier = cmd.tier else { return .failed(.malformed) }

        switch tier {
        case .savedList:
            guard let id = cmd.target.listID else { return .failed(.nothingToUnlock) }
            return await removeExplicit(tier: .savedList, targetKey: id.uuidString)
        case .category:
            guard let hint = cmd.target.categoryHint else { return .failed(.nothingToUnlock) }
            return await removeExplicit(tier: .category, targetKey: hint.lowercased())
        case .all:
            return await removeExplicit(tier: .all, targetKey: "all")
        case .exactApp:
            guard let bid = cmd.target.bundleID else { return .failed(.malformed) }
            return await unshieldAppByBundle(
                bundleID: bid,
                displayName: cmd.target.targetDisplay ?? bid,
                categoryHint: cmd.target.categoryHint
            )
        }
    }

    private func removeExplicit(tier: ShieldTier, targetKey: String) async -> AckResult {
        let recordKey = ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey)
        guard let removed = await ActiveLockStore.shared.removeShield(recordKey: recordKey) else {
            return .failed(.nothingToUnlock)
        }
        cancelScheduled(recordKey: recordKey)
        let query = AppQuery(bundleID: nil, categoryHint: nil)
        let state = await ActiveLockStore.shared.effectiveState(for: query)
        let eff = effectiveStateFrom(state.stillCovered, isBlocked: state.blockedAfter, possibleSavedList: state.possibleSavedListCoverage)
        return .confirmedExact(verb: .unshield, displayName: removed.record.displayName, effectiveState: eff)
    }

    private func unshieldAppByBundle(bundleID: String, displayName: String, categoryHint: String?) async -> AckResult {
        let query = AppQuery(bundleID: bundleID, categoryHint: categoryHint?.lowercased())
        let state = await ActiveLockStore.shared.effectiveState(for: query)

        if let exactAppShield = state.shieldsCovering.first(where: { $0.tier == .exactApp }) {
            guard let removed = await ActiveLockStore.shared.removeShield(recordKey: exactAppShield.recordKey) else {
                return .failed(.nothingToUnlock)
            }
            cancelScheduled(recordKey: exactAppShield.recordKey)
            let post = await ActiveLockStore.shared.effectiveState(for: query)
            let eff = effectiveStateFrom(post.stillCovered, isBlocked: post.blockedAfter, possibleSavedList: post.possibleSavedListCoverage)
            return .confirmedExact(verb: .unshield, displayName: removed.record.displayName, effectiveState: eff)
        }

        let broader = state.shieldsCovering.filter { $0.tier != .exactApp }
        switch broader.count {
        case 0:
            return .failed(.nothingToUnlock)
        case 1:
            let s = broader[0]
            return .failed(.execution(
                "\(displayName) is shielded by \(s.displayName). To release it, use \"unlock \(s.displayName)\"."
            ))
        default:
            let sources = broader.map { s -> String in
                if let exp = s.expiresAt {
                    let f = DateFormatter(); f.timeStyle = .short
                    return "\(s.displayName) (until \(f.string(from: exp)))"
                }
                return "\(s.displayName) (permanent)"
            }.joined(separator: ", ")
            return .failed(.execution(
                "\(displayName) is shielded by \(broader.count) sources: \(sources). Unlock one explicitly."
            ))
        }
    }

    // MARK: - Unblock

    private func executeUnblock(cmd: LockCommand) async -> AckResult {
        guard let bid = cmd.target.bundleID else { return .failed(.malformed) }
        guard let removed = await ActiveLockStore.shared.removeBlock(
            bundleID: bid,
            categoryHint: cmd.target.categoryHint
        ) else {
            return .failed(.nothingToUnlock)
        }
        let eff = effectiveStateFrom(
            removed.stillShieldedBy,
            isBlocked: false,
            possibleSavedList: removed.possibleSavedListCoverage
        )
        return .confirmedExact(verb: .unblock, displayName: removed.record.displayName, effectiveState: eff)
    }

    // MARK: - DeviceActivity scheduling

    private func scheduleRelock(recordKey: String, expiresAt: Date) throws {
        let now = Date()
        let requestedInterval = expiresAt.timeIntervalSince(now)
        let minInterval = TimeInterval(Self.minScheduleMinutes * 60)
        let clampedEnd = requestedInterval < minInterval
            ? now.addingTimeInterval(minInterval)
            : expiresAt
        let calendar = Calendar.current
        let startComp = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComp = calendar.dateComponents([.hour, .minute, .second], from: clampedEnd)
        let schedule = DeviceActivitySchedule(intervalStart: startComp, intervalEnd: endComp, repeats: false)
        let name = DeviceActivityName(deviceActivityNameFor(recordKey: recordKey))
        try activityCenter.startMonitoring(name, during: schedule)
    }

    private func cancelScheduled(recordKey: String) {
        let name = DeviceActivityName(deviceActivityNameFor(recordKey: recordKey))
        activityCenter.stopMonitoring([name])
    }

    private func cancelAllScheduled() {
        activityCenter.stopMonitoring()
    }

    private func deviceActivityNameFor(recordKey: String) -> String {
        let data = recordKey.data(using: .utf8) ?? Data()
        let bytes = sha256Hex16(data)
        return "evlin.shield.\(bytes)"
    }
}

// MARK: - Helpers

private func sha256Hex16(_ data: Data) -> String {
    let hash = SHA256.hash(data: data)
    return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
}

enum ExecuteError: Error {
    case malformed
    case listNotFound(String)
    case categoryNotConfigured(String)
    case notImplemented(String)

    var ackFailure: AckFailure {
        switch self {
        case .malformed: return .malformed
        case .listNotFound(let n): return .listNotFound(n)
        case .categoryNotConfigured(let n): return .categoryNotConfigured(n)
        case .notImplemented(let reason): return .execution("Not implemented in MVP: \(reason)")
        }
    }
}
