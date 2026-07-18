import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    /// Broadcast by ChatViewModel after a successful /parent/agent/exec so
    /// any active BigKidStatePoller refreshes right away. Without this the
    /// kid would have to wait up to one poll interval to see a reflection
    /// the parent just confirmed in chat.
    static let bigKidStateInvalidated = Notification.Name("bigKidStateInvalidated")
}

/// Polls `/child/state` every 10s while app is foregrounded; refreshes
/// immediately on `scenePhase == .active` transitions and on the
/// `bigKidStateInvalidated` notification. Hands snapshots to
/// `BigKidState` via the `apply(_:)` method.
@MainActor
final class BigKidStatePoller: ObservableObject {
    @Published var lastError: String?
    @Published var lastFetchedAt: Date?

    /// Plan 8 (§15.3): set once the kid's family was deleted (terminal
    /// `410 family_removed`). After this the loop stops and the poller is inert
    /// — a deleted family must never keep polling or re-arm a lock.
    @Published private(set) var familyRemoved = false

    private let client: BigKidAPIClient
    private let state: BigKidState
    private let expectedChildID: UUID?
    private let currentChildID: () -> UUID?
    private let fetchState: () async throws -> ChildStateResponse
    private let reconcileReflectionLock: (ChildStateResponse) async -> Void
    private let reconcileIdentityTransition: () -> Bool
    private let applySnapshot: (ChildStateResponse, BigKidState) -> Void
    private let mirrorChildIdentity: (UUID) -> Void
    private let syncEarnedRuntime: (EarnedTimeRuntime?) -> EarnedTimeStore.RuntimePolicyReconciliation
    private let setUsageCountingAllowed: (Bool) -> Bool
    private let reconcileMeteringRuntime: (Bool, EarnedTimeRuntime?) async -> Void
    private let markAuthoritativeReady: (UUID) -> Void
    private let clearAuthoritativeReadiness: () -> Void
    private let ensureEarnedArmed: () -> Void
    private let rearmUsageCounters: () -> Bool
    private let stopUsageCounters: () -> Void
    private let isCounterRecoveryRequired: (UUID) -> Bool
    private let setCounterRecoveryRequired: (UUID, Bool) -> Void
    private let reportEffectiveState: () async -> Void
    private let failOpenFamily: () async -> Void
    private let requestFreshPoll: () -> Void
    private var task: Task<Void, Never>?
    private var invalidationObserver: NSObjectProtocol?
    private var isFetchInFlight = false
    private var pendingRefreshAfterCurrent = false
    private var requiresCounterRecovery = false
    private var requestedRefreshForIdentityMismatch = false

    /// Reflection Lockdown glue. Runs after each state apply: reconciles the
    /// dedicated reflection ShieldRecord against the snapshot, schedules its
    /// DAM auto-removal, and records (never swallows) a schedule failure.
    private let reflectionLockApplier = ReflectionLockApplier(
        scheduler: LockScheduler(activityScheduler: DeviceActivityCenterScheduler()),
        currentChildID: {
            UserDefaults.standard.string(forKey: CommandPoller.childDeviceIDDefaultsKey)
                .flatMap(UUID.init(uuidString:))
        }
    )

    /// Polling cadence. 10s keeps a foregrounded kid device's worst-case
    /// reflection-delivery latency under ten seconds without explicit
    /// triggering, while still being polite to the backend. The
    /// `bigKidStateInvalidated` notification path and the scene-active
    /// `refreshNow()` in BigKidRootView cover the same-device
    /// parent→kid mode-toggle and foreground-return cases more tightly.
    private static let pollIntervalNanoseconds: UInt64 = 10_000_000_000

