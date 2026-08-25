import SwiftUI

nonisolated struct DeviceAppsDisplayState: Equatable {
    let hasMatchedApps: Bool
    let deviceCapMinutes: Int?
    let poolMinutes: Int?

    var showsDeviceCap: Bool {
        deviceCapMinutes != nil || poolMinutes != nil
    }

    var showsPerAppLimits: Bool {
        hasMatchedApps
    }
}

/// Per-app management for one device. Mirrors HTML 563-625.
/// Each row: app icon + name + toggle + tappable limit pill + progress bar.
/// Tap pill → expands inline 7-option limit picker (15/20/30/45/60/90/120 min).
///
/// HP-12: there is no backend for per-app usage/limits yet. At RUNTIME this
/// screen renders an honest "App limits coming soon" placeholder (the old
/// behavior keyed `DeviceAppsMockData` fixtures on literal "liam"/"maya", so
/// every real child saw emma's fake apps with invented usage). The fixture
/// rows are preview-only via `fixtureApps` (see #Preview below).
struct DeviceAppsSheet: View {
    let device: DeviceItem
    let childId: String
    var onClose: () -> Void = {}
    /// Preview-only seed. Runtime callers (ContentView's `.deviceDetail`
    /// route) leave this nil and trigger the real catalog fetch.
    var fixtureApps: [DeviceAppItem]? = nil

    @EnvironmentObject private var apiClient: APIClient
    @AppStorage("evlin.childDeviceID") private var pairedChildID: String = ""
    @AppStorage("evlin.familyID") private var pairedFamilyID: String = ""

    @State private var apps: [DeviceAppItem] = []
    /// Refreshes real usage while this detail page is visible. It is stopped
    /// while a parent is editing a limit so a background response cannot
    /// replace an optimistic value mid-interaction.
    @State private var refreshTask: Task<Void, Never>? = nil

    /// First-visit App Limits spotlight tour (device cap → per-app toggles →
    /// midnight reset). Starts only once apps have loaded so every anchor
    /// exists; seen-flag flips at display time.
    @AppStorage("parentDeviceLimitsTourSeen") private var deviceLimitsTourSeen = false
    @State private var showDeviceTour = false
    /// B-hardening: resolved-icon backfill (onAppear step 3) writes ONLY here,
    /// never into `apps`. Writing into `apps[i].artworkURL` per-icon caused a
    /// SwiftUI re-render of every row over several seconds after sheet-open;
    /// combined with the per-row hand-rolled `Toggle` binding (unstable
    /// identity), unrelated churn could fire ANOTHER row's toggle set closure
    /// — the suspected mechanism behind a phantom limit toggle on an app the
    /// parent never touched. Keyed by bundleID (see `appRow`'s lookup).
    @State private var artworkByBundleID: [String: URL] = [:]
    @State private var editingLimitFor: String? = nil
    @State private var isLoading = false
    @State private var loadFailed = false
    /// Inline error after a failed set/clear (the local change is reverted and
    /// this message shown briefly under the list, then auto-dismissed).
    @State private var actionError: String? = nil
    /// Auto-dismiss timer for `actionError`; replaced (cancelling the prior)
    /// each time a new error is surfaced so the ~4s window restarts.
    @State private var errorDismissTask: Task<Void, Never>? = nil
    /// Per-app monotonic supersession token. Bumped at the START of each
    /// `pickLimit`/`toggleLimit`; the captured value gates whether that
    /// interaction's response may still mutate state once its `await` resumes
    /// (see `AppLimitEditDecision`). Keeps the latest interaction authoritative.
    @State private var inflightSeq: [String: Int] = [:]
    @State private var appLimitEditQueue = AppLimitEditQueue()

    // B9: device-cap + dynamic picker options
    /// The device's current daily cap in minutes. Nil = not yet loaded / not configured.
    @State private var deviceCapMinutes: Int? = nil
    /// The family's earned-time pool. Shown alongside the cap: "/ of {pool} shared".
    @State private var poolMinutes: Int? = nil
    /// Policy-provided allowed cap options for this device (≤ pool, filtered by EarnedCapOptions).
    @State private var capOptions: [Int] = []
    /// Policy-provided allowed per-app options. Nil = use fallback base set.
    @State private var policyAppOptions: [Int]? = nil
    /// Cap picker expansion flag.
    @State private var showCapPicker = false
    /// Cap save in-flight.
    @State private var capSaving = false
    /// Cascade confirm: when non-nil, show the confirm sheet.
    @State private var pendingCascade: EarnedCascadeDecision.Result? = nil
    /// The cap the parent asked for while a cascade confirm is pending.
    @State private var pendingCascadeCap: Int?

