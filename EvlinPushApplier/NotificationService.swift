import UserNotifications
import FamilyControls
import ManagedSettings
import Foundation

/// Production Notification Service Extension (target: EvlinPushApplier).
///
/// The force-quit-resilient lock applier. iOS launches this extension for any
/// alert push carrying `mutable-content: 1` — which the backend's
/// `lock_command_alert` channel sets — EVEN when the host Evlin app is
/// user-terminated (the one delivery path that survives force-quit; proven by
/// the earlier spike). On delivery it:
///   1. reads `command_id` from `userInfo["evlin"]`,
///   2. GETs `/child/commands/{id}?device_id=<this device>` — auth is pure
///      device-ownership, no bearer (see backend `get_command_scoped`),
///   3. persists app-limit set/clear desired state for the main-app owner, or
///      decodes INLINE catalog token(s) and applies non-limit lock commands
///      through the shared `ActiveLockStore`, whose `recomputeAndApply()` writes
///      the DEFAULT `ManagedSettingsStore` — the exact store + App Group state
///      the main app uses — so the lock survives and reconciles with the app,
///   4. POSTs `/child/ack {status:"confirmed"}` so the ack-driven escalation
///      (`lock_escalation.py`) stops and the parent sees confirmation,
///   5. presents the (time-sensitive) alert.
///
/// SCOPE: the inline-token LOCK fast-path (`shield` / `block`) AND unlocks
/// (`unshield` / `unblock` / `unshield_all` / `unblock_all`) are applied here —
/// the `lock_command_alert` channel now carries both (NSE-primary for lock and
/// unlock). A lock that lacks inline tokens, or `expand_library`, is left
/// PENDING and UNACKED so the full app poller — which has the LocalAliasStore /
/// pending-blob fallbacks this target intentionally does NOT link — applies it
/// on next launch. Fail-safe: the NSE never guesses a lock, and never acks one
/// it did not actually apply.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    /// The in-flight apply pipeline, kept so expiry can cancel it instead of
    /// letting iOS suspend us mid-recovery at an arbitrary await.
    private var applyTask: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        if content.title.isEmpty { content.title = "Evlin" }
        self.bestAttempt = content

        let evlin = request.content.userInfo["evlin"] as? [String: Any]
        let kind = evlin?["kind"] as? String
        guard kind == "lock_command_alert",
              let cidString = evlin?["command_id"] as? String,
              let commandID = UUID(uuidString: cidString) else {
            NSEConfig.log("present-only kind=\(kind ?? "nil")")
            finish()
            return
        }

        applyTask = Task { [weak self] in
            await self?.applyLock(commandID: commandID)
            self?.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // iOS is about to suspend/kill us. Deliver whatever we have; the
        // ManagedSettings write (if reached) is synchronous inside the actor and
        // has already been attempted. Cancel the pipeline so a still-running
        // recovery unwinds at its next await instead of being suspended at an
        // arbitrary one (its durable work queue makes the cancellation safe).
        NSEConfig.log("time_will_expire")
        applyTask?.cancel()
        finish()
    }

    /// Idempotent: calls the system content handler at most once.
    private func finish() {
        guard let handler = contentHandler, let content = bestAttempt else { return }
        contentHandler = nil
        handler(content)
    }

    // MARK: - Apply pipeline

    private func applyLock(commandID: UUID) async {
        guard let baseURL = NSEConfig.baseURL, let deviceID = NSEConfig.deviceID else {
            NSEConfig.log("skip missing baseURL/deviceID cmd=\(commandID)")
            return
        }
        guard let command = await NSENetwork.fetchCommand(
            baseURL: baseURL, deviceID: deviceID, commandID: commandID
        ) else {
            NSEConfig.log("fetch failed cmd=\(commandID)")
            return
        }
        if command.action == .setLimit || command.action == .clearLimit {
            await persistAppLimit(
                command,
                baseURL: baseURL,
                deviceID: deviceID,
                commandID: commandID
            )
            return
        }
        if command.action == .earnedTimeConfig {
            await persistEarnedPolicy(
                command,
                baseURL: baseURL,
                deviceID: deviceID,
                commandID: commandID
            )
            return
        }
        if command.action == .meteringRearm {
            await rearmMetering(
                baseURL: baseURL,
                deviceID: deviceID,
                commandID: commandID
            )
            return
        }
        guard let outcome = await NSELockApplier.apply(
            command,
            fetchedDeviceID: deviceID
        ) else {
            NSEConfig.log("not applied (no inline token / not a lock) cmd=\(commandID) action=\(command.action.rawValue)")
            return
        }
        await NSENetwork.ack(baseURL: baseURL, deviceID: deviceID, commandID: commandID, outcome: outcome)
        NSEConfig.log("applied+acked cmd=\(commandID) verb=\(outcome.verb) name=\(outcome.displayName)")
        // Lifting the all-apps shield reopened the counting gate above. Run one
        // bounded recovery pass NOW so the paused pool actually resumes in this
        // same wake: on a force-quit device this extension is the only code
        // that will run until the kid reopens the app, and the config-command
        // path (the other recovery caller) may never fire.
        if outcome.verb == "unshield_all" {
            _ = try? await Self.withDeadline(seconds: 12) {
                try await MeteringProductionComposition.recoverFromSharedConfiguration(
                    role: .pushApplier
                )
            }
        }
    }

    private func persistAppLimit(
        _ command: LockCommand,
        baseURL: URL,
        deviceID: UUID,
        commandID: UUID
    ) async {
        let envelope: AppLimitCommandEnvelope
        do {
            envelope = try AppLimitProductionComposition.envelope(
                from: command,
                source: .notificationServiceExtension
            )
        } catch {
            NSEConfig.log("limit envelope rejected cmd=\(commandID)")
            return
        }

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: envelope,
            coordinator: AppLimitCommandCoordinator(),
            now: Date(),
            postAck: { ack in
                try await NSENetwork.ack(
                    baseURL: baseURL,
                    deviceID: deviceID,
                    commandID: commandID,
                    status: ack.status,
                    detail: ack.detail
                )
            },
            requestOwnerWake: {
                // Arm it HERE. A force-quit device only ever wakes its
                // extensions, so "persist now, let the owner arm later" meant
                // later never came: the rule sat `accepted_needs_owner`, iOS
                // was never handed a monitor, and the limit silently did not
                // exist until someone opened the app (2026-08-07, real device:
                // a 1-minute Apple TV limit that never fired).
                //
                // Running it here is safe alongside the app's own arm, but NOT
                // for the reason this comment used to give. It said the planner
                // "reconciles from the live DeviceActivity set" — which was only
                // safe while the arm held a cross-process flock that made the
                // app and this extension mutually exclusive. That lock was
                // removed to stop it wedging the app on an unanswered daemon
                // call, and reconciling from the live set then let whichever
                // side ran second tear down the other's monitor. What makes it
                // safe now is that the planner stops only activities no arm
                // provenance claims, so a concurrent arm's monitor is never
                // mistaken for a leftover.
                //
                // Failure is non-fatal — the ack stays pending and the durable
                // owner work remains pollable, exactly as before.
                let owner = MeteringOwnerMirror.current()
                let rules = AppLimitRuleStore.shared.all()
                let armed = owner.map { _ in
                    AppLimitPlanner().arm(rules: rules)
                }
                // NSLog cannot cross back from the extension, so record the
                // outcome where a `devicectl` pull can read it. Without this the
                // arm attempt is invisible: the provenance shows an armID with
                // no receipt and nothing says why.
                UserDefaults(suiteName: "group.com.evlin.ios")?.set(
                    "\(ISO8601DateFormatter().string(from: Date())) owner=\(owner != nil) "
                        + "rules=\(rules.count) result=\(String(describing: armed))",
                    forKey: "evlin.appLimit.nseArm"
                )
                NSEConfig.log(
                    "limit armed in NSE cmd=\(commandID) result=\(String(describing: armed))"
                )
            }
        )
        guard let delivery else {
            NSEConfig.log("limit persistence failed cmd=\(commandID)")
            return
        }
        let decision = await convergeLimitShield(
            envelope: envelope,
            command: command,
            commandID: commandID
        )
        bestAttempt?.body = AppLimitEnforcementConverger.noticeBody(
            for: envelope,
            decision: decision,
            fallbackDisplayName: command.target.targetDisplay
                ?? command.target.bundleID
                ?? "App"
        )
        NSEConfig.log(
            "limit persisted cmd=\(commandID) disposition=\(delivery.ack.disposition) ack=\(delivery.ackSucceeded)"
        )
    }

    /// Make the shield agree with the budget this command just set — here, in
    /// the extension that received it.
    ///
    /// The decision used to live on the backend, which could only guess whether
    /// the device was already shielded, and guessed wrong in one direction:
    /// raising a limit above today's usage emitted nothing and left the app
    /// locked (Fred, 2026-07-25: Snapchat 20/20 raised to 120, never unlocked).
    /// The device is the only party that both knows the shield's real state and
    /// can change it, so it decides — from the two numbers the command carries,
    /// with no reference to what came before.
    ///
    /// Running it in the NSE rather than the app is the point: a push arrives
    /// even when the app is not running, so the lock follows the parent's edit
    /// immediately instead of waiting for the child to next open Evlin.
    private func convergeLimitShield(
        envelope: AppLimitCommandEnvelope,
        command: LockCommand,
        commandID: UUID
    ) async -> AppLimitEnforcementDecision {
        let decision = AppLimitEnforcementConverger.decide(
            for: envelope,
            bundleID: command.target.bundleID
        )
        switch decision {
        case .defer_(let reason):
            // Deliberately no effect: the owner settles it on the next pass.
            NSEConfig.log("limit shield deferred cmd=\(commandID) reason=\(reason)")
        case .shield(let rule, let used):
            let applied = await ActiveLockStore.shared.applyLimitConvergence(decision, now: Date())
            NSEConfig.log(
                "limit shield cmd=\(commandID) used=\(used)/\(rule.budgetMinutes) applied=\(applied)"
            )
        case .release(_, let recordKey):
            let applied = await ActiveLockStore.shared.applyLimitConvergence(decision, now: Date())
            NSEConfig.log("limit release cmd=\(commandID) key=\(recordKey) applied=\(applied)")
        }
        return decision
    }

    private func persistEarnedPolicy(
        _ command: LockCommand,
        baseURL: URL,
        deviceID: UUID,
        commandID: UUID
    ) async {
        do {
            let disposition = try MeteringPolicyIngress.persist(
                command: command,
                fetchedDeviceID: deviceID
            )
            let recoveryRequired: Bool
            let status: String
            var detail: [String: Any] = ["owner": "device_epoch_store"]
            switch disposition {
            case .acceptedNeedsOwner, .duplicatePending:
                recoveryRequired = true
                status = "persisted_waiting_for_owner"
                detail["application_state"] = "pending"
                detail["reason"] = "persisted_waiting_for_owner"
            case .duplicateApplied:
                recoveryRequired = false
                let desired = try DeviceEpochStore.shared.read().desiredPolicy
                if desired?.ackedAt != nil {
                    status = "confirmed"
                    detail["application_state"] = "applied"
                    detail["source"] = "device_epoch_owner_readback"
                } else {
                    status = "persisted_waiting_for_owner"
                    detail["application_state"] = "applied_waiting_for_readback"
                    detail["reason"] = "persisted_waiting_for_owner"
                }
            case let .superseded(latestOrderingToken):
                recoveryRequired = false
                status = "confirmed"
                detail["application_state"] = "superseded"
                detail["reason"] = "superseded"
                detail["latest_ordering_token"] = latestOrderingToken
            case .equalTokenConflict:
                recoveryRequired = false
                status = "failed"
                detail["reason"] = "ordering_token_conflict"
            }
            if let token = command.earnedTimeConfig?.orderingToken {
                detail["ordering_token"] = token
            }
            try await NSENetwork.ack(
                baseURL: baseURL,
                deviceID: deviceID,
                commandID: commandID,
                status: status,
                detail: detail
            )
            NSEConfig.log("earned policy persisted cmd=\(commandID) status=\(status)")
            guard recoveryRequired else { return }
            // The recovery leg gets its own failure domain: the policy above
            // is already persisted AND acked, so a recovery error must never
            // read as "earned policy rejected". It is also deadline-bounded —
            // the NSE has ~30 s total, and an unbounded recovery left the
            // outcome to wherever iOS happened to suspend us.
            do {
                let outcome = try await Self.withDeadline(seconds: 18) {
                    try await MeteringProductionComposition.recoverFromSharedConfiguration(
                        role: .pushApplier
                    )
                }
                NSEConfig.log("recovery outcome=\(outcome) cmd=\(commandID)")
                // The early ack said "waiting for owner" as a fail-safe. If
                // the recovery actually applied the policy (the owner's ack
                // mark is set), upgrade the receipt so the backend does not
                // keep showing a command the device already honored.
                if let desired = try? DeviceEpochStore.shared.read().desiredPolicy,
                   desired.ackedAt != nil {
                    var upgraded: [String: Any] = [
                        "owner": "device_epoch_store",
                        "application_state": "applied",
                        "source": "push_applier_recovery_readback",
                    ]
                    if let token = command.earnedTimeConfig?.orderingToken {
                        upgraded["ordering_token"] = token
                    }
                    try await NSENetwork.ack(
                        baseURL: baseURL,
                        deviceID: deviceID,
                        commandID: commandID,
                        status: "confirmed",
                        detail: upgraded
                    )
                    NSEConfig.log("recovery ack upgraded cmd=\(commandID)")
                }
            } catch {
                NSEConfig.log(
                    "recovery failed (policy already persisted+acked) cmd=\(commandID) error=\(error)"
                )
            }
        } catch {
            NSEConfig.log("earned policy rejected cmd=\(commandID) error=\(error)")
        }
    }

    private func rearmMetering(
        baseURL: URL,
        deviceID: UUID,
        commandID: UUID
    ) async {
        do {
            let report = try await Self.withDeadline(seconds: 24) {
                _ = try await MeteringProductionComposition.recoverFromSharedConfiguration(
                    role: .pushApplier
                )
                return await MeteringTodayRouteRekick.runReport(
                    trigger: "rejected_burst_command",
                    role: .pushApplier
                )
            }
            try await NSENetwork.ack(
                baseURL: baseURL,
                deviceID: deviceID,
                commandID: commandID,
                status: report.isHealthy ? "confirmed" : "failed",
                detail: [
                    "verb": "metering_rearm",
                    "application_state": report.isHealthy ? "active" : "rearm_failed",
                    "verdict": report.verdict,
                    "message": report.message,
                    "source": "push_applier_daemon_readback",
                ]
            )
            NSEConfig.log(
                "metering rearm cmd=\(commandID) verdict=\(report.verdict)"
            )
        } catch {
            try? await NSENetwork.ack(
                baseURL: baseURL,
                deviceID: deviceID,
                commandID: commandID,
                status: "failed",
                detail: [
                    "verb": "metering_rearm",
                    "application_state": "rearm_failed",
                    "reason": "deadline_or_recovery_error",
                    "source": "push_applier",
                ]
            )
            NSEConfig.log("metering rearm failed cmd=\(commandID) error=\(error)")
        }
    }

    /// Bounded await: races `work` against a deadline and cancels the loser.
    /// The recovery's durable work queue makes mid-flight cancellation safe —
    /// unfinished legs are re-driven by the app's next pass.
    private static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Lock application (mirror of ActionExecutor, inline-token-only)