    init(client: BigKidAPIClient, state: BigKidState) {
        self.client = client
        self.state = state
        self.expectedChildID = client.childId
        self.currentChildID = {
            UserDefaults.standard.string(forKey: CommandPoller.childDeviceIDDefaultsKey)
                .flatMap(UUID.init(uuidString:))
        }
        self.fetchState = { try await client.fetchState() }
        let reflectionLockApplier = self.reflectionLockApplier
        self.reconcileReflectionLock = { snapshot in
            await reflectionLockApplier.reconcile(snapshot: snapshot, childID: client.childId)
        }
        self.reconcileIdentityTransition = {
            EarnedBudgetArming.reconcileIdentityTransition()
        }
        self.applySnapshot = { snapshot, state in
            state.apply(snapshot)
        }
        self.mirrorChildIdentity = { childID in
            EarnedBudgetArming.mirrorChildIdentity(childID, epochStore: .shared)
        }
        self.syncEarnedRuntime = Self.syncEarnedRuntimeFromSnapshot
        self.setUsageCountingAllowed = Self.writeUsageCountingAllowed
        self.reconcileMeteringRuntime = { allowed, runtime in
            do {
                try await MeteringProductionComposition.recoverFromSharedConfiguration(
                    role: .app,
                    runtime: runtime,
                    usageCountingAllowed: allowed
                )
            } catch {
                print("[BigKidStatePoller] metering epoch reconciliation failed: \(error)")
            }
        }
        self.markAuthoritativeReady = {
            EarnedTimeStore.shared.markAuthoritativeStateReady(deviceID: $0)
        }
        self.clearAuthoritativeReadiness = {
            EarnedTimeStore.shared.clearAuthoritativeStateReadiness()
        }
        self.ensureEarnedArmed = { EarnedBudgetArming.armIfReady() }
        self.rearmUsageCounters = Self.rearmOtherUsageCountersFromStoredPolicy
        self.stopUsageCounters = Self.stopUsageCountersForTaskPause
        self.isCounterRecoveryRequired = {
            EarnedTimeStore.shared.isCounterRecoveryRequired(deviceID: $0)
        }
        self.setCounterRecoveryRequired = {
            EarnedTimeStore.shared.setCounterRecoveryRequired($1, deviceID: $0)
        }
        self.reportEffectiveState = {
            guard let snapshot = await CommandPoller.globalEffectiveStateDictionary() else { return }
            do {
                try await client.reportHeartbeat(globalEffectiveState: snapshot)
            } catch {
                print("[BigKidStatePoller] report effective state failed: \(error)")
            }
        }
        self.failOpenFamily = { await FamilyGoneDetector.failOpen() }
        self.requestFreshPoll = {
            NotificationCenter.default.post(name: .bigKidStateInvalidated, object: nil)
        }
    }

    init(
        state: BigKidState,
        expectedChildID: UUID? = nil,
        currentChildID: @escaping () -> UUID? = { nil },
        fetchState: @escaping () async throws -> ChildStateResponse,
        reconcileReflectionLock: @escaping (ChildStateResponse) async -> Void,
        reconcileIdentityTransition: @escaping () -> Bool = { false },
        applySnapshot: @escaping (ChildStateResponse, BigKidState) -> Void = { snapshot, state in
            state.apply(snapshot)
        },
        mirrorChildIdentity: @escaping (UUID) -> Void = { _ in },
        syncEarnedRuntime: @escaping (EarnedTimeRuntime?) -> EarnedTimeStore.RuntimePolicyReconciliation = BigKidStatePoller.syncEarnedRuntimeFromSnapshot,
        setUsageCountingAllowed: @escaping (Bool) -> Bool = BigKidStatePoller.writeUsageCountingAllowed,
        reconcileMeteringRuntime: @escaping (Bool, EarnedTimeRuntime?) async -> Void = { _, _ in },
        markAuthoritativeReady: @escaping (UUID) -> Void = { _ in },
        clearAuthoritativeReadiness: @escaping () -> Void = {},
        ensureEarnedArmed: @escaping () -> Void = {},
        rearmUsageCounters: @escaping () -> Void = {},
        rearmUsageCountersResult: (() -> Bool)? = nil,
        stopUsageCounters: @escaping () -> Void = {},
        isCounterRecoveryRequired: @escaping (UUID) -> Bool = { _ in false },
        setCounterRecoveryRequired: @escaping (UUID, Bool) -> Void = { _, _ in },
        reportEffectiveState: @escaping () async -> Void = {},
        failOpenFamily: @escaping () async -> Void = { await FamilyGoneDetector.failOpen() },
        requestFreshPoll: @escaping () -> Void = {}
    ) {
        self.client = BigKidAPIClient(baseURL: URL(string: "https://example.invalid")!, childId: UUID())
        self.state = state
        self.expectedChildID = expectedChildID
        self.currentChildID = currentChildID
        self.fetchState = fetchState
        self.reconcileReflectionLock = reconcileReflectionLock
        self.reconcileIdentityTransition = reconcileIdentityTransition
        self.applySnapshot = applySnapshot
        self.mirrorChildIdentity = mirrorChildIdentity
        self.syncEarnedRuntime = syncEarnedRuntime
        self.setUsageCountingAllowed = setUsageCountingAllowed
        self.reconcileMeteringRuntime = reconcileMeteringRuntime
        self.markAuthoritativeReady = markAuthoritativeReady
        self.clearAuthoritativeReadiness = clearAuthoritativeReadiness
        self.ensureEarnedArmed = ensureEarnedArmed
        self.rearmUsageCounters = rearmUsageCountersResult ?? {
            rearmUsageCounters()
            return true
        }
        self.stopUsageCounters = stopUsageCounters
        self.isCounterRecoveryRequired = isCounterRecoveryRequired
        self.setCounterRecoveryRequired = setCounterRecoveryRequired
        self.reportEffectiveState = reportEffectiveState
        self.failOpenFamily = failOpenFamily
        self.requestFreshPoll = requestFreshPoll
    }