    /// Family id for parent API calls — sourced the same way ProfileView's
    /// lock-all does (`UserDefaults` "evlin.familyID"). `nil` until paired.
    private var familyID: UUID? { UUID(uuidString: pairedFamilyID) }
    /// Target device for this sheet. Runtime callers pass the tapped device;
    /// previews/legacy callers may fall back to the locally paired device id.
    private var childDeviceID: UUID? {
        DeviceTargetResolver.selectedChildDeviceID(
            tappedDeviceUUID: device.deviceUUID,
            pairedChildDeviceID: pairedChildID
        )
    }

    private var displayState: DeviceAppsDisplayState {
        DeviceAppsDisplayState(
            hasMatchedApps: !apps.isEmpty,
            deviceCapMinutes: deviceCapMinutes,
            poolMinutes: poolMinutes
        )
    }

    private var deviceTourSteps: [TourStep] {
        [
            TourStep(target: "device.cap",
                     text: "\(device.name)'s daily total. It draws from the family's shared screen-time pool."),
            TourStep(target: "device.apps",
                     text: "App Limits: flip a toggle to give an app its own daily budget, then tap the pill to pick the minutes."),
            TourStep(target: "device.reset",
                     text: "Every limit here resets at midnight — a fresh budget each day.",
                     cornerRadius: 12),
        ]
    }

