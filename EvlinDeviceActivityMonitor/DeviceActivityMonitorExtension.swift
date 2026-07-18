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

    /// Build the canonical day key in the backend policy timezone when known.
    private func currentDayKey() -> String {
        let context = EarnedTimeStore.shared.currentPolicyDateContext()
        return "\(context.usageDate)@\(context.timezoneIdentifier)"
    }

    private func authorizedEarnedGeneration(
        activityName: String
    ) -> EarnedActivityGeneration.Generation? {
        defaults?.synchronize()
        return EarnedActivityGeneration.authorizedCallback(
            activityName: activityName,
            currentDeviceID: defaults?.string(forKey: "evlin.childId"),
            lifecycle: EarnedActivityGeneration.loadLifecycle(defaults: defaults)
        )
    }

    private func earnedGenerationIsActive(
        _ generation: EarnedActivityGeneration.Generation
    ) -> Bool {
        EarnedActivityGeneration.isAuthorized(
            generation: generation,
            defaults: defaults
        )
    }

    @discardableResult
    private func performIfEarnedGenerationActive(
        _ generation: EarnedActivityGeneration.Generation,
        mutationKeys: [String] = [],
        rollbackExternalState: () -> Void = {},
        _ operation: () -> Void
    ) -> Bool {
        EarnedActivityGeneration.performIfAuthorized(
            generation: generation,
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

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

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
            Task { @MainActor in
                await DAMMeteringEntry.shared.recoverIfConfigured(
                    projectShields: { [weak self] shields in
                        self?.recomputeAndApplyShields(shields)
                    }
                )
            }
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
        if EarnedActivityGeneration.isEarnedActivityName(raw) {
            guard let generation = authorizedEarnedGeneration(activityName: raw) else { return }
            _ = ActiveLockPersistenceLock.shared.withLock {
                _ = performIfEarnedGenerationActive(
                    generation,
                    mutationKeys: [shieldsKey],
                    rollbackExternalState: {
                        recomputeAndApplyShields(loadShields())
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
        super.intervalDidEnd(for: activity)

        let raw = activity.rawValue
        // Diagnostic marker — every intervalDidEnd entry writes its name + ts
        // to the App Group so the main app can show "extension fired at X"
        // in Settings. Without this we can't tell whether iOS dispatched the
        // callback at all (vs the extension running but failing to clear).
        let ts = ISO8601DateFormatter().string(from: Date())
        let marker = "fired \(ts) activity=\(raw)"
        defaults?.set(marker, forKey: "evlin.lastIntervalDidEnd")
        NSLog("[Evlin/Ext] intervalDidEnd %@", marker)

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
                          let shields = decodeShields(from: data)
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
        super.eventDidReachThreshold(event, activity: activity)
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
            handleV2MeteringThreshold(event: event, activity: activity)
            return
        }
        // Per-app limit: the kid's usage of `<ruleId>`'s app crossed its daily
        // budget. The event name is `evlin.limit.<ruleId>` (see AppLimitPlanner).
        // Resolve the rule, write a `source == .limit` ShieldRecord, recompute.
        if event.rawValue.hasPrefix("evlin.limit.") {
            guard usageCountingAllowed(eventName: event.rawValue) else { return }
            applyLimitShield(eventName: event.rawValue)
        }

        // Per-app usage-bar MEASUREMENT: `evlin.applimit.<ruleId>.t<N>` fired at a
        // quarter of the budget. Report usage ONLY — the distinct `evlin.applimit.`
        // prefix routes it here and NEVER to the `evlin.limit.` shield branch above.
        if event.rawValue.hasPrefix("evlin.applimit.") {
            guard usageCountingAllowed(eventName: event.rawValue) else { return }
            reportAppLimitUsage(eventName: event.rawValue)
        }

        // B5 — Earned-time ladder threshold fired. Event name is `evlin.earned.t<N>`
        // (armed by `EarnedBudgetScheduler`). Two actions:
        //   1. POST an idempotent cumulative sample to the A2 backend (with retry queue).
        //   2. If N ≥ effective cap/tripwire AND no override flag → apply `.earnedTime`
        //      shield over the Locked-set tokens (pure App Group path, no actor).
        if event.rawValue.hasPrefix("evlin.earned.t"),
           EarnedActivityGeneration.isEarnedActivityName(activity.rawValue) {
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

    private func handleV2MeteringThreshold(
        event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        let project: ([String: ShieldRecord]) -> Void = { [weak self] shields in
            self?.recomputeAndApplyShields(shields)
        }
        do {
            let outcome = try DAMMeteringEntry.shared.handle(
                activityName: activity.rawValue,
                eventName: event.rawValue,
                observedAt: Date(),
                projectShields: project
            )
            NSLog("[Evlin/Ext] v2 metering callback %@", String(describing: outcome))
        } catch {
            NSLog("[Evlin/Ext] v2 metering callback failed: %@", String(describing: error))
        }
        Task { @MainActor in
            await DAMMeteringEntry.shared.recoverIfConfigured(
                projectShields: project
            )
        }
    }

    private func usageCountingAllowed(
        eventName: String,
        earnedGeneration: EarnedActivityGeneration.Generation? = nil
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

    /// Threshold-reached enforcement (P7). Parse the `ruleId` from the
    /// `evlin.limit.<ruleId>` event name, look the rule up in the App Group
    /// (`AppLimitRuleStore`), then insert/merge a `source == .limit` ShieldRecord
    /// (matchable by `ActiveLockStore.removeLimitShields`) and force a recompute so
    /// the app is shielded. If the rule isn't found (e.g. just cleared) we do
    /// nothing — there's nothing to shield.
    private func applyLimitShield(eventName: String) {
        let idString = String(eventName.dropFirst("evlin.limit.".count))
        guard let ruleId = UUID(uuidString: idString),
              let rule = AppLimitRuleStore.shared.rule(forID: ruleId) else {
            defaults?.set(
                "limit_threshold_norule event=\(eventName)",
                forKey: "evlin.lastLimitShield"
            )
            return
        }

        // Notify THEN lock: post the local "time's up" notice on the kid's
        // device before applying the shield, so the kid gets a heads-up the
        // moment the budget is hit. Cheap + crash-safe for the extension's
        // tight budget; if notification auth isn't granted, `add` silently
        // no-ops (the extension can't and must not request authorization).
        postLimitReachedNotification(ruleId: ruleId, rule: rule)

        _ = ActiveLockPersistenceLock.shared.withLock {
            let current = loadShields()
            let updated = LimitShieldLogic.applyingLimit(to: current, rule: rule)
            if let data = encodeShields(updated) {
                defaults?.set(data, forKey: shieldsKey)
            }
            recomputeAndApplyShields(updated)
        }

        let ts = ISO8601DateFormatter().string(from: Date())
        defaults?.set(
            "limit_shielded_at=\(ts) rule=\(ruleId.uuidString) key=\(LimitShieldLogic.recordKey(for: rule))",
            forKey: "evlin.lastLimitShield"
        )
        NSLog("[Evlin/Ext] limit threshold shielded rule=%@", ruleId.uuidString)
        emitEvent(kind: .lock, source: .perAppLimit,
                  app: LimitShieldLogic.recordKey(for: rule),
                  reason: "budget_reached",
                  transition: .init(before: "shielded:false", after: "shielded:true"))

        // Drive the parent's usage bar to 100%: post a `:budget` usage sample
        // (used == budget). This makes the bar read "reached" even for tiny
        // budgets that have no measurement thresholds. Additive — the shield is
        // untouched; usage reporting is a separate concern.
        let usageDate = EarnedTimeStore.shared.currentPolicyDateContext().usageDate
        postAppLimitUsageSample(
            ruleID: ruleId,
            thresholdMinutes: rule.budgetMinutes,
            estimatedMinutes: rule.budgetMinutes,
            clientSampleID: "applimit:\(ruleId.uuidString.lowercased()):\(usageDate):budget"
        )
    }

    /// Per-app usage-bar MEASUREMENT (never shields). Parse the
    /// `evlin.applimit.<ruleId>.t<N>` event name and POST N minutes used for that
    /// rule. The distinct `evlin.applimit.` prefix (routed here, NOT to
    /// `applyLimitShield`) is what keeps measurement from ever locking the app.
    private func reportAppLimitUsage(eventName: String) {
        let rest = String(eventName.dropFirst("evlin.applimit.".count))  // "<UUID>.t<N>"
        guard let sep = rest.range(of: ".t", options: .backwards) else { return }
        let idString = String(rest[..<sep.lowerBound])
        let nString = String(rest[sep.upperBound...])
        guard let ruleId = UUID(uuidString: idString), let n = Int(nString) else { return }
        postAppLimitUsageSample(
            ruleID: ruleId, thresholdMinutes: n, estimatedMinutes: n, clientSampleID: nil
        )
    }

    /// Drain the retry queue then POST one per-app usage sample via
    /// `AppLimitUsageReporter`. No shield. Uses the App-Group baseURL/childId the
    /// app mirrors for the extension (same source the earned-time reporter uses).
    private func postAppLimitUsageSample(
        ruleID: UUID, thresholdMinutes: Int, estimatedMinutes: Int, clientSampleID: String?
    ) {
        guard let baseURL = ExtensionConfig.baseURL,
              let deviceID = ExtensionConfig.childId else { return }
        let context = EarnedTimeStore.shared.currentPolicyDateContext()
        let usageDate = context.usageDate
        let tz = context.timezoneIdentifier
        let offset = EarnedTimeStore.shared.appLimitUsageOffsetMinutes(
            ruleID: ruleID,
            usageDate: usageDate
        )
        let isBudgetSample = clientSampleID?.hasSuffix(":budget") == true
        let adjustedThreshold = isBudgetSample ? thresholdMinutes : min(1440, offset + thresholdMinutes)
        let adjustedEstimate = isBudgetSample ? estimatedMinutes : min(1440, offset + estimatedMinutes)
        EarnedTimeStore.shared.recordAppLimitUsage(
            ruleID: ruleID,
            usageDate: usageDate,
            usedMinutes: adjustedEstimate
        )
        Task {
            await AppLimitUsageReporter.drainRetryQueue(baseURL: baseURL)
            await AppLimitUsageReporter.report(
                baseURL: baseURL, deviceID: deviceID, ruleID: ruleID,
                usageDate: usageDate, timezone: tz,
                thresholdMinutes: adjustedThreshold, estimatedMinutes: adjustedEstimate,
                clientSampleID: clientSampleID
            )
        }
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
        generation: EarnedActivityGeneration.Generation
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
        generation: EarnedActivityGeneration.Generation,
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
        let decision = EarnedSampleReporter.thresholdHandlingDecision(
            thresholdMinutes: adjustedN,
            isPlausible: true,
            localReconciliationAvailable: localReconciliation == .reconciled
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
            Task {
                let authorizationIsCurrent = {
                    EarnedActivityGeneration.isAuthorized(
                        generation: generation,
                        defaults: UserDefaults(suiteName: EarnedTimeStore.appGroupSuiteName)
                    )
                }
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

        guard decision.shouldApplyLocalShield else {
            _ = performIfEarnedGenerationActive(generation) {
                NSLog("[Evlin/Ext] earned threshold reported with local reconciliation deferred")
                emitEvent(kind: .decision, source: .earnedPool, app: "device-wide",
                          reason: "local_reconciliation_deferred")
            }
            return
        }
        guard earnedGenerationIsActive(generation) else { return }

        // Fresh-at-fire-time gate (Fix 4). The tripwire is the parent-set budget
        // read fresh from the store — NOT latestEstimate+backendRemaining (which
        // was a tautology: no writer for backendRemaining ⇒ effectiveCap ≤ adjustedN
        // ⇒ always fired). See EarnedGateTautologyTests.
        let poolMinutes = earnedStore.poolMinutes ?? 240
        let capMinutes  = earnedStore.capMinutes  ?? 240
        let usageDateForOverride = generation.usageDate

        guard EarnedSampleReporter.shouldApplyEarnedShieldFresh(
            adjustedN: adjustedN,
            poolMinutes: poolMinutes,
            capMinutes: capMinutes,
            usageDate: usageDateForOverride,
            store: earnedStore
        ) else {
            _ = performIfEarnedGenerationActive(generation) {
                emitEvent(kind: .decision, source: .earnedPool, app: "device-wide",
                          reason: "pool_under_cap")
            }
            return
        }

        // Defense-in-depth: a fresh backend sync with comfortable headroom vetoes
        // a LOCAL self-lock (the "backend same-second says rem=40" incident).
        if EarnedSampleReporter.backendVetoesSelfLock(
            lastBackendRemaining: earnedStore.backendRemainingAtLastSync,
            lastBackendSyncAt: earnedStore.lastBackendSyncAt,
            now: callbackAt
        ) {
            _ = performIfEarnedGenerationActive(generation) {
                emitEvent(kind: .drop, source: .earnedPool, app: "device-wide",
                          reason: "backend_headroom_veto")
            }
            return
        }
        guard earnedGenerationIsActive(generation) else { return }

        let boundSource: ScreenTimeEvent.Source =
            (capMinutes < poolMinutes && adjustedN >= capMinutes) ? .deviceCap : .earnedPool
        applyEarnedTimeShield(
            earnedStore: earnedStore,
            thresholdN: adjustedN,
            source: boundSource,
            generation: generation
        )
    }

    /// Apply the `.earnedTime` shield over the Locked-set tokens.
    ///
    /// Reads the Locked-set ID + token data from `EarnedTimeStore`, unions
    /// `.earnedTime` into the existing record (or creates one) via
    /// `ShieldSourceLogic.unioning`, persists, and recomputes.
    ///
    /// Pure App Group path — no actor, no `ActiveLockStore`.
    private func applyEarnedTimeShield(
        earnedStore: EarnedTimeStore,
        thresholdN: Int,
        source: ScreenTimeEvent.Source,
        generation: EarnedActivityGeneration.Generation
    ) {
        guard earnedGenerationIsActive(generation) else { return }
        guard let lockedSetID = earnedStore.lockedSetID else {
            _ = performIfEarnedGenerationActive(generation) {
                NSLog("[Evlin/Ext] earned shield: no lockedSetID in store — cannot shield")
            }
            return
        }

        // Route through the canonical helper (not raw interpolation) so this
        // stays in lockstep with any future normalization in `makeRecordKey`
        // (Wave-1 Task 5: helper now lowercases the savedList segment).
        let recordKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: lockedSetID)
        _ = ActiveLockPersistenceLock.shared.withLock {
            var current = loadShields()

            // Build the record if it doesn't exist yet; union .earnedTime if it does.
            if let existing = current[recordKey] {
                current[recordKey] = ShieldSourceLogic.unioning(existing, intoSources: [.earnedTime])
            } else {
                // Device-local union (paper-lock fix): earnedStore.lockedSetTokenData
                // is never actually populated anywhere in the app today (both
                // saveLockedSetID call sites pass tokenData: nil — ProfileView.swift,
                // CommandPoller.swift), so this blob decode was dead code. Read the
                // kid's live FamilyActivitySelection from DefaultLockGroupStore instead —
                // same ground-truth source ActionExecutor now uses on the parent-lock path.
                var appTokens: Set<ApplicationToken> = []
                var catTokens:  Set<ActivityCategoryToken> = []
                var webTokens:  Set<WebDomainToken> = []
                let localSelection = DefaultLockGroupStore.load()
                appTokens = localSelection.applicationTokens
                catTokens = localSelection.categoryTokens
                webTokens = localSelection.webDomainTokens
                // Legacy blob fallback, kept for completeness if a future writer
                // ever does populate lockedSetTokenData ahead of DefaultLockGroupStore.
                if appTokens.isEmpty && catTokens.isEmpty,
                   let blob = earnedStore.lockedSetTokenData,
                   let sel = try? JSONDecoder().decode(FamilyActivitySelection.self, from: blob) {
                    appTokens = sel.applicationTokens
                    catTokens = sel.categoryTokens
                    webTokens = sel.webDomainTokens
                }
                let record = ShieldRecord(
                    recordKey: recordKey,
                    tier: .savedList,
                    targetKey: lockedSetID,
                    displayName: "Locked Set",
                    lastCommandID: UUID(),
                    appTokens: appTokens,
                    categoryTokens: catTokens,
                    webDomainTokens: webTokens,
                    appliesToAll: earnedStore.lockedSetAllSelected,
                    issuedAt: Date(),
                    expiresAt: nil,
                    originalRequest: "earned time cap reached: t\(thresholdN)",
                    targetChildID: ExtensionConfig.childId ?? UUID(),
                    sources: [.earnedTime]
                )
                current[recordKey] = record
            }

            _ = performIfEarnedGenerationActive(
                generation,
                mutationKeys: [shieldsKey, "evlin.lastEarnedShield"],
                rollbackExternalState: {
                    recomputeAndApplyShields(loadShields())
                }
            ) {
                if let data = encodeShields(current) {
                    defaults?.set(data, forKey: shieldsKey)
                }
                recomputeAndApplyShields(current)

                let ts = ISO8601DateFormatter().string(from: Date())
                defaults?.set(
                    "earned_shielded_at=\(ts) t=\(thresholdN) key=\(recordKey)",
                    forKey: "evlin.lastEarnedShield"
                )
                NSLog("[Evlin/Ext] earned time cap reached t%d — .earnedTime shield applied", thresholdN)
                emitEvent(kind: .lock, source: source, app: "device-wide",
                          reason: source == .deviceCap ? "cap_exhausted" : "pool_exhausted",
                          transition: .init(before: "shielded:false", after: "shielded:true"))
            }
        }
    }

    /// B5 daily reset: strip ONLY `.earnedTime` from every shield record.
    /// Records with only `.earnedTime` are deleted; mixed records survive with
    /// their remaining sources. Preserves `.manual` and `.limit` sources.
    private func resetEarnedTimeShields(activity: String) {
        let current = loadShields()
        let stripped = ShieldSourceLogic.strippingSource(.earnedTime, from: current)
        let removedCount = current.count - stripped.count
        let modifiedCount = stripped.values.filter { rec in
            current[rec.recordKey]?.sources.contains(.earnedTime) == true
        }.count
        if let data = encodeShields(stripped) {
            defaults?.set(data, forKey: shieldsKey)
        }
        recomputeAndApplyShields(stripped)

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
    private func resetLimitShields(activity: String) {
        let dayKeyKey = "evlin.limitReset.dayKey"
        let today = EarnedTimeStore.shared.currentPolicyDateContext().usageDate
        let stored = defaults?.string(forKey: dayKeyKey)

        guard LimitShieldLogic.isDayBoundaryReset(storedDayKey: stored, today: today) else {
            defaults?.set(today, forKey: dayKeyKey)
            emitEvent(kind: .decision, source: .perAppLimit, app: "device-wide", reason: "rearm_restart_skip")
            NSLog("[Evlin/Ext] limit reset skipped (same-day re-arm) activity=%@ day=%@", activity, today)
            return
        }
        defaults?.set(today, forKey: dayKeyKey)

        var removedCount = 0
        var remainingCount = 0
        _ = ActiveLockPersistenceLock.shared.withLock {
            let current = loadShields()
            let stripped = LimitShieldLogic.strippingLimitShields(from: current)
            removedCount = current.count - stripped.count
            remainingCount = stripped.count
            if let data = encodeShields(stripped) {
                defaults?.set(data, forKey: shieldsKey)
            }
            recomputeAndApplyShields(stripped)
        }

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
    private func loadShields() -> [String: ShieldRecord] {
        guard let data = defaults?.data(forKey: shieldsKey),
              let decoded = decodeShields(from: data) else { return [:] }
        return decoded.mapValues { $0.normalizedForCurrentSchema().record }
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
        let shields: [String: ShieldRecord] = {
            guard let data = defaults?.data(forKey: shieldsKey),
                  let decoded = decodeShields(from: data) else { return [:] }
            return decoded.mapValues { record in
                let normalized = record.normalizedForCurrentSchema()
                migrated = migrated || normalized.migrated
                return normalized.record
            }
        }()

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

        let blockedApps = Set(blocks.values.map { ManagedSettings.Application(bundleIdentifier: $0.bundleID) })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps

        let broadRecords = shields.values.filter(\.appliesToAll)
        if !broadRecords.isEmpty {
            let includesFullWebShield = broadRecords.contains(where: \.isFullWebBroadShield)
            let allWeb = Set(shields.values.flatMap(\.webDomainTokens))
            store.shield.applicationCategories = .all()
            store.shield.applications = nil
            if includesFullWebShield {
                store.shield.webDomainCategories = .all()
                store.shield.webDomains = nil
            } else {
                store.shield.webDomainCategories = nil
                store.shield.webDomains = allWeb.isEmpty ? nil : allWeb
            }
        } else {
            let allApp = Set(shields.values.flatMap(\.appTokens))
            let allCat = Set(shields.values.flatMap(\.categoryTokens))
            let allWeb = Set(shields.values.flatMap(\.webDomainTokens))

            store.shield.applications = allApp.isEmpty ? nil : allApp
            store.shield.applicationCategories = allCat.isEmpty ? nil : .specific(allCat)
            store.shield.webDomains = allWeb.isEmpty ? nil : allWeb
            store.shield.webDomainCategories = nil
        }

        let broad = shields.values.contains(where: \.appliesToAll)
        let shieldTokenCount = broad ? -1
            : Set(shields.values.flatMap(\.appTokens)).count
              + Set(shields.values.flatMap(\.categoryTokens)).count
              + Set(shields.values.flatMap(\.webDomainTokens)).count
        emitEvent(kind: .decision, source: nil, app: "device-wide",
                  reason: broad ? "recompute_broad_lock" : "recompute_applied",
                  transition: .init(before: nil, after: "shield_tokens:\(shieldTokenCount)"))
        return blocks.count
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
        let blockedApps = Set(blocks.values.map {
            ManagedSettings.Application(bundleIdentifier: $0.bundleID)
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

/// Match `ActiveLockStore` — JSON for token-heavy `ShieldRecord`; plist only for legacy payloads.
private func decodeShields(from data: Data) -> [String: ShieldRecord]? {
    if let d = try? evlinJSONDecoder().decode([String: ShieldRecord].self, from: data) { return d }
    return try? PropertyListDecoder().decode([String: ShieldRecord].self, from: data)
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