/// Applies an inline-token lock to the shared `ActiveLockStore`. A faithful but
/// minimal mirror of the relevant `ActionExecutor` branches, restricted to the
/// inline-token case. Returns `nil` when it cannot apply — the caller then
/// leaves the command pending + unacked for the full app poller.
enum NSELockApplier {
    struct Outcome { let verb: String; let displayName: String }

    private static let minScheduleMinutes = 15

    static func apply(
        _ cmd: LockCommand,
        fetchedDeviceID: UUID? = nil
    ) async -> Outcome? {
        let earnedTimeStore = EarnedTimeStore.shared
        switch await NSELockMutationDispatcher.apply(
            cmd,
            recordKey: unshieldRecordKey(from: cmd),
            earnedTimeStore: earnedTimeStore,
            fetchedDeviceID: fetchedDeviceID,
            currentDeviceID: NSEConfig.deviceID,
            currentUsageDate: earnedTimeStore.currentCanonicalPolicyUsageDate()
        ) {
        case .rejected:
            return nil
        case .unshield:
            return Outcome(
                verb: "unshield",
                displayName: cmd.target.targetDisplay ?? "App"
            )
        case .unshieldAll:
            // Lifting the all-apps shield is how a reflection ends, and the
            // ONLY writer of the local counting gate used to be the kid app's
            // foreground poller. On a force-quit device that poller never runs,
            // so the gate stayed at the value it had while the reflection was
            // open — "paused" — and the metering recovery this extension runs
            // right after would dutifully keep the pool frozen. Reopening it
            // here makes the resume genuinely force-quit-proof, which is what
            // this command path already claims to be (2026-08-07).
            earnedTimeStore.usageCountingAllowed = true
            return Outcome(
                verb: "unshield_all",
                displayName: cmd.target.targetDisplay ?? "All apps"
            )
        case .notHandled:
            break
        }

        switch cmd.action {
        case .shield:
            guard let record = buildShieldRecord(from: cmd) else { return nil }
            _ = await ActiveLockStore.shared.addShield(record, force: cmd.target.forceDowngrade)
            // Every addShield result leaves the target shielded — newly, extended,
            // or by a pre-existing stronger lock — so "confirmed" is correct.
            return Outcome(verb: "shield", displayName: record.displayName)
        case .block:
            guard let record = buildBlockRecord(from: cmd) else { return nil }
            _ = await ActiveLockStore.shared.addBlock(record)
            return Outcome(verb: "block", displayName: record.displayName)
        case .unshieldAll:
            return nil
        case .unblockAll:
            _ = await ActiveLockStore.shared.unblockAll()
            return Outcome(verb: "unblock_all", displayName: cmd.target.targetDisplay ?? "All apps")
        case .unshield:
            return nil
        case .unblock:
            guard let bundleID = cmd.target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleID.isEmpty else { return nil }
            _ = await ActiveLockStore.shared.removeBlock(bundleID: bundleID)
            return Outcome(verb: "unblock", displayName: cmd.target.targetDisplay ?? bundleID)
        case .expandLibrary:
            // Not a lock-state change — leave for the app.
            return nil
        case .setLimit, .clearLimit:
            // Intercepted by NotificationService.persistAppLimit before this
            // lock-only dispatcher. NSE never owns limit enforcement effects.
            return nil
        case .earnedTimeConfig:
            // A4: same-day pool/cap sync — handled inline in CommandPoller on the
            // main app side. The NSE has no DeviceActivity scheduling capability,
            // so leave this command pending for the full app poller.
            return nil
        case .meteringRearm:
            return nil
        }
    }

