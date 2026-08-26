import Foundation
import DeviceActivity
import ManagedSettings
import FamilyControls
import CryptoKit
import UserNotifications

/// Fires when a scheduled shield interval ends. Removes the ShieldRecord from
/// App Group persistence and recomputes shield state for remaining records.
/// See spec §3.6 and §3.7.
class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let shieldsKey = "evlin.shieldRecords"
    private let blocksKey = "evlin.blockRecords"
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let store = ManagedSettingsStore()
    private let appLimitCallbackValidator = AppLimitCallbackValidator()
    private let appLimitEffectJournal = AppLimitEffectJournal()
    private let appLimitEffectWorkerID = UUID()

    /// Build the canonical day key in the backend policy timezone when known.
    private func currentDayKey() -> String {
        let context = EarnedTimeStore.shared.currentPolicyDateContext()
        return "\(context.usageDate)@\(context.timezoneIdentifier)"
    }

    private func authorizedEarnedGeneration(
        activityName: String
    ) -> LegacyGenerationProvenance? {
        defaults?.synchronize()
        return LegacyMeteringActivity.authorizedCallback(
            activityName: activityName,
            currentDeviceID: defaults?.string(forKey: "evlin.childId"),
            state: (try? DeviceEpochStore.shared.read())?.legacy
        )
    }

    private func earnedGenerationIsActive(
        _ generation: LegacyGenerationProvenance
    ) -> Bool {
        LegacyMeteringActivity.isAuthorized(
            generation: generation,
            store: .shared
        )
    }

    @discardableResult
    private func performIfEarnedGenerationActive(
        _ generation: LegacyGenerationProvenance,
        mutationKeys: [String] = [],
        rollbackExternalState: () -> Void = {},
        _ operation: () -> Void
    ) -> Bool {
        LegacyMeteringActivity.performIfAuthorized(
            generation: generation,
            store: .shared,
            defaults: defaults,
            mutationKeys: mutationKeys,
            rollbackExternalState: rollbackExternalState,
            operation
        )
    }

    /// Emit a ScreenTimeEvent from the extension (emitter = kid_extension).
    private func emitEvent(kind: ScreenTimeEvent.Kind,
                           source: ScreenTimeEvent.Source?,
                           app: String?,
                           reason: String,
                           transition: ScreenTimeEvent.Transition? = nil) {
        let e = ScreenTimeEvent(
            ts: ISO8601DateFormatter().string(from: Date()),
            emitter: .kidExtension,
            deviceID: defaults?.string(forKey: "evlin.childDeviceID"),
            dayKey: currentDayKey(),
            kind: kind, source: source, app: app, reason: reason,
            nums: nil, transition: transition, policyGen: nil, corrID: nil)
        ScreenTimeEventLog.emit(e)
    }

    private func expireParentUnlockOverrideIfNeeded(now: Date) {
        guard let owner = ExtensionConfig.childId,
              case .expired? = try? ParentUnlockOverrideExpiry.expireElapsedMirrorIfNeeded(
                now: now,
                expectedOwner: owner
              ),
              let shields = loadShields()
        else { return }
        recomputeAndApplyShields(shields)
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        let memoryTrace = DAMMemoryTrace.shared
        let traceContext = memoryTrace.begin(
            kind: .intervalStart,
            activityName: activity.rawValue,
            eventName: nil
        )
        defer { memoryTrace.mark(traceContext, stage: .exit) }
        super.intervalDidStart(for: activity)
        expireParentUnlockOverrideIfNeeded(now: Date())

        let raw = activity.rawValue

#if DEBUG
        if MeteringMonitorCapabilityProbe.isProbeActivity(raw) {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "dam callback timestamp=\(ts) activity=\(raw)"
            MeteringMonitorCapabilityProbe.append(line, defaults: defaults)
            defaults?.set(line, forKey: MeteringMonitorCapabilityProbe.callbackKey)
            NSLog("[Evlin/Ext] %@", line)
            return
        }
#endif

        if raw.hasPrefix(MeteringRouteNamespace.prefix) {
            let project: ([String: ShieldRecord]) -> Void = { [weak self] shields in
                self?.recomputeAndApplyShields(shields)
            }
            // Interval boundaries used to run the FULL metering recovery
            // driver here (network drain + DeviceActivityCenter reconciliation
            // + route repair) and block on it. That was every one of the XS
            // Max's re-arm-time deaths (5/5 `intervalStart`, 2026-08-16). The
            // extension is not the load-bearing installer — the host app fills
            // the whole dated horizon and DAM-role recovery never fresh-starts
            // today's route — so heavy recovery belongs to the app's watchdog
            // (foreground / hourly background wake). Keep only what is local
            // and cheap — and do it SYNCHRONOUSLY: a Task scheduled after
            // return may never run if the extension is suspended immediately,
            // and a pending terminal shield left unprojected is "time is up
            // but not locked". No network, no DeviceActivityCenter in here.
            memoryTrace.mark(traceContext, stage: .beforeState)
            DAMMeteringEntry.shared.recoverShieldEffectsSynchronouslyIfConfigured(
                projectShields: project
            )
            memoryTrace.mark(traceContext, stage: .afterShield)
            return
        }

        switch AppLimitIntervalStartRouter().route(
            activityName: raw,
            now: Date()
        ) {
        case .notPerAppV2:
            break
        case .resetLimitShields(let rollover):
            let confirmedRollover: Bool
            switch rollover {
            case .rolledOver:
                confirmedRollover = true
            case .unchanged:
                confirmedRollover = false
            case .rejected:
                confirmedRollover = false
            }
            resetLimitShields(
                activity: raw,
                confirmedV2Rollover: confirmedRollover
            )
            defaults?.set(
                "activity=\(raw) rollover=\(rollover)",
                forKey: "evlin.limit.v2.lastIntervalStart"
            )
            return
        case .failClosed(let reason):
            let diagnostic = "activity=\(raw) rejected=\(reason)"
            defaults?.set(
                diagnostic,
                forKey: "evlin.limit.v2.lastIntervalStart"
            )
            NSLog("[Evlin/Ext] per-app v2 interval start rejected: %@", diagnostic)
            return
        }

        // Per-app limit daily reset (P7). The window's interval start (midnight for
        // a daily window) means a fresh day's budget. DeviceActivity auto-resets
        // each event's threshold counter at the interval boundary, so the budget
        // refreshes on its own; this branch just un-shields so the kid gets the
        // new day's allowance. We strip ONLY `source == .limit` records — a
        // parent's `source == .manual` shield is NEVER touched.
        // Prefix MUST equal `AppLimitPlanner.windowActivityPrefix`. Hardcoded (not
        // referenced) because the planner is an app-target-only type not built into
        // this extension; the constant is asserted equal in P7 tests.
        if raw.hasPrefix("evlin.limit.window.") {
            resetLimitShields(activity: raw)
            return
        }

        // B5 — Earned-time daily reset. The earned activity interval starts at
        // midnight each day (see `EarnedBudgetScheduler.arm`). Strip ONLY the
        // `.earnedTime` source from all selected-set records — do NOT delete whole
        // records (a record with {.manual, .earnedTime} must survive with {.manual}).
        // This mirrors the limit daily-reset path above but is source-specific.
        if LegacyMeteringActivity.isEarnedActivityName(raw) {
            guard let generation = authorizedEarnedGeneration(activityName: raw) else { return }
            _ = ActiveLockPersistenceLock.shared.withLock {
                _ = performIfEarnedGenerationActive(
                    generation,
                    mutationKeys: [shieldsKey],
                    rollbackExternalState: {
                        if let shields = loadShields() {
                            recomputeAndApplyShields(shields)
                        }
                    }
                ) {
                    resetEarnedTimeShields(activity: raw)
                }
            }
            return
        }

        guard raw == "evlin.command.heartbeat" else { return }

        let ts = ISO8601DateFormatter().string(from: Date())

        // SPIKE: re-arm the next heartbeat window from INSIDE this extension
        // process. Whether `startMonitoring` is even permitted here (no repo
        // precedent — arming has only ever happened in the main app) is THE
        // unknown this experiment resolves. Capture ok / throw verbatim.
        let rearm = rearmHeartbeatSpike()

        // SPIKE: append (don't overwrite) to a capped history so the main app
        // can read the whole fire SEQUENCE + cadence, not just the last fire.
        let count = appendHeartbeatSpikeLog("fired \(ts) \(rearm)")

        defaults?.set(
            "\(ts) intervalDidStart activity=\(raw) fire#\(count) \(rearm)",
            forKey: "evlin.delivery.damHeartbeat"
        )
        NSLog("[Evlin/Ext] command heartbeat intervalDidStart %@ #%d %@", raw, count, rearm)
#if DEBUG
        runMeteringMonitorCapabilityProbe(
            sequence: count,
            canonicalTimezone: EarnedTimeStore.shared.currentPolicyDateContext()
                .timezoneIdentifier
        )
#endif
        Task { await BigKidExtensionReporter.shared.reportCommandHeartbeat() }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        let memoryTrace = DAMMemoryTrace.shared
        let traceContext = memoryTrace.begin(
            kind: .intervalEnd,
            activityName: activity.rawValue,
            eventName: nil
        )
        defer { memoryTrace.mark(traceContext, stage: .exit) }
        super.intervalDidEnd(for: activity)
        expireParentUnlockOverrideIfNeeded(now: Date())

        let raw = activity.rawValue
        // Diagnostic marker — every intervalDidEnd entry writes its name + ts
        // to the App Group so the main app can show "extension fired at X"
        // in Settings. Without this we can't tell whether iOS dispatched the
        // callback at all (vs the extension running but failing to clear).
        let ts = ISO8601DateFormatter().string(from: Date())
        let marker = "fired \(ts) activity=\(raw)"
        defaults?.set(marker, forKey: "evlin.lastIntervalDidEnd")
        NSLog("[Evlin/Ext] intervalDidEnd %@", marker)

        if raw.hasPrefix(ParentUnlockOverrideExpiry.activityPrefix) {
            guard let owner = ExtensionConfig.childId else { return }
            let result = try? ParentUnlockOverrideExpiry.expireFromActivityCallback(
                activityName: raw,
                now: Date(),
                expectedOwner: owner
            )
            if case .expired? = result,
               let shields = loadShields() {
                recomputeAndApplyShields(shields)
            }
            return
        }

        if raw.hasPrefix(MeteringRouteNamespace.prefix) {
            let project: ([String: ShieldRecord]) -> Void = { [weak self] shields in
                self?.recomputeAndApplyShields(shields)
            }
            // Interval boundaries used to run the FULL metering recovery
            // driver here (network drain + DeviceActivityCenter reconciliation
            // + route repair) and block on it. That was every one of the XS
            // Max's re-arm-time deaths (5/5 `intervalStart`, 2026-08-16). The
            // extension is not the load-bearing installer — the host app fills
            // the whole dated horizon and DAM-role recovery never fresh-starts
            // today's route — so heavy recovery belongs to the app's watchdog
            // (foreground / hourly background wake). Keep only what is local
            // and cheap — and do it SYNCHRONOUSLY: a Task scheduled after
            // return may never run if the extension is suspended immediately,
            // and a pending terminal shield left unprojected is "time is up
            // but not locked". No network, no DeviceActivityCenter in here.
            memoryTrace.mark(traceContext, stage: .beforeState)
            DAMMeteringEntry.shared.recoverShieldEffectsSynchronouslyIfConfigured(
                projectShields: project
            )
            memoryTrace.mark(traceContext, stage: .afterShield)
            return
        }

        // Two activity namespaces fire here:
        //   "evlin.shield.<16-byte-hex-of-recordKey>" — timed shield expiring
        //   "evlin.block.<16-byte-hex-of-bundleID>"  — timed block expiring
        if raw.hasPrefix("evlin.shield.") {
            let hashHex = String(raw.dropFirst("evlin.shield.".count))
            let found = removeShieldByHashAndRecompute(hashHex: hashHex)
            // On miss, surface what keys ARE in the dict so we can tell whether
            // the stored key drifted from what we hashed against, or the dict
            // is empty (main-app sweepExpired already cleared it).
            var detail = "\(marker) shieldRemoved=\(found)"
            if !found {
                let keys: [String] = {
                    guard let data = defaults?.data(forKey: shieldsKey),
                          let shields = ShieldSourceLogic.decodePersistedShields(data)
                    else { return [] }
                    return Array(shields.keys)
                }()
                detail += " keysCount=\(keys.count) keys=\(keys)"
            }
            defaults?.set(detail, forKey: "evlin.lastIntervalDidEnd")
            NSLog("[Evlin/Ext] %@", detail)
        } else if raw.hasPrefix("evlin.block.") {
            let hashHex = String(raw.dropFirst("evlin.block.".count))
            let found = removeBlockByHashAndRecompute(hashHex: hashHex)
            defaults?.set("\(marker) blockRemoved=\(found)", forKey: "evlin.lastIntervalDidEnd")
            NSLog("[Evlin/Ext] block remove found=%d hash=%@", found ? 1 : 0, hashHex)
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        let traceKind: DAMMemoryTrace.CallbackKind
        if activity.rawValue.hasPrefix(MeteringRouteNamespace.prefix) {
            traceKind = .thresholdPool
        } else if activity.rawValue.hasPrefix("evlin.limit.v2.") {
            traceKind = .thresholdAppLimit
        } else {
            traceKind = .thresholdOther
        }
        let memoryTrace = DAMMemoryTrace.shared
        let traceContext = memoryTrace.begin(
            kind: traceKind,
            activityName: activity.rawValue,
            eventName: event.rawValue
        )
        defer { memoryTrace.mark(traceContext, stage: .exit) }
        super.eventDidReachThreshold(event, activity: activity)
        expireParentUnlockOverrideIfNeeded(now: Date())
#if DEBUG
        let thresholdEntryCount =
            (defaults?.integer(forKey: "evlin.metering.thresholdEntryCount") ?? 0) + 1
        let thresholdEntry = [
            ISO8601DateFormatter().string(from: Date()),
            "activity=\(activity.rawValue)",
            "event=\(event.rawValue)",
            "entry=\(thresholdEntryCount)",
        ].joined(separator: " ")
        defaults?.set(
            thresholdEntryCount,
            forKey: "evlin.metering.thresholdEntryCount"
        )
        defaults?.set(
            thresholdEntry,
            forKey: "evlin.metering.lastThresholdEntry"
        )
        defaults?.synchronize()
#endif
#if DEBUG
        if event.rawValue.hasPrefix("evlin.debug.topology."),
           activity.rawValue.hasPrefix("evlin.debug.topology.") {
            AppLimitTopologyProbeCallbackStore.append(
                activityName: activity.rawValue,
                eventName: event.rawValue,
                defaults: defaults
            )
            return
        }
#endif
        // DEBUG whole-device-measurement spike: a threshold armed on ALL
        // CATEGORIES fired. The Monitor extension (unlike the Report extension)
        // CAN write the App Group, so this marker reliably crosses back to the
        // app — proving the threshold measured whole-device usage. Harmless in
        // production (nothing arms `evlin.test.wholeDevice` there).
        if event.rawValue == "evlin.test.wholeDevice" {
            let count = (defaults?.integer(forKey: "evlin.test.wholeDevice.count") ?? 0) + 1
            defaults?.set(count, forKey: "evlin.test.wholeDevice.count")
            defaults?.set(Date(), forKey: "evlin.test.wholeDevice.firedAt")
            defaults?.set(
                "fired #\(count) @ \(ISO8601DateFormatter().string(from: Date())) activity=\(activity.rawValue)",
                forKey: "evlin.test.wholeDevice.diag"
            )
            NSLog("[Evlin/Ext] wholeDevice test threshold fired #%d", count)
            return
        }
        if event.rawValue == "evlin.bigkid.chunk" {
            guard usageCountingAllowed(eventName: event.rawValue) else { return }
            Task { await BigKidExtensionReporter.shared.reportChunk() }
            return
        }
        if activity.rawValue.hasPrefix(MeteringRouteNamespace.prefix) {
            // A3: record the ARRIVAL, before any guard can discard it. A
            // callback that arrives and is then dropped and a callback Apple
            // never delivered used to look identical from the outside — that
            // ambiguity is what made every "bars frozen" report an overnight
            // investigation.
            let parsed = MeteringRouteNamespace.parse(
                activityName: activity.rawValue,
                eventName: event.rawValue
            )
            MeteringFlightRecorder.emitCallbackArrival(
                site: "dam.threshold",
                detail: MeteringFlightRecorder.detail([
                    ("act", activity.rawValue),
                    ("evt", event.rawValue),
                ]),
                nums: ScreenTimeEvent.Nums(threshold: parsed?.thresholdMinutes),
                corrID: parsed?.routeID
            )
            handleV2MeteringThreshold(
                event: event,
                activity: activity,
                traceContext: traceContext
            )
            return
        }
        if activity.rawValue.hasPrefix("evlin.limit.v2.") {
            handleValidatedAppLimitThreshold(
                event: event,
                activity: activity,
                traceContext: traceContext
            )
            return
        }

        // B5 — Earned-time ladder threshold fired. Event name is `evlin.earned.t<N>`
        // (armed by `EarnedBudgetScheduler`). Two actions:
        //   1. POST an idempotent cumulative sample to the A2 backend (with retry queue).
        //   2. If N ≥ effective cap/tripwire AND no override flag → apply `.earnedTime`
        //      shield over the Locked-set tokens (pure App Group path, no actor).
        if event.rawValue.hasPrefix("evlin.earned.t"),
           LegacyMeteringActivity.isEarnedActivityName(activity.rawValue) {
            guard let generation = authorizedEarnedGeneration(
                activityName: activity.rawValue
            ) else { return }
            guard usageCountingAllowed(
                eventName: event.rawValue,
                earnedGeneration: generation
            ) else { return }
            handleEarnedThreshold(
                eventName: event.rawValue,
                activity: activity,
                generation: generation
            )
        }
    }

    /// Seconds the callback will hold its thread waiting for a network drain.
    /// Generous enough for one POST on a slow connection, far short of anything
    /// the system would consider a hang.
    private static let drainWaitSeconds: TimeInterval = 6

    /// Run async work and WAIT for it, bounded.
    ///
    /// `eventDidReachThreshold` is a synchronous callback, and iOS may suspend
    /// or kill the extension process as soon as it returns. Every report site
    /// used to kick off a bare `Task { … }` and return immediately, which made
    /// delivery a race against that suspension. On 2026-07-27 a fresh install
    /// lost it twice in a row: thresholds fired at 18:40:53 and 18:45:53 and
    /// both samples reached the backend at 18:49:57 — the instant a parent
    /// happened to open the app. The bar only moved because someone looked at
    /// it.
    ///
    /// Safe by construction on both ends. Nothing in the drain path is
    /// MainActor-isolated (`EarnedSampleReporter` is a plain enum, this class is
    /// not `@MainActor`), so blocking the calling thread cannot deadlock on it.
    /// And if the wait expires, the entry is still durably queued and the app's
    /// foreground drain still picks it up — i.e. exactly today's behaviour.
    /// This can only make delivery earlier, never later.
    ///
    /// UPDATE 2026-08-19: the premise above turned out to be wrong for the
    /// earned/interval paths — blocking here is what got the extension
    /// terminated and its callback re-delivered 6–36 minutes later (see
    /// `DAMDrainCoordinator`). Those paths no longer call this. It survives
    /// ONLY for the per-app limit drain (`drainAcceptedAppLimitEffects`),
    /// which is scheduled to move to the same non-blocking shape (P0-3) once
    /// the event ring leaves App Group UserDefaults (P0-2).
    private func awaitBounded(
        traceContext: DAMMemoryTrace.Context? = nil,
        _ work: @escaping @Sendable () async -> Void
    ) {
        if let traceContext {
            DAMMemoryTrace.shared.mark(traceContext, stage: .beforeDrain)
        }
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            defer {
                if let traceContext {
                    DAMMemoryTrace.shared.mark(
                        traceContext,
                        stage: .afterDrainWait,
                        flags: .asyncCompleted
                    )
                }
                done.signal()
            }
            await work()
        }
        let result = done.wait(timeout: .now() + Self.drainWaitSeconds)
        if let traceContext {
            DAMMemoryTrace.shared.mark(
                traceContext,
                stage: .afterDrainWait,
                flags: result == .success ? .waitCompleted : .waitTimedOut
            )
        }
    }

    private func handleV2MeteringThreshold(
        event: DeviceActivityEvent.Name,
        activity: DeviceActivityName,
        traceContext: DAMMemoryTrace.Context
    ) {
        let project: ([String: ShieldRecord]) -> Void = { [weak self] shields in
            self?.recomputeAndApplyShields(shields)
        }
        do {
            DAMMemoryTrace.shared.mark(traceContext, stage: .beforeState)
            let outcome = try DAMMeteringEntry.shared.handle(
                activityName: activity.rawValue,
                eventName: event.rawValue,
                observedAt: Date(),
                projectShields: project
            )
            DAMMemoryTrace.shared.mark(traceContext, stage: .afterState)
            DAMMemoryTrace.shared.mark(traceContext, stage: .afterJournal)
            // Observability (no behavior change): record every callback outcome in
            // ALL builds, and emit an uploadable drop event whenever the guard
            // discards a callback. A silently-dropped late callback is exactly what
            // hid the year-long "bars frozen" bug — discards must never be invisible.
            defaults?.set(
                "\(ISO8601DateFormatter().string(from: Date())) \(String(describing: outcome))",
                forKey: "evlin.metering.lastV2ThresholdOutcome"
            )
            defaults?.synchronize()
            if case .discarded(let reason) = outcome {
                emitEvent(kind: .drop, source: .earnedPool, app: event.rawValue,
                          reason: "v2_callback_discarded:\(reason)")
            }
            NSLog("[Evlin/Ext] v2 metering callback %@", String(describing: outcome))
        } catch {
            DAMMemoryTrace.shared.mark(
                traceContext,
                stage: .afterState,
                flags: .failed
            )
#if DEBUG
            defaults?.set(
                "\(ISO8601DateFormatter().string(from: Date())) failed=\(String(describing: error))",
                forKey: "evlin.metering.lastV2ThresholdOutcome"
            )
            defaults?.synchronize()
#endif
            NSLog("[Evlin/Ext] v2 metering callback failed: %@", String(describing: error))
            // A throwing callback loses the rung entirely, and the DEBUG key
            // above is both release-stripped and single-slot.
            MeteringFlightRecorder.emitError(
                site: "dam.threshold",
                error: error,
                detail: MeteringFlightRecorder.detail([("evt", event.rawValue)])
            )
        }
        // The sample is durable (state + journal committed above) and the
        // terminal shield, if any, was projected inside `handle()`. Do NOT
        // wait for the upload here. This callback used to block on a
        // semaphore for up to six seconds; when the daemon had another
        // callback queued it terminated the blocked extension and re-delivered
        // the killed rung with growing backoff (2026-08-16 trace: 16/16
        // entry-without-exit deaths at exactly this spot, plus real
        // per-process-limit jetsams inside the drain's memory spike). Kick a
        // budgeted, single-flight, opportunistic drain and return; the journal
        // + host-app foreground drain + background wakes remain the durable
        // delivery path exactly as before.
        DAMDrainCoordinator.shared.requestDrain(traceContext: traceContext)
        Task { @MainActor in
            await DAMMeteringEntry.shared.recoverShieldEffectsIfConfigured(
                projectShields: project
            )
            DAMMemoryTrace.shared.mark(traceContext, stage: .afterShield)
        }
    }

    private func usageCountingAllowed(
        eventName: String,
        earnedGeneration: LegacyGenerationProvenance? = nil
    ) -> Bool {
        guard EarnedTimeStore.shared.usageCountingAllowed else {
            let recordSkip = {
                let ts = ISO8601DateFormatter().string(from: Date())
                self.defaults?.set("\(ts) skipped usage event=\(eventName) unfinished_tasks=true",
                                   forKey: "evlin.usageCounting.lastSkipped")
                NSLog("[Evlin/Ext] skipped usage event=%@ because unfinished tasks remain", eventName)
                self.emitEvent(kind: .drop, source: nil, app: eventName, reason: "usage_counting_disabled")
            }
            if let earnedGeneration {
                _ = performIfEarnedGenerationActive(
                    earnedGeneration,
                    mutationKeys: ["evlin.usageCounting.lastSkipped"],
                    recordSkip
                )
            } else {
                recordSkip()
            }
            return false
        }
        return true
    }

    private func handleValidatedAppLimitThreshold(
        event: DeviceActivityEvent.Name,
        activity: DeviceActivityName,
        traceContext: DAMMemoryTrace.Context
    ) {
        let context = EarnedTimeStore.shared.currentPolicyDateContext()
        // Record the ARRIVAL — but as a single defaults key, NEVER a durable
        // ring emit. The durable path loads and rewrites the full 2000-line
        // event ring, which on a mature device blows the DAM extension's ~6MB
        // memory cap and kills the process RIGHT HERE — consuming the one-shot
        // bell before the validator ever runs. That was the per-app massacre
        // of 2026-08-06/07: every bell arrived (entry breadcrumb advanced) and
        // died at this doorstep; devices with a near-empty ring (fresh iPad)
        // sailed through, which masqueraded as scheduling folklore. The earned
        // branch's `emitCallbackArrival` carries the same warning for the same
        // reason.
        defaults?.set(
            "\(ISO8601DateFormatter().string(from: Date())) arrived evt=\(event.rawValue)",
            forKey: "evlin.appLimit.lastCallback"
        )
        do {
            DAMMemoryTrace.shared.mark(traceContext, stage: .beforeState)
            let decision = try appLimitCallbackValidator.process(
                activityName: activity.rawValue,
                eventName: event.rawValue,
                canonicalUsageDate: context.usageDate,
                observedAt: Date(),
                usageCountingAllowed: EarnedTimeStore.shared.usageCountingAllowed
            ) { [self] callback in
                try appLimitEffectJournal.enqueue(callback)
            }
            DAMMemoryTrace.shared.mark(traceContext, stage: .afterState)
            switch decision {
            case .rejected(let reason):
                NSLog("[Evlin/Ext] app limit callback rejected: %@", reason)
                defaults?.set(
                    "\(ISO8601DateFormatter().string(from: Date())) \(reason) evt=\(event.rawValue)",
                    forKey: "evlin.appLimit.lastVerdict"
                )
            case .paused:
                defaults?.set(
                    "\(ISO8601DateFormatter().string(from: Date())) paused evt=\(event.rawValue)",
                    forKey: "evlin.appLimit.lastVerdict"
                )
                return
            case .accepted:
                DAMMemoryTrace.shared.mark(traceContext, stage: .afterJournal)
                break
            }
            drainAcceptedAppLimitEffects(traceContext: traceContext)
        } catch {
            DAMMemoryTrace.shared.mark(
                traceContext,
                stage: .afterState,
                flags: .failed
            )
            NSLog("[Evlin/Ext] app limit callback validation failed: %@", String(describing: error))
        }
    }

    private func drainAcceptedAppLimitEffects(
        traceContext: DAMMemoryTrace.Context? = nil
    ) {
        do {
            while let claim = try appLimitEffectJournal.claimNext(
                workerID: appLimitEffectWorkerID
            ) {
                let localReceipt = try appLimitEffectJournal.applyLocal(
                    claim,
                    source: "device_activity_monitor"
                ) { [self] callback in
                    try AppLimitEffectLocalPersistence.persist(
                        callback,
                        shieldPersistence: AppLimitShieldPersistence(
                            store: defaults,
                            storageKey: shieldsKey
                        )
                    )
                }
                guard localReceipt != nil else { continue }
                if let baseURL = ExtensionConfig.baseURL,
                   let deviceID = ExtensionConfig.childId {
                    let journal = appLimitEffectJournal
                    // Same race as the earned-pool reporter, same fix — see
                    // `awaitBounded`. The per-app ladder is the one a parent watches
                    // hit its budget, so a report that lands only when someone opens
                    // the app is a limit that appears not to work.
                    awaitBounded(traceContext: traceContext) {
                        do {
                            _ = try await journal.submitUsage(
                                claim,
                                baseURL: baseURL,
                                deviceID: deviceID
                            )
                        } catch {
                            NSLog(
                                "[Evlin/Ext] app limit usage journal failed: %@",
                                String(describing: error)
                            )
                        }
                    }
                }
                if claim.effect.key.effectKind == .enforcement {
                    projectLimitShield(callback: claim.effect.callback)
                    if let traceContext {
                        DAMMemoryTrace.shared.mark(traceContext, stage: .afterShield)
                    }
                }
            }
        } catch {
            NSLog("[Evlin/Ext] app limit effect journal failed: %@", String(describing: error))
        }
    }

    /// Runs after the journal has durably recorded both the local usage and
    /// shield intent. ManagedSettings is deliberately outside that transaction:
    /// a slow Screen Time daemon must not strand a claimed callback without its
    /// receipt and therefore delay parent-side usage.
    private func projectLimitShield(callback: AppLimitValidatedCallback) {
        let rule = callback.rule
        let ruleId = rule.id

        // Notify THEN lock: post the local "time's up" notice on the kid's
        // device before applying the shield, so the kid gets a heads-up the
        // moment the budget is hit. Cheap + crash-safe for the extension's
        // tight budget; if notification auth isn't granted, `add` silently
        // no-ops (the extension can't and must not request authorization).
        postLimitReachedNotification(ruleId: ruleId, rule: rule)

        let now = Date()
        if let shields = loadShields() {
            recomputeAndApplyShields(shields)
        }

        let ts = ISO8601DateFormatter().string(from: now)
        defaults?.set(
            "limit_shielded_at=\(ts) rule=\(ruleId.uuidString) key=\(LimitShieldLogic.recordKey(for: rule))",
            forKey: "evlin.lastLimitShield"
        )
        NSLog("[Evlin/Ext] limit threshold shielded rule=%@", ruleId.uuidString)
        emitEvent(kind: .lock, source: .perAppLimit,
                  app: LimitShieldLogic.recordKey(for: rule),
                  reason: "budget_reached",
                  transition: .init(before: "shielded:false", after: "shielded:true"))

    }
    /// Post the local "time's up" notification for a reached per-app limit.
    /// Content is built by the pure `LimitShieldLogic.limitReachedNotification`
    /// helper (unit-tested) and wrapped here in a `UNMutableNotificationContent`.
    /// Uses a deterministic per-rule identifier so an (unexpected) same-day
    /// re-fire replaces rather than stacks. `trigger: nil` delivers immediately.
    /// If authorization isn't granted, `add` is a silent no-op — fine; the
    /// extension neither can nor should request authorization.
    private func postLimitReachedNotification(ruleId: UUID, rule: AppLimitRule) {
        let copy = LimitShieldLogic.limitReachedNotification(
            appName: rule.displayName,
            minutes: rule.budgetMinutes
        )
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "evlin.limit.reached.\(ruleId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - B5: Earned-time enforcement

    /// Handle an `evlin.earned.t<N>` threshold event.
    ///
    /// 1. Parse N from the event name.
    /// 2. Update `EarnedTimeStore.latestDeviceEstimate` to N (cumulative usage).
    /// 3. POST an idempotent sample to the backend via `EarnedSampleReporter`.
    /// 4. Compute the effective cap/tripwire from the store.
    /// 5. If N ≥ effectiveCap AND override absent → apply `.earnedTime` shield
    ///    over the Locked-set tokens using the pure App Group path.
    ///
    /// Uses NO actor (App Group direct read/write only), matching how `applyLimitShield`
    /// uses `loadShields` → `LimitShieldLogic` → `recomputeAndApplyShields`.
    private func handleEarnedThreshold(
        eventName: String,
        activity: DeviceActivityName,
        generation: LegacyGenerationProvenance
    ) {
        let suffix = String(eventName.dropFirst("evlin.earned.t".count))
        guard let n = Int(suffix) else {
            NSLog("[Evlin/Ext] earned threshold: unparseable N in '%@'", eventName)
            return
        }

        let earnedStore = EarnedTimeStore.shared
        guard let generationDeviceID = UUID(uuidString: generation.deviceID) else { return }
        guard earnedGenerationIsActive(generation) else { return }

        let offset = generation.offsetMinutes
        let adjustedN = EarnedTimeStore.adjustedEarnedThreshold(
            rawThresholdMinutes: n,
            runningOffsetMinutes: offset
        )
        let callbackAt = Date()
        let currentUsageDate = earnedStore.currentPolicyDateContext(now: callbackAt).usageDate
        EarnedThresholdProductionCoordinator.process(
            generation: generation,
            eventName: eventName,
            rawThresholdMinutes: n,
            adjustedEstimateMinutes: adjustedN,
            callbackAt: callbackAt,
            currentUsageDate: currentUsageDate,
            recordDiagnostic: { diagnostic in
                _ = performIfEarnedGenerationActive(
                    generation,
                    mutationKeys: ["evlin.earned.implausibleThreshold"]
                ) {
                    defaults?.set(
                        diagnostic,
                        forKey: "evlin.earned.implausibleThreshold"
                    )
                }
            },
            runAcceptedProductionPath: {
                handleAcceptedEarnedThreshold(
                    eventName: eventName,
                    activity: activity,
                    generation: generation,
                    generationDeviceID: generationDeviceID,
                    rawThresholdMinutes: n,
                    adjustedEstimateMinutes: adjustedN,
                    callbackAt: callbackAt,
                    earnedStore: earnedStore
                )
            }
        )
    }

    private func handleAcceptedEarnedThreshold(
        eventName: String,
        activity: DeviceActivityName,
        generation: LegacyGenerationProvenance,
        generationDeviceID: UUID,
        rawThresholdMinutes: Int,
        adjustedEstimateMinutes adjustedN: Int,
        callbackAt: Date,
        earnedStore: EarnedTimeStore
    ) {
        let offset = generation.offsetMinutes
        let n = rawThresholdMinutes
        guard let generationArmedAt = generation.armedAt else { return }
        guard earnedGenerationIsActive(generation) else { return }
        let localReconciliation = earnedStore.recordLocalThresholdEstimate(
            adjustedN,
            expectedDeviceID: generationDeviceID,
            expectedGeneration: generation
        )

        let ts = ISO8601DateFormatter().string(from: callbackAt)
        _ = performIfEarnedGenerationActive(
            generation,
            mutationKeys: ["evlin.earned.lastThreshold"]
        ) {
            defaults?.set(
                "\(ts) event=\(eventName) activity=\(activity.rawValue) raw=\(n) adjusted=\(adjustedN) offset=\(offset)",
                forKey: "evlin.earned.lastThreshold"
            )
        }

        // Persist the newly fired sample before starting any async drain/network
        // work. Authorization aborts leave this exact device-scoped entry queued.
        let usageDate = generation.usageDate
        let tz = generation.timezoneIdentifier
        let newSample = EarnedSampleReporter.makeRetryEntry(
            deviceID: generationDeviceID,
            usageDate: usageDate,
            timezone: tz,
            thresholdMinutes: adjustedN,
            estimatedMinutes: adjustedN,
            observedAt: ts,
            generationArmedAt: generationArmedAt,
            generationOffsetMinutes: offset
        )
        let sampleQueued = EarnedSampleReporter.enqueueRetry(newSample)
        if let baseURL = ExtensionConfig.baseURL, sampleQueued {
            let authorizationIsCurrent = {
                LegacyMeteringActivity.isAuthorized(
                    generation: generation,
                    store: .shared
                )
            }
            // Legacy (v1) earned path: same rule — the sample is already in
            // the retry queue; upload opportunistically, never block the
            // callback on it. Routed through the SAME single-flight
            // coordinator so v1 callbacks cannot stack parallel uploads next
            // to the v2 drain (the legacy queue drain has no budget of its
            // own; single-flight is the bound it gets until v1 retires).
            DAMDrainCoordinator.shared.requestLegacyDrain {
                guard authorizationIsCurrent() else { return }
                await EarnedSampleReporter.drainRetryQueue(
                    baseURL: baseURL,
                    onlyDeviceID: generationDeviceID,
                    authorizationIsCurrent: authorizationIsCurrent
                )
            }
        } else {
            _ = performIfEarnedGenerationActive(
                generation,
                mutationKeys: [EarnedSampleReporter.lastSamplePostDebugKey]
            ) {
                defaults?.set(
                    "\(ts) sample queue/base unavailable event=\(eventName) baseURL=\(String(describing: ExtensionConfig.baseURL)) queued=\(sampleQueued) generationDeviceID=\(generation.deviceID)",
                    forKey: EarnedSampleReporter.lastSamplePostDebugKey
                )
            }
        }

        if localReconciliation != .reconciled {
            _ = performIfEarnedGenerationActive(generation) {
                NSLog("[Evlin/Ext] earned threshold reported with local reconciliation deferred")
                emitEvent(kind: .decision, source: .earnedPool, app: "device-wide",
                          reason: "local_reconciliation_deferred")
            }
        }
    }

    /// B5 daily reset: strip ONLY `.earnedTime` from every shield record.
    /// Records with only `.earnedTime` are deleted; mixed records survive with
    /// their remaining sources. Preserves `.manual` and `.limit` sources.
    private func resetEarnedTimeShields(activity: String) {
        var removedCount = 0
        var modifiedCount = 0
        var didReset = false
        // FIX-E: this was the ONE read-modify-write of `evlin.shieldRecords` in
        // this file that ran without the shared cross-process lock — its two
        // siblings (`resetLimitsAtIntervalEnd`, `removeShieldByHashAndRecompute`)
        // both take it. An unserialised read-modify-write against a key the main
        // app and the earned-shield store write concurrently can drop a
        // concurrent update or publish a half-written blob, which is how the
        // terminal lock came to read bytes it could not decode.
        _ = ActiveLockPersistenceLock.shared.withLock {
            guard let current = loadShields() else { return }
            let stripped = ShieldSourceLogic.strippingSource(.earnedTime, from: current)
            removedCount = current.count - stripped.count
            modifiedCount = stripped.values.filter { rec in
                current[rec.recordKey]?.sources.contains(.earnedTime) == true
            }.count
            if let data = encodeShields(stripped) {
                defaults?.set(data, forKey: shieldsKey)
            }
            recomputeAndApplyShields(stripped)
            didReset = true
        }

        guard didReset else { return }

        let ts = ISO8601DateFormatter().string(from: Date())
        defaults?.set(
            "earned_reset_at=\(ts) activity=\(activity) deleted=\(removedCount) modified=\(modifiedCount)",
            forKey: "evlin.lastEarnedReset"
        )
        NSLog("[Evlin/Ext] earned time daily reset activity=%@ deleted=%d modified=%d",
              activity, removedCount, modifiedCount)
        emitEvent(kind: .reset, source: .earnedPool, app: "device-wide", reason: "interval_reset")
    }

    /// Daily-reset enforcement (P7). Strip EVERY `source == .limit` ShieldRecord
    /// from the App Group shields dict, persist, and recompute so the kid regains
    /// the new day's allowance. NEVER touches `source == .manual` (parent)
    /// shields. Idempotent: if no limit shields exist this is a harmless recompute.
    ///
    /// Day-key guard: `intervalDidStart` fires for a limit activity BOTH at the
    /// real midnight interval boundary AND whenever a per-app limit is re-armed
    /// mid-day (every set_limit command restarts its DeviceActivity interval).
    /// Without a guard, any mid-day re-arm sweeps every OTHER app's limit shield,
    /// silently unlocking apps that are still at/over budget. We persist the last
    /// day we actually swept (`evlin.limitReset.dayKey`) and only strip when
    /// today differs from that stored key — see `LimitShieldLogic.isDayBoundaryReset`.
    private func resetLimitShields(
        activity: String,
        confirmedV2Rollover: Bool = false
    ) {
        let dayKeyKey = "evlin.limitReset.dayKey"
        let today = EarnedTimeStore.shared.currentPolicyDateContext().usageDate
        let stored = defaults?.string(forKey: dayKeyKey)

        guard LimitShieldLogic.shouldResetAtV2IntervalStart(
            confirmedRollover: confirmedV2Rollover,
            storedDayKey: stored,
            today: today
        ) else {
            defaults?.set(today, forKey: dayKeyKey)
            emitEvent(kind: .decision, source: .perAppLimit, app: "device-wide", reason: "rearm_restart_skip")
            NSLog("[Evlin/Ext] limit reset skipped (same-day re-arm) activity=%@ day=%@", activity, today)
            return
        }
        var removedCount = 0
        var remainingCount = 0
        var didReset = false
        _ = ActiveLockPersistenceLock.shared.withLock {
            guard let current = loadShields() else { return }
            let stripped = LimitShieldLogic.strippingLimitShields(from: current)
            removedCount = current.count - stripped.count
            remainingCount = stripped.count
            if let data = encodeShields(stripped) {
                defaults?.set(data, forKey: shieldsKey)
            }
            recomputeAndApplyShields(stripped)
            didReset = true
        }

        guard didReset else { return }
        defaults?.set(today, forKey: dayKeyKey)

        let ts = ISO8601DateFormatter().string(from: Date())
        defaults?.set(
            "limit_reset_at=\(ts) activity=\(activity) removed=\(removedCount)"
                + " remaining=\(remainingCount)",
            forKey: "evlin.lastLimitReset"
        )
        NSLog("[Evlin/Ext] limit daily reset activity=%@ removed=%d", activity, removedCount)
        emitEvent(kind: .reset, source: .perAppLimit, app: "device-wide", reason: "interval_reset")
    }

    /// Read the current shields dict from the App Group, normalizing each record
    /// to the current schema (same migration the shield-removal path applies).
    private func loadShields() -> [String: ShieldRecord]? {
        guard let data = defaults?.data(forKey: shieldsKey) else { return [:] }
        guard let decoded = ShieldSourceLogic.decodePersistedShields(data) else {
            recordShieldDecodeFailure(site: "load")
            return nil
        }
        return decoded.mapValues { $0.normalizedForCurrentSchema().record }
    }

    private func recordShieldDecodeFailure(site: String) {
        let reason = "shield_decode_failed_fail_closed"
        defaults?.set(
            "reason=\(reason) site=\(site) at=\(ISO8601DateFormatter().string(from: Date()))",
            forKey: "evlin.lastShieldDecodeFailure"
        )
        NSLog("[Evlin/Ext] %@ site=%@", reason, site)
        emitEvent(kind: .decision, source: nil, app: "device-wide", reason: reason)
    }

    @discardableResult
    private func removeShieldByHashAndRecompute(hashHex: String) -> Bool {
        ActiveLockPersistenceLock.shared.withLock {
            removeShieldByHashAndRecomputeLocked(hashHex: hashHex)
        } ?? false
    }

    private func removeShieldByHashAndRecomputeLocked(hashHex: String) -> Bool {
        // Read whatever the App Group says is current. If main-app sweepExpired
        // already pre-empted us, this dict may already be missing the hashed
        // record — that's fine, we still need to force-recompute the store
        // (the previous `store.shield.applications` write may not have
        // propagated, or sweepExpired set it from an actor thread that
        // springboard hasn't picked up yet). Idempotent recompute is safe.
        var migrated = false
        let decoded: [String: ShieldRecord]
        if let data = defaults?.data(forKey: shieldsKey) {
            guard let persisted = ShieldSourceLogic.decodePersistedShields(data) else {
                recordShieldDecodeFailure(site: "remove_by_hash")
                return false
            }
            decoded = persisted
        } else {
            decoded = [:]
        }
        let shields = decoded.mapValues { record in
            let normalized = record.normalizedForCurrentSchema()
            migrated = migrated || normalized.migrated
            return normalized.record
        }

        let targetKey = shields.keys.first(where: { key in
            let data = key.data(using: .utf8) ?? Data()
            let prefix = sha256Hex16(data)
            return prefix == hashHex
        })

        var mutated = shields
        let removedRecord: Bool
        if let recordKey = targetKey {
            mutated.removeValue(forKey: recordKey)
            if let updated = encodeShields(mutated) {
                defaults?.set(updated, forKey: shieldsKey)
            }
            removedRecord = true
        } else {
            // Dict already swept by main app — still recompute to ensure
            // the store reflects the current (possibly empty) record set.
            if migrated, let updated = encodeShields(mutated) {
                defaults?.set(updated, forKey: shieldsKey)
            }
            removedRecord = false
        }

        // Recompute & apply the surviving record set to the ManagedSettingsStore.
        let blocksRemaining = recomputeAndApplyShields(mutated)

        // Mark that the extension forced its own recompute. The diagnostic in
        // HomeSettingsSheet's "Last Extension Fire" already shows shieldRemoved;
        // augment it so we can tell apart 'pre-empted by main app + idempotent
        // recompute' (removedRecord=false) from 'extension did the work itself'
        // (removedRecord=true).
        let ts = ISO8601DateFormatter().string(from: Date())
        defaults?.set(
            "ext_recompute_at=\(ts) shieldsRemaining=\(mutated.count)"
                + " blocksRemaining=\(blocksRemaining) removedHere=\(removedRecord)",
            forKey: "evlin.lastRecompute"
        )

        return removedRecord
    }

    /// Recompute & apply shield/block state to the `ManagedSettingsStore` from the
    /// given shields dict + whatever blocks the App Group currently holds. EXACTLY
    /// the logic that used to live inline in `removeShieldByHashAndRecompute`
    /// (extracted verbatim for P7 so the threshold + daily-reset branches can reuse
    /// it). Same logic as `ActiveLockStore.recomputeAndApply`. Reads blocks from
    /// defaults here so every call site recomputes from the live block set.
    /// Returns the surviving block count for diagnostics.
    @discardableResult
    private func recomputeAndApplyShields(_ shields: [String: ShieldRecord]) -> Int {
        let blocks: [String: BlockRecord] = {
            guard let d = defaults?.data(forKey: blocksKey),
                  let decoded = decodeBlocks(from: d) else {
                return [:]
            }
            return decoded
        }()

        let effective = ParentUnlockOverrideProjectionApplication.project(
            shields: shields,
            blocks: blocks,
            expectedOwner: ExtensionConfig.childId
        )

        let blockedApps = Set(effective.blocks.values.map { record in
            record.appToken.map(ManagedSettings.Application.init(token:))
                ?? ManagedSettings.Application(bundleIdentifier: record.bundleID)
        })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps

        let broadRecords = effective.shields.values.filter(\.appliesToAll)
        if !broadRecords.isEmpty {
            let allWeb = Set(effective.shields.values.flatMap(\.webDomainTokens))
            store.shield.applicationCategories = .all()
            store.shield.applications = nil
            switch ShieldWebProjectionDecision.resolve(records: effective.shields.values) {
            case .all:
                store.shield.webDomainCategories = .all()
                store.shield.webDomains = nil
            case .specific:
                store.shield.webDomainCategories = nil
                store.shield.webDomains = allWeb
            case .open:
                store.shield.webDomainCategories = nil
                store.shield.webDomains = nil
            }
        } else {
            let allApp = Set(effective.shields.values.flatMap(\.appTokens))
            let allCat = Set(effective.shields.values.flatMap(\.categoryTokens))
            let allWeb = Set(effective.shields.values.flatMap(\.webDomainTokens))

            store.shield.applications = allApp.isEmpty ? nil : allApp
            store.shield.applicationCategories = allCat.isEmpty ? nil : .specific(allCat)
            switch ShieldWebProjectionDecision.resolve(records: effective.shields.values) {
            case .specific:
                store.shield.webDomains = allWeb
                store.shield.webDomainCategories = nil
            case .open:
                store.shield.webDomains = nil
                store.shield.webDomainCategories = nil
            case .all:
                assertionFailure("Broad full-web records must enter the broad branch")
                store.shield.webDomains = nil
                store.shield.webDomainCategories = .all()
            }
        }

        let broad = effective.shields.values.contains(where: \.appliesToAll)
        let shieldTokenCount = broad ? -1
            : Set(effective.shields.values.flatMap(\.appTokens)).count
              + Set(effective.shields.values.flatMap(\.categoryTokens)).count
              + Set(effective.shields.values.flatMap(\.webDomainTokens)).count
        emitEvent(kind: .decision, source: nil, app: "device-wide",
                  reason: broad ? "recompute_broad_lock" : "recompute_applied",
                  transition: .init(before: nil, after: "shield_tokens:\(shieldTokenCount)"))
        return effective.blocks.count
    }

    /// Symmetric to `removeShieldByHashAndRecompute` but for timed
    /// blocks: locate the BlockRecord whose bundleID hashes to this
    /// activity, drop it, then recompute `application.blockedApplications`
    /// from whatever's left.
    @discardableResult
    private func removeBlockByHashAndRecompute(hashHex: String) -> Bool {
        ActiveLockPersistenceLock.shared.withLock {
            removeBlockByHashAndRecomputeLocked(hashHex: hashHex)
        } ?? false
    }

    private func removeBlockByHashAndRecomputeLocked(hashHex: String) -> Bool {
        guard let blockData = defaults?.data(forKey: blocksKey),
              var blocks = decodeBlocks(from: blockData)
        else { return false }

        let target = blocks.keys.first { bundleID in
            let prefix = sha256Hex16(bundleID.data(using: .utf8) ?? Data())
            return prefix == hashHex
        }
        guard let bundleID = target else { return false }
        blocks.removeValue(forKey: bundleID)

        if let updated = encodeBlocks(blocks) {
            defaults?.set(updated, forKey: blocksKey)
        }

        // Re-derive blockedApplications from the surviving records.
        let blockedApps = Set(blocks.values.map { record in
            record.appToken.map(ManagedSettings.Application.init(token:))
                ?? ManagedSettings.Application(bundleIdentifier: record.bundleID)
        })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps
        return true
    }

    // MARK: - DAM heartbeat spike (throwaway diagnostics)

    /// SPIKE-ONLY. Re-arm a fresh 15-minute heartbeat window (start +60s) under
    /// the SAME activity name, from inside the extension process. Returns a
    /// short status ("rearm:ok" / "rearm:FAILED <err>") so the history log shows
    /// whether the extension can sustain its own heartbeat (the A2 ~15-min path)
    /// or whether only the main app can arm it (forcing the A1 tiled fallback).
    private func rearmHeartbeatSpike() -> String {
        let center = DeviceActivityCenter()
        let name = DeviceActivityName("evlin.command.heartbeat")
        let calendar = Calendar.current
        let start = Date().addingTimeInterval(60)
        let end = start.addingTimeInterval(15 * 60)
        let comps: Set<Calendar.Component> = [
            .calendar, .timeZone, .year, .month, .day, .hour, .minute, .second
        ]
        let schedule = DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(comps, from: start),
            intervalEnd: calendar.dateComponents(comps, from: end),
            repeats: false
        )
        do {
            try center.startMonitoring(name, during: schedule)
            return "rearm:ok"
        } catch {
            return "rearm:FAILED \(error.localizedDescription)"
        }
    }

    /// SPIKE-ONLY. Append one line to a capped (last 30) history array in the
    /// App Group + bump a running total, so the diagnostics view can show the
    /// whole fire sequence. Keys MUST match `CommandDeliveryDiagnostics`
    /// (`keyHeartbeatLog` / `keyHeartbeatCount`).
    private func appendHeartbeatSpikeLog(_ line: String) -> Int {
        let logKey = "evlin.spike.heartbeatLog"
        let countKey = "evlin.spike.heartbeatCount"
        var log = defaults?.stringArray(forKey: logKey) ?? []
        log.append(line)
        if log.count > 30 { log.removeFirst(log.count - 30) }
        defaults?.set(log, forKey: logKey)
        let count = (defaults?.integer(forKey: countKey) ?? 0) + 1
        defaults?.set(count, forKey: countKey)
        return count
    }