    deinit {
        if let obs = invalidationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
        if invalidationObserver == nil {
            invalidationObserver = NotificationCenter.default.addObserver(
                forName: .bigKidStateInvalidated, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refreshNow() }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let obs = invalidationObserver {
            NotificationCenter.default.removeObserver(obs)
            invalidationObserver = nil
        }
    }

    /// Force an immediate refresh (e.g. on scenePhase change or after a write).
    func refreshNow() async {
        await fetchOnce()
    }

    private func runLoop() async {
        while !Task.isCancelled && !familyRemoved {
            await fetchOnce()
            if familyRemoved { break }
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
    }

    private func fetchOnce() async {
        guard !isFetchInFlight else {
            pendingRefreshAfterCurrent = true
            return
        }
        isFetchInFlight = true
        defer {
            isFetchInFlight = false
            pendingRefreshAfterCurrent = false
        }

        repeat {
            pendingRefreshAfterCurrent = false
            await performFetchOnce()
        } while pendingRefreshAfterCurrent && !familyRemoved && !Task.isCancelled
    }

    private func performFetchOnce() async {
        let expectedChildID = self.expectedChildID
        guard isExpectedIdentityCurrent(expectedChildID) else {
            requestPollForCurrentIdentity()
            return
        }
        requestedRefreshForIdentityMismatch = false
        // Re-pairing under a new family can happen while the app stays
        // foregrounded (no scene-activation arm pass runs). Catch the identity
        // change here — within one poll tick — so the previous family's ladder
        // is stopped before it can bill usage to the new family.
        _ = reconcileIdentityTransition()
        // The App-Controls roster survives account switches locally but the
        // backend's family-scoped "Locked set" doesn't — re-publish it when
        // the current identity has no backend list yet (cheap no-op otherwise).
        AppControlsBackendSync.pushDefaultLockGroupIfNeeded()
        do {
            let snapshot = try await fetchState()
            guard isExpectedIdentityCurrent(expectedChildID) else {
                requestPollForCurrentIdentity()
                return
            }
            await reconcileReflectionLock(snapshot)
            guard isExpectedIdentityCurrent(expectedChildID) else {
                requestPollForCurrentIdentity()
                return
            }
            if let expectedChildID {
                mirrorChildIdentity(expectedChildID)
            }
            guard isExpectedIdentityCurrent(expectedChildID) else {
                requestPollForCurrentIdentity()
                return
            }
            applySnapshot(snapshot, state)
            let runtimeReconciliation = syncEarnedRuntime(snapshot.earnedTimeRuntime)
            let runtimeIsAuthoritative: Bool
            if runtimeReconciliation == .runtimeUnavailable {
                runtimeIsAuthoritative = false
                clearAuthoritativeReadiness()
            } else if case .reconciled = runtimeReconciliation {
                runtimeIsAuthoritative = true
            } else {
                requiresCounterRecovery = true
                if let expectedChildID {
                    setCounterRecoveryRequired(expectedChildID, true)
                }
                clearAuthoritativeReadiness()
                stopUsageCounters()
                lastError = "Screen time sync deferred"
                print("[BigKidStatePoller] earned runtime reconciliation deferred: \(runtimeReconciliation)")
                return
            }

            let allowed = snapshot.effectiveUsageCountingAllowed
            let wasCountingAllowed = setUsageCountingAllowed(allowed)
            if runtimeIsAuthoritative {
                await reconcileMeteringRuntime(allowed, snapshot.earnedTimeRuntime)
            }
            if runtimeIsAuthoritative, let expectedChildID {
                markAuthoritativeReady(expectedChildID)
            }
            let shouldRecoverSkippedUsage = allowed && Self.hasSkippedUnfinishedUsageEvent()
            if !allowed {
                // A closed task/reflection gate pauses accounting, not Apple's
                // monitors. Keeping the dated routes installed preserves raw
                // high-water so resume can replace the epoch conservatively.
                requiresCounterRecovery = false
                if let expectedChildID {
                    setCounterRecoveryRequired(expectedChildID, false)
                }
            } else {
                if runtimeIsAuthoritative {
                    ensureEarnedArmed()
                }
                let hasDurableRecovery = expectedChildID.map(isCounterRecoveryRequired) ?? false
                if !wasCountingAllowed || shouldRecoverSkippedUsage
                    || requiresCounterRecovery || hasDurableRecovery {
                    if let expectedChildID {
                        setCounterRecoveryRequired(expectedChildID, true)
                    }
                    let recovered = rearmUsageCounters()
                    requiresCounterRecovery = !recovered
                    if let expectedChildID, recovered {
                        setCounterRecoveryRequired(expectedChildID, false)
                    }
                    if shouldRecoverSkippedUsage && recovered {
                        CommandDeliveryDiagnostics.remove(CommandDeliveryDiagnostics.keyUsageCountingLastSkipped)
                    }
                }
            }
            await reportEffectiveState()
            lastFetchedAt = Date()
            lastError = nil
        } catch {
            guard isExpectedIdentityCurrent(expectedChildID) else {
                requestPollForCurrentIdentity()
                return
            }
            // Plan 8 (§15.3): a terminal `410 family_removed` means this kid's
            // family was deleted. FAIL OPEN — release every Evlin shield/block,
            // clear the reflection sticky + reset pairing — then stop the loop so
            // a deleted family can never brick the kid in a permanent lock.
            if FamilyGoneDetector.isFamilyGone(error: error) {
                print("[BigKidStatePoller] family_removed → failing open")
                familyRemoved = true
                await failOpenFamily()
                lastError = nil
                stop()
                return
            }
            print("[BigKidStatePoller] fetchState failed: \(error)")
            lastError = Self.userFacingMessage(for: error)
        }
    }

    private func isExpectedIdentityCurrent(_ expectedChildID: UUID?) -> Bool {
        guard let expectedChildID else { return true }
        return currentChildID() == expectedChildID
    }

    private func requestPollForCurrentIdentity() {
        guard !requestedRefreshForIdentityMismatch else { return }
        requestedRefreshForIdentityMismatch = true
        requestFreshPoll()
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return "Trying to reconnect"
            default:
                return "Couldn't refresh"
            }
        }
        return "Couldn't refresh"
    }

