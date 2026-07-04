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
    private let fetchState: () async throws -> ChildStateResponse
    private let reconcileReflectionLock: (ChildStateResponse) async -> Void
    private let applySnapshot: (ChildStateResponse, BigKidState) -> Void
    private let setUsageCountingAllowed: (Bool) -> Bool
    private let rearmUsageCounters: () -> Void
    private let stopUsageCounters: () -> Void
    private let reportEffectiveState: () async -> Void
    private var task: Task<Void, Never>?
    private var invalidationObserver: NSObjectProtocol?

    /// Reflection Lockdown glue. Runs after each state apply: reconciles the
    /// dedicated reflection ShieldRecord against the snapshot, schedules its
    /// DAM auto-removal, and records (never swallows) a schedule failure.
    private let reflectionLockApplier = ReflectionLockApplier(
        scheduler: LockScheduler(activityScheduler: DeviceActivityCenterScheduler()))

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
        self.fetchState = { try await client.fetchState() }
        let reflectionLockApplier = self.reflectionLockApplier
        self.reconcileReflectionLock = { snapshot in
            if let raw = UserDefaults.standard.string(forKey: CommandPoller.childDeviceIDDefaultsKey),
               let childID = UUID(uuidString: raw) {
                await reflectionLockApplier.reconcile(snapshot: snapshot, childID: childID)
            }
        }
        self.applySnapshot = { snapshot, state in
            state.apply(snapshot)
        }
        self.setUsageCountingAllowed = Self.writeUsageCountingAllowed
        self.rearmUsageCounters = Self.rearmUsageCountersFromStoredPolicy
        self.stopUsageCounters = Self.stopUsageCountersForTaskPause
        self.reportEffectiveState = {
            guard let snapshot = await CommandPoller.globalEffectiveStateDictionary() else { return }
            do {
                try await client.reportHeartbeat(globalEffectiveState: snapshot)
            } catch {
                print("[BigKidStatePoller] report effective state failed: \(error)")
            }
        }
    }

    init(
        state: BigKidState,
        fetchState: @escaping () async throws -> ChildStateResponse,
        reconcileReflectionLock: @escaping (ChildStateResponse) async -> Void,
        applySnapshot: @escaping (ChildStateResponse, BigKidState) -> Void = { snapshot, state in
            state.apply(snapshot)
        },
        setUsageCountingAllowed: @escaping (Bool) -> Bool = BigKidStatePoller.writeUsageCountingAllowed,
        rearmUsageCounters: @escaping () -> Void = {},
        stopUsageCounters: @escaping () -> Void = {},
        reportEffectiveState: @escaping () async -> Void = {}
    ) {
        self.client = BigKidAPIClient(baseURL: URL(string: "https://example.invalid")!, childId: UUID())
        self.state = state
        self.fetchState = fetchState
        self.reconcileReflectionLock = reconcileReflectionLock
        self.applySnapshot = applySnapshot
        self.setUsageCountingAllowed = setUsageCountingAllowed
        self.rearmUsageCounters = rearmUsageCounters
        self.stopUsageCounters = stopUsageCounters
        self.reportEffectiveState = reportEffectiveState
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
        // Re-pairing under a new family can happen while the app stays
        // foregrounded (no scene-activation arm pass runs). Catch the identity
        // change here — within one poll tick — so the previous family's ladder
        // is stopped before it can bill usage to the new family.
        if EarnedBudgetArming.reconcileIdentityTransition() {
            EarnedBudgetArming.armIfReady()
        }
        // The App-Controls roster survives account switches locally but the
        // backend's family-scoped "Locked set" doesn't — re-publish it when
        // the current identity has no backend list yet (cheap no-op otherwise).
        AppControlsBackendSync.pushDefaultLockGroupIfNeeded()
        do {
            let snapshot = try await fetchState()
            await reconcileReflectionLock(snapshot)
            applySnapshot(snapshot, state)
            let wasCountingAllowed = setUsageCountingAllowed(snapshot.usageCountingAllowed)
            let shouldRecoverSkippedUsage = snapshot.usageCountingAllowed
                && Self.hasSkippedUnfinishedUsageEvent()
            if !snapshot.usageCountingAllowed && wasCountingAllowed {
                stopUsageCounters()
            }
            if snapshot.usageCountingAllowed && (!wasCountingAllowed || shouldRecoverSkippedUsage) {
                rearmUsageCounters()
                if shouldRecoverSkippedUsage {
                    CommandDeliveryDiagnostics.remove(CommandDeliveryDiagnostics.keyUsageCountingLastSkipped)
                }
            }
            await reportEffectiveState()
            lastFetchedAt = Date()
            lastError = nil
        } catch {
            // Plan 8 (§15.3): a terminal `410 family_removed` means this kid's
            // family was deleted. FAIL OPEN — release every Evlin shield/block,
            // clear the reflection sticky + reset pairing — then stop the loop so
            // a deleted family can never brick the kid in a permanent lock.
            if FamilyGoneDetector.isFamilyGone(error: error) {
                print("[BigKidStatePoller] family_removed → failing open")
                familyRemoved = true
                await FamilyGoneDetector.failOpen()
                lastError = nil
                stop()
                return
            }
            print("[BigKidStatePoller] fetchState failed: \(error)")
            lastError = Self.userFacingMessage(for: error)
        }
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

    private static func hasSkippedUnfinishedUsageEvent() -> Bool {
        CommandDeliveryDiagnostics.read(CommandDeliveryDiagnostics.keyUsageCountingLastSkipped)
            .contains("unfinished_tasks=true")
    }

    private static func stopUsageCountersForTaskPause() {
        EarnedBudgetScheduler.shared.stop()
        BigKidActivityScheduler.shared.stop()
        _ = AppLimitPlanner().arm(rules: [])
    }

    // Pure seam (Fix 4 test 6): the real pool/cap/offset the re-arm uses.
    nonisolated static func earnedRearmInputs(store: EarnedTimeStore) -> (poolMinutes: Int, capMinutes: Int, offset: Int) {
        let offset = max(store.latestDeviceEstimate ?? 0, store.earnedUsageOffsetMinutes)
        let pool = store.poolMinutes ?? 60
        let cap  = store.capMinutes ?? pool
        return (pool, cap, offset)
    }

    private static func rearmUsageCountersFromStoredPolicy() {
        let store = EarnedTimeStore.shared

        if store.isEarnedTimeReady, let selection = store.measurementSelection {
            let inputs = Self.earnedRearmInputs(store: store)
            store.earnedUsageOffsetMinutes = inputs.offset
            // Arm at the REAL pool/cap; the offset is applied by the extension
            // (adjustedN = offset + rawN), so the ladder itself keeps real budgets.
            if min(inputs.poolMinutes, inputs.capMinutes) - inputs.offset > 0 {
                EarnedBudgetScheduler.shared.armFromNow(
                    poolMinutes: inputs.poolMinutes,
                    capMinutes: inputs.capMinutes,
                    selection: selection
                )
            } else {
                CommandDeliveryDiagnostics.record(
                    CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                    "skipped state-poll-no-remaining pool=\(inputs.poolMinutes) cap=\(inputs.capMinutes) offset=\(inputs.offset) \(EarnedBudgetScheduler.selectionSummary(selection))"
                )
            }
        } else {
            let selection = store.measurementSelection
            let summary = selection.map(EarnedBudgetScheduler.selectionSummary) ?? "(missing)"
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped state-poll-not-ready lockedSetID=\(store.lockedSetID ?? "(missing)") \(summary)"
            )
        }

        let adjustedRules = AppLimitRuleStore.shared.all().compactMap { rule -> AppLimitRule? in
            let used = max(
                store.appLimitUsageOffsetMinutes(ruleID: rule.id),
                store.appLimitReportedMinutes(ruleID: rule.id)
            )
            store.setAppLimitUsageOffset(ruleID: rule.id, usedMinutes: used)
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
        _ = AppLimitPlanner().arm(rules: adjustedRules)
    }
}
