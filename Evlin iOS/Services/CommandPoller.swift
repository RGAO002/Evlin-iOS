import Foundation
import FamilyControls
import ManagedSettings
import UIKit
import Sentry

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
        guard !isPolling, let deviceID = currentDeviceID, let api = currentAPIClient else { return }
        isPolling = true
        defer { isPolling = false }

        do {
            // DeviceActivityMonitor is the primary expiry path, but Screen Time
            // callbacks can be delayed or missed. Polling is our foreground
            // fallback so timed shields/blocks don't stay applied forever.
            _ = await ActiveLockStore.shared.sweepExpired()
            let cmds = try await api.pollCommands(deviceID: deviceID)
            for poll in cmds {
                await execute(poll: poll, api: api)
            }
        } catch {
            print("[CommandPoller] poll error: \(error)")
            SentrySDK.capture(error: error)
        }
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
        guard let deviceID = childDeviceIDProvider() else { return }
        let api = currentAPIClient ?? oneShotAPIClientFactory()

        if let override = oneShotPollOverride {
            await override(deviceID, api)
            return
        }

        // Point the shared poll state at this device/client and run the
        // existing one-shot path. We do NOT touch the timer here.
        currentDeviceID = deviceID
        currentAPIClient = api
        await pollOnce()
    }

    static func lockCommand(from poll: PollCommandDTO) -> LockCommand {
        // tier maps to new ShieldTier set; backend emits "exactApp"|"savedList"|"category"|"all"
        let tier = poll.tier.flatMap(ShieldTier.init(rawValue:))
        let trimmedHint = poll.target.category_hint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryHint = (trimmedHint?.isEmpty == false) ? trimmedHint : nil
        let target = CommandTarget(
            bundleID: poll.target.bundle_id,
            listName: poll.target.list_name,
            listID: poll.target.list_id.flatMap(UUID.init(uuidString:)),
            categoryHint: categoryHint,
            targetAll: poll.target.target_all ?? false,
            originalRequest: poll.target.original_request,
            targetDisplay: poll.target.target_display,
            targetChildID: poll.target.target_child_id.flatMap(UUID.init(uuidString:)),
            hasPendingBlob: poll.target.has_pending_blob ?? false,
            forceDowngrade: poll.target.force_downgrade ?? false,
            catalogTokenDataBase64: poll.target.catalog_token_data_base64,
            catalogCategoryTokenDataBase64: poll.target.catalog_category_token_data_base64,
            catalogApplicationTokenDataBase64s: poll.target.applications ?? [],
            catalogCategoryTokenDataBase64s: poll.target.applicationCategories ?? []
        )
        let action: CommandAction = CommandAction(rawValue: poll.action) ?? .shield

        let issued = ISO8601DateFormatter().date(from: poll.issued_at) ?? Date()
        return LockCommand(
            id: poll.command_id,
            action: action,
            tier: tier,
            target: target,
            durationMinutes: poll.duration_minutes,
            issuedAt: issued
        )
    }

    private func execute(poll: PollCommandDTO, api: APIClient) async {
        let cmd = Self.lockCommand(from: poll)

        var blob: Data? = nil
        if cmd.target.hasPendingBlob {
            blob = try? await api.fetchPendingBlob(commandID: cmd.id)
        }

        let result = await ActionExecutor.shared.execute(cmd, blob: blob)

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
                }
                return ("failed", d)
            }
        }()

        var ackDetail = detail
        if status == "confirmed" {
            var d = ackDetail ?? [:]
            if let global = await globalEffectiveStateDictionary() {
                d["global_effective_state"] = global
            }
            ackDetail = d
        }

        do {
            try await api.ack(commandID: cmd.id, status: status, detail: ackDetail)
        } catch {
            print("[CommandPoller] ack failed for \(cmd.id): \(error)")
        }
    }

    private func globalEffectiveStateDictionary() async -> [String: Any]? {
        let current = await ActiveLockStore.shared.allCurrent()
        let covers = current.shields
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
                    tier: $0.tier.rawValue
                )
            }
        let snapshot = AckEffectiveState(
            isBlocked: !current.blocks.isEmpty,
            shieldsCovering: covers,
            possibleSavedListCoverage: false
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
