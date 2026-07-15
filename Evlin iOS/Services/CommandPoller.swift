import Foundation
import FamilyControls
import ManagedSettings
import UIKit
import Sentry

enum CommandDeliveryDiagnostics {
    static let keyTokenRegistered = "evlin.delivery.apnsTokenRegistered"
    static let keyTokenUpload = "evlin.delivery.apnsTokenUpload"
    static let keyRemoteNotification = "evlin.delivery.remoteNotification"
    static let keyOneShotPoll = "evlin.delivery.oneShotPoll"
    static let keyCommandPoll = "evlin.delivery.commandPoll"
    static let keyCommandAck = "evlin.delivery.commandAck"
    static let keyDAMHeartbeat = "evlin.delivery.damHeartbeat"
    static let keyEarnedLastThreshold = "evlin.earned.lastThreshold"
    static let keyEarnedArmAttempt = "evlin.earned.armAttempt"
    static let keyEarnedIdentityTransition = "evlin.earned.identityTransition"
    static let keyUsageCountingLastSkipped = "evlin.usageCounting.lastSkipped"
    /// SPIKE-ONLY (DAM heartbeat experiment). Capped history of heartbeat
    /// `intervalDidStart` fires written by the extension, so the diagnostics
    /// view can show the cadence + self-rearm result SEQUENCE, not just the
    /// last fire. MUST match the literals the extension writes in
    /// `DeviceActivityMonitorExtension.intervalDidStart` (the extension can't
    /// import this enum — it has UIKit/Sentry deps — so the strings are paired
    /// by convention).
    static let keyHeartbeatLog = "evlin.spike.heartbeatLog"
    static let keyHeartbeatCount = "evlin.spike.heartbeatCount"
    /// SPIKE-ONLY (NSE force-quit experiment). Capped history of pushes the
    /// EvlinPushApplier Notification Service Extension processed, with whether
    /// it could apply a ManagedSettings shield off-process. MUST match the
    /// literals the NSE writes in `NotificationService.didReceive`.
    static let keyNSELog = "evlin.spike.nseLog"
    static let keyNSECount = "evlin.spike.nseCount"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "group.com.evlin.ios") ?? .standard
    }

    static func record(_ key: String, _ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        defaults.set("\(ts) \(message)", forKey: key)
    }

    static func read(_ key: String) -> String {
        defaults.string(forKey: key) ?? "(none)"
    }

    /// SPIKE-ONLY. Read the capped heartbeat-fire history (oldest → newest).
    static func readLog(_ key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// SPIKE-ONLY. Read a running integer counter (e.g. total heartbeat fires).
    static func readInt(_ key: String) -> Int {
        defaults.integer(forKey: key)
    }

    static func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }

    /// SPIKE-ONLY. Wipe the heartbeat history + counter between experiments.
    static func clearHeartbeatLog() {
        defaults.removeObject(forKey: keyHeartbeatLog)
        defaults.removeObject(forKey: keyHeartbeatCount)
    }

    static func tokenSummary(_ token: String) -> String {
        let suffix = String(token.suffix(8))
        return "len=\(token.count) suffix=\(suffix)"
    }
}

/// Foreground command poller. Every 5s, fetches pending commands from the backend
/// and dispatches them to ActionExecutor. Posts ack back on completion.
///
/// MVP delivery tier: foreground-only. APNs silent-push integration is Phase 5.
/// BGAppRefreshTask catchup is Phase 5.
@MainActor
final class CommandPoller {
    static let shared = CommandPoller()

    private var timer: Timer?
    private var backgroundPollTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isPolling = false
    private var currentDeviceID: UUID?
    private var currentAPIClient: APIClient?
    private var pendingPollAfterCurrent = false

    /// UserDefaults key the whole app uses for the paired child device id.
    /// Same store `@AppStorage("evlin.childDeviceID")` writes to (see
    /// `Evlin_iOSApp.startPollerIfPaired` and `APIClient.sendChatMessage`).
    static let childDeviceIDDefaultsKey = "evlin.childDeviceID"

    // MARK: - Injectable seams (test-only hooks; production uses the defaults)

    /// Resolves the current child device id. Production reads
    /// `evlin.childDeviceID` from `UserDefaults.standard`; tests can swap this
    /// to drive `pollOnceForCurrentDevice()` hermetically (no shared defaults).
    var childDeviceIDProvider: () -> UUID? = {
        UserDefaults.standard.string(forKey: CommandPoller.childDeviceIDDefaultsKey)
            .flatMap(UUID.init(uuidString:))
    }

