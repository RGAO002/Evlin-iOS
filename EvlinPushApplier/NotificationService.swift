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
///   3. decodes the command's INLINE catalog token(s) and applies the lock
///      through the shared `ActiveLockStore`, whose `recomputeAndApply()` writes
///      the DEFAULT `ManagedSettingsStore` — the exact store + App Group state
///      the main app uses — so the lock survives and reconciles with the app,
///   4. POSTs `/child/ack {status:"confirmed"}` so the ack-driven escalation
///      (`lock_escalation.py`) stops and the parent sees confirmation,
///   5. presents the (time-sensitive) alert.
///
/// SCOPE: only the inline-token LOCK fast-path (`shield` / `block`) is applied
/// here — that is all the `lock_command_alert` channel carries. Anything else
/// (no inline tokens, unlocks, library expansion) is deliberately left PENDING
/// and UNACKED so the full app poller — which has the LocalAliasStore /
/// pending-blob fallbacks this target intentionally does NOT link — applies it
/// on next launch. Fail-safe: the NSE never guesses a lock, and never acks one
/// it did not actually apply.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

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

        Task { [weak self] in
            await self?.applyLock(commandID: commandID)
            self?.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // iOS is about to suspend/kill us. Deliver whatever we have; the
        // ManagedSettings write (if reached) is synchronous inside the actor and
        // has already been attempted.
        NSEConfig.log("time_will_expire")
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
        guard let outcome = await NSELockApplier.apply(command) else {
            NSEConfig.log("not applied (no inline token / not a lock) cmd=\(commandID) action=\(command.action.rawValue)")
            return
        }
        await NSENetwork.ack(baseURL: baseURL, deviceID: deviceID, commandID: commandID, outcome: outcome)
        NSEConfig.log("applied+acked cmd=\(commandID) verb=\(outcome.verb) name=\(outcome.displayName)")
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

    static func apply(_ cmd: LockCommand) async -> Outcome? {
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
        case .unshield, .unblock, .unshieldAll, .unblockAll, .expandLibrary:
            // Not safety-critical under force-quit (fail-safe = stay locked).
            // Leave for the app poller, which reconciles on next launch.
            return nil
        }
    }

    // MARK: Record construction

    private static func buildShieldRecord(from cmd: LockCommand) -> ShieldRecord? {
        let tier = cmd.tier ?? .category
        var appTokens: Set<ApplicationToken> = []
        var categoryTokens: Set<ActivityCategoryToken> = []
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
            // No inline tokens → app handles it via blob / LocalAliasStore.
            guard !appTokens.isEmpty || !categoryTokens.isEmpty else { return nil }
            displayName = cmd.target.listName ?? "saved list"
        case .category:
            guard let token = decodeCategoryToken(cmd.target.catalogCategoryTokenDataBase64),
                  let hint = categoryLookupName(cmd.target) else { return nil }
            categoryTokens = [token]
            targetKey = hint.lowercased()
            displayName = cmd.target.targetDisplay ?? hint.capitalized
        case .all:
            targetKey = "all"
            appliesToAll = true
            displayName = "All Apps"
        }

        let recordKey = ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey)
        var expiresAt = cmd.expiresAt
        if let exp = expiresAt, exp.timeIntervalSinceNow < TimeInterval(minScheduleMinutes * 60) {
            expiresAt = Date().addingTimeInterval(TimeInterval(minScheduleMinutes * 60))
        }
        return ShieldRecord(
            recordKey: recordKey,
            tier: tier,
            targetKey: targetKey,
            displayName: displayName,
            lastCommandID: cmd.id,
            appTokens: appTokens,
            categoryTokens: categoryTokens,
            webDomainTokens: [],
            appliesToAll: appliesToAll,
            issuedAt: cmd.issuedAt,
            expiresAt: expiresAt,
            originalRequest: cmd.target.originalRequest,
            targetChildID: cmd.target.targetChildID ?? UUID()
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
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let dto = try? JSONDecoder().decode(NSEWireCommand.self, from: data) else { return nil }
        return NSEWireCommand.lockCommand(from: dto)
    }

    /// POST /child/ack — v2 generic "confirmed" with verb/display_name so the
    /// parent receipt renders and the ack-driven escalation stops.
    static func ack(baseURL: URL, deviceID: UUID, commandID: UUID, outcome: NSELockApplier.Outcome) async {
        guard let url = childEndpoint(baseURL, "/child/ack") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "command_id": commandID.uuidString,
            "device_id": deviceID.uuidString,
            "status": "confirmed",
            "detail": ["verb": outcome.verb, "display_name": outcome.displayName, "source": "nse"],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Wire decode (verbatim mirror of APIClient.PollCommandDTO/PollTargetDTO)

/// APIClient is intentionally not linked into this target, so the `/child/commands`
/// wire shape + its mapping to `LockCommand` is mirrored here. Kept byte-for-byte
/// faithful to `PollCommandDTO` / `PollTargetDTO` and `CommandPoller.lockCommand`.
private struct NSEWireCommand: Decodable {
    let command_id: UUID
    let action: String
    let tier: String?
    let target: NSEWireTarget
    let duration_minutes: Int?
    let issued_at: String

    static func lockCommand(from poll: NSEWireCommand) -> LockCommand {
        let tier = poll.tier.flatMap(ShieldTier.init(rawValue:))
        let trimmedHint = poll.target.category_hint?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let action = CommandAction(rawValue: poll.action) ?? .shield
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
}

private struct NSEWireTarget: Decodable {
    let bundle_id: String?
    let list_name: String?
    let list_id: String?
    let has_pending_blob: Bool?
    let category_hint: String?
    let target_all: Bool?
    let original_request: String
    let target_display: String?
    let target_child_id: String?
    let force_downgrade: Bool?
    let catalog_token_data_base64: String?
    let catalog_category_token_data_base64: String?
    let applications: [String]?
    let applicationCategories: [String]?

    private enum CodingKeys: String, CodingKey {
        case bundle_id
        case list_name
        case list_id
        case has_pending_blob
        case category_hint
        case categoryHint
        case target_all
        case original_request
        case target_display
        case target_child_id
        case force_downgrade
        case applications
        case applicationCategories
        case application_categories
        case canonicalCatalogTokenDataBase64 = "catalog_token_data_base64"
        case canonicalCatalogCategoryTokenDataBase64 = "catalog_category_token_data_base64"
        case legacyTokenDataBase64 = "token_data_base64"
        case legacyCategoryTokenDataBase64 = "category_token_data_base64"
        case camelCatalogTokenDataBase64 = "catalogTokenDataBase64"
        case camelCatalogCategoryTokenDataBase64 = "catalogCategoryTokenDataBase64"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundle_id = try c.decodeIfPresent(String.self, forKey: .bundle_id)
        list_name = try c.decodeIfPresent(String.self, forKey: .list_name)
        list_id = try c.decodeIfPresent(String.self, forKey: .list_id)
        has_pending_blob = try c.decodeIfPresent(Bool.self, forKey: .has_pending_blob)
        category_hint = try c.decodeIfPresent(String.self, forKey: .category_hint)
            ?? c.decodeIfPresent(String.self, forKey: .categoryHint)
        target_all = try c.decodeIfPresent(Bool.self, forKey: .target_all)
        original_request = try c.decodeIfPresent(String.self, forKey: .original_request) ?? ""
        target_display = try c.decodeIfPresent(String.self, forKey: .target_display)
        target_child_id = try c.decodeIfPresent(String.self, forKey: .target_child_id)
        force_downgrade = try c.decodeIfPresent(Bool.self, forKey: .force_downgrade)
        catalog_token_data_base64 = try c.decodeIfPresent(String.self, forKey: .canonicalCatalogTokenDataBase64)
            ?? c.decodeIfPresent(String.self, forKey: .legacyTokenDataBase64)
            ?? c.decodeIfPresent(String.self, forKey: .camelCatalogTokenDataBase64)
        catalog_category_token_data_base64 = try c.decodeIfPresent(String.self, forKey: .canonicalCatalogCategoryTokenDataBase64)
            ?? c.decodeIfPresent(String.self, forKey: .legacyCategoryTokenDataBase64)
            ?? c.decodeIfPresent(String.self, forKey: .camelCatalogCategoryTokenDataBase64)
        applications = try c.decodeIfPresent([String].self, forKey: .applications)
        applicationCategories = try c.decodeIfPresent([String].self, forKey: .applicationCategories)
            ?? c.decodeIfPresent([String].self, forKey: .application_categories)
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