    /// recordKey of the shield an `unshield` command targets — mirrors the key
    /// `buildShieldRecord` would have produced for the same tier/target.
    private static func unshieldRecordKey(from cmd: LockCommand) -> String {
        let tier = cmd.tier ?? .category
        let targetKey: String
        switch tier {
        case .exactApp: targetKey = exactAppTargetKey(cmd.target)
        case .savedList: targetKey = cmd.target.listID?.uuidString ?? "?"
        case .category: targetKey = (categoryLookupName(cmd.target) ?? "?").lowercased()
        case .all, .allApps: targetKey = "all"
        }
        return ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey)
    }

    // MARK: Record construction

    private static func buildShieldRecord(from cmd: LockCommand) -> ShieldRecord? {
        let tier = cmd.tier ?? .category
        var appTokens: Set<ApplicationToken> = []
        var categoryTokens: Set<ActivityCategoryToken> = []
        var webDomainTokens: Set<WebDomainToken> = []
        var appliesToAll = false
        let targetKey: String
        var displayName = cmd.target.targetDisplay ?? "Unknown"

        switch tier {
        case .exactApp:
            guard let token = decodeApplicationToken(cmd.target.catalogTokenDataBase64) else { return nil }
            appTokens = [token]
            targetKey = exactAppTargetKey(cmd.target)
            displayName = cmd.target.targetDisplay ?? cmd.target.bundleID ?? cmd.target.categoryHint ?? "App"
        case .savedList:
            guard let id = cmd.target.listID else { return nil }
            targetKey = id.uuidString
            appTokens = Set(cmd.target.catalogApplicationTokenDataBase64s.compactMap(decodeApplicationToken))
            categoryTokens = Set(cmd.target.catalogCategoryTokenDataBase64s.compactMap(decodeCategoryToken))
            // Device-local union (paper-lock fix, NSE parity with ActionExecutor's
            // buildShieldRecord): DefaultLockGroupStore is the same App-Group-shared
            // ground truth for "what did the kid actually pick" that the main app's
            // executor and the DeviceActivityMonitor extension both now consult.
            // Union it in here too so NSE-delivered savedList locks (the
            // force-quit-resilient fast path) also cover unmatched apps/categories —
            // BUT only when this command targets the device's one default "Locked
            // set". `.savedList` is also used for arbitrary parent-named custom
            // lists that share nothing with the default group, so unioning
            // unconditionally would over-lock those. EarnedTimeStore.swift is
            // compiled into this target too (see project.pbxproj membership
            // exceptions for EvlinPushApplier), so it can be read directly here,
            // same App-Group suite `group.com.evlin.ios` as DefaultLockGroupStore.
            // Compare lowercased, matching the `savedList:<targetKey.lowercased()>`
            // recordKey normalization (ShieldRecord.makeRecordKey).
            // The command itself can assert default-group identity (backend
            // `default_lock_group` flag): a fresh family's very first lock
            // arrives before any earned_time_config ever carried the list id
            // (the list is empty at provision time), so lockedSetID would be
            // nil here and the union below would silently paper-lock. Adopt
            // the id from the flagged command before evaluating the gate.
            if cmd.target.defaultLockGroup == true,
               EarnedTimeStore.shared.lockedSetID?.lowercased() != targetKey.lowercased() {
                EarnedTimeStore.shared.saveLockedSetID(targetKey, tokenData: nil)
            }
            let isDefaultLockGroup = EarnedTimeStore.shared.lockedSetID
                .map { $0.lowercased() == targetKey.lowercased() } ?? false
            if isDefaultLockGroup {
                let localSelection = DefaultLockGroupStore.load()
                appTokens.formUnion(localSelection.applicationTokens)
                categoryTokens.formUnion(localSelection.categoryTokens)
                webDomainTokens.formUnion(localSelection.webDomainTokens)
            }
            // No tokens from ANY source → app handles it via blob / LocalAliasStore
            // fallback paths this target intentionally does not link.
            guard !appTokens.isEmpty || !categoryTokens.isEmpty || !webDomainTokens.isEmpty else { return nil }
            if cmd.target.allSelected == true {
                appliesToAll = true
            }
            displayName = cmd.target.listName ?? "saved list"
        case .category:
            guard let token = decodeCategoryToken(cmd.target.catalogCategoryTokenDataBase64),
                  let hint = categoryLookupName(cmd.target) else { return nil }
            categoryTokens = [token]
            targetKey = hint.lowercased()
            displayName = cmd.target.targetDisplay ?? hint.capitalized
        case .all, .allApps:
            targetKey = "all"
            appliesToAll = true
            displayName = "All Apps"
        }

        var expiresAt = cmd.expiresAt
        if let exp = expiresAt, exp.timeIntervalSinceNow < TimeInterval(minScheduleMinutes * 60) {
            expiresAt = Date().addingTimeInterval(TimeInterval(minScheduleMinutes * 60))
        }
        return NSEShieldRecordFactory.make(
            command: cmd,
            tier: tier,
            targetKey: targetKey,
            displayName: displayName,
            appTokens: appTokens,
            categoryTokens: categoryTokens,
            webDomainTokens: webDomainTokens,
            appliesToAll: appliesToAll,
            expiresAt: expiresAt,
        )
    }

    private static func buildBlockRecord(from cmd: LockCommand) -> BlockRecord? {
        guard let bundleID = cmd.target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else { return nil }
        var expiresAt = cmd.expiresAt
        if let exp = expiresAt, exp.timeIntervalSinceNow < TimeInterval(minScheduleMinutes * 60) {
            expiresAt = Date().addingTimeInterval(TimeInterval(minScheduleMinutes * 60))
        }
        return BlockRecord(
            bundleID: bundleID,
            displayName: cmd.target.targetDisplay ?? bundleID,
            blockedAt: cmd.issuedAt,
            lastCommandID: cmd.id,
            originalRequest: cmd.target.originalRequest,
            targetChildID: cmd.target.targetChildID ?? UUID(),
            expiresAt: expiresAt
        )
    }

    // MARK: Token decode (mirror of CatalogCommandTokenData)

    private static func decodeApplicationToken(_ base64: String?) -> ApplicationToken? {
        decodeToken(ApplicationToken.self, base64)
    }
    private static func decodeCategoryToken(_ base64: String?) -> ActivityCategoryToken? {
        decodeToken(ActivityCategoryToken.self, base64)
    }
    private static func decodeToken<T: Decodable>(_ type: T.Type, _ base64: String?) -> T? {
        guard let trimmed = base64?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let data = Data(base64Encoded: trimmed) else { return nil }
        let json = JSONDecoder()
        json.dateDecodingStrategy = .iso8601
        if let token = try? json.decode(type, from: data) { return token }
        return try? PropertyListDecoder().decode(type, from: data)
    }

    // MARK: targetKey helpers (mirror of ActionExecutor)

    private static func exactAppTargetKey(_ target: CommandTarget) -> String {
        if let raw = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw.lowercased()
        }
        for raw in [target.targetDisplay, target.categoryHint, target.originalRequest] {
            if let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                return clean.lowercased()
            }
        }
        return "app"
    }

    private static func categoryLookupName(_ target: CommandTarget) -> String? {
        for raw in [target.categoryHint, target.targetDisplay, target.originalRequest] {
            if let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                return clean
            }
        }
        return nil
    }
}

