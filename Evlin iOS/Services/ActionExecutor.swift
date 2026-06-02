import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import CryptoKit

enum CatalogCommandTokenData {
    static func decodedApplicationData(from target: CommandTarget) -> Data? {
        decodedData(from: target.catalogTokenDataBase64)
    }

    static func decodedCategoryData(from target: CommandTarget) -> Data? {
        decodedData(from: target.catalogCategoryTokenDataBase64)
    }

    static func decodedApplicationDatas(from target: CommandTarget) -> [Data] {
        target.catalogApplicationTokenDataBase64s.compactMap(decodedData)
    }

    static func decodedCategoryDatas(from target: CommandTarget) -> [Data] {
        target.catalogCategoryTokenDataBase64s.compactMap(decodedData)
    }

    static func decodedApplicationToken(from target: CommandTarget) -> ApplicationToken? {
        decodedApplicationData(from: target).flatMap {
            decodeToken(ApplicationToken.self, from: $0)
        }
    }

    static func decodedCategoryToken(from target: CommandTarget) -> ActivityCategoryToken? {
        decodedCategoryData(from: target).flatMap {
            decodeToken(ActivityCategoryToken.self, from: $0)
        }
    }

    static func decodedApplicationTokenSet(from target: CommandTarget) throws -> Set<ApplicationToken>? {
        let payloads = cleanedPayloads(target.catalogApplicationTokenDataBase64s)
        guard !payloads.isEmpty else { return nil }
        var tokens = Set<ApplicationToken>()
        for payload in payloads {
            guard let data = decodedData(from: payload),
                  let token = decodeToken(ApplicationToken.self, from: data)
            else { throw ExecuteError.malformed }
            tokens.insert(token)
        }
        return tokens
    }

    static func decodedCategoryTokenSet(from target: CommandTarget) throws -> Set<ActivityCategoryToken>? {
        let payloads = cleanedPayloads(target.catalogCategoryTokenDataBase64s)
        guard !payloads.isEmpty else { return nil }
        var tokens = Set<ActivityCategoryToken>()
        for payload in payloads {
            guard let data = decodedData(from: payload),
                  let token = decodeToken(ActivityCategoryToken.self, from: data)
            else { throw ExecuteError.malformed }
            tokens.insert(token)
        }
        return tokens
    }

    private static func decodedData(from base64: String?) -> Data? {
        guard let trimmed = base64?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return Data(base64Encoded: trimmed)
    }

    private static func cleanedPayloads(_ base64s: [String]) -> [String] {
        base64s
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func decodeToken<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let json = JSONDecoder()
        json.dateDecodingStrategy = .iso8601
        if let token = try? json.decode(type, from: data) { return token }
        return try? PropertyListDecoder().decode(type, from: data)
    }
}

protocol DeviceActivityScheduling {
    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws
    func stopMonitoring(_ activities: [DeviceActivityName])
    func stopMonitoring()
}

struct DeviceActivityCenterScheduler: DeviceActivityScheduling {
    private let center = DeviceActivityCenter()

    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        try center.startMonitoring(name, during: schedule)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        center.stopMonitoring(activities)
    }

    func stopMonitoring() {
        center.stopMonitoring()
    }
}

/// Translates LockCommand into ActiveLockStore mutations.
/// See spec §6 for dispatcher logic and §3.4 for merge rules.
final class ActionExecutor: @unchecked Sendable {
    static let shared = ActionExecutor()

    private let activityScheduler: DeviceActivityScheduling
    private let authorizationStatusProvider: () -> AuthorizationStatus

    /// iOS DeviceActivitySchedule hard minimum.
    static let minScheduleMinutes: Int = 15

    init(
        activityScheduler: DeviceActivityScheduling = DeviceActivityCenterScheduler(),
        authorizationStatusProvider: @escaping () -> AuthorizationStatus = {
            AuthorizationCenter.shared.authorizationStatus
        }
    ) {
        self.activityScheduler = activityScheduler
        self.authorizationStatusProvider = authorizationStatusProvider
    }

