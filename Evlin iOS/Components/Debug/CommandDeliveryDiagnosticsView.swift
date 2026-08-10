import SwiftUI
import FamilyControls
import ManagedSettings
#if DEBUG
import DeviceActivity
#endif

struct CommandDeliveryDiagnosticsView: View {
    @State private var refreshTick: Int = 0
    @State private var sepSelection = FamilyActivitySelection(includeEntireCategory: false)
    @State private var sepShowPicker = false
    @State private var sepShieldStatus = "—"
#if DEBUG
    @State private var meteringRepairInProgress = false
    @State private var meteringRepairStatus: String?
    @State private var meteringNukeInProgress = false
    @State private var meteringNukeStatus: String?
    @State private var meteringRekickStatus: String?
#endif
    private let sepStore = ManagedSettingsStore(named: .init("evlin.sep.test"))

    var body: some View {
        List {
            Section {
                deliveryDiagnosticRow("APNs token registered", CommandDeliveryDiagnostics.keyTokenRegistered)
                deliveryDiagnosticRow("APNs token upload", CommandDeliveryDiagnostics.keyTokenUpload)
                deliveryDiagnosticRow("Remote notification", CommandDeliveryDiagnostics.keyRemoteNotification)
                deliveryDiagnosticRow("One-shot poll", CommandDeliveryDiagnostics.keyOneShotPoll)
                deliveryDiagnosticRow("Command poll", CommandDeliveryDiagnostics.keyCommandPoll)
                deliveryDiagnosticRow("Command ack", CommandDeliveryDiagnostics.keyCommandAck)
                deliveryDiagnosticRow("DAM heartbeat spike", CommandDeliveryDiagnostics.keyDAMHeartbeat)
                Button("Arm DAM heartbeat spike (starts in 2 min)") {
                    armDAMHeartbeatSpike()
                }
                Button(role: .destructive) {
                    BigKidActivityScheduler.shared.stopCommandHeartbeatSpike()
                    CommandDeliveryDiagnostics.record(
                        CommandDeliveryDiagnostics.keyDAMHeartbeat,
                        "stopped debug heartbeat schedule"
                    )
                    refreshTick += 1
                } label: {
                    Text("Stop DAM heartbeat spike")
                }
            } header: {
                Text("Command Delivery")
            } footer: {
                Text("Expected APNs path: token registered → token upload ok → remote notification received → one-shot poll completed → command ack ok. DAM heartbeat is a debug-only spike: arm it, background/lock/force-quit the app, then wait about 2 minutes to see whether the extension wakes and reports /child/heartbeat.")
            }

            mainThreadAuditSection
            earnedTimeDiagnosticsSection
            heartbeatHistorySection
            nseSpikeSection
#if DEBUG
            Section("Metering") {
                NavigationLink {
                    MeteringDaemonDiagnosticsView()
                } label: {
                    Label("Metering Daemon", systemImage: "gauge.with.dots.needle.67percent")
                }
                Button {
                    meteringRepairInProgress = true
                    meteringRepairStatus = "Repairing…"
                    Task {
                        meteringRepairStatus = await CommandDeliveryMeteringRepair.run()
                        meteringRepairInProgress = false
                        refreshTick += 1
                    }
                } label: {
                    Label("Repair metering activities", systemImage: "wrench.and.screwdriver")
                }
                .disabled(meteringRepairInProgress)

                if let meteringRepairStatus {
                    Text(meteringRepairStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // Same-name stop+start of today's ACTIVE route. Apple re-evaluates
                // and back-delivers already-met thresholds; by now the route is
                // fully active so the guard accepts what the instant delivery at
                // arm time raced past. Non-destructive (state machine untouched).
                Button {
                    meteringRekickStatus = "Re-kicking…"
                    Task { meteringRekickStatus = await MeteringTodayRouteRekick.run() }
                } label: {
                    Label("Re-kick today's route (same-name)", systemImage: "arrow.clockwise.circle")
                }

                if let meteringRekickStatus {
                    Text(meteringRekickStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // Repair only stops STALE activities, so it can't free Apple's
                // capacity when the exhaustion is held by retired-but-registered
                // routes (coverageExhausted). Nuclear reset stops EVERY activity
                // (frees capacity) + clears all shields/blocks; foreground
                // recovery then arms a fresh route.
                Button(role: .destructive) {
                    meteringNukeInProgress = true
                    meteringNukeStatus = "Resetting…"
                    Task {
                        meteringNukeStatus = await MeteringNuclearReset.run(includeMeteringStore: true)
                        meteringNukeInProgress = false
                        refreshTick += 1
                    }
                } label: {
                    Label("Nuclear Reset (frees Apple capacity)", systemImage: "exclamationmark.triangle.fill")
                }
                .disabled(meteringNukeInProgress)

                if let meteringNukeStatus {
                    Text(meteringNukeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            meteringMonitorProbeSection
            Section {
                blockedApplicationsReadbackRows
            } header: {
                Text("Blocked Applications Readback")
            } footer: {
                Text("Live read of ManagedSettingsStore.application.blockedApplications — what iOS is actually holding, not what we recorded. Use to tell a lost write apart from a write iOS accepted but does not enforce.")
                    .font(.system(size: 11))
            }
            AppLimitOneMinuteProbeView()
#endif
            pickerSeparationSection
        }
        .navigationTitle("Command Delivery")
        .toolbar {
            Button("Refresh") {
                refreshTick += 1
            }
        }
        .familyActivityPicker(isPresented: $sepShowPicker, selection: $sepSelection)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refreshTick += 1
            }
        }
    }

    @ViewBuilder
    private var earnedTimeDiagnosticsSection: some View {
        let store = EarnedTimeStore.shared
        Section {
            earnedRow("usageCountingAllowed", store.usageCountingAllowed ? "true" : "false")
            earnedRow("last skipped usage event", CommandDeliveryDiagnostics.read(CommandDeliveryDiagnostics.keyUsageCountingLastSkipped))
            earnedRow("last identity teardown", CommandDeliveryDiagnostics.read(CommandDeliveryDiagnostics.keyEarnedIdentityTransition))
            earnedRow("last arm attempt", CommandDeliveryDiagnostics.read(CommandDeliveryDiagnostics.keyEarnedArmAttempt))
            earnedRow("last earned threshold", CommandDeliveryDiagnostics.read(CommandDeliveryDiagnostics.keyEarnedLastThreshold))
            earnedRow("last sample POST", CommandDeliveryDiagnostics.read(EarnedSampleReporter.lastSamplePostDebugKey))
            earnedRow("retry queue", EarnedSampleReporter.retryQueueDebugSummary())
            earnedRow("latestDeviceEstimate", optionalMinutes(store.latestDeviceEstimate))
            earnedRow("usage offset", "\(store.earnedUsageOffsetMinutes) min")
            earnedRow("backend remaining", optionalMinutes(store.backendRemainingAtLastSync))
            earnedRow("pool / cap", "\(optionalMinutes(store.poolMinutes)) / \(optionalMinutes(store.capMinutes))")
            earnedRow("baseURL", CommandDeliveryDiagnostics.read("evlin.baseURL"))
            earnedRow("childId", CommandDeliveryDiagnostics.read("evlin.childId"))
            earnedRow("measurement selection", measurementSelectionSummary(store.measurementSelection))
            earnedRow("locked set id", store.lockedSetID ?? "(missing)")

            Button(role: .destructive) {
                CommandDeliveryDiagnostics.remove(CommandDeliveryDiagnostics.keyEarnedLastThreshold)
                CommandDeliveryDiagnostics.remove(CommandDeliveryDiagnostics.keyEarnedArmAttempt)
                CommandDeliveryDiagnostics.remove(CommandDeliveryDiagnostics.keyEarnedIdentityTransition)
                CommandDeliveryDiagnostics.remove(CommandDeliveryDiagnostics.keyUsageCountingLastSkipped)
                CommandDeliveryDiagnostics.remove(EarnedSampleReporter.lastSamplePostDebugKey)
                EarnedSampleReporter.clearRetryQueue()
                refreshTick += 1
            } label: {
                Text("Clear earned-time diagnostics")
            }
        } header: {
            Text("Earned Time")
        } footer: {
            Text("If the total pool stops moving, check this section. No new last threshold means DeviceActivity stopped firing. last skipped means unfinished-task gating blocked it. Retry queue or failed POST means the extension fired but could not reach the backend.")
        }
        .id("earned-\(refreshTick)")
    }

    private func earnedRow(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .font(.system(size: 12, weight: .semibold))
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func optionalMinutes(_ value: Int?) -> String {
        value.map { "\($0) min" } ?? "(missing)"
    }

    private func measurementSelectionSummary(_ selection: FamilyActivitySelection?) -> String {
        guard let selection else { return "(missing)" }
        return "apps=\(selection.applicationTokens.count) categories=\(selection.categoryTokens.count) web=\(selection.webDomainTokens.count)"
    }

    /// Debug-only acceptance gate for the App Controls v2 redesign. The whole
    /// "app vs category clean separation" rests on a combined picker opened with
    /// `includeEntireCategory: false` keeping app/category tokens in disjoint
    /// buckets. `ScreenTimeManager`'s comment claims the opposite, so this must be
    /// settled on a real authorized device before building on it. Uses an isolated
    /// named store so the shield test never touches the real lock.
    @ViewBuilder
    private var blockedApplicationsReadbackRows: some View {
        let held = ManagedSettingsStore().application.blockedApplications
        if let held, !held.isEmpty {
            ForEach(Array(held).indices, id: \.self) { index in
                let app = Array(held)[index]
                Text(app.bundleIdentifier ?? "(token-only entry)")
                    .font(.system(size: 12, design: .monospaced))
            }
            Text("count=\(held.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(held == nil ? "nil (no denylist set)" : "empty set")
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var pickerSeparationSection: some View {
        Section {
            Button("Open picker (includeEntireCategory = false)") {
                sepShowPicker = true
            }
            Button(role: .destructive) {
                sepSelection = FamilyActivitySelection(includeEntireCategory: false)
                sepShieldStatus = "—"
            } label: {
                Text("Reset selection")
            }

            sepRow("includeEntireCategory", sepSelection.includeEntireCategory ? "true  ⚠️" : "false")
            sepRow("applicationTokens", "\(sepSelection.applicationTokens.count)")
            sepRow("categoryTokens", "\(sepSelection.categoryTokens.count)")
            sepRow("webDomainTokens", "\(sepSelection.webDomainTokens.count)")

            Button("Shield current selection") {
                sepStore.shield.applicationCategories = sepSelection.categoryTokens.isEmpty
                    ? nil
                    : .specific(sepSelection.categoryTokens)
                sepStore.shield.applications = sepSelection.applicationTokens.isEmpty
                    ? nil
                    : sepSelection.applicationTokens
                sepShieldStatus = "Shielded \(sepSelection.categoryTokens.count) categories + \(sepSelection.applicationTokens.count) apps. Now open an app in that category — it should be blocked."
            }
            Button(role: .destructive) {
                sepStore.clearAllSettings()
                sepShieldStatus = "Cleared all shields."
            } label: {
                Text("Unshield (clear)")
            }
            Text(sepShieldStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Picker separation test (includeEntireCategory = false)")
        } footer: {
            Text("Run three times: (a) one category only, (b) one app only, (c) one app + one category. PASS = the category-only run gives applicationTokens = 0 and categoryTokens ≥ 1 (buckets disjoint, no expansion), AND shielding a category actually blocks its apps. Both true → the App Controls v2 separation design is safe.")
        }
    }

    private func sepRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// SPIKE: shows the whole heartbeat-fire history (newest first) + the
    /// self-rearm result on each line, so a force-quit experiment reveals both
    /// the cadence and whether the extension can sustain its own heartbeat.
    @ViewBuilder
    private var heartbeatHistorySection: some View {
        Section {
            if heartbeatLog.isEmpty {
                Text("No heartbeat fires recorded yet.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(heartbeatLog.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Button(role: .destructive) {
                CommandDeliveryDiagnostics.clearHeartbeatLog()
                refreshTick += 1
            } label: {
                Text("Clear heartbeat history")
            }
        } header: {
            Text("Heartbeat history — total fires: \(heartbeatTotal)")
        } footer: {
            Text("Each line = one extension intervalDidStart fire + whether it could self-rearm. Several lines with rearm:ok = the extension sustains its own heartbeat (path A2, ~15-min). rearm:FAILED = only the main app can arm it (fall back to A1 tiled windows). Empty after force-quit + heavy phone use = the window doesn't wake under force-quit at all.")
        }
        .id("hb-\(refreshTick)")
    }

    private var heartbeatLog: [String] {
        CommandDeliveryDiagnostics.readLog(CommandDeliveryDiagnostics.keyHeartbeatLog)
    }

    private var heartbeatTotal: Int {
        CommandDeliveryDiagnostics.readInt(CommandDeliveryDiagnostics.keyHeartbeatCount)
    }

    /// SPIKE: shows whether the EvlinPushApplier NSE woke + applied a shield on
    /// each alert push — the decisive force-quit-resilience test. The block it
    /// applies (Safari, via an isolated named store) is cleared with the button.
    @ViewBuilder
    private var nseSpikeSection: some View {
        Section {
            if nseLog.isEmpty {
                Text("No NSE fires recorded yet.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(nseLog.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Button(role: .destructive) {
                ManagedSettingsStore(named: .init("evlin.nsespike")).clearAllSettings()
                refreshTick += 1
            } label: {
                Text("Clear NSE test block (unblocks Safari)")
            }
        } header: {
            Text("NSE force-quit spike — total fires: \(nseTotal)")
        } footer: {
            Text("Force-quit the kid app, then have the backend fire one alert push. If a line appears here saying the shield applied AND Safari shows the block screen while Evlin is force-quit, the NSE path works. The test block uses an isolated store; tap Clear to remove it.")
        }
        .id("nse-\(refreshTick)")
    }

    private var nseLog: [String] {
        CommandDeliveryDiagnostics.readLog(CommandDeliveryDiagnostics.keyNSELog)
    }

    private var nseTotal: Int {
        CommandDeliveryDiagnostics.readInt(CommandDeliveryDiagnostics.keyNSECount)
    }

#if DEBUG
    @ViewBuilder
    private var meteringMonitorProbeSection: some View {
        Section {
            earnedRow("latest result", meteringMonitorProbeLatestResult)

            if meteringMonitorProbeLog.isEmpty {
                Text("No metering monitor probe results yet.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    Array(meteringMonitorProbeLog.reversed().enumerated()),
                    id: \.offset
                ) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Button {
                clearMeteringMonitorProbe()
                do {
                    try BigKidActivityScheduler.shared.startCommandHeartbeatSpike(
                        delaySeconds: 30
                    )
                } catch {
                    MeteringMonitorCapabilityProbe.append(
                        "control operation=arm_dam_heartbeat result=error=\(error.localizedDescription)",
                        defaults: meteringMonitorProbeDefaults
                    )
                }
                refreshTick += 1
            } label: {
                Label("Run DAM monitor probe", systemImage: "play.fill")
            }

            Button(role: .destructive) {
                clearMeteringMonitorProbe()
                refreshTick += 1
            } label: {
                Label("Clear monitor probe results", systemImage: "trash")
            }
        } header: {
            Text("Metering Monitor Capability")
        }
        .id("metering-monitor-probe-\(refreshTick)")
    }

    private var meteringMonitorProbeDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.evlin.ios")
    }

    private var meteringMonitorProbeLog: [String] {
        meteringMonitorProbeDefaults?.stringArray(
            forKey: MeteringMonitorCapabilityProbe.logKey
        ) ?? []
    }

    private var meteringMonitorProbeLatestResult: String {
        meteringMonitorProbeDefaults?.string(
            forKey: MeteringMonitorCapabilityProbe.callbackKey
        ) ?? meteringMonitorProbeLog.last
        ?? "(none)"
    }

    private func clearMeteringMonitorProbe() {
        meteringMonitorProbeDefaults?.removeObject(
            forKey: MeteringMonitorCapabilityProbe.logKey
        )
        meteringMonitorProbeDefaults?.removeObject(
            forKey: MeteringMonitorCapabilityProbe.callbackKey
        )
    }
#endif

    /// Screen Time calls that ran on the main thread, with the stack that got
    /// there. Every entry is a watchdog kill waiting for a daemon that does not
    /// answer within ten seconds — which is how the app died on 2026-08-08.
    ///
    /// Empty is the goal, and after normal use it is also the evidence that the
    /// remaining un-routed call sites are cold and can wait.
    @ViewBuilder
    private var mainThreadAuditSection: some View {
        let sites = DeviceActivityMainThreadAudit.recordedSites()
        let refusals = MeteringDeviceActivityGateway.recordedRefusals()
        Section {
            if sites.isEmpty {
                Label("No main-thread Screen Time calls recorded", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(sites.enumerated()), id: \.offset) { _, site in
                    Text(site)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if !refusals.isEmpty {
                ForEach(Array(refusals.enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Text("In flight now: \(MeteringDeviceActivityGateway.inFlightCount())")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                DeviceActivityMainThreadAudit.reset()
                refreshTick += 1
            } label: {
                Text("Clear recorded sites")
            }
        } header: {
            Text("Main-thread Screen Time calls")
        } footer: {
            Text("Each line is one call site that ran a synchronous Screen Time call on the main thread, newest last, with the call stack. These are the remaining watchdog-kill risks (0x8BADF00D). Use the app normally — onboarding, adding and changing limits, locking and unlocking, leaving it overnight — then send this list. Orange lines are calls the gateway refused because too many were already stuck.")
        }
    }

    @ViewBuilder
    private func deliveryDiagnosticRow(_ title: String, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(CommandDeliveryDiagnostics.read(key))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .id("\(key)-\(refreshTick)")
        }
        .padding(.vertical, 2)
    }

    private func armDAMHeartbeatSpike() {
        do {
            try BigKidActivityScheduler.shared.startCommandHeartbeatSpike()
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyDAMHeartbeat,
                "armed debug heartbeat schedule; expected intervalDidStart in ~2 min"
            )
        } catch {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyDAMHeartbeat,
                "failed to arm debug heartbeat schedule error=\(error.localizedDescription)"
            )
        }
        refreshTick += 1
    }
}

#if DEBUG
/// K-device-only recovery tool. It removes only stale Evlin metering activities,
/// then reuses the production recovery paths. It never clears selections,
/// accounting data, ManagedSettings, or lock records.
nonisolated enum CommandDeliveryMeteringRepair {
    static func staleEarnedActivityNames(
        liveActivityNames: Set<String>,
        desiredEarnedActivityNames: Set<String>
    ) -> [String] {
        liveActivityNames
            .filter {
                (LegacyMeteringActivity.isEarnedActivityName($0)
                    || $0.hasPrefix(MeteringRouteNamespace.prefix))
                    && !desiredEarnedActivityNames.contains($0)
            }
            .sorted()
    }

    @MainActor
    static func run() async -> String {
        guard let owner = MeteringOwnerMirror.current() else {
            return "Not repaired: missing K-device identity."
        }

        let repairTask: Task<(Bool, String), Never> = Task.detached(priority: .userInitiated) {
            let center = SystemMeteringDeviceActivityCenter()
            let epochStore = DeviceEpochStore.shared
            let state: DeviceEpochStoreState
            do {
                state = try epochStore.read()
            } catch {
                return (false, "Not repaired: could not read metering state: \(error)")
            }
            guard state.ownerChildDeviceID == owner else {
                return (false, "Not repaired: metering owner does not match this K device.")
            }

            let desiredNames = Set(state.installWork.values.compactMap { work -> String? in
                guard work.ownerChildDeviceID == owner,
                      work.retry.terminal == .pending || work.retry.terminal == .succeeded,
                      work.phase != .pendingStop,
                      work.phase != .stopped,
                      let route = state.routes[work.routeID],
                      route.lifecycle == .planned || route.lifecycle == .active
                else { return nil }
                return route.activityName
            })
            let staleNames = staleEarnedActivityNames(
                liveActivityNames: Set(center.activities.map(\.rawValue)),
                desiredEarnedActivityNames: desiredNames
            )
            if !staleNames.isEmpty {
                center.stopMonitoring(staleNames.map { DeviceActivityName($0) })
            }

            do {
                try epochStore.transaction(expectedOwner: owner) { state in
                    for key in state.installWork.keys {
                        guard var work = state.installWork[key],
                              work.ownerChildDeviceID == owner,
                              work.retry.terminal == .pending
                        else { continue }
                        switch work.phase {
                        case .pendingStart, .starting, .installed:
                            work.phase = .pendingStart
                            work.claim = nil
                            work.retry.nextAttemptAt = Date()
                            state.installWork[key] = work
                        case .verified, .dualActive, .active, .pendingStop, .stopped:
                            continue
                        }
                    }
                }
            } catch {
                return (false, "Not repaired: could not schedule earned recovery: \(error)")
            }

            let perApp = AppLimitPlanner().arm(rules: AppLimitRuleStore.shared.all())
            let perAppText: String
            switch perApp {
            case .armed(let activities, let events):
                perAppText = "per-app armed (\(activities) activities, \(events) events)"
            case .partiallyArmed(let armed, let failed):
                perAppText = "per-app partial (\(armed) armed, \(failed) failed)"
            case .quotaExceeded(let windows, let needed, let cap):
                perAppText = "per-app quota exceeded (\(windows) windows, \(needed)/\(cap) slots)"
            }
            return (
                true,
                "Stopped \(staleNames.count) stale earned activities; \(perAppText); earned recovery requested."
            )
        }
        let result = await repairTask.value

        guard result.0 else { return result.1 }
        await AppMeteringEntry.shared.recoverIfConfigured()
        await AppLimitRecoveryTrigger.foreground()
        return result.1
    }
}
#endif