    private func maybeStartDeviceTour() {
        guard !deviceLimitsTourSeen else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !deviceLimitsTourSeen, !apps.isEmpty else { return }
            deviceLimitsTourSeen = true   // mark at display time
            withAnimation(.easeOut(duration: 0.3)) { showDeviceTour = true }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isLoading && apps.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if !displayState.showsPerAppLimits {
                emptyPlaceholder
            } else {
                // Reader lets the first-visit App Limits tour scroll targets
                // (e.g. the reset note) into view.
                ScrollViewReader { tourProxy in
                ScrollView {
                    // B9: Device-cap card — shown at the top when a cap or pool
                    // value is available. "Daily total for this device / of {pool} shared".
                    if displayState.showsDeviceCap {
                        deviceCapCard
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .tourTarget("device.cap")
                            .id("device.cap")
                    }

                    VStack(spacing: 0) {
                        // Layer 2: `ForEach($apps)` gives each row a STABLE identity
                        // bound directly to its element (DeviceAppItem.id is the
                        // backend-derived aliasKey UUID string — not a fresh UUID()
                        // per render), instead of a plain function re-invoked with a
                        // value copy on every parent re-render. Combined with the
                        // extracted `DeviceAppRow` view, this stops unrelated state
                        // churn (e.g. the artwork backfill) from destabilizing which
                        // row's Toggle closure is live.
                        ForEach($apps) { $app in
                            let idx = apps.firstIndex(where: { $0.id == app.id }) ?? 0
                            DeviceAppRow(
                                app: $app,
                                resolvedArtworkURL: app.artworkURL ?? app.bundleID.flatMap { artworkByBundleID[$0] },
                                isEditingLimit: editingLimitFor == app.id,
                                onToggleEditingLimit: {
                                    editingLimitFor = (editingLimitFor == app.id) ? nil : app.id
                                },
                                limitPicker: { limitPicker(for: app) },
                                onToggle: { newValue in toggleLimit(for: app, on: newValue) }
                            )
                            if idx < apps.count - 1 {
                                Rectangle()
                                    .fill(Color.evOutlineVariant.opacity(0.4))
                                    .frame(height: 1)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.evSurfaceContainerLowest)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .tourTarget("device.apps")
                    .id("device.apps")

                    if let actionError {
                        Text(actionError)
                            .font(.custom("Inter", size: 11).weight(.semibold))
                            .foregroundStyle(Color.evError)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.top, 10)
                            // Reachable by VoiceOver (in addition to the
                            // announcement posted when the error is set).
                            .accessibilityHidden(false)
                            .accessibilityLabel(actionError)
                    }

                    // Footer: daily-reset note (the limits the parent sets here
                    // reset every midnight on the kid device).
                    Text("Limits reset daily at midnight.")
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 110)
                        .tourTarget("device.reset")
                        .id("device.reset")
                }
                .refreshable {
                    await reloadApps()
                }
                .onReceive(NotificationCenter.default.publisher(for: .evlinTourStepChanged)) { note in
                    guard let target = note.userInfo?["target"] as? String,
                          target.hasPrefix("device.") else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        tourProxy.scrollTo(target, anchor: .center)
                    }
                }
                }
            }
        }
        .background(Color.evSurfaceContainerLow)
        // Pushed onto the parent NavigationStack — hide the system nav
        // bar and rely on this view's own header arrow / edge-swipe.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        // App Limits first-visit tour: wait for the app list (anchors) to exist.
        .onChange(of: apps.isEmpty) { _, empty in
            if !empty { maybeStartDeviceTour() }
        }
        .onAppear { if !apps.isEmpty { maybeStartDeviceTour() } }
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            if showDeviceTour {
                SpotlightTourOverlay(steps: deviceTourSteps,
                                     anchors: anchors,
                                     lastButtonTitle: "Done",
                                     onStepChange: { target in
                    // The ScrollViewReader inside the list listens for this.
                    NotificationCenter.default.post(name: .evlinTourStepChanged,
                                                    object: nil,
                                                    userInfo: ["target": target])
                }) {
                    withAnimation(.easeOut(duration: 0.25)) { showDeviceTour = false }
                }
            }
        }
        .onAppear {
            Task {
                await loadAppsIfNeeded()
            }
            startAutoRefresh()
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
        // B9: cascade-confirm sheet.
        .sheet(item: Binding(
            get: { pendingCascade.map { CascadeConfirmItem(result: $0) } },
            set: { if $0 == nil { pendingCascade = nil } }
        )) { item in
            EarnedCascadeConfirmSheet(
                result: item.result,
                summary: "Lowering this device's limit may reduce app limits.",
                onApply: { effective in
                    pendingCascade = nil
                    // Re-send the REQUESTED cap, not `deviceCapMinutes`: the
                    // optimistic value is rolled back when the backend answers
                    // `needs_confirmation`, so reading it here would re-submit
                    // the OLD cap and the confirm button would do nothing.
                    if let cap = pendingCascadeCap ?? deviceCapMinutes {
                        pendingCascadeCap = nil
                        saveDeviceCap(cap, confirmedCascade: true, effective: effective)
                    }
                },
                onCancel: {
                    pendingCascade = nil
                    pendingCascadeCap = nil
                }
            )
        }
        // Device daily total — a slider, matching the Daily Screen Time rule so
        // the two related limits are edited the same way. Save still goes
        // through `saveDeviceCap`, so the cascade gate above still fires when
        // the new total would clamp an existing app limit.
        .sheet(isPresented: $showCapPicker) {
            if let pool = poolMinutes {
                DeviceDailyTotalEditor(
                    currentMinutes: deviceCapMinutes,
                    poolMinutes: pool
                ) { newCap in
                    saveDeviceCap(newCap, confirmedCascade: false)
                }
            }
        }
    }

    @MainActor
    private func loadAppsIfNeeded() async {
        guard apps.isEmpty else { return }
        await reloadApps()
    }

    @MainActor
    private func reloadApps() async {
        guard !isLoading else { return }
        if let fixtureApps {
            apps = fixtureApps
            return
        }
        guard let cid = childDeviceID else { return }
        isLoading = true
        loadFailed = false

        // Load policy before the catalog so the first rendered pill already
        // respects the current device cap.
        if let childProfileID = UUID(uuidString: childId),
           let policy = try? await apiClient.fetchEarnedPolicy(childProfileID: childProfileID) {
            poolMinutes = policy.pool_minutes
            policyAppOptions = policy.allowed_app_options
            if let devEntry = policy.devices?.first(where: { $0.child_device_id == cid }) {
                deviceCapMinutes = devEntry.device_cap_minutes ?? policy.pool_minutes
                capOptions = EarnedCapOptions.compute(
                    policyCapOptions: devEntry.allowed_cap_options,
                    poolMinutes: policy.pool_minutes ?? Int.max)
            } else {
                deviceCapMinutes = policy.daily_cap_minutes ?? policy.pool_minutes
                capOptions = []
            }
        }

        do {
            let targets = try await apiClient.fetchLazyTagCatalogTargets(childDeviceID: cid)
            let appTargets = targets.filter { $0.type == .app }
            let defaultPill = EarnedAppOptions.defaultPill(deviceCap: deviceCapMinutes ?? 60)
            let catalogApps = appTargets.map { target in
                DeviceAppItem(
                    id: target.aliasKey.uuidString,
                    name: NameWithIcon.displayName(target.displayName),
                    iconSystemName: "app.fill",
                    brandColor: Color.evPrimary,
                    bgColor: Color.evPrimaryContainer,
                    enabled: false,
                    usedMin: 0,
                    limitMin: defaultPill,
                    artworkURL: target.artworkURL,
                    bundleID: target.bundleID
                )
            }
            var merged = catalogApps
            if let famID = familyID {
                let rules = (try? await apiClient.listAppLimits(
                    familyID: famID,
                    childDeviceID: cid
                )) ?? []
                let summaries = rules.map {
                    AppLimitRuleSummary(
                        ruleID: $0.rule_id,
                        bundleID: $0.bundle_id,
                        dailyBudgetMinutes: $0.daily_budget_minutes,
                        orderingToken: $0.ordering_token,
                        usedMinutes: $0.used_minutes ?? 0
                    )
                }
                merged = DeviceAppLimitMerge.apply(rules: summaries, to: catalogApps)
            }
            apps = merged
            for app in merged {
                appLimitEditQueue.seed(
                    key: app.id,
                    state: .init(ruleID: app.ruleID, orderingToken: app.orderingToken)
                )
            }
            isLoading = false

            for target in appTargets where target.artworkURL == nil {
                let pretty = NameWithIcon.displayName(target.displayName)
                if let url = await AppArtworkResolver.shared.artwork(forName: pretty),
                   let bundle = target.bundleID {
                    artworkByBundleID[bundle] = url
                }
            }
        } catch {
            loadFailed = true
            isLoading = false
        }
    }

    @MainActor
    private func startAutoRefresh() {
        guard fixtureApps == nil, refreshTask == nil else { return }
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                guard editingLimitFor == nil, !capSaving, !isLoading else { continue }
                await reloadApps()
            }
        }
    }

    /// Wrapper to make EarnedCascadeDecision.Result Identifiable for .sheet(item:).
    private struct CascadeConfirmItem: Identifiable {
        let id = UUID()
        let result: EarnedCascadeDecision.Result
    }

    /// Empty state: honest message for "no apps yet" vs load failure.
    private var emptyPlaceholder: some View {
        VStack(spacing: 14) {
            if displayState.showsDeviceCap {
                deviceCapCard
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            Spacer()
            Image(systemName: loadFailed ? "wifi.slash" : "app.dashed")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text(loadFailed ? "Couldn't load apps" : "No apps added yet")
                .font(.custom("Manrope", size: 16).weight(.heavy))
                .foregroundStyle(Color.evOnSurface)
            Text(loadFailed
                 ? "Check your connection and try again."
                 : "Apps captured on \(device.name) will show up here.")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("APP LIMITS")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Text(device.name)
                    .font(.custom("Manrope", size: 19).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
            }
            Spacer()
            Button {
                Task { await reloadApps() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel("Refresh app limits")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.evSurface
                .overlay(
                    Rectangle()
                        .fill(Color.evOutlineVariant)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }


    // MARK: - B9: Device-cap card

    /// "Daily total for this device / of {pool} shared" card with a cap picker.
    private var deviceCapCard: some View {
        let cap = deviceCapMinutes
        let pool = poolMinutes
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DEVICE DAILY TOTAL")
                        .font(.custom("Inter", size: 10).weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(cap.map { DeviceAppsMockData.formatLimit($0) } ?? "—")
                            .font(.custom("Manrope", size: 22).weight(.heavy))
                            .foregroundStyle(Color.evPrimary)
                        if let pool {
                            Text("/ of \(DeviceAppsMockData.formatLimit(pool)) shared")
                                .font(.custom("Inter", size: 12))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                    }
                }
                Spacer()
                // Gated on the POOL, not on `capOptions`: the slider needs a
                // ceiling, not a preset list. The backend accepts any value in
                // 0...pool (it 422s only above the pool), so the presets were
                // always a UI suggestion rather than an allowed set.
                if poolMinutes != nil {
                    Button {
                        showCapPicker = true
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.evPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }

        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - B9: Dynamic per-app limit picker

    /// Per-app limit picker with options computed from the earned-time policy.
    /// Options = policy.allowed_app_options (if available) else fallback base,
    /// both filtered to ≤ deviceCap. DEBUG injects 1-minute.
    /// An existing rule > cap is shown as a read-only "applies immediately" chip.
    private func limitPicker(for app: DeviceAppItem) -> some View {
        let cap = deviceCapMinutes ?? Int.max
        let isDebug: Bool = {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }()
        let computed = EarnedAppOptions.compute(
            policyOptions: policyAppOptions,
            deviceCap: cap,
            existingBudget: app.enabled ? app.limitMin : nil,
            isDebug: isDebug
        )

        return VStack(alignment: .leading, spacing: 8) {
            // Over-cap existing chip (read-only, "changes tomorrow")
            if !computed.overCapExisting.isEmpty {
                HStack(spacing: 6) {
                    ForEach(computed.overCapExisting, id: \.self) { val in
                        HStack(spacing: 4) {
                            Text(DeviceAppsMockData.formatLimit(val))
                                .font(.custom("Manrope", size: 11).weight(.heavy))
                            Text("· applies immediately")
                                .font(.custom("Inter", size: 10))
                        }
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.evSurfaceContainerHigh)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.evOutlineVariant, lineWidth: 1.5)
                        )
                    }
                }
            }

            FlowLayout(spacing: 6) {
                ForEach(computed.selectable, id: \.self) { min in
                    Button {
                        pickLimit(min, for: app)
                    } label: {
                        Text(DeviceAppsMockData.formatLimit(min))
                            .font(.custom("Manrope", size: 11).weight(.heavy))
                            .foregroundStyle(app.limitMin == min ? .white : Color.evOnSurface)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(app.limitMin == min ? Color.evPrimary : Color.white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(app.limitMin == min ? Color.evPrimary : Color.evOutlineVariant,
                                            lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Resets daily at midnight")
                .font(.custom("Inter", size: 11))
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
    }

    // MARK: - Persistence (P9)

    /// Surface an inline error, announce it for VoiceOver, and (re)start the
    /// ~4s auto-dismiss timer — cancelling any prior timer so a fresh error
    /// resets the window rather than being cleared early by the old one.
    private func setActionError(_ message: String) {
        actionError = message
        AccessibilityNotification.Announcement(message).post()
        errorDismissTask?.cancel()
        errorDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            actionError = nil
        }
    }

    /// Picker tap: optimistically set the local limit, then POST it. The same
    /// set_limit POST both creates a rule (if off) and updates the budget (if
    /// on), so this also turns a limit ON. Reverts + surfaces an error on
    /// failure.
    ///
    /// Supersession: a per-app token is bumped before the `await`; once it
    /// resumes, the success write-back / failure revert only run if this is
    /// still the latest interaction for the app (a slower earlier response is a
    /// NO-OP). See `AppLimitEditDecision`.
    private func pickLimit(_ minutes: Int, for app: DeviceAppItem) {
        editingLimitFor = nil
        guard let bundleID = app.bundleID,
              let famID = familyID,
              let cid = childDeviceID else {
            setActionError("This app can't be limited.")
            return
        }
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        let previous = apps[i]
        actionError = nil

        // Layer 3 (minimal, chip-picker variant): unlike the Toggle, each chip
        // Button already captures its own concrete `minutes` value per-render
        // (no hand-rolled Binding), so identity instability is not the same
        // risk here. Still instrument every tap — fired or a no-op re-tap of
        // the already-applied value — so the event timeline covers both
        // per-app controls uniformly.
        let fired = !(previous.enabled && previous.limitMin == minutes)
        ScreenTimeEventLog.emit(ScreenTimeEvent(
            ts: ISO8601DateFormatter().string(from: Date()),
            emitter: .parentApp,
            deviceID: nil,
            dayKey: nil,
            kind: .decision,
            source: .perAppLimit,
            app: bundleID,
            reason: fired ? "pick_user" : "pick_suppressed_no_change",
            nums: ScreenTimeEvent.Nums(budget: minutes),
            transition: ScreenTimeEvent.Transition(
                before: "\(previous.enabled ? previous.limitMin : 0)",
                after: "\(minutes)"),
            policyGen: nil,
            corrID: nil))
        guard fired else { return }
        apps[i].limitMin = minutes
        apps[i].enabled = true
        let seq = (inflightSeq[app.id] ?? 0) + 1
        inflightSeq[app.id] = seq
        appLimitEditQueue.enqueue(key: app.id) { serverState in
            do {
                let rule = try await apiClient.setAppLimit(
                    familyID: famID,
                    childDeviceID: cid,
                    bundleID: bundleID,
                    dailyBudgetMinutes: minutes,
                    basedOnOrderingToken: serverState.orderingToken,
                    displayName: app.name)
                let nextState = AppLimitEditQueue.ServerState(
                    ruleID: rule.rule_id,
                    orderingToken: rule.ordering_token)
                // Superseded by a newer tap/toggle → drop this response.
                guard AppLimitEditDecision.decide(
                    currentSeq: inflightSeq[app.id], capturedSeq: seq) == .apply else {
                    return nextState
                }
                if let j = apps.firstIndex(where: { $0.id == app.id }) {
                    apps[j].ruleID = rule.rule_id
                    apps[j].orderingToken = rule.ordering_token
                    apps[j].limitMin = rule.daily_budget_minutes
                    apps[j].enabled = true
                }
                return nextState
            } catch {
                // Superseded → do NOT revert; the newer interaction owns state.
                guard AppLimitEditDecision.decide(
                    currentSeq: inflightSeq[app.id], capturedSeq: seq) == .apply else {
                    return nil
                }
                if let j = apps.firstIndex(where: { $0.id == app.id }) {
                    apps[j] = previous
                }
                setActionError("Couldn't save the limit — try again.")
                return nil
            }
        }
    }

    /// Toggle: ON → set_limit with the current pill value; OFF → clear the rule.
    /// Reverts + surfaces an error on failure.
    ///
    /// Supersession: same per-app token guard as `pickLimit` — a response that
    /// is no longer the latest interaction is a NO-OP (no write-back, no
    /// revert), preventing stale overwrites and enabled/ruleID desync.
    private func toggleLimit(for app: DeviceAppItem, on: Bool) {
        guard let bundleID = app.bundleID,
              let famID = familyID,
              let cid = childDeviceID else {
            setActionError("This app can't be limited.")
            return
        }
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        let previous = apps[i]
        actionError = nil
        apps[i].enabled = on
        let seq = (inflightSeq[app.id] ?? 0) + 1
        inflightSeq[app.id] = seq
        appLimitEditQueue.enqueue(key: app.id) { serverState in
            do {
                if on {
                    // Clamp to the device's effective cap (mirrors the backend's
                    // _validate_budget_vs_cap): a stale rule budget set when the pool
                    // was higher would otherwise 422 once the pool drops below it.
                    let budget = max(1, min(app.limitMin, deviceCapMinutes ?? app.limitMin))
                    let rule = try await apiClient.setAppLimit(
                        familyID: famID,
                        childDeviceID: cid,
                        bundleID: bundleID,
                        dailyBudgetMinutes: budget,
                        basedOnOrderingToken: serverState.orderingToken,
                        displayName: app.name)
                    let nextState = AppLimitEditQueue.ServerState(
                        ruleID: rule.rule_id,
                        orderingToken: rule.ordering_token)
                    // Superseded by a newer tap/toggle → drop this response.
                    guard AppLimitEditDecision.decide(
                        currentSeq: inflightSeq[app.id], capturedSeq: seq) == .apply else {
                        return nextState
                    }
                    if let j = apps.firstIndex(where: { $0.id == app.id }) {
                        apps[j].ruleID = rule.rule_id
                        apps[j].orderingToken = rule.ordering_token
                        apps[j].limitMin = rule.daily_budget_minutes
                    }
                    return nextState
                } else if let ruleID = serverState.ruleID {
                    _ = try await apiClient.clearAppLimit(
                        familyID: famID,
                        ruleID: ruleID)
                    // Superseded by a newer tap/toggle → drop this response.
                    guard AppLimitEditDecision.decide(
                        currentSeq: inflightSeq[app.id], capturedSeq: seq) == .apply else {
                        return AppLimitEditQueue.ServerState(
                            ruleID: nil,
                            orderingToken: nil)
                    }
                    if let j = apps.firstIndex(where: { $0.id == app.id }) {
                        apps[j].ruleID = nil
                        apps[j].orderingToken = nil
                    }
                }
                // OFF with no ruleID: nothing persisted yet, local flip is enough.
                return AppLimitEditQueue.ServerState(
                    ruleID: nil,
                    orderingToken: nil)
            } catch {
                // Superseded → do NOT revert; the newer interaction owns state.
                guard AppLimitEditDecision.decide(
                    currentSeq: inflightSeq[app.id], capturedSeq: seq) == .apply else {
                    return nil
                }
                if let j = apps.firstIndex(where: { $0.id == app.id }) {
                    apps[j] = previous
                }
                setActionError(on
                    ? "Couldn't turn on the limit — try again."
                    : "Couldn't turn off the limit — try again.")
                return nil
            }
        }
    }

    // MARK: - B9: Device cap persistence

    /// Save the device daily cap via putDeviceCap. When the new cap is lower than
    /// an existing app-limit rule, gate on cascade confirmation before calling the
    /// API. Pass `confirmedCascade: true` on re-call (from the confirm sheet).
    ///
    /// Gate logic (R10/R11/R12):
    ///   1. If `confirmedCascade` is false, compute the cascade decision from the
    ///      apps that currently have a rule budget exceeding `newCap`.
    ///   2. If `needsConfirmation`, store the result in `pendingCascade` (which
    ///      presents `CascadeConfirmSheet`) and return WITHOUT calling putDeviceCap.
    ///   3. The confirm sheet re-calls this function with `confirmedCascade: true`,
    ///      which skips the gate and proceeds to putDeviceCap.
    private func saveDeviceCap(_ newCap: Int, confirmedCascade: Bool, effective: String = "today") {
        guard let cid = childDeviceID else {
            setActionError("Can't save — device not paired.")
            return
        }
        guard let childProfileID = UUID(uuidString: childId) else {
            setActionError("Can't save — child profile not loaded.")
            return
        }

        // Gate: check whether any enabled app rules exceed the new cap.
        // Skip the gate when the parent already confirmed.
        if !confirmedCascade {
            let affectedApps = apps
                .filter { $0.enabled && $0.limitMin > newCap }
                .map { app in
                    EarnedCascadeDecision.AffectedApp(
                        bundleID: app.bundleID ?? app.id,
                        name: app.name,
                        currentBudgetMinutes: app.limitMin,
                        newBudgetMinutes: newCap)
                }
            let currentPool = poolMinutes ?? newCap
            let decision = EarnedCascadeDecision.decide(
                newPoolMinutes: newCap,
                currentPoolMinutes: currentPool,
                affectedDevices: [],
                affectedApps: affectedApps)
            if decision.needsConfirmation {
                pendingCascade = decision
                pendingCascadeCap = newCap
                return   // DO NOT call putDeviceCap — wait for confirmation
            }
        }

        let previousCap = deviceCapMinutes
        deviceCapMinutes = newCap   // optimistic
        capSaving = true
        Task {
            defer { capSaving = false }
            do {
                let response = try await apiClient.putDeviceCap(
                    childProfileID: childProfileID,
                    childDeviceID: cid,
                    capMinutes: newCap,
                    effective: effective,
                    confirmCascade: confirmedCascade)
                // The backend runs its OWN cascade check against the real
                // app-limit rows. The local gate above only sees `apps`, which
                // is the App Controls selection — a rule can be active while
                // absent (or stale) there, and then the backend answers
                // `needs_confirmation`: a DRY RUN that writes nothing. Treating
                // that as success left the sheet showing the new cap and
                // promising the limits were adjusted while the database kept
                // the old cap and the untouched rule (2026-08-07: 130 → 55
                // refused three times, silently).
                if response.needsConfirmation {
                    deviceCapMinutes = previousCap
                    pendingCascadeCap = newCap
                    pendingCascade = EarnedCascadeDecision.Result(
                        needsConfirmation: true,
                        affectedDevices: [],
                        affectedApps: (response.affected_app_limits ?? []).map {
                            EarnedCascadeDecision.AffectedApp(
                                bundleID: $0.bundle_id,
                                name: appDisplayName(forBundleID: $0.bundle_id),
                                currentBudgetMinutes: $0.current_budget_minutes,
                                newBudgetMinutes: $0.new_budget_minutes)
                        },
                        defaultAction: .applyNow)
                }
                // Otherwise the cap is already applied optimistically.
            } catch {
                // Revert on failure.
                deviceCapMinutes = previousCap
                setActionError("Couldn't save the cap — try again.")
            }
        }
    }

    /// Friendly name for a bundle id the backend flagged, falling back to the
    /// bundle id itself when the row is not in the local App Controls list —
    /// exactly the case the local gate misses.
    private func appDisplayName(forBundleID bundleID: String) -> String {
        apps.first { ($0.bundleID ?? $0.id) == bundleID }?.name ?? bundleID
    }
}

// MARK: - Hardening: stable-identity app row (phantom-toggle fix)

/// A single app row in `DeviceAppsSheet`. Extracted into a real `View` type
/// (Layer 2 of the phantom-toggle hardening) so SwiftUI can give each row a
/// STABLE identity driven by `$apps[index]` via `ForEach($apps)`, instead of
/// the previous plain `appRow(_:)` FUNCTION whose `Toggle` used a hand-rolled
/// `Binding(get:set:)` recaptured fresh on every parent re-render — unstable
/// control identity that let unrelated churn (e.g. the artwork backfill,
/// see Layer 1) potentially fire another row's toggle-set closure.
///
/// Layer 3 (explicit switch intent): the row renders a button styled like an
/// iOS switch instead of putting network side effects in a `Toggle` binding
/// setter. SwiftUI may call a binding setter for reasons other than a direct
/// touch; this path logs and persists only from the button's tap action.
private struct DeviceAppRow: View {
    @Binding var app: DeviceAppItem
    let resolvedArtworkURL: URL?
    let isEditingLimit: Bool
    let onToggleEditingLimit: () -> Void
    let limitPicker: () -> AnyView
    /// Called ONLY from the explicit switch tap action. Owns the network call
    /// + optimistic update in the parent (`toggleLimit`) — this row does not
    /// touch persistence.
    let onToggle: (Bool) -> Void

    init(app: Binding<DeviceAppItem>,
         resolvedArtworkURL: URL?,
         isEditingLimit: Bool,
         onToggleEditingLimit: @escaping () -> Void,
         limitPicker: @escaping () -> some View,
         onToggle: @escaping (Bool) -> Void) {
        self._app = app
        self.resolvedArtworkURL = resolvedArtworkURL
        self.isEditingLimit = isEditingLimit
        self.onToggleEditingLimit = onToggleEditingLimit
        self.limitPicker = { AnyView(limitPicker()) }
        self.onToggle = onToggle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Group {
                    if let artworkURL = resolvedArtworkURL {
                        AsyncImage(url: artworkURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            default:
                                // While loading or on failure, fall back to SF symbol
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(app.bgColor)
                                    Image(systemName: app.iconSystemName)
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(app.brandColor)
                                }
                            }
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(app.bgColor)
                            Image(systemName: app.iconSystemName)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(app.brandColor)
                        }
                        .frame(width: 40, height: 40)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(app.name)
                            .font(.custom("Manrope", size: 14).weight(.bold))
                            .foregroundStyle(Color.evOnSurface)

                        Spacer()

                        // Limit pill (tap to expand picker). Disabled when the
                        // app has no bundle id — there's nothing to limit on.
                        Button(action: onToggleEditingLimit) {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 11))
                                Text(DeviceAppsMockData.formatLimit(app.limitMin))
                                    .font(.custom("Manrope", size: 11).weight(.heavy))
                            }
                            .foregroundStyle(app.enabled ? Color.evPrimary : Color.evOutline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(app.enabled ? Color.evPrimaryContainer : Color.evSurfaceContainerHigh)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(app.bundleID == nil)
                        .opacity(app.bundleID == nil ? 0.5 : 1)

                        Button(action: handleToggleTap) {
                            AppLimitSwitchVisual(isOn: app.enabled)
                        }
                        .buttonStyle(.plain)
                        // No bundle id → can't set/clear a backend limit; lock off.
                        .disabled(app.bundleID == nil)
                        .opacity(app.bundleID == nil ? 0.5 : 1)
                        .accessibilityLabel("\(app.name) limit")
                        .accessibilityValue(app.enabled ? "On" : "Off")
                    }

                    // Progress bar
                    progressBar

                    // Status text
                    HStack {
                        Text(statusText)
                            .font(.custom("Inter", size: 10))
                            .foregroundStyle(app.enabled && app.usedMin >= app.limitMin
                                             ? Color.evError
                                             : Color.evOnSurfaceVariant)
                        Spacer()
                        if app.enabled && app.usedMin >= app.limitMin {
                            Text("LIMIT REACHED")
                                .font(.custom("Inter", size: 10).weight(.heavy))
                                .tracking(0.8)
                                .foregroundStyle(Color.evError)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if isEditingLimit {
                limitPicker()
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
        }
    }

    /// Layer 3: only a direct tap on this switch button reaches the network
    /// path. The event is still logged so the parent/kid/backend timeline can
    /// prove exactly which row initiated a command.
    private func handleToggleTap() {
        let previousValue = app.enabled
        let newValue = AppLimitToggleIntent.nextValue(currentEnabled: previousValue)
        ScreenTimeEventLog.emit(ScreenTimeEvent(
            ts: ISO8601DateFormatter().string(from: Date()),
            emitter: .parentApp,
            deviceID: nil,
            dayKey: nil,
            kind: .decision,
            source: .perAppLimit,
            app: app.bundleID ?? app.id,
            reason: "toggle_user",
            nums: nil,
            transition: ScreenTimeEvent.Transition(
                before: previousValue ? "on" : "off",
                after: newValue ? "on" : "off"),
            policyGen: nil,
            corrID: nil))
        onToggle(newValue)
    }

    private var progressBar: some View {
        let pct = min(1.0, Double(app.usedMin) / Double(max(app.limitMin, 1)))
        let color: Color = !app.enabled
            ? Color.evOutlineVariant
            : pct >= 1.0 ? Color.evError
            : pct > 0.75 ? Color(hex: 0xF97316)
            : Color.evSecondary
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.evSurfaceContainerHigh)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * (app.enabled ? pct : 0))
            }
        }
        .frame(height: 4)
    }

    private var statusText: String {
        // usedMin is REAL (coarse) per-app usage from the backend usage samples
        // (merged in onAppear). The formatter shows "X / Y min".
        EarnedDisplayFormatters.appRowStatusText(
            limitEnabled: app.enabled,
            usedMin: app.usedMin,
            limitMin: app.limitMin
        )
    }
}

private struct AppLimitSwitchVisual: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isOn ? Color.evSecondary : Color.evSurfaceContainerHigh)
            .frame(width: 51, height: 31)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isOn ? Color.clear : Color.evOutlineVariant.opacity(0.7), lineWidth: 1)
            )
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 27, height: 27)
                    .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.16), value: isOn)
    }
}

#Preview("Fixture apps (preview-only)") {
    NavigationStack {
        DeviceAppsSheet(
            device: DeviceItem(iconSystemName: "iphone", name: "iPhone 13",
                               detail: "Primary device", locked: false),
            childId: "liam",
            fixtureApps: DeviceAppsMockData.apps(for: "liam")
        )
    }
}

#Preview("Runtime (coming soon)") {
    NavigationStack {
        DeviceAppsSheet(
            device: DeviceItem(iconSystemName: "iphone", name: "iPhone 13",
                               detail: "Primary device", locked: false),
            childId: "liam"
        )
    }
}
