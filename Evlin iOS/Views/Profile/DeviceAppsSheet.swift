import SwiftUI

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

    var body: some View {
        VStack(spacing: 0) {
            header
            if isLoading && apps.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if apps.isEmpty {
                emptyPlaceholder
            } else {
                ScrollView {
                    // B9: Device-cap card — shown at the top when a cap or pool
                    // value is available. "Daily total for this device / of {pool} shared".
                    if deviceCapMinutes != nil || poolMinutes != nil {
                        deviceCapCard
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { idx, app in
                            appRow(app)
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
                }
            }
        }
        .background(Color.evSurfaceContainerLow)
        // Pushed onto the parent NavigationStack — hide the system nav
        // bar and rely on this view's own header arrow / edge-swipe.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .onAppear {
            if let fixtureApps {
                apps = fixtureApps
                return
            }
            guard apps.isEmpty, let cid = childDeviceID else { return }
            isLoading = true

            // B9: load earned-time policy (cap options + pool) alongside the catalog.
            // Uses child.id as the profile UUID when available.
            if let childProfileID = UUID(uuidString: childId) {
                Task {
                    if let policy = try? await apiClient.fetchEarnedPolicy(childProfileID: childProfileID) {
                        poolMinutes = policy.pool_minutes
                        policyAppOptions = policy.allowed_app_options
                        // Find the cap entry for this specific device. The EFFECTIVE
                        // per-app cap mirrors the backend (R7 / _validate_budget_vs_cap):
                        // an explicit device cap if set, ELSE the daily pool. Without
                        // this fallback `deviceCapMinutes` was nil for a pool-only device,
                        // so `defaultPill` became min(60, 60)=60 and turning on a limit
                        // POSTed budget=60 — which the backend 422s once the pool drops
                        // below 60 ("app_limit_exceeds_device_cap").
                        if let devEntry = policy.devices?.first(where: { $0.child_device_id == cid }) {
                            deviceCapMinutes = devEntry.daily_cap_minutes ?? policy.pool_minutes
                            capOptions = EarnedCapOptions.compute(
                                policyCapOptions: devEntry.allowed_cap_options,
                                poolMinutes: policy.pool_minutes ?? Int.max)
                        } else {
                            deviceCapMinutes = policy.daily_cap_minutes ?? policy.pool_minutes
                            capOptions = []
                        }
                    }
                }
            }

            Task {
                do {
                    let targets = try await apiClient.fetchLazyTagCatalogTargets(childDeviceID: cid)
                    let appTargets = targets.filter { $0.type == .app }
                    // 1) Render immediately: prettified names + any backend artwork.
                    //    Default the pill to min(60, cap) — B9; leave the limit OFF — the real
                    //    rules merge below flips on the apps that actually have one.
                    let defaultPill = EarnedAppOptions.defaultPill(deviceCap: deviceCapMinutes ?? 60)
                    let catalogApps = appTargets.map { t in
                        DeviceAppItem(
                            id: t.aliasKey.uuidString,
                            name: NameWithIcon.displayName(t.displayName),   // fixes casing (ig→Instagram, etc.)
                            iconSystemName: "app.fill",
                            brandColor: Color.evPrimary,
                            bgColor: Color.evPrimaryContainer,
                            enabled: false,
                            usedMin: 0,
                            limitMin: defaultPill,
                            artworkURL: t.artworkURL,
                            bundleID: t.bundleID
                        )
                    }
                    // 2) Load real per-app limits and merge by bundle_id (apps with
                    //    a rule → on + that budget + ruleID; without → limit off).
                    var merged = catalogApps
                    if let famID = familyID {
                        let rules = (try? await apiClient.listAppLimits(
                            familyID: famID, childDeviceID: cid)) ?? []
                        let summaries = rules.map {
                            AppLimitRuleSummary(
                                ruleID: $0.rule_id,
                                bundleID: $0.bundle_id,
                                dailyBudgetMinutes: $0.daily_budget_minutes,
                                usedMinutes: $0.used_minutes ?? 0)
                        }
                        merged = DeviceAppLimitMerge.apply(rules: summaries, to: catalogApps)
                    }
                    apps = merged
                    isLoading = false
                    // 3) Backfill real icons: when the backend gave no artwork URL,
                    //    resolve the App Store icon by name (cached) and patch it in.
                    for t in appTargets where t.artworkURL == nil {
                        let pretty = NameWithIcon.displayName(t.displayName)
                        if let url = await AppArtworkResolver.shared.artwork(forName: pretty),
                           let i = apps.firstIndex(where: { $0.id == t.aliasKey.uuidString }) {
                            apps[i].artworkURL = url
                        }
                    }
                } catch {
                    loadFailed = true
                    isLoading = false
                }
            }
        }
        // B9: cascade-confirm sheet.
        .sheet(item: Binding(
            get: { pendingCascade.map { CascadeConfirmItem(result: $0) } },
            set: { if $0 == nil { pendingCascade = nil } }
        )) { item in
            CascadeConfirmSheet(
                result: item.result,
                onApplyTomorrow: {
                    pendingCascade = nil
                    // Re-call putDeviceCap with confirm_cascade (handled in saveDeviceCap).
                    if let cap = deviceCapMinutes {
                        saveDeviceCap(cap, confirmedCascade: true)
                    }
                },
                onCancel: { pendingCascade = nil }
            )
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

    private func appRow(_ app: DeviceAppItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Group {
                    if let artworkURL = app.artworkURL {
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
                        Button {
                            editingLimitFor = (editingLimitFor == app.id) ? nil : app.id
                        } label: {
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

                        Toggle("", isOn: Binding(
                            get: { app.enabled },
                            set: { newValue in toggleLimit(for: app, on: newValue) }
                        ))
                        .labelsHidden()
                        .tint(Color.evSecondary)
                        // No bundle id → can't set/clear a backend limit; lock off.
                        .disabled(app.bundleID == nil)
                    }

                    // Progress bar
                    progressBar(for: app)

                    // Status text
                    HStack {
                        Text(statusText(for: app))
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

            if editingLimitFor == app.id {
                limitPicker(for: app)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
        }
    }

    private func progressBar(for app: DeviceAppItem) -> some View {
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

    private func statusText(for app: DeviceAppItem) -> String {
        // usedMin is REAL (coarse) per-app usage from the backend usage samples
        // (merged in onAppear). The formatter shows "X / Y min".
        EarnedDisplayFormatters.appRowStatusText(
            limitEnabled: app.enabled,
            usedMin: app.usedMin,
            limitMin: app.limitMin
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
                if !capOptions.isEmpty {
                    Button {
                        showCapPicker.toggle()
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.evPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Inline cap picker
            if showCapPicker && !capOptions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(capOptions, id: \.self) { opt in
                        Button {
                            showCapPicker = false
                            saveDeviceCap(opt, confirmedCascade: false)
                        } label: {
                            Text(DeviceAppsMockData.formatLimit(opt))
                                .font(.custom("Manrope", size: 11).weight(.heavy))
                                .foregroundStyle(deviceCapMinutes == opt ? .white : Color.evOnSurface)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(deviceCapMinutes == opt ? Color.evPrimary : Color.white)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(deviceCapMinutes == opt ? Color.evPrimary
                                                                        : Color.evOutlineVariant,
                                                lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
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
        apps[i].limitMin = minutes
        apps[i].enabled = true
        let seq = (inflightSeq[app.id] ?? 0) + 1
        inflightSeq[app.id] = seq
        Task {
            do {
                let rule = try await apiClient.setAppLimit(
                    familyID: famID,
                    childDeviceID: cid,
                    bundleID: bundleID,
                    dailyBudgetMinutes: minutes,
                    displayName: app.name)
                // Superseded by a newer tap/toggle → drop this response.
                guard AppLimitEditDecision.decide(
                    currentSeq: inflightSeq[app.id], capturedSeq: seq) == .apply else { return }
                if let j = apps.firstIndex(where: { $0.id == app.id }) {
                    apps[j].ruleID = rule.rule_id
                    apps[j].limitMin = rule.daily_budget_minutes
                    apps[j].enabled = true
                }
            } catch {
                // Superseded → do NOT revert; the newer interaction owns state.
                guard AppLimitEditDecision.decide(
                    currentSeq: inflightSeq[app.id], capturedSeq: seq) == .apply else { return }
                if let j = apps.firstIndex(where: { $0.id == app.id }) {
                    apps[j] = previous
                }
                setActionError("Couldn't save the limit — try again.")
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
        Task {
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
                        displayName: app.name)
                    // Superseded by a newer tap/toggle → drop this response.
                    guard AppLimitEditDecision.decide(
                        currentSeq: inflightSeq[app.id], capturedSeq: seq) == .apply else { return }
                    if let j = apps.firstIndex(where: { $0.id == app.id }) {
                        apps[j].ruleID = rule.rule_id
                        apps[j].limitMin = rule.daily_budget_minutes
                    }
                } else if let ruleID = app.ruleID {
                    try await apiClient.clearAppLimit(familyID: famID, ruleID: ruleID)
                    // Superseded by a newer tap/toggle → drop this response.
                    guard AppLimitEditDecision.decide(
                        currentSeq: inflightSeq[app.id], capturedSeq: seq) == .apply else { return }
                    if let j = apps.firstIndex(where: { $0.id == app.id }) {
                        apps[j].ruleID = nil
                    }
                }
                // OFF with no ruleID: nothing persisted yet, local flip is enough.
            } catch {
                // Superseded → do NOT revert; the newer interaction owns state.
                guard AppLimitEditDecision.decide(
                    currentSeq: inflightSeq[app.id], capturedSeq: seq) == .apply else { return }
                if let j = apps.firstIndex(where: { $0.id == app.id }) {
                    apps[j] = previous
                }
                setActionError(on
                    ? "Couldn't turn on the limit — try again."
                    : "Couldn't turn off the limit — try again.")
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
                return   // DO NOT call putDeviceCap — wait for confirmation
            }
        }

        let previousCap = deviceCapMinutes
        deviceCapMinutes = newCap   // optimistic
        capSaving = true
        Task {
            defer { capSaving = false }
            do {
                _ = try await apiClient.putDeviceCap(
                    childProfileID: childProfileID,
                    childDeviceID: cid,
                    capMinutes: newCap,
                    effective: effective,
                    confirmCascade: true)
                // On success the cap is already applied optimistically.
            } catch {
                // Revert on failure.
                deviceCapMinutes = previousCap
                setActionError("Couldn't save the cap — try again.")
            }
        }
    }
}

// MARK: - B9: Cascade confirm sheet

/// Presented when lowering pool or cap would affect existing device/app rules.
/// Lists the affected items, defaults to "Apply tomorrow".
private struct CascadeConfirmSheet: View {
    let result: EarnedCascadeDecision.Result
    var onApplyTomorrow: () -> Void = {}
    var onCancel: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(result.affectedDevices, id: \.deviceID) { dev in
                        Text(dev.description)
                            .font(.custom("Inter", size: 14))
                    }
                    ForEach(result.affectedApps, id: \.bundleID) { app in
                        Text(app.description)
                            .font(.custom("Inter", size: 14))
                    }
                } header: {
                    Text("These limits will change")
                        .font(.custom("Inter", size: 12).weight(.semibold))
                }

                Section {
                    Text("The changes take effect at midnight so today's sessions aren't cut short.")
                        .font(.custom("Inter", size: 13))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }
            .navigationTitle("Confirm Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .foregroundStyle(Color.evPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply Tomorrow") {
                        onApplyTomorrow()
                        dismiss()
                    }
                    .font(.custom("Inter", size: 17).weight(.semibold))
                    .foregroundStyle(Color.evPrimary)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
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