    func execute(_ cmd: LockCommand, blob: Data? = nil) async -> AckResult {
        guard authorizationStatusProvider() == .approved else {
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

    /// Direct receipt-action unlock path. This intentionally bypasses chat/AI
    /// re-dispatch: the receipt already identified the still-covering shield.
    func executeReceiptUnlock(_ target: ReceiptUnlockTarget) async -> AckResult {
        let requestedName = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            return .failed(.malformed)
        }

        let current = await ActiveLockStore.shared.allCurrent().shields
        let matches = current.filter { record in
            record.displayName.caseInsensitiveCompare(requestedName) == .orderedSame
                && (target.tier == nil || record.tier == target.tier)
        }

        guard let record = strongestShield(in: matches) else {
            return .failed(.nothingToUnlock)
        }
        guard let removed = await ActiveLockStore.shared.removeShield(recordKey: record.recordKey) else {
            return .failed(.nothingToUnlock)
        }
        cancelScheduled(recordKey: record.recordKey)

        let effective = effectiveStateFrom(
            removed.stillCovered,
            isBlocked: removed.blockedAfter,
            possibleSavedList: false
        )
        return .confirmedExact(
            verb: .unshield,
            displayName: removed.record.displayName,
            effectiveState: effective
        )
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
                    // Don't swallow scheduling errors with try? — when this
                    // throws, the shield gets applied but the auto-unshield
                    // never fires, and the parent only finds out 15 minutes
                    // later when the app is still locked. Log to NSLog so it
                    // shows in Xcode console + write a marker to App Group
                    // UserDefaults so we can read it from the chat UI later.
                    do {
                        try scheduleRelock(recordKey: record.recordKey, expiresAt: expiresAt)
                        let ok = "schedule_ok recordKey=\(record.recordKey) " +
                                 "expiresAt=\(ISO8601DateFormatter().string(from: expiresAt))"
                        NSLog("[Evlin] %@", ok)
                        UserDefaults(suiteName: "group.com.evlin.ios")?.set(
                            ok, forKey: "evlin.lastScheduleResult"
                        )
                    } catch {
                        let err = "schedule_FAILED recordKey=\(record.recordKey) " +
                                  "expiresAt=\(ISO8601DateFormatter().string(from: expiresAt)) " +
                                  "error=\(error.localizedDescription)"
                        NSLog("[Evlin] %@", err)
                        UserDefaults(suiteName: "group.com.evlin.ios")?.set(
                            err, forKey: "evlin.lastScheduleResult"
                        )
                    }
                }
                // Audit-only window log (best-effort, off the hot path). A
                // write failure here must never affect the lock or receipt.
                LockWindowStore.append(LockWindowRecord(
                    recordKey: record.recordKey,
                    displayName: record.displayName,
                    bundleID: record.appTokens.isEmpty ? nil
                        : (cmd.target.bundleID ?? LocalAliasStore.shared
                            .primaryBundleID(forDisplayOrHint: record.displayName)),
                    issuedAt: record.issuedAt,
                    expiresAt: record.expiresAt
                ))
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

    // Honest-receipt contract: parent ReceiptCard appends
    // EvlinReceiptCopy.appliedOnKidDevice under the AckResult this builds.
    // This builder must never encode an "Apple confirmed" style claim.
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
                category: categoryLookupName(from: cmd.target) ?? "unknown",
                origRequest: cmd.target.originalRequest,
                effectiveState: effectiveState
            )
        default:
            return .confirmedExact(verb: verb, displayName: record.displayName, effectiveState: effectiveState)
        }
    }

    private func currentEffectiveState(forShieldRecord record: ShieldRecord, cmd: LockCommand) async -> AckEffectiveState? {
        let query: AppQuery
        if cmd.tier == .exactApp, let resolved = try? resolveExactApp(from: cmd.target) {
            let bundleForQuery = canonicalBundleID(for: cmd.target)
            query = AppQuery(bundleID: bundleForQuery, token: resolved.token, categoryHint: nil)
        } else if cmd.tier == .category {
            query = AppQuery(categoryHint: categoryLookupName(from: cmd.target)?.lowercased())
        } else if let bid = cmd.target.bundleID {
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

    private func strongestShield(in records: [ShieldRecord]) -> ShieldRecord? {
        records.sorted { a, b in
            if a.expiresAt == nil && b.expiresAt != nil { return true }
            if a.expiresAt != nil && b.expiresAt == nil { return false }
            return (a.expiresAt ?? .distantPast) > (b.expiresAt ?? .distantPast)
        }.first
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
            // Catalog-captured apps live in LocalAliasStore but are not necessarily in
            // the legacy active Managed Apps selection. Don't require the token to be
            // "active": if the kid holds a real captured token for this app, shield it.
            // (When the command carries a catalog token, resolveExactApp uses it
            // directly and this flag is moot.)
            let resolved = try resolveExactApp(from: cmd.target, requireActiveToken: false)
            appTokens = [resolved.token]
            targetKey = resolved.targetKey
            displayName = cmd.target.targetDisplay
                ?? cmd.target.bundleID
                ?? cmd.target.categoryHint
                ?? "App"
        case .savedList:
            if let id = cmd.target.listID {
                targetKey = id.uuidString
            } else {
                throw ExecuteError.malformed
            }
            if let catalogApps = try CatalogCommandTokenData.decodedApplicationTokenSet(from: cmd.target) {
                appTokens = catalogApps
            }
            if let catalogCategories = try CatalogCommandTokenData.decodedCategoryTokenSet(from: cmd.target) {
                categoryTokens = catalogCategories
            }
            if appTokens.isEmpty && categoryTokens.isEmpty {
                let sel: FamilyActivitySelection
                // iOS 26 PropertyListEncoder crashes on FamilyControls tokens; try JSON first,
                // fall back to plist for legacy server payloads. See LocalAliasStore._decodeTokenAny.
                if let blob = blob,
                   let decoded = (try? JSONDecoder().decode(FamilyActivitySelection.self, from: blob))
                              ?? (try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: blob)) {
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
            }
            displayName = cmd.target.listName ?? "saved list"
        case .category:
            guard let hint = categoryLookupName(from: cmd.target) else {
                throw ExecuteError.categoryNotConfigured("unknown")
            }
            let tok: ActivityCategoryToken
            if let decoded = CatalogCommandTokenData.decodedCategoryToken(from: cmd.target) {
                tok = decoded
            } else if let local = LocalAliasStore.shared.categoryToken(forName: hint) {
                tok = local
            } else {
                throw ExecuteError.categoryNotConfigured(hint)
            }
            categoryTokens = [tok]
            targetKey = hint.lowercased()
            displayName = cmd.target.targetDisplay ?? hint.capitalized
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
        // Timed block: clamp to iOS DeviceActivitySchedule's hard 15-minute
        // minimum same way shield does, so 'block IG for 5 min' becomes a
        // 15-minute block rather than silently never-firing.
        var expiresAt = cmd.expiresAt
        if let exp = expiresAt, exp.timeIntervalSinceNow < TimeInterval(Self.minScheduleMinutes * 60) {
            expiresAt = Date().addingTimeInterval(TimeInterval(Self.minScheduleMinutes * 60))
        }
        let record = BlockRecord(
            bundleID: bundleID,
            displayName: cmd.target.targetDisplay ?? bundleID,
            blockedAt: cmd.issuedAt,
            lastCommandID: cmd.id,
            originalRequest: cmd.target.originalRequest,
            targetChildID: cmd.target.targetChildID ?? UUID(),
            expiresAt: expiresAt
        )
        let result = await ActiveLockStore.shared.addBlock(record)
        // Schedule auto-unblock for timed blocks. The DeviceActivityMonitor
        // extension fires intervalDidEnd at expiry and removes the record.
        // Don't swallow with try? — see executeShield for rationale.
        if let exp = expiresAt {
            do {
                try scheduleAutoUnblock(bundleID: bundleID, expiresAt: exp)
                NSLog("[Evlin] block_schedule_ok bundleID=%@ expiresAt=%@",
                      bundleID, ISO8601DateFormatter().string(from: exp))
            } catch {
                NSLog("[Evlin] block_schedule_FAILED bundleID=%@ error=%@",
                      bundleID, error.localizedDescription)
                UserDefaults(suiteName: "group.com.evlin.ios")?.set(
                    "block_schedule_FAILED bundleID=\(bundleID) error=\(error.localizedDescription)",
                    forKey: "evlin.lastScheduleResult"
                )
            }
        }
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

    /// Schedule a DeviceActivityMonitor activity that fires intervalDidEnd
    /// at `expiresAt`, so the extension can remove the BlockRecord and
    /// recompute the effective state. Activity name namespace is
    /// `evlin.block.<sha-of-bundleID>` so the extension knows it's a
    /// block-expiry event vs a shield-expiry event.
    private func scheduleAutoUnblock(bundleID: String, expiresAt: Date) throws {
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
        let name = DeviceActivityName(deviceActivityNameForBlock(bundleID: bundleID))
        try activityScheduler.startMonitoring(name, during: schedule)
    }

    private func deviceActivityNameForBlock(bundleID: String) -> String {
        let data = bundleID.data(using: .utf8) ?? Data()
        let bytes = sha256Hex16(data)
        return "evlin.block.\(bytes)"
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
            guard let resolved = try? resolveExactApp(from: cmd.target, requireActiveToken: false) else {
                return .failed(.applicationNotConfigured(resolveExactAppFailureReference(from: cmd.target)))
            }
            let bundleForQuery = canonicalBundleID(for: cmd.target)
            let display = cmd.target.targetDisplay ?? bundleForQuery ?? cmd.target.categoryHint ?? "App"
            return await unshieldAppByBundle(
                bundleID: bundleForQuery,
                token: resolved.token,
                displayName: display,
                categoryHint: cmd.target.categoryHint
            )
        }
    }

    /// Bundle id when known (command or Managed Apps lookup); may be nil for display-only aliases.
    private func canonicalBundleID(for target: CommandTarget) -> String? {
        if let raw = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        let hints = [target.targetDisplay, target.categoryHint]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for hint in hints {
            if let bid = LocalAliasStore.shared.primaryBundleID(forDisplayOrHint: hint) {
                return bid
            }
        }
        return nil
    }

    private func resolveExactAppFailureReference(from target: CommandTarget) -> String {
        if let bid = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bid.isEmpty {
            return bid
        }
        return target.targetDisplay
            ?? target.categoryHint
            ?? target.originalRequest
    }

    private struct ExactAppResolution {
        let token: ApplicationToken
        /// Matches `ShieldRecord.targetKey`: preferred lowercased bundle id, else lowercased display hint.
        let targetKey: String
    }

    private func resolveExactApp(
        from target: CommandTarget,
        requireActiveToken: Bool = false
    ) throws -> ExactAppResolution {
        if let token = CatalogCommandTokenData.decodedApplicationToken(from: target) {
            return ExactAppResolution(token: token, targetKey: exactAppTargetKey(from: target))
        }

        let store = LocalAliasStore.shared
        let activeTokens = ScreenTimeManager.shared.selectedApps.applicationTokens
        func lookup(_ key: String) -> ApplicationToken? {
            if requireActiveToken {
                return store.activeApplicationToken(forLookupKey: key, activeTokens: activeTokens)
            }
            return store.applicationToken(forLookupKey: key)
        }

        if let rawBid = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !rawBid.isEmpty {
            let bidLower = rawBid.lowercased()
            if let t = lookup(rawBid) {
                return ExactAppResolution(token: t, targetKey: bidLower)
            }
        }
        var seen = Set<String>()
        let hintStrings = [target.targetDisplay, target.categoryHint]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for hint in hintStrings {
            let norm = hint.lowercased()
            guard seen.insert(norm).inserted else { continue }
            guard let tok = lookup(hint) else { continue }
            let key = store.primaryBundleID(forDisplayOrHint: hint)?.lowercased() ?? norm
            return ExactAppResolution(token: tok, targetKey: key)
        }
        throw ExecuteError.applicationNotConfigured(resolveExactAppFailureReference(from: target))
    }

    private func exactAppTargetKey(from target: CommandTarget) -> String {
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

    private func categoryLookupName(from target: CommandTarget) -> String? {
        for raw in [target.categoryHint, target.targetDisplay, target.originalRequest] {
            if let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                return clean
            }
        }
        return nil
    }

    private func removeExplicit(tier: ShieldTier, targetKey: String) async -> AckResult {
        let recordKey = ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey)
        guard let removed = await ActiveLockStore.shared.removeShield(recordKey: recordKey) else {
            return .failed(.nothingToUnlock)
        }
        cancelScheduled(recordKey: recordKey)

        // P2 fix: narrow the post-query so the "Still shielded by …" disclosure
        // only mentions shields that actually overlap what we just removed.
        // The broken version used AppQuery(nil, nil) which matched `all`-tier
        // shields + flagged every saved-list shield as "possibly covering" — so
        // `unshield list 1` would falsely claim list 2 might still cover it.
        let eff: AckEffectiveState
        switch tier {
        case .all:
            // After removing the broadest possible shield, there is nothing
            // specific to "still cover" — effective state is trivially empty.
            eff = AckEffectiveState(isBlocked: false, shieldsCovering: [], possibleSavedListCoverage: false)
        case .category:
            // Re-ask with the same category hint. Remaining shields on that
            // category (or `all`-tier) are correctly reported; unrelated
            // saved-list shields on OTHER apps won't be flagged.
            let post = await ActiveLockStore.shared.effectiveState(
                for: AppQuery(categoryHint: targetKey)
            )
            eff = effectiveStateFrom(
                post.stillCovered,
                isBlocked: post.blockedAfter,
                possibleSavedList: post.possibleSavedListCoverage
            )
        case .savedList:
            // Ask per-token: did any remaining shield cover an app that was in
            // the list we just removed? Union the results, dedup by recordKey.
            var union: [String: ShieldRecord] = [:]
            var blockedAny = false
            var possibleList = false
            for token in removed.record.appTokens {
                let s = await ActiveLockStore.shared.effectiveState(
                    for: AppQuery(token: token)
                )
                for r in s.stillCovered { union[r.recordKey] = r }
                if s.blockedAfter { blockedAny = true }
                if s.possibleSavedListCoverage { possibleList = true }
            }
            // Category tokens in the removed list: no bundle-level reverse lookup,
            // but we can still check if any `all`-tier or same-category shield remains.
            for _ in removed.record.categoryTokens {
                let s = await ActiveLockStore.shared.effectiveState(for: AppQuery())
                // `all`-tier always matches AppQuery(). This catches the edge case.
                for r in s.stillCovered where r.tier == .all { union[r.recordKey] = r }
            }
            eff = effectiveStateFrom(
                Array(union.values),
                isBlocked: blockedAny,
                possibleSavedList: possibleList
            )
        case .exactApp:
            // removeExplicit is called for list/category/all; exactApp goes through
            // unshieldAppByBundle. Defensive default.
            eff = AckEffectiveState(isBlocked: false, shieldsCovering: [], possibleSavedListCoverage: false)
        }

        return .confirmedExact(verb: .unshield, displayName: removed.record.displayName, effectiveState: eff)
    }

    private func unshieldAppByBundle(
        bundleID: String?,
        token: ApplicationToken?,
        displayName: String,
        categoryHint: String?
    ) async -> AckResult {
        let tk = token ?? bundleID.flatMap { LocalAliasStore.shared.applicationToken(forLookupKey: $0) }
        let query = AppQuery(bundleID: bundleID, token: tk, categoryHint: categoryHint?.lowercased())
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
        try activityScheduler.startMonitoring(name, during: schedule)
    }

    private func cancelScheduled(recordKey: String) {
        let name = DeviceActivityName(deviceActivityNameFor(recordKey: recordKey))
        activityScheduler.stopMonitoring([name])
    }

    private func cancelAllScheduled() {
        activityScheduler.stopMonitoring()
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
    case applicationNotConfigured(String)
    case notImplemented(String)

    var ackFailure: AckFailure {
        switch self {
        case .malformed: return .malformed
        case .listNotFound(let n): return .listNotFound(n)
        case .categoryNotConfigured(let n): return .categoryNotConfigured(n)
        case .applicationNotConfigured(let n): return .applicationNotConfigured(n)
        case .notImplemented(let reason): return .execution("Not implemented in MVP: \(reason)")
        }
    }
}
