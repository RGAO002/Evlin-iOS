import SwiftUI
import FamilyControls
import ManagedSettings
import DeviceActivity
import AVFoundation

struct HomeSettingsSheet: View {
    @EnvironmentObject var apiClient: APIClient
    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    var onClose: () -> Void

    @AppStorage("parentName") private var parentName: String = "Morgan"
    @AppStorage("childName") private var childName: String = "Liam"
    @AppStorage("appMode") private var appMode: String = ""
    @AppStorage("evlin.familyID") private var familyID: String = ""
    @AppStorage("evlin.parentDeviceID") private var parentDeviceID: String = ""
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""

    @State private var children: [ChildProfile] = ChildProfile.all
    @State private var editing: ChildProfile? = nil
    @State private var adding: Bool = false

    @State private var serverURL: String = ""
    @State private var isPickerPresented = false

    @AppStorage("evlin.protectionMode") private var savedProtectionMode: String = "std"

    /// Bumps SwiftUI redraw after camera permission callbacks.
    @State private var cameraPermissionFreshness: Int = 0

    /// Family protection mode mirror — synced from backend on appear, PUT-back when the segmented control changes.
    @State private var protectionMode: String = "std"
    @State private var protectionModeStatus: String = ""

    /// Strategy-agent T11.13 — Smart Mode toggle (iOS-side gate for the
    /// thinking/QuestionCard pipeline). When ON the agent can think and ask
    /// follow-up questions; when OFF only simple commands are accepted.
    @StateObject private var smartMode = SmartModeStore()