#if DEBUG
    private func runMeteringMonitorCapabilityProbe(
        sequence: Int,
        canonicalTimezone: String
    ) {
        let now = Date()
        guard let plan = MeteringMonitorCapabilityProbe.schedulePlan(
            origin: "dam",
            sequence: sequence,
            now: now,
            canonicalTimezone: canonicalTimezone
        ),
        let stoppedStart = plan.dateComponents(for: plan.stoppedStart),
        let supersededActiveStart = plan.dateComponents(
            for: plan.supersededActiveStart
        ),
        let replacementActiveStart = plan.dateComponents(
            for: plan.replacementActiveStart
        ),
        let end = plan.dateComponents(for: plan.end) else {
            MeteringMonitorCapabilityProbe.append(
                "origin=dam sequence=\(sequence) operation=validate result=error invalid_timezone=\(canonicalTimezone)",
                defaults: defaults
            )
            return
        }

        let formatter = ISO8601DateFormatter()
        let center = DeviceActivityCenter()
        let stoppedName = DeviceActivityName(plan.stoppedActivityName)
        let activeName = DeviceActivityName(plan.activeActivityName)

        func append(
            role: String,
            operation: String,
            result: String,
            expectedCallback: String
        ) {
            MeteringMonitorCapabilityProbe.append(
                "origin=dam sequence=\(sequence) role=\(role) operation=\(operation) result=\(result) expected_callback=\(expectedCallback)",
                defaults: defaults
            )
        }

        let stoppedSchedule = DeviceActivitySchedule(
            intervalStart: stoppedStart,
            intervalEnd: end,
            repeats: false
        )
        let stoppedExpected = formatter.string(from: plan.stoppedStart)
        do {
            try center.startMonitoring(stoppedName, during: stoppedSchedule)
            append(
                role: "stopped",
                operation: "start",
                result: "ok",
                expectedCallback: stoppedExpected
            )
        } catch {
            append(
                role: "stopped",
                operation: "start",
                result: "error=\(error.localizedDescription)",
                expectedCallback: stoppedExpected
            )
        }
        center.stopMonitoring([stoppedName])
        append(
            role: "stopped",
            operation: "stop",
            result: "called",
            expectedCallback: "suppressed@\(stoppedExpected)"
        )

        let supersededSchedule = DeviceActivitySchedule(
            intervalStart: supersededActiveStart,
            intervalEnd: end,
            repeats: false
        )
        let supersededExpected = formatter.string(from: plan.supersededActiveStart)
        do {
            try center.startMonitoring(activeName, during: supersededSchedule)
            append(
                role: "active",
                operation: "start",
                result: "ok",
                expectedCallback: supersededExpected
            )
        } catch {
            append(
                role: "active",
                operation: "start",
                result: "error=\(error.localizedDescription)",
                expectedCallback: supersededExpected
            )
        }

        let replacementSchedule = DeviceActivitySchedule(
            intervalStart: replacementActiveStart,
            intervalEnd: end,
            repeats: false
        )
        let replacementExpected = formatter.string(from: plan.replacementActiveStart)
        do {
            try center.startMonitoring(activeName, during: replacementSchedule)
            append(
                role: "active",
                operation: "replace_same_name",
                result: "ok",
                expectedCallback: replacementExpected
            )
        } catch {
            append(
                role: "active",
                operation: "replace_same_name",
                result: "error=\(error.localizedDescription)",
                expectedCallback: replacementExpected
            )
        }
    }