// MARK: - Off-process networking (mirrors BigKidExtensionReporter idiom)

private enum NSENetwork {
    enum NetworkError: Error { case invalidURL, rejected }

    /// Build a `/child/...` URL from the App-Group base URL, slash-safe.
    private static func childEndpoint(_ baseURL: URL, _ path: String) -> URL? {
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)
    }

    /// GET /child/commands/{id}?device_id= — decoded with the same wire contract
    /// the app's APIClient uses, then mapped to the shared `LockCommand`.
    static func fetchCommand(baseURL: URL, deviceID: UUID, commandID: UUID) async -> LockCommand? {
        guard let endpoint = childEndpoint(baseURL, "/child/commands/\(commandID.uuidString)"),
              var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [URLQueryItem(name: "device_id", value: deviceID.uuidString)]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? NSECommandWireDecoder.decode(data)
    }

    /// POST /child/ack — v2 generic "confirmed" with verb/display_name so the
    /// parent receipt renders and the ack-driven escalation stops.
    static func ack(baseURL: URL, deviceID: UUID, commandID: UUID, outcome: NSELockApplier.Outcome) async {
        try? await ack(
            baseURL: baseURL,
            deviceID: deviceID,
            commandID: commandID,
            status: "confirmed",
            detail: [
                "verb": outcome.verb,
                "display_name": outcome.displayName,
                "source": "nse",
            ]
        )
    }

    static func ack(
        baseURL: URL,
        deviceID: UUID,
        commandID: UUID,
        status: String,
        detail: [String: Any]
    ) async throws {
        guard let url = childEndpoint(baseURL, "/child/ack") else {
            throw NetworkError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "command_id": commandID.uuidString,
            "device_id": deviceID.uuidString,
            "status": status,
            "detail": detail,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw NetworkError.rejected }
    }
}

// MARK: - App Group config bridge

/// The kid app's `BigKidRootView` mirrors `evlin.baseURL` + `evlin.childId` into
/// the shared App Group (the same keys the DeviceActivityMonitor extension
/// reads). The NSE reads them here. Diagnostics reuse the spike's NSE log keys
/// so the existing CommandDelivery diagnostics view surfaces NSE activity.
private enum NSEConfig {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: "group.com.evlin.ios") }

    static var baseURL: URL? {
        guard let s = defaults?.string(forKey: "evlin.baseURL") else { return nil }
        return URL(string: s)
    }
    static var deviceID: UUID? {
        guard let s = defaults?.string(forKey: "evlin.childId") else { return nil }
        return UUID(uuidString: s)
    }

    static func log(_ message: String) {
        guard let d = defaults else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        var log = d.stringArray(forKey: "evlin.spike.nseLog") ?? []
        log.append("\(ts) \(message)")
        if log.count > 30 { log.removeFirst(log.count - 30) }
        d.set(log, forKey: "evlin.spike.nseLog")
        d.set(d.integer(forKey: "evlin.spike.nseCount") + 1, forKey: "evlin.spike.nseCount")
    }
}
