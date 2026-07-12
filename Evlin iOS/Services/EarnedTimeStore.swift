import Foundation
import FamilyControls

/// Shared activity naming and App Group persistence used by both the app and
/// DeviceActivity extension targets.
nonisolated enum EarnedActivityGeneration {
    static let legacyActivityName = "evlin.earned.budget"
    static let generatedActivityPrefix = "evlin.earned.budget."
    static let activeActivityNameKey = "evlin.earned.activeActivityName"

    static func generatedActivityName(id: UUID) -> String {
        generatedActivityPrefix + id.uuidString.lowercased()
    }

    static func isEarnedActivityName(_ raw: String) -> Bool {
        raw == legacyActivityName || raw.hasPrefix(generatedActivityPrefix)
    }

    static func stopTargets(activeActivityName: String?) -> [String] {
        var targets: [String] = []
        if let activeActivityName, !activeActivityName.isEmpty {
            targets.append(activeActivityName)
        }
        if !targets.contains(legacyActivityName) {
            targets.append(legacyActivityName)
        }
        return targets
    }

    @discardableResult
    static func installReplacement(
        id: UUID = UUID(),
        defaults: UserDefaults?,
        startMonitoring: (String) throws -> Void,
        stopMonitoring: ([String]) -> Void
    ) -> String? {
        let previous = defaults?.string(forKey: activeActivityNameKey)
        let next = generatedActivityName(id: id)
        do {
            try startMonitoring(next)
        } catch {
            return nil
        }

        let targets = stopTargets(activeActivityName: previous).filter { $0 != next }
        if !targets.isEmpty {
            stopMonitoring(targets)
        }
        defaults?.set(next, forKey: activeActivityNameKey)
        defaults?.synchronize()
        return next
    }

    static func stopPersisted(
        defaults: UserDefaults?,
        stopMonitoring: ([String]) -> Void
    ) {
        let active = defaults?.string(forKey: activeActivityNameKey)
        stopMonitoring(stopTargets(activeActivityName: active))
        defaults?.removeObject(forKey: activeActivityNameKey)
        defaults?.synchronize()
    }
}