    var body: some View {
        NavigationStack {
            Form {
                SmartModeToggle().environmentObject(smartMode)

                Section("Children") {
                    ForEach(children) { c in
                        Button { editing = c } label: {
                            HStack(spacing: 12) {
                                EvlinAvatarView(url: c.avatarURL, name: c.name, size: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name)
                                        .font(.custom("Manrope", size: 14).weight(.bold))
                                        .foregroundStyle(Color.evOnSurface)
                                    Text("Age \(c.age)")
                                        .font(.custom("Inter", size: 12))
                                        .foregroundStyle(Color.evOnSurfaceVariant)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.evOutline)
                            }
                        }
                    }
                    .onDelete { children.remove(atOffsets: $0) }

                    Button { adding = true } label: {
                        Label("Add child", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.evPrimary)
                    }

                    LabeledContent("Parent name") {
                        TextField("", text: $parentName)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                    }
                }

                Section("Connection") {
                    #if DEBUG
                    // Dev-only quick-swap. Production builds (DEBUG not
                    // defined) hide this entirely so users never see the
                    // local IP. Tapping a segment writes the corresponding
                    // preset into both serverURL (the live text field) and
                    // APIClient.baseURL via saveServerURL.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Backend Preset")
                            .font(.custom("Inter", size: 11).weight(.bold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.evOutline)
                        Picker("Backend", selection: $serverURL) {
                            Text("Local").tag(APIClient.localDevURL)
                            Text("Production").tag(APIClient.defaultURL)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: serverURL) { oldValue, newValue in
                            // Only persist when the new value matches one of
                            // the two presets — otherwise the free-text
                            // field below would re-fire this on every
                            // keystroke. The custom-URL flow has its own
                            // explicit Save button.
                            let isPreset = newValue == APIClient.localDevURL
                                || newValue == APIClient.defaultURL
                            guard isPreset else { return }
                            apiClient.saveServerURL(newValue)

                            // Safety net for backend swap mid-session.
                            // Pairing IDs are backend-scoped — Render's
                            // family_id won't exist in Local's DB and vice
                            // versa. Wipe pairing-related UserDefaults and
                            // force onboarding to re-run so the next
                            // /family/pair fresh-writes IDs for the new
                            // backend. Without this clear, chat would keep
                            // hitting "No child device is paired" after a
                            // switch because the cached IDs are orphaned.
                            //
                            // Only fires when actually CHANGING backends —
                            // initial onAppear-driven population (where
                            // oldValue == newValue) is skipped.
                            guard !oldValue.isEmpty, oldValue != newValue else { return }
                            UserDefaults.standard.removeObject(forKey: "evlin.familyID")
                            UserDefaults.standard.removeObject(forKey: "evlin.parentDeviceID")
                            UserDefaults.standard.removeObject(forKey: "evlin.childDeviceID")
                            UserDefaults.standard.set(false, forKey: "onboardingComplete")
                            UserDefaults.standard.set("", forKey: "appMode")
                        }
                    }
                    #endif

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server URL")
                            .font(.custom("Inter", size: 11).weight(.bold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.evOutline)
                        TextField("http://192.168.1.x:8000/api/v1", text: $serverURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Child Name")
                            .font(.custom("Inter", size: 11).weight(.bold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.evOutline)
                        TextField("Liam", text: $childName)
                    }

                    if !familyID.isEmpty {
                        idRow(title: "Family ID", value: familyID)
                    }

                    if !parentDeviceID.isEmpty {
                        idRow(title: "Parent Device ID", value: parentDeviceID)
                    }

                    if !childDeviceID.isEmpty {
                        idRow(title: "Child Device ID", value: childDeviceID)
                    }
                }

                Section("Screen Time") {
                    HStack {
                        Text("Authorization")
                        Spacer()
                        if screenTimeManager.isAuthorized {
                            Label("Authorized", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.evSecondary)
                        } else {
                            Button("Authorize") {
                                Task { await screenTimeManager.requestScreenTimeAuthorization() }
                            }
                        }
                    }

                    Text(
                        savedProtectionMode == "max"
                            ? "Mode: Maximum — Screen Time authorization uses the child's Apple ID on this phone."
                            : "Mode: Standard — authorization is tied to this Apple ID."
                    )
                    .font(.caption)
                    .foregroundStyle(Color.evOutline)

                    if let authErr = screenTimeManager.errorMessage, !authErr.isEmpty {
                        Text(authErr)
                            .font(.caption)
                            .foregroundStyle(Color.evError)
                    }

                    Button {
                        Task { await screenTimeManager.openScreenTimeSettings() }
                    } label: {
                        Label("Screen Time Settings", systemImage: "gearshape")
                    }

                    Toggle(isOn: Binding(
                        get: { screenTimeManager.deletionProtectionEnabled },
                        set: { screenTimeManager.setDeletionProtectionEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Prevent deleting apps")
                            Text("Uses Screen Time. When ON, uninstalling Evlin — and usually other apps — is blocked.")
                                .font(.caption)
                                .foregroundStyle(Color.evOutline)
                        }
                    }

                    let appCount = screenTimeManager.selectedApps.applicationTokens.count
                    let catCount = screenTimeManager.selectedApps.categoryTokens.count

                    Button {
                        isPickerPresented = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Managed Apps & Categories")
                                    .foregroundStyle(Color.evOnSurface)
                                if appCount > 0 || catCount > 0 {
                                    Text("\(appCount) apps, \(catCount) categories")
                                        .font(.caption)
                                        .foregroundStyle(Color.evOutline)
                                } else {
                                    Text("Nothing selected yet")
                                        .font(.caption)
                                        .foregroundStyle(Color.evOutline)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.evOutline)
                        }
                    }

                    Text("Tip: tap a category row's header (e.g. \"Games\") to lock the whole group, or tap individual apps to lock just those.")
                        .font(.caption)
                        .foregroundStyle(Color.evOutline)

                    ManagedActivitySelectionDiagnostics(selection: screenTimeManager.selectedApps)

                    NavigationLink {
                        LabelTokenInspectorView()
                    } label: {
                        Label("Label(token) snapshot test", systemImage: "rectangle.and.text.magnifyingglass")
                    }

                    NavigationLink {
                        DeviceActivityReportMetadataProbeView()
                    } label: {
                        Label("DeviceActivityReport metadata test", systemImage: "chart.bar.doc.horizontal")
                    }

                    NavigationLink {
                        TokenScreenshotImportView()
                    } label: {
                        Label("Auto-tag via screenshots", systemImage: "camera.viewfinder")
                    }

                    NavigationLink {
                        TokenPickerProbeView()
                    } label: {
                        Label("Lazy-tag picker test", systemImage: "tag")
                    }

                    NavigationLink {
                        AliasManagementView()
                    } label: {
                        Label("Saved tags (chat aliases)", systemImage: "tag.fill")
                    }

                    NavigationLink {
                        AliasLibraryInspectorView()
                    } label: {
                        Label("Alias library (after hydrate)", systemImage: "books.vertical")
                    }

                    NavigationLink {
                        AliasE2ETestView()
                    } label: {
                        Label("Alias E2E test (start here)", systemImage: "checkmark.seal")
                    }

                    if appCount > 0 || catCount > 0 {
                        Button {
                            screenTimeManager.shieldApps()
                        } label: {
                            Label("Lock Selected Apps", systemImage: "lock.fill")
                                .foregroundStyle(Color.evError)
                        }
                    }

                    Button {
                        screenTimeManager.clearAllShields()
                    } label: {
                        Label("Unlock All Apps", systemImage: "lock.open.fill")
                            .foregroundStyle(Color.evSecondary)
                    }

                    // Nuclear reset — only use this when ActiveLockStore + the
                    // ManagedSettings store have desynced (e.g. "lock IG" does
                    // nothing but "lock FB" then locks both). Wipes every code
                    // path that could write to the shield/block state:
                    //   1. ManagedSettings.store.clearAllSettings() — Apple's
                    //      official "drop every policy on this device" hammer
                    //   2. ActiveLockStore.shieldRecords + blockRecords
                    //   3. DeviceActivityCenter.stopMonitoring(.all) — kills
                    //      every scheduled intervalDidEnd callback, so no
                    //      ghost record can be re-applied later
                    //   4. App Group UserDefaults — every evlin.* key
                    //   5. Re-enable deletion protection (clearAllSettings
                    //      drops application.denyAppRemoval too, which we
                    //      MUST put back so the user can't accidentally
                    //      uninstall Evlin and lose enforcement)
                    Button(role: .destructive) {
                        Task { await nuclearReset() }
                    } label: {
                        Label("Nuclear Reset (lock state)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.evError)
                    }
                }

                Section("Camera & Photos") {
                    HStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .foregroundStyle(Color.evOutline)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Camera")
                                .foregroundStyle(Color.evOnSurface)
                            Text(cameraStatusText)
                                .font(.caption)
                                .foregroundStyle(Color.evOutline)
                        }
                        Spacer()
                    }
                    Group {
                        if cameraIsAuthorized {
                            Text("Ready for task evidence and profile photos.")
                                .font(.caption)
                                .foregroundStyle(Color.evSecondary)
                        } else {
                            Button(cameraPermissionActionTitle) {
                                handleCameraPermissionTap()
                            }
                        }
                    }
                    .id(cameraPermissionFreshness)

                    Text("Camera is used when your child submits task photos or evidence.")
                        .font(.caption)
                        .foregroundStyle(Color.evOutline)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Evlin Settings", systemImage: "slider.horizontal.3")
                    }

                    Label("Choosing photos may offer limited-library access instead of full Photos permission.", systemImage: "photo.on.rectangle.angled")
                        .font(.caption)
                        .foregroundStyle(Color.evOutline)
                }

                Section("Device Status") {
                    HStack {
                        Text("Lock State")
                        Spacer()
                        Text(screenTimeManager.isUnlocked ? "Unlocked" : "Locked")
                            .foregroundStyle(screenTimeManager.isUnlocked ? Color.evSecondary : Color.evError)
                    }
                }

                Section("Chat") {
                    Button(role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "evlin_chat_history")
                        NotificationCenter.default.post(name: .evlinClearChat, object: nil)
                    } label: {
                        Label("Clear Chat History", systemImage: "trash")
                    }
                }

                // Diagnostic: last DeviceActivitySchedule attempt. If a timed
                // shield isn't auto-releasing, this surfaces the exact reason
                // (auth missing, interval invalid, monitoring limit hit, etc.).
                // ActionExecutor writes this on every shield/block schedule.
                Section {
                    let lastResult = UserDefaults(suiteName: "group.com.evlin.ios")?
                        .string(forKey: "evlin.lastScheduleResult")
                        ?? "(no schedule attempted yet — set a timed lock first)"
                    Text(lastResult)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(lastResult.contains("FAILED") ? Color.red : Color.evOnSurface)
                        .textSelection(.enabled)
                } header: {
                    Text("Last Auto-Unshield Schedule")
                } footer: {
                    Text("Should say 'schedule_ok' after every timed lock. If 'FAILED', the auto-unlock won't fire — copy the error and tell us.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // Diagnostic: did the DeviceActivityMonitor extension actually
                // fire when the interval ended? Written by the extension itself
                // (see EvlinDeviceActivityMonitor). If the schedule says ok but
                // this is empty after expiresAt, iOS isn't dispatching the
                // callback — likely an extension-install / auth issue.
                Section {
                    let lastFired = UserDefaults(suiteName: "group.com.evlin.ios")?
                        .string(forKey: "evlin.lastIntervalDidEnd")
                        ?? "(extension never fired since launch)"
                    Text(lastFired)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(lastFired.contains("shieldRemoved=false") ? Color.orange : Color.evOnSurface)
                        .textSelection(.enabled)
                } header: {
                    Text("Last Extension Fire")
                } footer: {
                    Text("After a timed lock expires this should update within 1-2 min. If empty long after expiresAt, the extension isn't being woken — check that EvlinDeviceActivityMonitor is signed and installed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // Diagnostic: every recomputeAndApply() call writes here, both
                // from the main app (ActiveLockStore.sweepExpired path) AND
                // from any code path that mutates shields/blocks. If a timed
                // shield's expiry passes and this stamp is FRESHER than the
                // shield's expiresAt with apps=0, then the main app already
                // cleared store.shield.applications — meaning the OS just
                // hasn't propagated the ManagedSettings mutation yet.
                Section {
                    let lastRecompute = UserDefaults(suiteName: "group.com.evlin.ios")?
                        .string(forKey: "evlin.lastRecompute")
                        ?? "(no recompute since install)"
                    Text(lastRecompute)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.evOnSurface)
                        .textSelection(.enabled)
                } header: {
                    Text("Last Recompute")
                } footer: {
                    Text("Shows what ActiveLockStore last pushed to ManagedSettings. apps=0 means shield.applications was set to nil. If you see apps=0 but Apple is still shielding an app, the OS hasn't propagated the mutation yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Mode") {
                    HStack {
                        Text("Current Mode")
                        Spacer()
                        Text(appMode == "parent" ? "Parent" : "Child")
                            .foregroundStyle(Color.evPrimary)
                    }

                    Button(role: .destructive) {
                        appMode = "setup"
                        onClose()
                    } label: {
                        Label("Switch Device Mode", systemImage: "arrow.triangle.2.circlepath")
                    }

                    if appMode == "parent" {
                        Button {
                            EvlinDemoShortcuts.seedPlaceholderChildUUIDIfMissing()
                            appMode = "child"
                            onClose()
                        } label: {
                            Label("Switch to Child Mode", systemImage: "figure.child")
                        }
                    } else if appMode == "child" {
                        Button {
                            appMode = "parent"
                            onClose()
                        } label: {
                            Label("Switch to Parent Mode", systemImage: "person.fill")
                        }
                    }

                    Button(role: .destructive) {
                        screenTimeManager.clearAllShields()
                        UserDefaults.standard.removeObject(forKey: "onboardingComplete")
                        UserDefaults.standard.removeObject(forKey: "appMode")
                        UserDefaults.standard.removeObject(forKey: "childId")
                        UserDefaults.standard.removeObject(forKey: "childName")
                        UserDefaults.standard.removeObject(forKey: "targetChildId")
                        UserDefaults.standard.removeObject(forKey: "evlin.familyID")
                        UserDefaults.standard.removeObject(forKey: "evlin.parentDeviceID")
                        UserDefaults.standard.removeObject(forKey: "evlin.childDeviceID")
                        UserDefaults.standard.removeObject(forKey: "evlin_chat_history")
                        UserDefaults.standard.removeObject(forKey: "serverURL")
                        EvlinDemoShortcuts.clearFlag()
                        NotificationCenter.default.post(name: .evlinClearChat, object: nil)
                        appMode = ""
                        onClose()
                    } label: {
                        Label("Reset Everything (Re-run Onboarding)", systemImage: "arrow.counterclockwise")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }

                #if DEBUG
                Section("Developer Tools") {
                    NavigationLink {
                        SpikeView()
                    } label: {
                        Label("Diagnostics & Spike Tests", systemImage: "wrench.and.screwdriver")
                    }

                    Text("One-device setup, backend checks, auth checks, and explicit hard-block experiments. Hidden in release builds.")
                        .font(.caption)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                #endif

                Section {
                    if let famID = UUID(uuidString: familyID) {
                        Picker("Protection Mode", selection: $protectionMode) {
                            Text("Standard (.individual)").tag("std")
                            Text("Maximum (.child)").tag("max")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: protectionMode) { old, new in
                            Task {
                                do {
                                    try await apiClient.setProtectionMode(familyID: famID, mode: new)
                                    await MainActor.run {
                                        protectionModeStatus = "✅ Set to \(new.uppercased())"
                                        UserDefaults.standard.set(new, forKey: "evlin.protectionMode")
                                    }
                                } catch {
                                    await MainActor.run {
                                        protectionMode = old
                                        UserDefaults.standard.set(old, forKey: "evlin.protectionMode")
                                        protectionModeStatus = "⚠️ Failed: \(error.localizedDescription)"
                                    }
                                }
                            }
                        }
                        if !protectionModeStatus.isEmpty {
                            Text(protectionModeStatus)
                                .font(.caption)
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                        Text(
                            """
                            Backend policy: Standard limits certain lock actions; Maximum enables broader blocks. \
                            This also drives which Screen Time authorization type applies on this phone (Settings → Screen Time → Authorize).
                            """
                        )
                        .font(.caption)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                    } else {
                        Text("Pair a device first — we need a family id to sync protection mode.")
                            .font(.caption)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                } header: {
                    Text("Protection Mode")
                }

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !serverURL.isEmpty {
                            apiClient.saveServerURL(serverURL)
                        }
                        onClose()
                    }
                }
            }
            .familyActivityPicker(
                isPresented: $isPickerPresented,
                selection: $screenTimeManager.selectedApps
            )
            .onChange(of: isPickerPresented) { _, open in
                // `FamilyActivitySelection` equality can ignore picker-only metadata deltas; always
                // persist when the sheet closes so `LocalAliasStore` + label snapshots refresh.
                if !open {
                    screenTimeManager.saveSelection()
                }
            }
            .onChange(of: screenTimeManager.selectedApps) { _, _ in
                screenTimeManager.saveSelection()
            }
            .onChange(of: smartMode.isOn) { _, _ in
                guard let famID = UUID(uuidString: familyID) else { return }
                Task { await smartMode.push(familyId: famID, apiClient: apiClient) }
            }
            .onAppear {
                serverURL = apiClient.baseURL
                screenTimeManager.refreshAuthorizationStatus()
                // Sync DEBUG protection-mode picker from backend so the
                // segmented control reflects truth, not the @State default.
                if let famID = UUID(uuidString: familyID) {
                    Task {
                        await smartMode.sync(familyId: famID, apiClient: apiClient)
                        if let m = try? await apiClient.getProtectionMode(familyID: famID) {
                            await MainActor.run {
                                protectionMode = m
                                UserDefaults.standard.set(m, forKey: "evlin.protectionMode")
                            }
                        }
                    }
                }
            }
            .sheet(item: $editing) { child in
                ChildEditSheet(child: child) { updated in
                    if let idx = children.firstIndex(where: { $0.id == updated.id }) {
                        children[idx] = updated
                    }
                    editing = nil
                }
            }
            .sheet(isPresented: $adding) {
                ChildEditSheet(child: nil) { newChild in
                    children.append(newChild)
                    adding = false
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var cameraIsAuthorized: Bool {
        _ = cameraPermissionFreshness
        if case .authorized = AVCaptureDevice.authorizationStatus(for: .video) { return true }
        return false
    }

    private var cameraStatusText: String {
        _ = cameraPermissionFreshness
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "Allowed"
        case .denied, .restricted: return "Blocked — use Evlin Settings below"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private var cameraPermissionActionTitle: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return "Allow Camera Access"
        case .authorized: return ""
        default: return "Fix Camera in Settings…"
        }
    }

    private func handleCameraPermissionTap() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async {
                    cameraPermissionFreshness += 1
                }
            }
        default:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    @ViewBuilder
    private func idRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.custom("Inter", size: 11).weight(.bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.evOutline)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .textSelection(.enabled)
        }
    }

    /// Nuclear reset — wipes every layer that holds lock state. See the
    /// Button comment above for rationale. Idempotent: safe to call when
    /// nothing is locked. Async because ActiveLockStore is an actor.
    private func nuclearReset() async {
        // 1. Stop every scheduled DeviceActivity callback FIRST. If we don't,
        //    a pending intervalDidEnd could fire mid-reset and write its own
        //    recompute back on top of us.
        DeviceActivityCenter().stopMonitoring()

        // 2. Drop every ManagedSettings policy this app has set. This is
        //    broader than clearLockRestrictions() — it also clears categories,
        //    webDomains, application.denyAppRemoval, etc. We restore the
        //    deletion-protection one explicitly in step 5.
        ManagedSettingsStore().clearAllSettings()

        // 3. Wipe ActiveLockStore's record dicts. unshieldAll/unblockAll also
        //    re-run recomputeAndApply which (with empty dicts) writes nils
        //    again — belt and suspenders after step 2.
        _ = await ActiveLockStore.shared.unshieldAll()
        _ = await ActiveLockStore.shared.unblockAll()

        // 4. Scrub every evlin.* key in the App Group. Even though steps 1-3
        //    cover the live state, persisted JSON for shield/block records
        //    and diagnostic markers could mislead future debugging if left.
        if let groupDefaults = UserDefaults(suiteName: "group.com.evlin.ios") {
            for key in [
                "evlin.shieldRecords",
                "evlin.blockRecords",
                "evlin.lastScheduleResult",
                "evlin.lastIntervalDidEnd",
                "evlin.lastRecompute",
            ] {
                groupDefaults.removeObject(forKey: key)
            }
        }

        // 5. Re-enable deletion protection. clearAllSettings() drops
        //    application.denyAppRemoval, which means after step 2 the parent
        //    could accidentally delete Evlin → lose enforcement. Put it
        //    back before returning.
        await MainActor.run {
            screenTimeManager.enableDeletionProtection()
            // Update the local UI flag so the lock indicator agrees.
            screenTimeManager.isUnlocked = true
            NotificationCenter.default.post(name: .evlinLockStateChanged, object: false)
        }
    }
}

private struct ChildEditSheet: View {
    let child: ChildProfile?
    var onSave: (ChildProfile) -> Void

    @State private var name: String = ""
    @State private var age: Int = 8

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    Stepper("Age: \(age)", value: $age, in: 1...18)
                }
            }
            .navigationTitle(child == nil ? "Add child" : "Edit \(child?.name ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let c = child {
                    name = c.name
                    age = c.age
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let id = child?.id ?? name.lowercased()
                        let updated = ChildProfile(
                            id: id, name: name, age: age,
                            avatarURL: child?.avatarURL,
                            accentColor: child?.accentColor ?? .evPrimary,
                            status: child?.status ?? .unlocked,
                            timeLeft: child?.timeLeft ?? "1h",
                            timePct: child?.timePct ?? 0.5,
                            subtitle: child?.subtitle ?? "New family member"
                        )
                        onSave(updated)
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
        .preferredColorScheme(.light)
    }
}

#Preview {
    HomeSettingsSheet(onClose: {})
        .environmentObject(APIClient(baseURL: "http://preview.local"))
        .environmentObject(ScreenTimeManager.shared)
}
