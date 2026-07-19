import Foundation
import FamilyControls
import Darwin

/// Shared activity naming and App Group persistence used by both the app and
/// DeviceActivity extension targets.
nonisolated enum EarnedActivityGeneration {
    static let legacyActivityName = "evlin.earned.budget"
    static let generatedActivityPrefix = "evlin.earned.budget."
    static let activeActivityNameKey = "evlin.earned.activeActivityName"
    static let lifecycleKey = "evlin.earned.activityLifecycle"
    static let lifecycleBreadcrumbsKey = "evlin.earned.activityBreadcrumbs"
    static let currentLifecycleVersion = 2

    struct Generation: Codable, Equatable, Sendable {
        let activityName: String
        let deviceID: String
        let offsetMinutes: Int
        let usageDate: String
        let timezoneIdentifier: String
        let generationKey: MeteringGenerationKey?
        let armedAt: Date?

        init(
            activityName: String,
            deviceID: String,
            offsetMinutes: Int,
            usageDate: String,
            timezoneIdentifier: String,
            generationKey: MeteringGenerationKey? = nil,
            armedAt: Date? = nil
        ) {
            self.activityName = activityName
            self.deviceID = deviceID
            self.offsetMinutes = offsetMinutes
            self.usageDate = usageDate
            self.timezoneIdentifier = timezoneIdentifier
            self.generationKey = generationKey
            self.armedAt = armedAt
        }

        var isValid: Bool {
            isEarnedActivityName(activityName)
                && canonicalDeviceID(deviceID) != nil
                && offsetMinutes >= 0
                && EarnedTimeStore.isCanonicalUsageDate(usageDate)
                && TimeZone(identifier: timezoneIdentifier) != nil
        }
    }

    struct Lifecycle: Codable, Equatable, Sendable {
        var version: Int
        var active: Generation?
        var pending: Generation?
        var retiringActivityNames: [String]
        var isStopped: Bool

        init(
            version: Int = EarnedActivityGeneration.currentLifecycleVersion,
            active: Generation?,
            pending: Generation?,
            retiringActivityNames: [String] = [],
            isStopped: Bool = false
        ) {
            self.version = version
            self.active = active
            self.pending = pending
            self.retiringActivityNames = retiringActivityNames
            self.isStopped = isStopped
        }

        private enum CodingKeys: String, CodingKey {
            case version, active, pending, retiringActivityNames, isStopped
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            guard (1...EarnedActivityGeneration.currentLifecycleVersion).contains(version) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: values,
                    debugDescription: "Unsupported earned lifecycle version \(version)"
                )
            }
            active = try values.decodeIfPresent(Generation.self, forKey: .active)
            pending = try values.decodeIfPresent(Generation.self, forKey: .pending)
            retiringActivityNames = try values.decodeIfPresent(
                [String].self,
                forKey: .retiringActivityNames
            ) ?? []
            isStopped = try values.decodeIfPresent(Bool.self, forKey: .isStopped) ?? false
        }

        var isValid: Bool {
            let reservedNames = [active?.activityName, pending?.activityName].compactMap { $0 }
            return (1...EarnedActivityGeneration.currentLifecycleVersion).contains(version)
                && active?.isValid != false
                && pending?.isValid != false
                && (active == nil
                    || pending == nil
                    || active?.activityName != pending?.activityName)
                && retiringActivityNames.allSatisfy(isEarnedActivityName)
                && Set(retiringActivityNames).count == retiringActivityNames.count
                && retiringActivityNames.allSatisfy { !reservedNames.contains($0) }
                && (!isStopped || (active == nil && pending == nil))
        }
    }

    static func canonicalDeviceID(_ raw: String?) -> String? {
        guard let raw,
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return id.uuidString.lowercased()
    }

    static func generatedActivityName(id: UUID) -> String {
        generatedActivityPrefix + id.uuidString.lowercased()
    }

    static func isEarnedActivityName(_ raw: String) -> Bool {
        raw == legacyActivityName || raw.hasPrefix(generatedActivityPrefix)
    }

    static func authorizedCallback(
        activityName: String,
        currentDeviceID: String?,
        lifecycle: Lifecycle?
    ) -> Generation? {
        guard let lifecycle,
              lifecycle.isValid,
              let active = lifecycle.active,
              active.activityName == activityName,
              canonicalDeviceID(active.deviceID) == canonicalDeviceID(currentDeviceID)
        else { return nil }

        if activityName == legacyActivityName {
            return active
        }
        return activityName.hasPrefix(generatedActivityPrefix) ? active : nil
    }

    static func isAuthorized(
        generation: Generation,
        defaults: UserDefaults?
    ) -> Bool {
        defaults?.synchronize()
        return authorizedCallback(
            activityName: generation.activityName,
            currentDeviceID: defaults?.string(forKey: "evlin.childId"),
            lifecycle: loadLifecycle(defaults: defaults)
        ) == generation
    }

    @discardableResult
    static func performIfAuthorized(
        generation: Generation,
        defaults: UserDefaults?,
        mutationKeys: [String] = [],
        beforeFinalAuthorizationCheck: () -> Void = {},
        rollbackExternalState: () -> Void = {},
        _ operation: () -> Void
    ) -> Bool {
        guard isAuthorized(generation: generation, defaults: defaults) else {
            return false
        }
        let before = snapshot(defaults: defaults, keys: mutationKeys)
        operation()
        let written = snapshot(defaults: defaults, keys: mutationKeys)
        beforeFinalAuthorizationCheck()
        defaults?.synchronize()
        guard !isAuthorized(generation: generation, defaults: defaults) else {
            return true
        }
        restore(
            defaults: defaults,
            prior: before,
            whereCurrentMatches: written
        )
        defaults?.synchronize()
        rollbackExternalState()
        return false
    }

    private struct DefaultsValue {
        let key: String
        let value: Any?
    }

    private static func snapshot(
        defaults: UserDefaults?,
        keys: [String]
    ) -> [DefaultsValue] {
        keys.map { DefaultsValue(key: $0, value: defaults?.object(forKey: $0)) }
    }

    private static func restore(
        defaults: UserDefaults?,
        prior: [DefaultsValue],
        whereCurrentMatches written: [DefaultsValue]
    ) {
        guard let defaults else { return }
        for priorValue in prior {
            let writtenValue = written.first { $0.key == priorValue.key }?.value
            guard defaultsValuesEqual(
                defaults.object(forKey: priorValue.key),
                writtenValue
            ) else { continue }
            if let value = priorValue.value {
                defaults.set(value, forKey: priorValue.key)
            } else {
                defaults.removeObject(forKey: priorValue.key)
            }
        }
    }

    private static func defaultsValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let left?, let right?): return (left as AnyObject).isEqual(right)
        }
    }

    static func loadLifecycle(defaults: UserDefaults?) -> Lifecycle? {
        guard let data = defaults?.data(forKey: lifecycleKey),
              let lifecycle = try? JSONDecoder().decode(Lifecycle.self, from: data),
              lifecycle.isValid
        else { return nil }
        return lifecycle
    }

    @discardableResult
    static func persistLifecycle(
        _ lifecycle: Lifecycle,
        defaults: UserDefaults?,
        synchronizeDefaults: (UserDefaults) -> Bool = { $0.synchronize() },
        readBackObject: (UserDefaults, String) -> Any? = {
            defaults, key in defaults.object(forKey: key)
        }
    ) -> Bool {
        guard lifecycle.isValid, let defaults else { return false }
        guard lifecycle.active != nil
                || lifecycle.pending != nil
                || !lifecycle.retiringActivityNames.isEmpty
                || lifecycle.isStopped
        else {
            defaults.removeObject(forKey: lifecycleKey)
            defaults.removeObject(forKey: lifecycleBreadcrumbsKey)
            if !synchronizeDefaults(defaults) {
                recordLifecycleSynchronizeDiagnostic(stage: "clear")
            }
            return readBackObject(defaults, lifecycleKey) == nil
                && readBackObject(defaults, lifecycleBreadcrumbsKey) == nil
        }
        let breadcrumbs = stopTargets(lifecycle: lifecycle)
        defaults.set(breadcrumbs, forKey: lifecycleBreadcrumbsKey)
        if !synchronizeDefaults(defaults) {
            recordLifecycleSynchronizeDiagnostic(stage: "breadcrumbs")
        }
        guard defaultsValuesEqual(
                  readBackObject(defaults, lifecycleBreadcrumbsKey),
                  breadcrumbs
              ),
              let data = try? JSONEncoder().encode(lifecycle)
        else { return false }
        defaults.set(data, forKey: lifecycleKey)
        if !synchronizeDefaults(defaults) {
            recordLifecycleSynchronizeDiagnostic(stage: "lifecycle")
        }
        guard defaultsValuesEqual(
            readBackObject(defaults, lifecycleKey),
            data
        ) else {
            return false
        }
        return true
    }

    private static func recordLifecycleSynchronizeDiagnostic(stage: String) {
        NSLog("[Evlin/Earned] lifecycle synchronize diagnostic stage=%@", stage)
    }

    @discardableResult
    static func persistPending(_ generation: Generation, defaults: UserDefaults?) -> Bool {
        guard generation.isValid else { return false }
        var lifecycle = loadLifecycle(defaults: defaults)
            ?? Lifecycle(active: nil, pending: nil, retiringActivityNames: [])
        lifecycle.pending = generation
        lifecycle.isStopped = false
        return persistLifecycle(lifecycle, defaults: defaults)
    }

    static func migrateActiveIfNeeded(
        _ generation: Generation,
        defaults: UserDefaults?
    ) {
        guard defaults?.data(forKey: lifecycleKey) == nil,
              loadLifecycle(defaults: defaults) == nil,
              generation.isValid
        else { return }
        _ = persistLifecycle(
            .init(active: generation, pending: nil, retiringActivityNames: []),
            defaults: defaults
        )
    }

    static func recoverPending(
        defaults: UserDefaults?,
        stopMonitoring: ([String]) -> Void
    ) {
        guard let defaults else { return }
        guard var lifecycle = loadLifecycle(defaults: defaults) else {
            let hasCorruptLifecycle = defaults.data(forKey: lifecycleKey) != nil
            let breadcrumbs = loadBreadcrumbs(defaults: defaults)
            guard hasCorruptLifecycle || !breadcrumbs.isEmpty else { return }
            let targets = uniqueTargets(
                breadcrumbs
                    + [defaults.string(forKey: activeActivityNameKey), legacyActivityName]
                        .compactMap { $0 }
            )
            if !targets.isEmpty { stopMonitoring(targets) }
            defaults.removeObject(forKey: activeActivityNameKey)
            _ = persistLifecycle(
                .init(active: nil, pending: nil, isStopped: true),
                defaults: defaults
            )
            return
        }
        var targets = lifecycle.retiringActivityNames
        if let pending = lifecycle.pending,
           !targets.contains(pending.activityName) {
            targets.insert(pending.activityName, at: 0)
        }
        guard !targets.isEmpty else { return }
        stopMonitoring(targets)
        lifecycle.pending = nil
        lifecycle.retiringActivityNames = []
        if lifecycle.active == nil { lifecycle.isStopped = true }
        _ = persistLifecycle(lifecycle, defaults: defaults)
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

    static func stopTargets(lifecycle: Lifecycle?) -> [String] {
        var targets: [String] = []
        ([lifecycle?.pending?.activityName]
            + (lifecycle?.retiringActivityNames.map(Optional.some) ?? [])
            + [lifecycle?.active?.activityName, legacyActivityName]).forEach { name in
            guard let name, !name.isEmpty, !targets.contains(name) else { return }
            targets.append(name)
        }
        return targets
    }

    static func loadBreadcrumbs(defaults: UserDefaults?) -> [String] {
        uniqueTargets(defaults?.stringArray(forKey: lifecycleBreadcrumbsKey) ?? [])
    }

    private static func uniqueTargets(_ names: [String]) -> [String] {
        var result: [String] = []
        for name in names where isEarnedActivityName(name) && !result.contains(name) {
            result.append(name)
        }
        return result
    }

    @discardableResult
    static func installReplacement(
        _ next: Generation,
        defaults: UserDefaults?,
        startMonitoring: (String) throws -> Void,
        stopMonitoring: ([String]) -> Void,
        persistLifecycle: (Lifecycle, UserDefaults?) -> Bool = { lifecycle, defaults in
            EarnedActivityGeneration.persistLifecycle(lifecycle, defaults: defaults)
        }
    ) -> Bool {
        guard next.isValid,
              next.activityName.hasPrefix(generatedActivityPrefix)
        else { return false }

        recoverPending(defaults: defaults, stopMonitoring: stopMonitoring)
        let previousLifecycle = loadLifecycle(defaults: defaults)
        let previousBreadcrumbs = defaults?.stringArray(forKey: lifecycleBreadcrumbsKey)
        let previousActiveName = defaults?.string(forKey: activeActivityNameKey)
        var pendingLifecycle = previousLifecycle
            ?? Lifecycle(active: nil, pending: nil, retiringActivityNames: [])
        pendingLifecycle.pending = next
        pendingLifecycle.isStopped = false
        guard persistLifecycle(pendingLifecycle, defaults) else { return false }

        func restorePreviousState() {
            let rollback = previousLifecycle
                ?? Lifecycle(active: nil, pending: nil, isStopped: true)
            if persistLifecycle(rollback, defaults) {
                if let previousBreadcrumbs {
                    defaults?.set(previousBreadcrumbs, forKey: lifecycleBreadcrumbsKey)
                } else {
                    defaults?.removeObject(forKey: lifecycleBreadcrumbsKey)
                }
                if let previousActiveName {
                    defaults?.set(previousActiveName, forKey: activeActivityNameKey)
                } else {
                    defaults?.removeObject(forKey: activeActivityNameKey)
                }
                _ = defaults?.synchronize()
                return
            }
            _ = EarnedActivityGeneration.persistLifecycle(
                .init(active: nil, pending: nil, isStopped: true),
                defaults: defaults
            )
            defaults?.removeObject(forKey: activeActivityNameKey)
            _ = defaults?.synchronize()
        }
        do {
            try startMonitoring(next.activityName)
        } catch {
            stopMonitoring([next.activityName])
            restorePreviousState()
            return false
        }

        guard var lifecycle = loadLifecycle(defaults: defaults),
              lifecycle.pending == next
        else {
            stopMonitoring([next.activityName])
            restorePreviousState()
            return false
        }
        let previous = lifecycle.active
        let targets = stopTargets(activeActivityName: previous?.activityName)
            .filter { $0 != next.activityName }
        lifecycle.active = next
        lifecycle.pending = nil
        lifecycle.retiringActivityNames = targets
        lifecycle.isStopped = false
        guard persistLifecycle(lifecycle, defaults) else {
            stopMonitoring([next.activityName])
            restorePreviousState()
            return false
        }
        defaults?.set(next.activityName, forKey: activeActivityNameKey)
        defaults?.synchronize()

        if !targets.isEmpty {
            stopMonitoring(targets)
        }
        if var promoted = loadLifecycle(defaults: defaults),
           promoted.active == next {
            promoted.retiringActivityNames = []
            _ = persistLifecycle(promoted, defaults)
        }
        return true
    }

    @discardableResult
    static func stopPersisted(
        defaults: UserDefaults?,
        stopMonitoring: ([String]) -> Void
    ) -> Bool {
        let lifecycle = loadLifecycle(defaults: defaults)
        let persistedName = defaults?.string(forKey: activeActivityNameKey)
        var targets = uniqueTargets(
            stopTargets(lifecycle: lifecycle)
                + loadBreadcrumbs(defaults: defaults)
        )
        if let persistedName,
           !targets.contains(persistedName),
           isEarnedActivityName(persistedName) {
            targets.insert(persistedName, at: 0)
        }
        guard persistLifecycle(
            .init(
                active: nil,
                pending: nil,
                retiringActivityNames: targets,
                isStopped: true
            ),
            defaults: defaults
        ) else { return false }
        defaults?.removeObject(forKey: activeActivityNameKey)
        defaults?.synchronize()
        stopMonitoring(targets)
        _ = persistLifecycle(
            .init(active: nil, pending: nil, isStopped: true),
            defaults: defaults
        )
        return true
    }
}