/// App Group persistence for the earned screen-time subsystem (Task B3).
///
/// Persists to `group.com.evlin.ios` using plain JSON so both the main app
/// target AND the `EvlinDeviceActivityMonitor` extension can read it. **No actor,
/// no main-app-only types.** FamilyActivitySelection is Codable (conformance
/// supplied by FamilyControls) and serializes via JSONEncoder without requiring
/// the Screen Time entitlement at decode time, so the extension can decode it.
///
/// Membership: this file is compiled into BOTH the `Evlin iOS` app target AND
/// the `EvlinDeviceActivityMonitor` extension target (see `project.pbxproj`
/// `B6F1645E2F999D8A008E858C` membershipExceptions). Keep it free of any
/// app-only or extension-only API.
///
/// Keys (all under the `group.com.evlin.ios` suite):
///   - `earned.measurementSelection`       — JSON-encoded FamilyActivitySelection
///   - `earned.lockedSetID`                — UUID string of the Locked catalog list
///   - `earned.lockedSetTokenData`         — raw Data blob (opaque FamilyActivitySelection)
///   - `earned.overridden.<usageDate>`     — Bool override flag per date string
///   - `earned.backendRemainingAtLastSync` — Int minutes from last backend sync
///   - `earned.latestDeviceEstimate`       — Int minutes from extension's latest estimate
///   - `earned.acceptedUsageDate`          — Canonical backend usage date for accepted estimate
///   - `earned.acceptedEstimateMinutes`    — Int backend-accepted cumulative usage
///   - `earned.poolMinutes`                — Int total earned pool for today (from backend)
///   - `earned.capMinutes`                 — Int hard parent-set cap (from backend)
///   - `evlin.usageCountingAllowed`        — Bool gate written from /child/state
///   - `earned.usageCountingOffset`        — Int counted minutes before a task pause
///   - `evlin.earned.activeActivityName`    — Current generated DeviceActivity name
nonisolated final class EarnedTimeStore: @unchecked Sendable {
    static let shared = EarnedTimeStore()
    private static let acceptedUsageReconciliationLock = NSLock()

    enum AcceptedUsageReconciliation: Equatable {
        case reconciled(Int)
        case stale(acceptedUsageDate: String)
    }

    enum RuntimePolicyReconciliation: Equatable {
        case reconciled(Int)
        case stale(acceptedUsageDate: String)
        case invalid
    }

    private let defaults: UserDefaults?

    init(suiteName: String = "group.com.evlin.ios") {
        defaults = UserDefaults(suiteName: suiteName)
    }

    // MARK: - Keys

    private let measurementKey   = "earned.measurementSelection"
    private let lockedSetIDKey          = "earned.lockedSetID"
    private let lockedSetDataKey        = "earned.lockedSetTokenData"
    private let lockedSetListAliasKeyKey = "earned.lockedSetListAliasKey"
    private let lockedSetAllSelectedKey = "earned.lockedSetAllSelected"
    private let backendKey       = "earned.backendRemainingAtLastSync"
    private let lastBackendSyncAtKey = "earned.lastBackendSyncAt"
    private let estimateKey      = "earned.latestDeviceEstimate"
    private let acceptedUsageDateKey = "earned.acceptedUsageDate"
    private let acceptedEstimateKey = "earned.acceptedEstimateMinutes"
    private let poolKey          = "earned.poolMinutes"
    private let capKey           = "earned.capMinutes"
    private let usageCountingAllowedKey = "evlin.usageCountingAllowed"
    private let earnedUsageOffsetKey = "earned.usageCountingOffset"
    private let appLimitUsageOffsetPrefix = "evlin.appLimitUsageOffset."
    private let appLimitReportedPrefix = "evlin.appLimitReported."

    private func overrideKey(for usageDate: String) -> String {
        "earned.overridden.\(usageDate)"
    }

    // MARK: - Readiness

    /// True once the measurement selection has at least one token that
    /// DeviceActivity can measure. A persisted-but-empty selection is not
    /// enough: it makes setup look complete while total/device usage never
    /// fires thresholds.
    var hasMeasurableSelection: Bool {
        guard let selection = measurementSelection else { return false }
        return !selection.applicationTokens.isEmpty
            || !selection.categoryTokens.isEmpty
            || !selection.webDomainTokens.isEmpty
    }

    /// True once the measurement selection AND the Locked-set identity are
    /// both present. The earned-time feature cannot be enabled until this is
    /// true ([R5/R18/§5.5]).
    var isEarnedTimeReady: Bool {
        hasMeasurableSelection && lockedSetID != nil
    }

    // MARK: - All-category measurement selection

    /// The `FamilyActivityPicker`-captured selection that covers the whole
    /// device (all categories). Nil until the one-time capture flow completes.
    var measurementSelection: FamilyActivitySelection? {
        guard let data = defaults?.data(forKey: measurementKey) else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    /// Persist the all-category selection from the capture flow.
    func saveMeasurementSelection(_ selection: FamilyActivitySelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults?.set(data, forKey: measurementKey)
        defaults?.synchronize()
    }

    // MARK: - Locked-set identity + token blob

    /// The UUID string that identifies the Locked catalog list on the backend.
    /// The extension uses this as a tripwire key for offline shield enforcement.
    var lockedSetID: String? {
        defaults?.string(forKey: lockedSetIDKey)
    }

    /// The raw serialised `FamilyActivitySelection` data for the Locked set.
    /// Used by the extension for offline shield enforcement without the picker.
    var lockedSetTokenData: Data? {
        defaults?.data(forKey: lockedSetDataKey)
    }

    /// The `alias_key` UUID of the "Locked set" `ChildCatalogList` on the backend.
    /// Returned by the backend in lock-state and policy responses (B8 carry) and persisted
    /// via `applyListIDIfNeeded`. The backend now auto-maintains this list server-side.
    var lockedSetListAliasKey: UUID? {
        guard let str = defaults?.string(forKey: lockedSetListAliasKeyKey) else { return nil }
        return UUID(uuidString: str)
    }

    /// Persist the alias_key returned by `createControlList` / `updateControlList`.
    func saveLockedSetListAliasKey(_ key: UUID) {
        defaults?.set(key.uuidString, forKey: lockedSetListAliasKeyKey)
        defaults?.synchronize()
    }

    /// Persist the Locked-set identity and optional token blob.
    func saveLockedSetID(_ id: String, tokenData: Data?) {
        defaults?.set(id, forKey: lockedSetIDKey)
        if let tokenData {
            defaults?.set(tokenData, forKey: lockedSetDataKey)
        } else {
            defaults?.removeObject(forKey: lockedSetDataKey)
        }
        defaults?.synchronize()
    }

    /// True when the backend's `all_selected` flag (Task 1/2 plumbing) says
    /// the kid's Locked-set selection was "all apps and categories" as of
    /// the last sync. Read by the extension's `applyEarnedTimeShield` on the
    /// earned-time exhaustion path (offline-safe, since it's App-Group local).
    var lockedSetAllSelected: Bool {
        defaults?.bool(forKey: lockedSetAllSelectedKey) ?? false
    }

    /// Persist the `all_selected` flag alongside the Locked-set identity.
    func saveLockedSetAllSelected(_ value: Bool) {
        defaults?.set(value, forKey: lockedSetAllSelectedKey)
        defaults?.synchronize()
    }

    // MARK: - Override flag

    /// True if the earned-time override was set for `usageDate` (ISO-8601 date
    /// string, e.g. "2026-06-23"). The extension respects this to skip shielding.
    func isOverridden(forUsageDate usageDate: String) -> Bool {
        defaults?.bool(forKey: overrideKey(for: usageDate)) ?? false
    }

    /// Set or clear the earned-time override flag for a given date.
    func setOverride(_ value: Bool, forUsageDate usageDate: String) {
        if value {
            defaults?.set(true, forKey: overrideKey(for: usageDate))
        } else {
            defaults?.removeObject(forKey: overrideKey(for: usageDate))
        }
    }

    // MARK: - Sync / estimate values

    /// Minutes of earned screen time remaining as of the last backend sync.
    /// Nil if no sync has occurred.
    var backendRemainingAtLastSync: Int? {
        get {
            guard defaults?.object(forKey: backendKey) != nil else { return nil }
            return defaults?.integer(forKey: backendKey)
        }
        set {
            if let v = newValue {
                defaults?.set(v, forKey: backendKey)
            } else {
                defaults?.removeObject(forKey: backendKey)
            }
            defaults?.synchronize()
        }
    }

    /// The wall-clock time of the last successful backend sync that wrote
    /// `backendRemainingAtLastSync`. Nil if no sync has occurred. Stored as
    /// epoch seconds (`Double`) so it round-trips through `UserDefaults`.
    var lastBackendSyncAt: Date? {
        get {
            guard defaults?.object(forKey: lastBackendSyncAtKey) != nil else { return nil }
            let epoch = defaults?.double(forKey: lastBackendSyncAtKey) ?? 0
            return Date(timeIntervalSince1970: epoch)
        }
        set {
            if let v = newValue {
                defaults?.set(v.timeIntervalSince1970, forKey: lastBackendSyncAtKey)
            } else {
                defaults?.removeObject(forKey: lastBackendSyncAtKey)
            }
            defaults?.synchronize()
        }
    }

    /// The extension's latest on-device screen-time estimate in minutes.
    /// Nil until the first threshold callback fires.
    var latestDeviceEstimate: Int? {
        get {
            guard defaults?.object(forKey: estimateKey) != nil else { return nil }
            return defaults?.integer(forKey: estimateKey)
        }
        set {
            if let v = newValue {
                defaults?.set(v, forKey: estimateKey)
            } else {
                defaults?.removeObject(forKey: estimateKey)
            }
            defaults?.synchronize()
        }
    }

    /// Backend-accepted usage is the future re-arm authority. The latest device
    /// estimate remains a raw extension observation until reconciliation.
    var acceptedUsageDate: String? {
        get { defaults?.string(forKey: acceptedUsageDateKey) }
        set { defaults?.set(newValue, forKey: acceptedUsageDateKey) }
    }

    var acceptedEstimateMinutes: Int? {
        get {
            guard defaults?.object(forKey: acceptedEstimateKey) != nil else { return nil }
            return max(0, defaults?.integer(forKey: acceptedEstimateKey) ?? 0)
        }
        set {
            if let newValue {
                defaults?.set(max(0, newValue), forKey: acceptedEstimateKey)
            } else {
                defaults?.removeObject(forKey: acceptedEstimateKey)
            }
        }
    }

    // MARK: - Pool + cap

    /// The total earned pool for today (minutes), as last written by the backend sync.
    /// Nil until the first sync. The extension uses this for tripwire math.
    var poolMinutes: Int? {
        get {
            guard defaults?.object(forKey: poolKey) != nil else { return nil }
            return defaults?.integer(forKey: poolKey)
        }
        set {
            if let v = newValue {
                defaults?.set(v, forKey: poolKey)
            } else {
                defaults?.removeObject(forKey: poolKey)
            }
            defaults?.synchronize()
        }
    }

    /// The hard parent-set cap (minutes), as last written by the backend sync.
    /// Nil until the first sync. The extension uses this for tripwire math.
    var capMinutes: Int? {
        get {
            guard defaults?.object(forKey: capKey) != nil else { return nil }
            return defaults?.integer(forKey: capKey)
        }
        set {
            if let v = newValue {
                defaults?.set(v, forKey: capKey)
            } else {
                defaults?.removeObject(forKey: capKey)
            }
            defaults?.synchronize()
        }
    }

    // MARK: - Usage counting gate

    /// True when screen/app usage should count toward earned pool, device cap,
    /// and per-app limits. The child state poller flips this off while any task
    /// is still unfinished; the DeviceActivity extension reads it before
    /// reporting or enforcing usage thresholds.
    var usageCountingAllowed: Bool {
        get {
            guard defaults?.object(forKey: usageCountingAllowedKey) != nil else { return true }
            return defaults?.bool(forKey: usageCountingAllowedKey) ?? true
        }
        set {
            defaults?.set(newValue, forKey: usageCountingAllowedKey)
            defaults?.synchronize()
        }
    }

    /// Earned-time cumulative minutes that were already counted before usage
    /// counting was paused for unfinished tasks. After re-arming DeviceActivity,
    /// the extension adds this offset to fresh threshold values.
    var earnedUsageOffsetMinutes: Int {
        get {
            guard defaults?.object(forKey: earnedUsageOffsetKey) != nil else { return 0 }
            return max(0, defaults?.integer(forKey: earnedUsageOffsetKey) ?? 0)
        }
        set {
            defaults?.set(max(0, newValue), forKey: earnedUsageOffsetKey)
            defaults?.synchronize()
        }
    }

    static func adjustedEarnedThreshold(
        rawThresholdMinutes: Int,
        runningOffsetMinutes: Int
    ) -> Int {
        min(1440, max(0, runningOffsetMinutes) + max(0, rawThresholdMinutes))
    }

    @discardableResult
    func reconcileAcceptedUsage(
        usageDate: String,
        serverEstimatedMinutes: Int,
        allowSameDayDecrease: Bool
    ) -> Int {
        Self.withAcceptedUsageReconciliationLock {
            reconcileAcceptedUsageLocked(
                usageDate: usageDate,
                serverEstimatedMinutes: serverEstimatedMinutes,
                allowSameDayDecrease: allowSameDayDecrease
            )
        }
    }

    func reconcileAcceptedUsageIfNotStale(
        usageDate: String,
        serverEstimatedMinutes: Int,
        allowSameDayDecrease: Bool
    ) -> AcceptedUsageReconciliation {
        Self.withAcceptedUsageReconciliationLock {
            if let currentDate = acceptedUsageDate,
               Self.isCanonicalUsageDate(currentDate),
               usageDate < currentDate {
                return .stale(acceptedUsageDate: currentDate)
            }
            return .reconciled(reconcileAcceptedUsageLocked(
                usageDate: usageDate,
                serverEstimatedMinutes: serverEstimatedMinutes,
                allowSameDayDecrease: allowSameDayDecrease
            ))
        }
    }

    func reconcileRuntimePolicy(
        usageDate: String,
        timezoneIdentifier: String,
        poolMinutes: Int,
        capMinutes: Int,
        remainingMinutes: Int,
        estimatedMinutes: Int,
        syncedAt: Date = Date()
    ) -> RuntimePolicyReconciliation {
        Self.withAcceptedUsageReconciliationLock {
            guard Self.isCanonicalUsageDate(usageDate),
                  TimeZone(identifier: timezoneIdentifier) != nil,
                  (1...1440).contains(poolMinutes),
                  (1...1440).contains(capMinutes),
                  (0...1440).contains(remainingMinutes),
                  (0...1440).contains(estimatedMinutes)
            else { return .invalid }

            if let currentDate = acceptedUsageDate,
               Self.isCanonicalUsageDate(currentDate),
               usageDate < currentDate {
                return .stale(acceptedUsageDate: currentDate)
            }

            self.poolMinutes = poolMinutes
            self.capMinutes = capMinutes
            backendRemainingAtLastSync = remainingMinutes
            lastBackendSyncAt = syncedAt
            let accepted = reconcileAcceptedUsageLocked(
                usageDate: usageDate,
                serverEstimatedMinutes: estimatedMinutes,
                allowSameDayDecrease: false
            )
            return .reconciled(accepted)
        }
    }

    @discardableResult
    static func withAcceptedUsageReconciliationLock<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        acceptedUsageReconciliationLock.lock()
        defer { acceptedUsageReconciliationLock.unlock() }
        return try body()
    }

    private func reconcileAcceptedUsageLocked(
        usageDate: String,
        serverEstimatedMinutes: Int,
        allowSameDayDecrease: Bool
    ) -> Int {
        let server = max(0, serverEstimatedMinutes)
        let sameDay = acceptedUsageDate == usageDate
        let accepted: Int
        if !sameDay || allowSameDayDecrease {
            accepted = server
        } else {
            accepted = max(acceptedEstimateMinutes ?? 0, server)
        }
        acceptedUsageDate = usageDate
        acceptedEstimateMinutes = accepted
        if !sameDay || allowSameDayDecrease {
            // New-day and paused responses remove raw usage the backend did not accept.
            latestDeviceEstimate = accepted
        } else {
            latestDeviceEstimate = max(latestDeviceEstimate ?? 0, accepted)
        }
        defaults?.synchronize()
        return accepted
    }

    private static func isCanonicalUsageDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func appLimitUsageDate(
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    private func appLimitUsageKey(
        prefix: String,
        ruleID: UUID,
        usageDate: String
    ) -> String {
        "\(prefix)\(ruleID.uuidString.lowercased()).\(usageDate)"
    }

    private func prepareAppLimitUsageWrite(ruleID: UUID, usageDate: String) -> Bool {
        guard let suite = defaults else { return true }
        let id = ruleID.uuidString.lowercased()
        let offsetRoot = appLimitUsageOffsetPrefix + id
        let reportedRoot = appLimitReportedPrefix + id
        let roots = [offsetRoot, reportedRoot]
        let keys = suite.dictionaryRepresentation().keys
        let scopedDates = keys.compactMap { key -> String? in
            roots.compactMap { root -> String? in
                guard key.hasPrefix(root + ".") else { return nil }
                return String(key.dropFirst(root.count + 1))
            }.first
        }

        guard !scopedDates.contains(where: { $0 > usageDate }) else { return false }

        keys.filter { key in
            roots.contains(key)
                || roots.contains { root in
                    key.hasPrefix(root + ".")
                        && String(key.dropFirst(root.count + 1)) < usageDate
                }
        }
        .forEach { suite.removeObject(forKey: $0) }
        return true
    }

    func appLimitUsageOffsetMinutes(ruleID: UUID, usageDate: String) -> Int {
        let key = appLimitUsageKey(
            prefix: appLimitUsageOffsetPrefix,
            ruleID: ruleID,
            usageDate: usageDate
        )
        guard defaults?.object(forKey: key) != nil else { return 0 }
        return max(0, defaults?.integer(forKey: key) ?? 0)
    }

    func setAppLimitUsageOffset(
        ruleID: UUID,
        usageDate: String,
        usedMinutes: Int
    ) {
        guard prepareAppLimitUsageWrite(ruleID: ruleID, usageDate: usageDate) else { return }
        let key = appLimitUsageKey(
            prefix: appLimitUsageOffsetPrefix,
            ruleID: ruleID,
            usageDate: usageDate
        )
        defaults?.set(max(0, usedMinutes), forKey: key)
        defaults?.synchronize()
    }

    func appLimitReportedMinutes(ruleID: UUID, usageDate: String) -> Int {
        let key = appLimitUsageKey(
            prefix: appLimitReportedPrefix,
            ruleID: ruleID,
            usageDate: usageDate
        )
        guard defaults?.object(forKey: key) != nil else { return 0 }
        return max(0, defaults?.integer(forKey: key) ?? 0)
    }

    func recordAppLimitUsage(
        ruleID: UUID,
        usageDate: String,
        usedMinutes: Int
    ) {
        guard prepareAppLimitUsageWrite(ruleID: ruleID, usageDate: usageDate) else { return }
        let key = appLimitUsageKey(
            prefix: appLimitReportedPrefix,
            ruleID: ruleID,
            usageDate: usageDate
        )
        let current = appLimitReportedMinutes(ruleID: ruleID, usageDate: usageDate)
        defaults?.set(max(current, usedMinutes), forKey: key)
        defaults?.synchronize()
    }

    // MARK: - Reset

    /// Wipe all earned-time keys. Used by tests and a full account reset.
    /// NOTE: override flags for specific dates are NOT enumerable via UserDefaults
    /// public API; `removeAll` removes the keys known at call time plus known-date
    /// prefixes. Tests call `removeAll` in tearDown and then re-assert the keys
    /// they care about, so residual keys from other dates do not affect results.
    func removeAll() {
        defaults?.removeObject(forKey: measurementKey)
        clearUsageStateForIdentityChange()
    }

    /// Clear per-family usage/day state when the child-device identity changes
    /// (re-pairing under a new family / account switch). Everything armed or
    /// counted under the previous identity — day odometer, re-arm offset,
    /// backend sync, pool/cap policy, locked set, per-app offsets, override
    /// flags — belongs to the OLD family and must not leak into the new one.
    /// The measurement selection is kept: it describes this device's apps,
    /// not a family policy.
    func clearUsageStateForIdentityChange() {
        [lockedSetIDKey, lockedSetDataKey, lockedSetListAliasKeyKey,
         lockedSetAllSelectedKey,
         backendKey, lastBackendSyncAtKey, estimateKey, acceptedUsageDateKey,
         acceptedEstimateKey, poolKey, capKey, usageCountingAllowedKey,
         earnedUsageOffsetKey].forEach { defaults?.removeObject(forKey: $0) }
        // Sweep any per-date override flags and per-app usage offsets.
        if let suite = defaults {
            let prefix = "earned.overridden."
            suite.dictionaryRepresentation().keys
                .filter {
                    $0.hasPrefix(prefix)
                    || $0.hasPrefix(appLimitUsageOffsetPrefix)
                    || $0.hasPrefix(appLimitReportedPrefix)
                }
                .forEach { suite.removeObject(forKey: $0) }
        }
    }
}
