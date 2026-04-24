import Foundation
import FamilyControls
import ManagedSettings

/// Foreground command poller. Every 5s, fetches pending commands from the backend
/// and dispatches them to ActionExecutor. Posts ack back on completion.
///
/// MVP delivery tier: foreground-only. APNs silent-push integration is Phase 5.
/// BGAppRefreshTask catchup is Phase 5.
@MainActor
final class CommandPoller {
    static let shared = CommandPoller()

    private var timer: Timer?
    private var isPolling = false
    private var currentDeviceID: UUID?
    private var currentAPIClient: APIClient?

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
        currentDeviceID = nil
        currentAPIClient = nil
    }

    /// Fetch all pending commands and dispatch. Safe to call manually (e.g. on push wake).
    func pollOnce() async {
        guard !isPolling, let deviceID = currentDeviceID, let api = currentAPIClient else { return }
        isPolling = true
        defer { isPolling = false }

        do {
            let cmds = try await api.pollCommands(deviceID: deviceID)
            for poll in cmds {
                await execute(poll: poll, api: api)
            }
        } catch {
            print("[CommandPoller] poll error: \(error)")
        }
    }

    private func execute(poll: PollCommandDTO, api: APIClient) async {
        // tier maps to new ShieldTier set; backend emits "exactApp"|"savedList"|"category"|"all"
        let tier = poll.tier.flatMap(ShieldTier.init(rawValue:))
        let target = CommandTarget(
            bundleID: poll.target.bundle_id,
            listName: poll.target.list_name,
            listID: poll.target.list_id.flatMap(UUID.init(uuidString:)),
            categoryHint: poll.target.category_hint,
            targetAll: poll.target.target_all ?? false,
            originalRequest: poll.target.original_request,
            targetDisplay: poll.target.target_display,
            targetChildID: poll.target.target_child_id.flatMap(UUID.init(uuidString:)),
            hasPendingBlob: poll.target.has_pending_blob ?? false,
            forceDowngrade: poll.target.force_downgrade ?? false
        )
        let action: CommandAction = CommandAction(rawValue: poll.action) ?? .shield

        let issued = ISO8601DateFormatter().date(from: poll.issued_at) ?? Date()
        let cmd = LockCommand(
            id: poll.command_id,
            action: action,
            tier: tier,
            target: target,
            durationMinutes: poll.duration_minutes,
            issuedAt: issued
        )

        var blob: Data? = nil
        if target.hasPendingBlob {
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
                return ("failed", ["reason": String(describing: fail)])
            }
        }()

        do {
            try await api.ack(commandID: cmd.id, status: status, detail: detail)
        } catch {
            print("[CommandPoller] ack failed for \(cmd.id): \(error)")
        }
    }
}