    private static func writeUsageCountingAllowed(_ allowed: Bool) -> Bool {
        let store = EarnedTimeStore.shared
        let previous = store.usageCountingAllowed
        store.usageCountingAllowed = allowed
        return previous
    }

    private static func syncEarnedRuntimeFromSnapshot(
        _ runtime: EarnedTimeRuntime?
    ) -> EarnedTimeStore.RuntimePolicyReconciliation {
        reconcileEarnedRuntime(runtime, store: .shared)
    }

    static func reconcileEarnedRuntime(
        _ runtime: EarnedTimeRuntime?,
        store: EarnedTimeStore
    ) -> EarnedTimeStore.RuntimePolicyReconciliation {
        guard let runtime else {
            return store.reconciliationLockIsAvailable()
                ? .runtimeUnavailable
                : .lockUnavailable
        }
        if runtime.dailyPoolMinutes == 0 || runtime.deviceCapMinutes == 0 {
            return store.reconciliationLockIsAvailable()
                ? .runtimeUnavailable
                : .lockUnavailable
        }
        return store.reconcileRuntimePolicy(
            usageDate: runtime.usageDate,
            timezoneIdentifier: runtime.timezone,
            poolMinutes: runtime.dailyPoolMinutes,
            capMinutes: runtime.deviceCapMinutes,
            remainingMinutes: runtime.remainingMinutes,
            estimatedMinutes: runtime.estimatedMinutes
        )
    }