nonisolated enum EarnedOverrideCommandApplier {
    enum Outcome: Equatable, Sendable {
        case absent
        case applied(String)
        case invalid
    }

    static func applyIfPresent(
        _ command: LockCommand,
        currentUsageDate: String?,
        store: EarnedTimeStore
    ) -> Outcome {
        guard let usageDate = command.target.earnedOverrideUsageDate else {
            return .absent
        }
        guard command.action == .unshield,
              command.tier == .savedList,
              command.target.unlockSources == ["earned_time"],
              EarnedTimeStore.isCanonicalUsageDate(usageDate),
              currentUsageDate == usageDate
        else { return .invalid }

        store.setOverride(true, forUsageDate: usageDate)
        return .applied(usageDate)
    }
}

nonisolated private enum EarnedLockOutcome<Value> {
    case acquired(Value)
    case unavailable(stage: String, code: Int32)
}

nonisolated private enum EarnedTransactionOutcome<Value> {
    case committed(Value)
    case unavailable(stage: String, code: Int32)
}

nonisolated private final class EarnedReconciliationLock: @unchecked Sendable {
    private static let fallback = NSLock()
    private let selection: EarnedTimeStore.ReconciliationLockSelection
    private let useInProcessLock: Bool

    init(
        selection: EarnedTimeStore.ReconciliationLockSelection,
        useInProcessLock: Bool
    ) {
        self.selection = selection
        self.useInProcessLock = useInProcessLock
    }

    func withLock<T>(_ body: () -> T) -> EarnedLockOutcome<T> {
        if useInProcessLock { Self.fallback.lock() }
        defer { if useInProcessLock { Self.fallback.unlock() } }
        switch selection {
        case .inProcess:
            return .acquired(body())
        case .unavailable(let reason):
            return .unavailable(stage: reason, code: 0)
        case .file(let url):
            let descriptor = open(
                url.path,
                O_CREAT | O_RDWR | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
            guard descriptor >= 0 else {
                return .unavailable(stage: "open", code: errno)
            }
            guard flock(descriptor, LOCK_EX) == 0 else {
                let code = errno
                close(descriptor)
                return .unavailable(stage: "flock", code: code)
            }
            defer {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            return .acquired(body())
        }
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
    static let appGroupSuiteName = "group.com.evlin.ios"
    static let reconciliationLockFailureKey = "earned.reconciliationLockFailure"
    static let reconciliationSynchronizeDiagnosticKey =
        "earned.reconciliationSynchronizeDiagnostic"
    static let shared = EarnedTimeStore()

    enum ReconciliationLockSelection: Equatable, Sendable {
        case file(URL)
        case inProcess
        case unavailable(String)
    }

    struct UsageContext: Equatable, Sendable {
        let usageDate: String
        let timezoneIdentifier: String
    }

    enum AcceptedUsageReconciliation: Equatable {
        case reconciled(Int)
        case stale(acceptedUsageDate: String)
        case identityMismatch
        case lockUnavailable
    }

    enum RuntimePolicyReconciliation: Equatable {
        case reconciled(Int)
        case runtimeUnavailable
        case stale(acceptedUsageDate: String)
        case invalid
        case lockUnavailable
    }

    enum LocalThresholdReconciliation: Equatable {
        case reconciled
        case identityMismatch
        case lockUnavailable
    }

    private let suiteName: String
    private let defaults: UserDefaults?
    private let verificationDefaultsFactory: (String) -> UserDefaults?
    private let reconciliationLock: EarnedReconciliationLock
    private let synchronizeDefaults: (UserDefaults) -> Bool

    init(
        suiteName: String = EarnedTimeStore.appGroupSuiteName,
        lockSelection: ReconciliationLockSelection? = nil,
        useInProcessLock: Bool = true,
        defaultsFactory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) },
        verificationDefaultsFactory: @escaping (String) -> UserDefaults? = {
            UserDefaults(suiteName: $0)
        },
        synchronizeDefaults: @escaping (UserDefaults) -> Bool = { $0.synchronize() }
    ) {
        self.suiteName = suiteName
        defaults = defaultsFactory(suiteName)
        self.verificationDefaultsFactory = verificationDefaultsFactory
        self.synchronizeDefaults = synchronizeDefaults
        let containerURL = suiteName == Self.appGroupSuiteName
            ? FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: Self.appGroupSuiteName
            )
            : nil
        reconciliationLock = EarnedReconciliationLock(
            selection: lockSelection ?? Self.reconciliationLockSelection(
                suiteName: suiteName,
                containerURL: containerURL
            ),
            useInProcessLock: useInProcessLock
        )
    }

    static func reconciliationLockSelection(
        suiteName: String,
        containerURL: URL?
    ) -> ReconciliationLockSelection {
        guard suiteName == appGroupSuiteName else {
            return .inProcess
        }
        guard let containerURL else { return .unavailable("missing_app_group_container") }
        return .file(containerURL.appendingPathComponent("earned-runtime.lock"))
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
    private let runtimeTimezoneKey = "earned.runtimeTimezoneIdentifier"
    private let runtimePolicyRevisionKey = "earned.runtimePolicyRevision"
    private let poolKey          = "earned.poolMinutes"
    private let capKey           = "earned.capMinutes"
    private let usageCountingAllowedKey = "evlin.usageCountingAllowed"
    private let authoritativeStateReadyDeviceIDKey = "evlin.earned.authoritativeReadyDeviceID"
    private let meteringCoverageStatusKey = "evlin.earned.meteringCoverageStatus"
    private let meteringReadyThroughUsageDateKey = "evlin.earned.meteringReadyThroughUsageDate"
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
        hasMeasurableSelection && lockedSetID != nil && isMeteringCoverageReady
    }

    var meteringCoverageStatus: MonitorCoverageStatus? {
        defaults?.string(forKey: meteringCoverageStatusKey)
            .flatMap(MonitorCoverageStatus.init(rawValue:))
    }

    var meteringReadyThroughUsageDate: String? {
        defaults?.string(forKey: meteringReadyThroughUsageDateKey)
    }

    /// Missing coverage is the wire-compatible v1 state. Explicit exhaustion
    /// is the only state that makes production readiness false; installLimited
    /// still measures every date through its verified ready-through value.
    var isMeteringCoverageReady: Bool {
        meteringCoverageStatus != .coverageExhausted
    }

    func reconcileMeteringCoverage(_ coverage: MonitorCoverageState?) {
        if let coverage {
            defaults?.set(coverage.status.rawValue, forKey: meteringCoverageStatusKey)
            if let readyThrough = coverage.readyThroughUsageDate {
                defaults?.set(readyThrough, forKey: meteringReadyThroughUsageDateKey)
            } else {
                defaults?.removeObject(forKey: meteringReadyThroughUsageDateKey)
            }
        } else {
            defaults?.removeObject(forKey: meteringCoverageStatusKey)
            defaults?.removeObject(forKey: meteringReadyThroughUsageDateKey)
        }
        defaults?.synchronize()
    }

    func markAuthoritativeStateReady(deviceID: UUID) {
        defaults?.set(
            deviceID.uuidString.lowercased(),
            forKey: authoritativeStateReadyDeviceIDKey
        )
        defaults?.synchronize()
    }

    func clearAuthoritativeStateReadiness() {
        defaults?.removeObject(forKey: authoritativeStateReadyDeviceIDKey)
        defaults?.synchronize()
    }

    func isAuthoritativeStateReady(deviceID: UUID) -> Bool {
        EarnedActivityGeneration.canonicalDeviceID(
            defaults?.string(forKey: authoritativeStateReadyDeviceIDKey)
        ) == deviceID.uuidString.lowercased()
    }

    // MARK: - All-category measurement selection

    /// The `FamilyActivityPicker`-captured selection that covers the whole
    /// device (all categories). Nil until the one-time capture flow completes.
    var measurementSelection: FamilyActivitySelection? {
        guard let data = measurementSelectionBytes else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    var measurementSelectionBytes: Data? {
        defaults?.data(forKey: measurementKey)
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

    func restoreLockedSetIDIfCurrent(
        _ expectedCurrentID: String,
        priorID: String?,
        priorTokenData: Data?
    ) {
        guard lockedSetID?.caseInsensitiveCompare(expectedCurrentID) == .orderedSame else {
            return
        }
        if let priorID {
            saveLockedSetID(priorID, tokenData: priorTokenData)
        } else {
            defaults?.removeObject(forKey: lockedSetIDKey)
            defaults?.removeObject(forKey: lockedSetDataKey)
            defaults?.synchronize()
        }
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
        if let defaults {
            if value {
                defaults.set(true, forKey: overrideKey(for: usageDate))
            } else {
                defaults.removeObject(forKey: overrideKey(for: usageDate))
            }
            _ = synchronizeDefaults(defaults)
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

    var runtimeTimezoneIdentifier: String? {
        guard let identifier = defaults?.string(forKey: runtimeTimezoneKey),
              TimeZone(identifier: identifier) != nil
        else { return nil }
        return identifier
    }

    var runtimePolicyRevision: String? {
        guard let revision = defaults?.string(forKey: runtimePolicyRevisionKey),
              !revision.isEmpty else { return nil }
        return revision
    }

    func currentCanonicalPolicyUsageDate(now: Date = Date()) -> String? {
        guard let timezoneIdentifier = runtimeTimezoneIdentifier,
              let timeZone = TimeZone(identifier: timezoneIdentifier)
        else { return nil }
        return Self.appLimitUsageDate(now: now, timeZone: timeZone)
    }

    func usageContext(
        now: Date = Date(),
        fallbackTimeZone: TimeZone = .current
    ) -> UsageContext {
        let timezoneIdentifier = runtimeTimezoneIdentifier ?? fallbackTimeZone.identifier
        let timeZone = TimeZone(identifier: timezoneIdentifier) ?? fallbackTimeZone
        let usageDate: String
        if let acceptedUsageDate,
           Self.isCanonicalUsageDate(acceptedUsageDate) {
            usageDate = acceptedUsageDate
        } else {
            usageDate = Self.appLimitUsageDate(now: now, timeZone: timeZone)
        }
        return UsageContext(
            usageDate: usageDate,
            timezoneIdentifier: timeZone.identifier
        )
    }

    func currentPolicyDateContext(
        now: Date = Date(),
        fallbackTimeZone: TimeZone = .current
    ) -> UsageContext {
        let timezoneIdentifier = runtimeTimezoneIdentifier ?? fallbackTimeZone.identifier
        let timeZone = TimeZone(identifier: timezoneIdentifier) ?? fallbackTimeZone
        return UsageContext(
            usageDate: Self.appLimitUsageDate(now: now, timeZone: timeZone),
            timezoneIdentifier: timeZone.identifier
        )
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

    func recordLocalThresholdEstimate(
        _ estimatedMinutes: Int,
        expectedDeviceID: UUID? = nil,
        expectedGeneration: EarnedActivityGeneration.Generation? = nil,
        beforeCommit: () -> Void = {}
    ) -> LocalThresholdReconciliation {
        let committed: LocalThresholdReconciliation? = withReconciliationTransaction(
            rollbackKeys: [estimateKey],
            expectedDeviceID: expectedDeviceID,
            identityMismatchValue: { .identityMismatch },
            authorizationIsCurrent: {
                guard let expectedGeneration else { return true }
                return EarnedActivityGeneration.isAuthorized(
                    generation: expectedGeneration,
                    defaults: self.defaults
                )
            },
            beforeCommit: beforeCommit
        ) {
            let estimate = min(1_440, max(0, estimatedMinutes))
            let current = defaults?.integer(forKey: estimateKey) ?? 0
            defaults?.set(max(current, estimate), forKey: estimateKey)
            return .reconciled
        }
        return committed ?? .lockUnavailable
    }

    private func mirrorMatches(_ expectedDeviceID: UUID?) -> Bool {
        guard let expectedDeviceID else { return true }
        return EarnedActivityGeneration.canonicalDeviceID(
            defaults?.string(forKey: "evlin.childId")
        ) == expectedDeviceID.uuidString.lowercased()
    }

    @discardableResult
    func reconcileAcceptedUsage(
        usageDate: String,
        serverEstimatedMinutes: Int
    ) -> Int {
        withReconciliationTransaction(rollbackKeys: acceptedUsageRollbackKeys) {
            reconcileAcceptedUsageLocked(
                usageDate: usageDate,
                serverEstimatedMinutes: serverEstimatedMinutes
            )
        } ?? (acceptedEstimateMinutes ?? 0)
    }

    func reconcileAcceptedUsageIfNotStale(
        usageDate: String,
        serverEstimatedMinutes: Int,
        expectedDeviceID: UUID? = nil,
        beforeCommit: () -> Void = {}
    ) -> AcceptedUsageReconciliation {
        withReconciliationTransaction(
            rollbackKeys: acceptedUsageRollbackKeys,
            expectedDeviceID: expectedDeviceID,
            identityMismatchValue: { .identityMismatch },
            beforeCommit: beforeCommit
        ) {
            if let currentDate = acceptedUsageDate,
               Self.isCanonicalUsageDate(currentDate),
               usageDate < currentDate {
                return .stale(acceptedUsageDate: currentDate)
            }
            return .reconciled(reconcileAcceptedUsageLocked(
                usageDate: usageDate,
                serverEstimatedMinutes: serverEstimatedMinutes
            ))
        } ?? .lockUnavailable
    }

    func reconcileRuntimePolicy(
        usageDate: String,
        timezoneIdentifier: String,
        poolMinutes: Int,
        capMinutes: Int,
        remainingMinutes: Int,
        estimatedMinutes: Int,
        policyRevision: String = "",
        syncedAt: Date = Date()
    ) -> RuntimePolicyReconciliation {
        withReconciliationTransaction(rollbackKeys: runtimePolicyRollbackKeys) {
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
            defaults?.set(timezoneIdentifier, forKey: runtimeTimezoneKey)
            if !policyRevision.isEmpty {
                defaults?.set(policyRevision, forKey: runtimePolicyRevisionKey)
            } else {
                defaults?.removeObject(forKey: runtimePolicyRevisionKey)
            }
            backendRemainingAtLastSync = remainingMinutes
            lastBackendSyncAt = syncedAt
            let accepted = reconcileAcceptedUsageLocked(
                usageDate: usageDate,
                serverEstimatedMinutes: estimatedMinutes
            )
            return .reconciled(accepted)
        } ?? .lockUnavailable
    }

    private var acceptedUsageRollbackKeys: [String] {
        [acceptedUsageDateKey, acceptedEstimateKey, estimateKey]
    }

    private var runtimePolicyRollbackKeys: [String] {
        [
            poolKey, capKey, runtimeTimezoneKey, runtimePolicyRevisionKey,
            backendKey, lastBackendSyncAtKey,
            acceptedUsageDateKey, acceptedEstimateKey, estimateKey,
        ]
    }

    @discardableResult
    private func withReconciliationTransaction<T>(
        rollbackKeys: [String] = [],
        expectedDeviceID: UUID? = nil,
        identityMismatchValue: (() -> T)? = nil,
        authorizationIsCurrent: (() -> Bool)? = nil,
        beforeCommit: () -> Void = {},
        _ body: () -> T
    ) -> T? {
        let outcome = reconciliationLock.withLock {
            guard let defaults else {
                return EarnedTransactionOutcome<T>.unavailable(
                    stage: "defaults_unavailable",
                    code: 0
                )
            }
            if !synchronizeDefaults(defaults) {
                recordReconciliationDiagnostic(stage: "pre_synchronize_nonfatal")
            }
            let isAuthorized = {
                self.mirrorMatches(expectedDeviceID)
                    && (authorizationIsCurrent?() ?? true)
            }
            if !isAuthorized(), let identityMismatchValue {
                return EarnedTransactionOutcome<T>.committed(identityMismatchValue())
            }
            let before = snapshotDefaults(defaults, keys: rollbackKeys)
            let value = body()
            let written = snapshotDefaults(defaults, keys: rollbackKeys)
            beforeCommit()
            if !isAuthorized(), let identityMismatchValue {
                restoreDefaults(
                    defaults,
                    from: before,
                    whereCurrentMatches: written
                )
                defaults.synchronize()
                return EarnedTransactionOutcome<T>.committed(identityMismatchValue())
            }
            if !synchronizeDefaults(defaults) {
                recordReconciliationDiagnostic(stage: "post_synchronize_nonfatal")
            }
            guard verificationMatches(written) else {
                restoreDefaults(
                    defaults,
                    from: before,
                    whereCurrentMatches: written
                )
                defaults.synchronize()
                return EarnedTransactionOutcome<T>.unavailable(
                    stage: "post_write_readback",
                    code: 0
                )
            }
            if !isAuthorized(), let identityMismatchValue {
                restoreDefaults(
                    defaults,
                    from: before,
                    whereCurrentMatches: written
                )
                defaults.synchronize()
                return EarnedTransactionOutcome<T>.committed(identityMismatchValue())
            }
            return .committed(value)
        }
        switch outcome {
        case .acquired(.committed(let value)):
            return value
        case .acquired(.unavailable(let stage, let code)),
             .unavailable(let stage, let code):
            recordReconciliationFailure(stage: stage, code: code)
            return nil
        }
    }

    private struct DefaultsSnapshotValue {
        let key: String
        let value: Any?
    }

    private func snapshotDefaults(
        _ defaults: UserDefaults,
        keys: [String]
    ) -> [DefaultsSnapshotValue] {
        keys.map { DefaultsSnapshotValue(key: $0, value: defaults.object(forKey: $0)) }
    }

    private func verificationMatches(_ written: [DefaultsSnapshotValue]) -> Bool {
        guard !written.isEmpty else { return true }
        guard let verificationDefaults = verificationDefaultsFactory(suiteName) else {
            return false
        }
        return written.allSatisfy { entry in
            defaultsValuesEqual(
                verificationDefaults.object(forKey: entry.key),
                entry.value
            )
        }
    }

    private func restoreDefaults(
        _ defaults: UserDefaults,
        from before: [DefaultsSnapshotValue],
        whereCurrentMatches written: [DefaultsSnapshotValue]
    ) {
        for prior in before {
            let expectedWritten = written.first { $0.key == prior.key }?.value
            guard defaultsValuesEqual(
                defaults.object(forKey: prior.key),
                expectedWritten
            ) else { continue }
            if let value = prior.value {
                defaults.set(value, forKey: prior.key)
            } else {
                defaults.removeObject(forKey: prior.key)
            }
        }
    }

    private func defaultsValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let left?, let right?):
            return (left as AnyObject).isEqual(right)
        }
    }

    private func recordReconciliationFailure(stage: String, code: Int32) {
        let diagnostic = "\(ISO8601DateFormatter().string(from: Date())) stage=\(stage) errno=\(code)"
        defaults?.set(diagnostic, forKey: Self.reconciliationLockFailureKey)
        defaults?.synchronize()
        NSLog("[Evlin/Earned] reconciliation lock unavailable %@", diagnostic)
    }

    private func recordReconciliationDiagnostic(stage: String) {
        let diagnostic = "\(ISO8601DateFormatter().string(from: Date())) stage=\(stage) errno=0"
        defaults?.set(diagnostic, forKey: Self.reconciliationSynchronizeDiagnosticKey)
        NSLog("[Evlin/Earned] reconciliation synchronize diagnostic %@", diagnostic)
    }

    func reconciliationLockIsAvailable() -> Bool {
        withReconciliationTransaction { true } ?? false
    }

    func withReconciliationLockForTesting(_ body: () -> Void) -> Bool {
        withReconciliationTransaction {
            body()
            return true
        } ?? false
    }

    private func reconcileAcceptedUsageLocked(
        usageDate: String,
        serverEstimatedMinutes: Int
    ) -> Int {
        let server = max(0, serverEstimatedMinutes)
        let sameDay = acceptedUsageDate == usageDate
        let accepted = sameDay ? max(acceptedEstimateMinutes ?? 0, server) : server
        acceptedUsageDate = usageDate
        acceptedEstimateMinutes = accepted
        if !sameDay {
            latestDeviceEstimate = accepted
        } else {
            latestDeviceEstimate = max(latestDeviceEstimate ?? 0, accepted)
        }
        defaults?.synchronize()
        return accepted
    }

    static func isCanonicalUsageDate(_ value: String) -> Bool {
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
         acceptedEstimateKey, runtimeTimezoneKey, runtimePolicyRevisionKey,
         poolKey, capKey, usageCountingAllowedKey,
         authoritativeStateReadyDeviceIDKey, meteringCoverageStatusKey,
         meteringReadyThroughUsageDateKey, earnedUsageOffsetKey].forEach {
            defaults?.removeObject(forKey: $0)
        }
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