#endif
}

// CRITICAL: date strategy MUST match `ActiveLockStore.persist()` / `restore()`,
// which use `.iso8601` (dates as strings). A plain `JSONDecoder()` defaults to
// `.deferredToDate` (dates as numbers) and so FAILS to decode the main app's
// records — silently returning empty. When this extension recomputed on a
// shield interval-end, that empty read made it write
// `store.application.blockedApplications = nil`, wiping EVERY active block
// (e.g. unshielding a timed app cancelled its activity → intervalDidEnd → this
// recompute → all blocks dropped) even though the main app's records were
// intact. Keeping the strategy aligned is what makes the cross-process read
// faithful.
private func evlinJSONDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

private func evlinJSONEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}

private func encodeShields(_ shields: [String: ShieldRecord]) -> Data? {
    try? evlinJSONEncoder().encode(shields)
}

private func decodeBlocks(from data: Data) -> [String: BlockRecord]? {
    if let d = try? evlinJSONDecoder().decode([String: BlockRecord].self, from: data) { return d }
    return try? PropertyListDecoder().decode([String: BlockRecord].self, from: data)
}

private func encodeBlocks(_ blocks: [String: BlockRecord]) -> Data? {
    try? evlinJSONEncoder().encode(blocks)
}

private func sha256Hex16(_ data: Data) -> String {
    let hash = SHA256.hash(data: data)
    return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
}