    private static func hasSkippedUnfinishedUsageEvent() -> Bool {
        CommandDeliveryDiagnostics.read(CommandDeliveryDiagnostics.keyUsageCountingLastSkipped)
            .contains("unfinished_tasks=true")
    }

    private static func stopUsageCountersForTaskPause() {
        stopUsageCounters(
            stopEarned: { EarnedBudgetArming.stopAndInvalidateSignature() },
            stopDeviceTotal: { BigKidActivityScheduler.shared.stop() },
            stopPerApp: { _ = AppLimitPlanner().arm(rules: []) }
        )
    }

    static func stopUsageCounters(
        stopEarned: () -> Void,
        stopDeviceTotal: () -> Void,
        stopPerApp: () -> Void
    ) {
        stopEarned()
        stopDeviceTotal()
        stopPerApp()
    }

    // Pure seam (Fix 4 test 6): the real pool/cap/offset the re-arm uses.
    nonisolated static func earnedRearmInputs(store: EarnedTimeStore) -> (poolMinutes: Int, capMinutes: Int, offset: Int) {
        let offset = EarnedBudgetArming.replacementOffset(
            acceptedEstimateMinutes: store.acceptedEstimateMinutes,
            runningOffsetMinutes: store.earnedUsageOffsetMinutes
        )
        let pool = store.poolMinutes ?? 60
        let cap  = store.capMinutes ?? pool
        return (pool, cap, offset)
    }

    private static func rearmOtherUsageCountersFromStoredPolicy() -> Bool {
        let store = EarnedTimeStore.shared

        let deviceTotalArmed: Bool
        if store.hasMeasurableSelection, let selection = store.measurementSelection {
            deviceTotalArmed = BigKidActivityScheduler.shared.start(appsToMeasure: selection)
        } else {
            deviceTotalArmed = false
        }

        let appLimitUsageDate = EarnedTimeStore.appLimitUsageDate()
        let adjustedRules = AppLimitRuleStore.shared.all().compactMap { rule -> AppLimitRule? in
            let used = max(
                store.appLimitUsageOffsetMinutes(
                    ruleID: rule.id,
                    usageDate: appLimitUsageDate
                ),
                store.appLimitReportedMinutes(
                    ruleID: rule.id,
                    usageDate: appLimitUsageDate
                )
            )
            store.setAppLimitUsageOffset(
                ruleID: rule.id,
                usageDate: appLimitUsageDate,
                usedMinutes: used
            )
            let remaining = rule.budgetMinutes - used
            guard remaining > 0 else { return nil }
            return AppLimitRule(
                id: rule.id,
                appTokens: rule.appTokens,
                bundleID: rule.bundleID,
                displayName: rule.displayName,
                budgetMinutes: remaining,
                window: rule.window,
                effectiveFrom: rule.effectiveFrom,
                expiresAt: rule.expiresAt
            )
        }
        let perAppResult = AppLimitPlanner().arm(rules: adjustedRules)
        return counterRearmSucceeded(
            deviceTotalArmed: deviceTotalArmed,
            perAppResult: perAppResult
        )
    }

    nonisolated static func counterRearmSucceeded(
        deviceTotalArmed: Bool,
        perAppResult: AppLimitPlanResult
    ) -> Bool {
        guard deviceTotalArmed else { return false }
        switch perAppResult {
        case .armed:
            return true
        case .partiallyArmed, .quotaExceeded:
            return false
        }
    }
}