    /// Supplies the API client used by `pollOnceForCurrentDevice()` when the
    /// poller hasn't been started with one (the common silent-push case: the
    /// app may be woken in the background before the foreground poller ran).
    /// Production builds a default `APIClient()`.
    var oneShotAPIClientFactory: () -> APIClient = { APIClient() }

    /// Test seam: when set, `pollOnceForCurrentDevice()` invokes this with the
    /// resolved (deviceID, apiClient) INSTEAD of the real `pollOnce()` network
    /// path, so a unit test can assert the wiring without hitting the network.
    /// Nil in production → the real `pollOnce()` runs.
    var oneShotPollOverride: ((UUID, APIClient) async -> Void)?

    /// Test seam for the real network poll. Nil in production.
    var pollCommandsOverride: ((UUID, APIClient) async throws -> [PollCommandDTO])?

    // MARK: - Earned-time config seams (test-only hooks; production uses the defaults)

    /// A4: Called by the inline `earned_time_config` handler instead of
    /// `EarnedTimeStore.shared.saveLockedSetID` so tests can observe without
    /// touching real App Group UserDefaults. Nil in production.
    var saveLockedSetIDOverride: ((String, Data?) -> Void)?

    /// Test seams around the suspension and ack points in earned config handling.
    var afterRekeyShieldRecord: ((String, String) async -> Void)?
    var ackEarnedTimeConfigOverride: ((UUID, APIClient) async -> Void)?

    /// Test-only capture of the remaining policy an earned config would arm.
    /// Production always routes through `EarnedBudgetArming.armIfReady()`.
    var armBudgetOverride: ((Int, Int, FamilyActivitySelection) -> Void)?

    /// Allows config tests to exercise the arm path with an empty synthetic
    /// selection while production continues to require measurable tokens.
    var hasMeasurableSelectionOverride: (() -> Bool)?

    /// How often to poll while iOS grants background execution after the app
    /// leaves foreground. Tunable in tests.
    var backgroundPollIntervalNanoseconds: UInt64 = 5_000_000_000

    /// Max attempts during one background grace window. iOS can end the task
    /// earlier; this cap only bounds our own loop.
    var backgroundPollMaxAttempts: Int = 6

    /// Start polling for the given child device ID. Safe to call repeatedly.
    func start(deviceID: UUID, apiClient: APIClient) {
        stop()
        currentDeviceID = deviceID
        currentAPIClient = apiClient
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollOnce()
            }
        }
        // Fire once immediately so we don't wait 5s after start
        Task { @MainActor in await pollOnce() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopBackgroundGracePolling()
        currentDeviceID = nil
        currentAPIClient = nil
    }

    /// Pause the foreground timer and poll briefly while iOS allows background
    /// execution.
    ///
    /// This covers the common case where the kid backgrounds Evlin or locks the
    /// screen shortly before a parent sends a command. It is NOT a force-quit
    /// solution; after the user swipes Evlin away, iOS will not give us normal
    /// background execution until another system wake path exists.
    func startBackgroundGracePolling() {
        timer?.invalidate()
        timer = nil
        stopBackgroundGracePolling()

        let taskID = UIApplication.shared.beginBackgroundTask(withName: "EvlinCommandPoll") {
            Task { @MainActor in
                CommandPoller.shared.stopBackgroundGracePolling()
            }
        }
        backgroundTaskID = taskID

        backgroundPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<max(1, self.backgroundPollMaxAttempts) {
                if Task.isCancelled { break }
                await self.pollOnceForCurrentDevice()
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: self.backgroundPollIntervalNanoseconds)
            }
            self.stopBackgroundGracePolling()
        }
    }

    private func stopBackgroundGracePolling() {
        backgroundPollTask?.cancel()
        backgroundPollTask = nil
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    /// Fetch all pending commands and dispatch. Safe to call manually (e.g. on push wake).
    func pollOnce() async {
        guard currentDeviceID != nil, currentAPIClient != nil else { return }
        if isPolling {
            pendingPollAfterCurrent = true
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyCommandPoll,
                "coalesced pending_poll"
            )
            return
        }
        isPolling = true
        defer {
            isPolling = false
            pendingPollAfterCurrent = false
        }

        repeat {
            pendingPollAfterCurrent = false
            guard let deviceID = currentDeviceID, let api = currentAPIClient else { return }
            do {
                // DeviceActivityMonitor is the primary expiry path, but Screen Time
                // callbacks can be delayed or missed. Polling is our foreground
                // fallback so timed shields/blocks don't stay applied forever.
                _ = await ActiveLockStore.shared.sweepExpired()
                guard isExpectedDeviceCurrent(deviceID) else {
                    coalescePollForCurrentIdentity(expectedDeviceID: deviceID)
                    continue
                }
                let cmds: [PollCommandDTO]
                if let override = pollCommandsOverride {
                    cmds = try await override(deviceID, api)
                } else {
                    cmds = try await api.pollCommands(deviceID: deviceID)
                }
                guard isExpectedDeviceCurrent(deviceID) else {
                    coalescePollForCurrentIdentity(expectedDeviceID: deviceID)
                    continue
                }
                CommandDeliveryDiagnostics.record(
                    CommandDeliveryDiagnostics.keyCommandPoll,
                    "ok device=\(deviceID.uuidString) commands=\(cmds.count)"
                )
                for poll in cmds {
                    guard isExpectedDeviceCurrent(deviceID) else {
                        coalescePollForCurrentIdentity(expectedDeviceID: deviceID)
                        break
                    }
                    await execute(poll: poll, expectedDeviceID: deviceID, api: api)
                }
            } catch {
                guard isExpectedDeviceCurrent(deviceID) else {
                    coalescePollForCurrentIdentity(expectedDeviceID: deviceID)
                    continue
                }
                // Plan 8 (§15.3): a terminal `410 family_removed` from the kid
                // command read-path means this device's family was deleted. FAIL
                // OPEN — release every Evlin shield/block, clear the reflection
                // sticky + reset pairing — then stop the poller so a deleted family
                // can never brick the kid by leaving stale locks applied.
                if FamilyGoneDetector.isFamilyGone(error: error) {
                    CommandDeliveryDiagnostics.record(
                        CommandDeliveryDiagnostics.keyCommandPoll,
                        "family_removed device=\(deviceID.uuidString)"
                    )
                    print("[CommandPoller] family_removed → failing open")
                    await FamilyGoneDetector.failOpen()
                    stop()
                    return
                }
                CommandDeliveryDiagnostics.record(
                    CommandDeliveryDiagnostics.keyCommandPoll,
                    "failed device=\(deviceID.uuidString) error=\(error.localizedDescription)"
                )
                print("[CommandPoller] poll error: \(error)")
                SentrySDK.capture(error: error)
            }
        } while pendingPollAfterCurrent
    }

    private func isExpectedDeviceCurrent(_ expectedDeviceID: UUID) -> Bool {
        currentDeviceID == expectedDeviceID && childDeviceIDProvider() == expectedDeviceID
    }

    private func coalescePollForCurrentIdentity(expectedDeviceID: UUID) {
        guard let current = childDeviceIDProvider(), current != expectedDeviceID else { return }
        currentDeviceID = current
        pendingPollAfterCurrent = true
        CommandDeliveryDiagnostics.record(
            CommandDeliveryDiagnostics.keyCommandPoll,
            "discarded stale_device=\(expectedDeviceID.uuidString) current=\(current.uuidString)"
        )
    }

    /// One-shot poll for the current child device WITHOUT starting the timer.
    ///
    /// This is the silent-push entry point (Phase 5 L2 delivery): when the
    /// backend sends a `content-available:1` push, the app delegate's
    /// background remote-notification handler calls this to fetch + apply any
    /// queued commands while the app is not foregrounded. Unlike `start()`,
    /// it does not schedule a repeating `Timer` — it fires exactly once and
    /// returns, which is what `application(_:didReceiveRemoteNotification:…)`
    /// needs before calling its completion handler.
    ///
    /// Device id comes from `evlin.childDeviceID` (the same source the
    /// foreground poller uses). If no child is paired, this is a safe no-op.
    /// It reuses the existing `pollOnce()` fetch+apply+ack path; if the
    /// foreground poller is already running with a client, that client is
    /// reused, otherwise a default `APIClient` is constructed.
    func pollOnceForCurrentDevice() async {
        guard let deviceID = childDeviceIDProvider() else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyOneShotPoll,
                "skipped no_child_device_id"
            )
            return
        }
        let api = currentAPIClient ?? oneShotAPIClientFactory()
        CommandDeliveryDiagnostics.record(
            CommandDeliveryDiagnostics.keyOneShotPoll,
            "started device=\(deviceID.uuidString)"
        )

        if let override = oneShotPollOverride {
            await override(deviceID, api)
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyOneShotPoll,
                "override_completed device=\(deviceID.uuidString)"
            )
            return
        }

        // Point the shared poll state at this device/client and run the
        // existing one-shot path. We do NOT touch the timer here.
        currentDeviceID = deviceID
        currentAPIClient = api
        await pollOnce()
        CommandDeliveryDiagnostics.record(
            CommandDeliveryDiagnostics.keyOneShotPoll,
            "completed device=\(deviceID.uuidString)"
        )
    }

    /// Tolerant ISO8601 parser for command timestamps. The backend serializes
    /// command timestamps via Python `datetime.now(timezone.utc).isoformat()` and
    /// Postgres `func.now()`, which emit microseconds (e.g.
    /// `2026-06-19T21:00:00.123456+00:00`). A bare `ISO8601DateFormatter` is
    /// strict and rejects fractional seconds → every real payload would parse to
    /// nil. Try the fractional-seconds variant first, fall back to plain. Matches
    /// the pattern used in `U1ExpiryParser`, `NotificationFeedClient`, etc.
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlainFormatter = ISO8601DateFormatter()
    private static func parseISO8601(_ s: String) -> Date? {
        isoFractionalFormatter.date(from: s) ?? isoPlainFormatter.date(from: s)
    }

    static func lockCommand(from poll: PollCommandDTO) -> LockCommand {
        // tier maps to new ShieldTier set; backend emits "exactApp"|"savedList"|"category"|"all"
        let tier = poll.tier.flatMap(ShieldTier.init(rawValue:))
        let trimmedHint = poll.target.category_hint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryHint = (trimmedHint?.isEmpty == false) ? trimmedHint : nil
        // B2: top-level lock_source takes precedence over target.lock_source (spec §5.4).
        let resolvedLockSource = poll.lock_source ?? poll.target.lock_source
        let resolvedUnlockSources = poll.unlock_sources ?? poll.target.unlock_sources
        let target = CommandTarget(
            bundleID: poll.target.bundle_id,
            listName: poll.target.list_name,
            listID: poll.target.list_id.flatMap(UUID.init(uuidString:)),
            categoryHint: categoryHint,
            targetAll: poll.target.target_all ?? false,
            allSelected: poll.target.all_selected,
            defaultLockGroup: poll.target.default_lock_group,
            originalRequest: poll.target.original_request,
            targetDisplay: poll.target.target_display,
            targetChildID: poll.target.target_child_id.flatMap(UUID.init(uuidString:)),
            hasPendingBlob: poll.target.has_pending_blob ?? false,
            forceDowngrade: poll.target.force_downgrade ?? false,
            catalogTokenDataBase64: poll.target.catalog_token_data_base64,
            catalogCategoryTokenDataBase64: poll.target.catalog_category_token_data_base64,
            catalogApplicationTokenDataBase64s: poll.target.applications ?? [],
            catalogCategoryTokenDataBase64s: poll.target.applicationCategories ?? [],
            lockSource: resolvedLockSource,
            unlockSources: resolvedUnlockSources,
            earnedOverrideUsageDate: poll.target.earned_override_usage_date
        )
        let action: CommandAction = CommandAction(rawValue: poll.action) ?? .shield

        let issued = parseISO8601(poll.issued_at) ?? Date()
        return LockCommand(
            id: poll.command_id,
            action: action,
            tier: tier,
            target: target,
            durationMinutes: poll.duration_minutes,
            issuedAt: issued,
            limit: limitRule(from: poll.limit),
            clear: clearLimit(from: poll.clear)
        )
    }

    /// Instant counter re-arm after a task_pause unshield (2026-07-03). True
    /// only for a SUCCESSFUL unshield (`.confirmedExact`/`.confirmedFallback`
    /// with `verb == .unshield`) whose resolved `unlock_sources` include
    /// `"task_pause"` — i.e. exactly the command `task_lock_service.
    /// reconcile_task_lock` queues when the last task completes. Any other
    /// verb/source (manual unlock, limit clear, etc.) is left on the normal
    /// poll cadence; this seam only targets the task-completion gap.
    @MainActor
    static func notifyStateInvalidatedIfTaskPauseUnshield(cmd: LockCommand, result: AckResult) {
        guard cmd.unlockSources?.contains("task_pause") == true else { return }
        let verb: AckVerb
        switch result {
        case .confirmedExact(let v, _, _): verb = v
        case .confirmedFallback(let v, _, _, _, _): verb = v
        case .pendingConfirmation, .failed: return
        }
        guard verb == .unshield else { return }
        NotificationCenter.default.post(name: .bigKidStateInvalidated, object: nil)
    }

    /// Map a decoded `set_limit.limit` DTO into the internal `LimitRule` (P3).
    /// Parses the "HH:mm" schedule window into minutes-since-midnight and the
    /// ISO8601 timestamp strings into `Date`. Returns nil for a missing or
    /// malformed payload so a bad limit maps gracefully rather than crashing.
    private static func limitRule(from dto: PollLimitDTO?) -> LimitRule? {
        guard let dto else { return nil }
        guard
            let startMinute = minutesSinceMidnight(dto.schedule.starts_at),
            let endMinute = minutesSinceMidnight(dto.schedule.ends_at),
            let effectiveFrom = parseISO8601(dto.effective_from),
            let updatedAt = parseISO8601(dto.updated_at)
        else { return nil }
        let expiresAt = dto.expires_at.flatMap { parseISO8601($0) }
        return LimitRule(
            ruleId: dto.rule_id,
            dailyBudgetMinutes: dto.daily_budget_minutes,
            resetPolicy: dto.reset_policy,
            startMinute: startMinute,
            endMinute: endMinute,
            timezone: dto.schedule.timezone,
            effectiveFrom: effectiveFrom,
            expiresAt: expiresAt,
            updatedAt: updatedAt,
            usedTodayMinutes: dto.used_today_minutes
        )
    }

    /// Map a decoded `clear_limit.clear` DTO into the internal `ClearLimit` (P3).
    private static func clearLimit(from dto: PollClearDTO?) -> ClearLimit? {
        guard let dto else { return nil }
        guard let updatedAt = parseISO8601(dto.updated_at) else { return nil }
        return ClearLimit(ruleId: dto.rule_id, reason: dto.reason, updatedAt: updatedAt)
    }

    /// Parse a "HH:mm" 24h clock string into minutes-since-midnight (0...1439).
    /// Returns nil for malformed input.
    private static func minutesSinceMidnight(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...23).contains(hours), (0...59).contains(minutes)
        else { return nil }
        return hours * 60 + minutes
    }

    private func execute(poll: PollCommandDTO, expectedDeviceID: UUID, api: APIClient) async {
        guard isExpectedDeviceCurrent(expectedDeviceID) else {
            coalescePollForCurrentIdentity(expectedDeviceID: expectedDeviceID)
            return
        }
        // A4: Intercept earned_time_config BEFORE lockCommand() so the command
        // never reaches ActionExecutor. Handle inline and ack confirmed.
        if poll.action == CommandAction.earnedTimeConfig.rawValue {
            await handleEarnedTimeConfig(
                poll: poll,
                expectedDeviceID: expectedDeviceID,
                api: api
            )
            return
        }

        let cmd = Self.lockCommand(from: poll)

        var blob: Data? = nil
        if cmd.target.hasPendingBlob {
            blob = try? await api.fetchPendingBlob(commandID: cmd.id)
            guard isExpectedDeviceCurrent(expectedDeviceID) else {
                coalescePollForCurrentIdentity(expectedDeviceID: expectedDeviceID)
                return
            }
        }

        let result = await ActionExecutor.shared.execute(
            cmd,
            blob: blob,
            expectedChildID: expectedDeviceID,
            identityIsCurrent: { [weak self] deviceID in
                self?.isExpectedDeviceCurrent(deviceID) == true
            }
        )
        guard isExpectedDeviceCurrent(expectedDeviceID) else {
            coalescePollForCurrentIdentity(expectedDeviceID: expectedDeviceID)
            return
        }

        // Close the resume "free window" (2026-07-03): a task_pause unshield
        // reaches this device and gets applied via ActionExecutor within
        // seconds, but the usage counters (EarnedBudgetScheduler /
        // AppLimitPlanner) only re-arm on the next BigKidStatePoller poll —
        // up to 10s later. That's a gap where the kid is unlocked but
        // meters aren't running. Trigger the SAME notification ChatViewModel
        // posts after a parent write (`.bigKidStateInvalidated`) so any
        // active BigKidStatePoller runs `refreshNow()` immediately: it
        // re-fetches `/child/state`, and the authoritative
        // `usageCountingAllowed` on that snapshot drives both the flag flip
        // and the re-arm through the poller's existing logic — no need to
        // duplicate rearm/cap semantics here.
        Self.notifyStateInvalidatedIfTaskPauseUnshield(cmd: cmd, result: result)

        // Map AckResult → ack status + rich detail (verb + effective_state + pending payload).
        // See plan Phase 6 Task 6.4 for the backend schema.
        let (status, detail): (String, [String: Any]?) = {
            switch result {
            case .confirmedExact(let verb, let name, let eff):
                var d: [String: Any] = ["verb": verb.rawValue, "display_name": name]
                if let eff = eff, let data = try? JSONEncoder().encode(eff),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    d["effective_state"] = dict
                }
                // Plumb rule_id for per-app limit verbs (P3). No existing ack
                // path carries rule_id; copy it from the decoded limit/clear.
                if verb == .setLimit || verb == .clearLimit,
                   let ruleID = cmd.limit?.ruleId ?? cmd.clear?.ruleId {
                    d["rule_id"] = ruleID.uuidString
                }
                return ("confirmed", d)
            case .confirmedFallback(let verb, let name, let cat, let orig, let eff):
                var d: [String: Any] = [
                    "verb": verb.rawValue,
                    "display_name": name,
                    "category": cat,
                    "orig_request": orig,
                ]
                if let eff = eff, let data = try? JSONEncoder().encode(eff),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    d["effective_state"] = dict
                }
                return ("confirmed", d)
            case .pendingConfirmation(let cardID, let ctx):
                return ("pending_confirmation", ["card_id": cardID, "context": ctx])
            case .failed(let fail):
                // Structured failure detail so the parent receipt can render a
                // specific ReceiptState (failedPermission, failedListNotFound,
                // failedCategoryNotConfigured, …) instead of dumping Swift's
                // default enum description like `categoryNotConfigured("social")`.
                var d: [String: Any] = [:]
                switch fail {
                case .notAuthorized:
                    d["reason"] = "not_authorized"
                case .listNotFound(let n):
                    d["reason"] = "list_not_found"
                    d["list_name"] = n
                case .categoryNotConfigured(let c):
                    d["reason"] = "category_not_configured"
                    d["category"] = c
                case .applicationNotConfigured(let a):
                    d["reason"] = "application_not_configured"
                    d["app_reference"] = a
                case .nothingToUnlock:
                    d["reason"] = "nothing_to_unlock"
                case .malformed:
                    d["reason"] = "malformed"
                case .execution(let s):
                    d["reason"] = "execution"
                    d["message"] = s
                case .limitQuotaExceeded(let windows, let slotsNeeded, let cap):
                    // Per-app limit could not be scheduled within the OS window
                    // cap (P3 ack wire only). snake_case detail keys match the
                    // sibling branches above; plumb verb + rule_id like success.
                    d["reason"] = "limit_quota_exceeded"
                    d["windows"] = windows
                    d["slots_needed"] = slotsNeeded
                    d["cap"] = cap
                    d["verb"] = (cmd.action == .clearLimit ? AckVerb.clearLimit : AckVerb.setLimit).rawValue
                    if let ruleID = cmd.limit?.ruleId ?? cmd.clear?.ruleId {
                        d["rule_id"] = ruleID.uuidString
                    }
                }
                return ("failed", d)
            }
        }()

        var ackDetail = detail
        if status == "confirmed" {
            var d = ackDetail ?? [:]
            if let global = await Self.globalEffectiveStateDictionary() {
                guard isExpectedDeviceCurrent(expectedDeviceID) else { return }
                d["global_effective_state"] = global
            }
            ackDetail = d
        }

        do {
            guard isExpectedDeviceCurrent(expectedDeviceID) else { return }
            try await api.ack(commandID: cmd.id, status: status, detail: ackDetail)
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyCommandAck,
                "ok command=\(cmd.id.uuidString) status=\(status)"
            )
        } catch {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyCommandAck,
                "failed command=\(cmd.id.uuidString) status=\(status) error=\(error.localizedDescription)"
            )
            print("[CommandPoller] ack failed for \(cmd.id): \(error)")
        }
    }

    /// Enforcement-truth snapshot: reads the PERSISTED App-Group shield/block
    /// records (what the extension actually wrote and iOS enforces) — NOT the
    /// in-memory ActiveLockStore copy, which lags when the extension locks
    /// while this app is suspended (proven divergence, 2026-07-01).
    static func globalEffectiveStateDictionary() async -> [String: Any]? {
        globalEffectiveStateDictionary(
            defaults: UserDefaults(suiteName: CurrentRestrictionsReader.suiteName))
    }

    nonisolated static func globalEffectiveStateDictionary(defaults: UserDefaults?) -> [String: Any]? {
        guard let d = defaults else { return nil }
        let shields = CurrentRestrictionsReader.persistedShields(from: d)
        let blocks = CurrentRestrictionsReader.persistedBlocks(from: d)
        let covers = shields
            .sorted { lhs, rhs in
                if lhs.displayName == rhs.displayName {
                    return lhs.recordKey < rhs.recordKey
                }
                return lhs.displayName < rhs.displayName
            }
            .map {
                AckEffectiveState.ShieldCover(
                    displayName: $0.displayName,
                    expiresAtISO: $0.expiresAt.map { ISO8601DateFormatter().string(from: $0) },
                    tier: $0.tier.rawValue,
                    recordKey: $0.recordKey,
                    targetKey: $0.targetKey,
                    sources: $0.sources.map { $0.rawValue }.sorted()
                )
            }
        let snapshot = AckEffectiveState(
            isBlocked: !blocks.isEmpty,
            shieldsCovering: covers,
            possibleSavedListCoverage: false,
            blocks: blocks
                .sorted { $0.bundleID < $1.bundleID }
                .map { .init(bundleID: $0.bundleID, displayName: $0.displayName) }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - A4: earned_time_config inline handler

    /// Handle a `earned_time_config` command inline, without going through
    /// `ActionExecutor`.
    ///
    /// 1. Persists `selected_set.list_id` via EarnedTimeStore (+ re-keys any
    ///    existing savedList shield record via ActiveLockStore.reKeyShieldRecord).
    /// 2. Persists policy, then asks the sole earned arming entry point to
    ///    install a generation-safe DeviceActivity ladder when ready.
    /// 3. Acks the command as "confirmed" regardless of missing optional fields.
    ///
    /// Guard: if the device has no measurement selection (earned-time capture
    /// never ran), arm() is skipped but the command is still acked confirmed.
    private func handleEarnedTimeConfig(
        poll: PollCommandDTO,
        expectedDeviceID: UUID,
        api: APIClient
    ) async {
        guard isExpectedDeviceCurrent(expectedDeviceID) else {
            coalescePollForCurrentIdentity(expectedDeviceID: expectedDeviceID)
            return
        }
        let cfg = poll.earned_time_config
        let commandID = poll.command_id

        // Step 1: Persist locked-set list_id + re-key any existing shield record.
        if let listID = cfg?.selected_set?.list_id, !listID.isEmpty {
            let existing = EarnedTimeStore.shared.lockedSetID ?? ""
            // Task 3 (paper-lock fix): would also persist
            // EarnedTimeStore.shared.saveLockedSetAllSelected(...) here, but
            // `PollEarnedConfigSelectedSetDTO` (this handler's only response
            // shape for `earned_time_config.selected_set`) does not carry an
            // `all_selected` field on the wire — Task 1 only threaded
            // `all_selected` onto the lock-command `target` payload consumed
            // by ActionExecutor.buildShieldRecord, not onto this same-day
            // pool/cap sync payload. Not guessing a nonexistent wire field;
            // if this payload later gains `all_selected`, wire it the same way.
            // Re-key any shield record stored under an old/provisional id.
            if existing != listID {
                let mutation = await ActiveLockStore.shared.reKeyShieldRecord(
                    fromLocalID: existing,
                    toBackendID: listID
                )
                await afterRekeyShieldRecord?(existing, listID)
                guard isExpectedDeviceCurrent(expectedDeviceID) else {
                    if let mutation {
                        await ActiveLockStore.shared.rollbackRekey(mutation)
                    }
                    coalescePollForCurrentIdentity(expectedDeviceID: expectedDeviceID)
                    return
                }
            }
            guard isExpectedDeviceCurrent(expectedDeviceID) else {
                coalescePollForCurrentIdentity(expectedDeviceID: expectedDeviceID)
                return
            }
            if let override = saveLockedSetIDOverride {
                override(listID, nil)
            } else {
                EarnedTimeStore.shared.saveLockedSetID(listID, tokenData: nil)
            }
        }

        // Step 2: Re-arm the DeviceActivity budget ladder if measurement selection
        // is present (captured during the one-time setup flow).
        let poolMinutes = cfg?.daily_pool_minutes ?? 0
        let capMinutes  = cfg?.device_cap_minutes  ?? 0

        if poolMinutes > 0, capMinutes > 0 {
            EarnedTimeStore.shared.poolMinutes = poolMinutes
            EarnedTimeStore.shared.capMinutes = capMinutes
            let replacementOffset = EarnedBudgetArming.replacementOffset(
                acceptedEstimateMinutes: EarnedTimeStore.shared.acceptedEstimateMinutes,
                runningOffsetMinutes: EarnedTimeStore.shared.earnedUsageOffsetMinutes
            )
            // Wave-2 Task 1 veto-staleness fix: prefer the server-authoritative
            // `remaining_minutes` carried on the wire (pool − used, computed
            // backend-side). Falling back to a device-derived estimate here is
            // what caused the original bug — remaining never refreshed as usage
            // grew within the freshness window, so it could wrongly suppress a
            // legitimate at-budget local self-lock. Only fall back to the old
            // derived formula for backends that omit the new field.
            if let wireRemaining = cfg?.remaining_minutes {
                EarnedTimeStore.shared.backendRemainingAtLastSync = max(0, wireRemaining)
            } else {
                EarnedTimeStore.shared.backendRemainingAtLastSync = max(
                    0,
                    min(poolMinutes, capMinutes) - replacementOffset
                )
            }
            EarnedTimeStore.shared.lastBackendSyncAt = Date()
            guard EarnedTimeStore.shared.usageCountingAllowed else {
                EarnedBudgetArming.stopAndInvalidateSignature()
                return await ackEarnedTimeConfig(
                    commandID: commandID,
                    expectedDeviceID: expectedDeviceID,
                    api: api
                )
            }
            guard isExpectedDeviceCurrent(expectedDeviceID),
                  EarnedTimeStore.shared.isAuthoritativeStateReady(deviceID: expectedDeviceID)
            else {
                CommandDeliveryDiagnostics.record(
                    CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                    "skipped config-authoritative-state-not-ready"
                )
                return await ackEarnedTimeConfig(
                    commandID: commandID,
                    expectedDeviceID: expectedDeviceID,
                    api: api
                )
            }
            if let armOverride = armBudgetOverride {
                let hasMeasurableSelection = hasMeasurableSelectionOverride?()
                    ?? EarnedTimeStore.shared.hasMeasurableSelection
                if hasMeasurableSelection,
                   let selection = EarnedTimeStore.shared.measurementSelection,
                   let remainingPolicy = EarnedBudgetScheduler.remainingPolicy(
                       poolMinutes: poolMinutes,
                       capMinutes: capMinutes,
                       offsetMinutes: replacementOffset
                   ) {
                    CommandDeliveryDiagnostics.record(
                        CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                        "test-policy-capture pool=\(remainingPolicy.poolMinutes) cap=\(remainingPolicy.capMinutes) offset=\(replacementOffset) \(EarnedBudgetScheduler.selectionSummary(selection))"
                    )
                    armOverride(remainingPolicy.poolMinutes, remainingPolicy.capMinutes, selection)
                }
            } else {
                EarnedBudgetArming.armIfReady()
            }
        }

        // Step 3: Ack as confirmed.
        await ackEarnedTimeConfig(
            commandID: commandID,
            expectedDeviceID: expectedDeviceID,
            api: api
        )
    }

    private func ackEarnedTimeConfig(
        commandID: UUID,
        expectedDeviceID: UUID,
        api: APIClient
    ) async {
        guard isExpectedDeviceCurrent(expectedDeviceID) else { return }
        if let ackEarnedTimeConfigOverride {
            await ackEarnedTimeConfigOverride(commandID, api)
            return
        }
        do {
            try await api.ack(commandID: commandID, status: "confirmed", detail: nil)
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyCommandAck,
                "ok command=\(commandID.uuidString) status=confirmed (earned_time_config)"
            )
        } catch {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyCommandAck,
                "failed command=\(commandID.uuidString) status=confirmed " +
                "error=\(error.localizedDescription)"
            )
            print("[CommandPoller] ack failed for earned_time_config \(commandID): \(error)")
        }
    }
}
