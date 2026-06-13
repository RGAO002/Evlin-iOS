import SwiftUI
import FamilyControls
import ManagedSettings
import DeviceActivity
import AVFoundation

/// Pure, testable mapping for child create/edit/delete. Kept free of SwiftUI
/// so it can be unit-tested without a view host. The view layer (below) calls
/// these then performs the async APIClient round-trip + FamilyStore refresh.
enum ChildCRUDMapper {
    static func createBody(name: String, age: Int, referenceYear: Int) -> CreateChildBody {
        CreateChildBody(
            display_name: name,
            birth_year: referenceYear - age,
            gender: nil,
            child_device_id: nil
        )
    }

    static func updateBody(name: String, age: Int, referenceYear: Int) -> UpdateChildBody {
        UpdateChildBody(
            display_name: name,
            birth_year: referenceYear - age,
            gender: nil,
            avatar_kind: nil,
            avatar_value: nil,
            avatar_color: nil
        )
    }

    /// Human-readable message for a delete failure. The backend returns 409
    /// when a child still has a linked device (DELETE /family/children/{id}).
    static func deleteErrorMessage(for error: Error) -> String {
        if case APIError.serverError(409) = error {
            return "This child still has a paired device. Unpair the device before deleting."
        }
        return "Couldn't delete this child. \(error.localizedDescription)"
    }

    static func saveErrorMessage(for error: Error) -> String {
        "Couldn't save. \(error.localizedDescription)"
    }
}

struct HomeSettingsSheet: View {
    @EnvironmentObject var apiClient: APIClient
    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    @Environment(FamilyStore.self) private var familyStore
    var onClose: () -> Void

    @AppStorage("parentName") private var parentName: String = ""
    @AppStorage("childName") private var childName: String = ""
    @AppStorage("appMode") private var appMode: String = ""
    @AppStorage("evlin.familyID") private var familyID: String = ""
    @AppStorage("evlin.parentDeviceID") private var parentDeviceID: String = ""
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""

    /// Seeded from `FamilyStore.childProfiles` (real GET /family data) in
    /// `.onAppear`. Kept as local state because add/edit/delete mutate the list
    /// in place during the session.
    @State private var children: [ChildProfile] = []
    @State private var editing: ChildProfile? = nil
    @State private var adding: Bool = false

    @State private var serverURL: String = ""
    @State private var childOpError: String? = nil
    @State private var isChildOpInFlight: Bool = false
    /// HP-14: baseline for the "Parent name" field captured on appear, so we
    /// only PUT /me/profile when the user actually edited the name in THIS
    /// session (a stale legacy @AppStorage value must not silently rename
    /// the parent on Done).
    @State private var parentNameAtOpen: String = ""
    @State private var parentNameError: String? = nil
    @State private var isSavingParentName: Bool = false
    @State private var isPickerPresented = false
    @State private var showPINGate = false
    @State private var showAddApp = false
    @State private var showAddList = false
    @State private var showLockListGate = false
    @State private var showLockListManager = false
    @State private var pendingGatedAction: GatedAction?

    @AppStorage("evlin.protectionMode") private var savedProtectionMode: String = "std"

    /// Bumps SwiftUI redraw after camera permission callbacks.
    @State private var cameraPermissionFreshness: Int = 0

    /// Family protection mode mirror — synced from backend on appear, PUT-back when the segmented control changes.
    @State private var protectionMode: String = "std"
    @State private var protectionModeStatus: String = ""

    private enum GatedAction {
        case addApp
        case addList
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    .onDelete { offsets in
                        let toDelete = offsets.map { children[$0] }
                        Task { await deleteChildren(toDelete) }
                    }

                    Button { adding = true } label: {
                        Label("Add child", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.evPrimary)
                    }

                    LabeledContent("Parent name") {
                        TextField("", text: $parentName)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                            // HP-14: the @AppStorage write alone is dead —
                            // HomeView prefers the server display_name, so
                            // commit edits to the backend.
                            .onSubmit { Task { _ = await saveParentNameIfChanged() } }
                    }

                    if let parentNameError {
                        Text(parentNameError)
                            .font(.caption)
                            .foregroundStyle(Color.evError)
                    }

                    if let childOpError {
                        Text(childOpError)
                            .font(.caption)
                            .foregroundStyle(Color.evError)
                    }
                }

                #if DEBUG
                if false {
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
                        TextField("Child's name", text: $childName)
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
                }
                #endif

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

                    #if DEBUG
                    if false {
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

                    Button {
                        showLockListGate = true
                    } label: {
                        Label("App Controls", systemImage: "slider.horizontal.3")
                    }

                    Button {
                        pendingGatedAction = .addApp
                        showPINGate = true
                    } label: {
                        Label("Add app", systemImage: "plus.app")
                    }

                    Button {
                        pendingGatedAction = .addList
                        showPINGate = true
                    } label: {
                        Label("Add list", systemImage: "rectangle.stack.badge.plus")
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
                        ShieldHarvestProbeView()
                    } label: {
                        Label("ShieldConfig harvest (E1)", systemImage: "lock.doc")
                    }

                    NavigationLink {
                        DeviceActivityReportMetadataProbeView()
                    } label: {
                        Label("DeviceActivityReport metadata test", systemImage: "chart.bar.doc.horizontal")
                    }

                    NavigationLink {
                        LockActivityReviewScreen()
                    } label: {
                        Label("Lock activity review", systemImage: "clock.arrow.circlepath")
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
                        Label("Manage aliases", systemImage: "tag.fill")
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

                    NavigationLink {
                        QrSpikeDebugView()
                    } label: {
                        Label("QR-over-pixel DAR spike", systemImage: "qrcode.viewfinder")
                    }

                    NavigationLink {
                        ChildAppCatalogDebugView()
                    } label: {
                        Label("Child app catalog cross-device test", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }

                    NavigationLink {
                        ChildPickerSpikeView()
                    } label: {
                        Label(".child parent picker spike", systemImage: "person.2.badge.gearshape")
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
                    #endif
                }

                Section("App Controls") {
                    Button {
                        showLockListGate = true
                    } label: {
                        Label("App Controls", systemImage: "slider.horizontal.3")
                    }

                    NavigationLink {
                        AliasManagementView()
                    } label: {
                        Label("Manage aliases", systemImage: "tag.fill")
                    }

                    // Plan 5 — owner mints/approves/revokes co-parent invites.
                    NavigationLink {
                        OwnerInviteApprovalView()
                            .environmentObject(apiClient)
                    } label: {
                        Label("Co-parents", systemImage: "person.2.badge.gearshape")
                    }
                }

                #if DEBUG
                if false {
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
                }
                #endif

                #if DEBUG
                if false {
                Section("Device Status") {
                    HStack {
                        Text("Lock State")
                        Spacer()
                        Text(screenTimeManager.isUnlocked ? "Unlocked" : "Locked")
                            .foregroundStyle(screenTimeManager.isUnlocked ? Color.evSecondary : Color.evError)
                    }
                }
                }
                #endif

                Section("Chat") {
                    Button(role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "evlin_chat_history")
                        NotificationCenter.default.post(name: .evlinClearChat, object: nil)
                    } label: {
                        Label("Clear Chat History", systemImage: "trash")
                    }
                }

                #if DEBUG
                if false {
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

                // Diagnostic: did the reflection-lockdown DAM auto-removal fail to
                // schedule? The ReflectionLockApplier records the error here instead
                // of swallowing it — a failed schedule means no OS timer, so the
                // lock could outlive its lease.
                Section {
                    let failure = UserDefaults(suiteName: "group.com.evlin.ios")?
                        .string(forKey: "evlin.reflectionLockScheduleFailure") ?? "none"
                    Text(failure)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(failure == "none" ? Color.evOnSurface : Color.red)
                        .textSelection(.enabled)
                } header: {
                    Text("Reflection lock schedule")
                } footer: {
                    Text("'none' is healthy. A line here means the reflection lock's auto-removal failed to schedule — copy it and tell us.")
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
                }
                #endif

                #if DEBUG
                if false {
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
                }
                #endif

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }

                #if DEBUG
                Section("Debug") {
                    NavigationLink {
                        debugSettingsMenu
                    } label: {
                        Label("Diagnostics & experiments", systemImage: "ladybug")
                    }

                    Text("Developer-only tools. Hidden from TestFlight and release builds.")
                        .font(.caption)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                #endif

                #if DEBUG
                if false {
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
                }
                #endif

                #if DEBUG
                if false {
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
                #endif

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !serverURL.isEmpty {
                            apiClient.saveServerURL(serverURL)
                        }
                        // HP-14: commit a parent-name edit before closing.
                        // On failure the sheet stays open so the error is
                        // actually visible (revert the field or retry).
                        Task {
                            if await saveParentNameIfChanged() {
                                onClose()
                            }
                        }
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
            .onAppear {
                // Seed the editable children list from the live FamilyStore
                // (real GET /family data) instead of the retired mock. Only
                // seed once so in-session add/edit/delete aren't clobbered.
                if children.isEmpty {
                    children = familyStore.childProfiles
                }
                // HP-14: the server display_name is the source of truth
                // (HomeView prefers it over the local @AppStorage shadow) —
                // seed the field from it so the user edits what they
                // actually see, and capture the baseline so Done only PUTs
                // names changed in this session.
                if let serverName = familyStore.selfParent?.display_name,
                   !serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parentName = serverName
                }
                parentNameAtOpen = parentName
                serverURL = apiClient.baseURL
                screenTimeManager.refreshAuthorizationStatus()
                // Sync DEBUG protection-mode picker from backend so the
                // segmented control reflects truth, not the @State default.
                if let famID = UUID(uuidString: familyID) {
                    Task {
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
                ChildEditSheet(child: child) { name, age in
                    Task { await saveEditedChild(id: child.id, name: name, age: age) }
                }
            }
            .sheet(isPresented: $adding) {
                ChildEditSheet(child: nil) { name, age in
                    Task { await addChild(name: name, age: age) }
                }
            }
            .sheet(isPresented: $showPINGate) {
                EvlinPINGateView(
                    store: .shared,
                    onUnlocked: {
                        showPINGate = false
                        switch pendingGatedAction {
                        case .addApp:
                            showAddApp = true
                        case .addList:
                            showAddList = true
                        case .none:
                            break
                        }
                        pendingGatedAction = nil
                    },
                    onCancel: {
                        showPINGate = false
                        pendingGatedAction = nil
                    }
                )
            }
            .sheet(isPresented: $showLockListGate) {
                EvlinPINGateView(
                    store: .shared,
                    onUnlocked: {
                        showLockListGate = false
                        showLockListManager = true
                    },
                    onCancel: {
                        showLockListGate = false
                    }
                )
            }
            .sheet(isPresented: $showLockListManager) {
                if let familyID = UUID(uuidString: familyID),
                   let childID = UUID(uuidString: childDeviceID) {
                    NavigationStack {
                        LockListManagerView(
                            familyID: familyID,
                            childDeviceID: childID
                        )
                        .environmentObject(apiClient)
                    }
                } else {
                    Text("Pair this device first (missing family / child device ID).")
                        .padding()
                }
            }
            .sheet(isPresented: $showAddApp) {
                if let childID = UUID(uuidString: childDeviceID) {
                    NavigationStack {
                        AddAppFlowView(childDeviceID: childID) { _ in
                            showAddApp = false
                        }
                        .environmentObject(apiClient)
                    }
                } else {
                    Text("Pair this device first (missing child device ID).")
                        .padding()
                }
            }
            .sheet(isPresented: $showAddList) {
                if let familyID = UUID(uuidString: familyID),
                   let childID = UUID(uuidString: childDeviceID) {
                    NavigationStack {
                        SavedListPickerView(
                            familyID: familyID,
                            owningDeviceID: childID,
                            mode: "child_device"
                        ) { _ in
                            showAddList = false
                        }
                        .environmentObject(apiClient)
                    }
                } else {
                    Text("Pair this device first (missing family / child device ID).")
                        .padding()
                }
            }
        }
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var debugSettingsMenu: some View {
        Form {
            Section("Connection") {
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
                        let isPreset = newValue == APIClient.localDevURL
                            || newValue == APIClient.defaultURL
                        guard isPreset else { return }
                        apiClient.saveServerURL(newValue)

                        guard !oldValue.isEmpty, oldValue != newValue else { return }
                        UserDefaults.standard.removeObject(forKey: "evlin.familyID")
                        UserDefaults.standard.removeObject(forKey: "evlin.parentDeviceID")
                        UserDefaults.standard.removeObject(forKey: "evlin.childDeviceID")
                        UserDefaults.standard.set(false, forKey: "onboardingComplete")
                        UserDefaults.standard.set("", forKey: "appMode")
                    }
                }

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
                    TextField("Child's name", text: $childName)
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

            Section("Screen Time Debug") {
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

                ManagedActivitySelectionDiagnostics(selection: screenTimeManager.selectedApps)

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

            Section("Protection Mode") {
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
                                    protectionModeStatus = "Set to \(new.uppercased())"
                                    UserDefaults.standard.set(new, forKey: "evlin.protectionMode")
                                }
                            } catch {
                                await MainActor.run {
                                    protectionMode = old
                                    UserDefaults.standard.set(old, forKey: "evlin.protectionMode")
                                    protectionModeStatus = "Failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                    if !protectionModeStatus.isEmpty {
                        Text(protectionModeStatus)
                            .font(.caption)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                } else {
                    Text("Pair a device first — we need a family id to sync protection mode.")
                        .font(.caption)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }

            diagnosticsSections

            Section("Spike Tests") {
                NavigationLink {
                    SpikeView()
                } label: {
                    Label("Diagnostics & Spike Tests", systemImage: "wrench.and.screwdriver")
                }
                NavigationLink {
                    LabelTokenInspectorView()
                } label: {
                    Label("Label(token) snapshot test", systemImage: "rectangle.and.text.magnifyingglass")
                }
                NavigationLink {
                    ShieldHarvestProbeView()
                } label: {
                    Label("ShieldConfig harvest (E1)", systemImage: "lock.doc")
                }
                NavigationLink {
                    DeviceActivityReportMetadataProbeView()
                } label: {
                    Label("DeviceActivityReport metadata test", systemImage: "chart.bar.doc.horizontal")
                }
                NavigationLink {
                    LockActivityReviewScreen()
                } label: {
                    Label("Lock activity review", systemImage: "clock.arrow.circlepath")
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
                    AliasLibraryInspectorView()
                } label: {
                    Label("Alias library (after hydrate)", systemImage: "books.vertical")
                }
                NavigationLink {
                    AliasE2ETestView()
                } label: {
                    Label("Alias E2E test (start here)", systemImage: "checkmark.seal")
                }
                NavigationLink {
                    QrSpikeDebugView()
                } label: {
                    Label("QR-over-pixel DAR spike", systemImage: "qrcode.viewfinder")
                }
                NavigationLink {
                    ChildAppCatalogDebugView()
                } label: {
                    Label("Child app catalog cross-device test", systemImage: "iphone.gen3.radiowaves.left.and.right")
                }
                NavigationLink {
                    ChildPickerSpikeView()
                } label: {
                    Label(".child parent picker spike", systemImage: "person.2.badge.gearshape")
                }
            }
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var diagnosticsSections: some View {
        Section {
            NavigationLink {
                CommandDeliveryDiagnosticsView()
            } label: {
                Label("Command Delivery", systemImage: "antenna.radiowaves.left.and.right")
            }
        } header: {
            Text("Command Delivery")
        } footer: {
            Text("Use this when parent commands do not land on the kid device. On the kid phone, prefer opening this from Kid mode so switching modes does not poll and contaminate the result.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

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
        }

        Section {
            let failure = UserDefaults(suiteName: "group.com.evlin.ios")?
                .string(forKey: "evlin.reflectionLockScheduleFailure") ?? "none"
            Text(failure)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(failure == "none" ? Color.evOnSurface : Color.red)
                .textSelection(.enabled)
        } header: {
            Text("Reflection lock schedule")
        }

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
        }

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
        }
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

    private var referenceYear: Int { Calendar.current.component(.year, from: Date()) }

    /// HP-14: push an edited parent name to the backend
    /// (`PUT /me/profile`) and refresh the family aggregate so HomeView's
    /// header (which prefers `selfParent.display_name`) picks it up.
    /// Returns true when there was nothing to save or the save succeeded;
    /// false on failure (an inline error is shown and the sheet should
    /// stay open).
    @MainActor
    private func saveParentNameIfChanged() async -> Bool {
        let trimmed = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseline = parentNameAtOpen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != baseline else { return true }
        guard !isSavingParentName else { return false }
        isSavingParentName = true
        defer { isSavingParentName = false }
        do {
            _ = try await apiClient.updateParentProfile(
                UpdateParentProfileBody(
                    display_name: trimmed,
                    avatar_kind: nil,
                    avatar_value: nil,
                    avatar_color: nil
                )
            )
            await familyStore.refresh()
            parentNameAtOpen = trimmed   // new baseline — don't re-PUT on Done
            parentNameError = nil
            return true
        } catch {
            parentNameError = "Couldn't save parent name. \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    private func addChild(name: String, age: Int) async {
        isChildOpInFlight = true
        defer { isChildOpInFlight = false }
        do {
            // Server returns the authoritative ChildDTO (with the real id).
            _ = try await apiClient.createChild(
                ChildCRUDMapper.createBody(name: name, age: age, referenceYear: referenceYear))
            await familyStore.refresh()
            children = familyStore.childProfiles            // re-seed from truth
            adding = false
            childOpError = nil
        } catch {
            childOpError = ChildCRUDMapper.saveErrorMessage(for: error)
        }
    }

    @MainActor
    private func saveEditedChild(id: String, name: String, age: Int) async {
        isChildOpInFlight = true
        defer { isChildOpInFlight = false }
        do {
            _ = try await apiClient.updateChild(
                id: id,
                ChildCRUDMapper.updateBody(name: name, age: age, referenceYear: referenceYear))
            await familyStore.refresh()
            children = familyStore.childProfiles
            editing = nil
            childOpError = nil
        } catch {
            childOpError = ChildCRUDMapper.saveErrorMessage(for: error)
        }
    }

    @MainActor
    private func deleteChildren(_ toDelete: [ChildProfile]) async {
        isChildOpInFlight = true
        defer { isChildOpInFlight = false }
        for child in toDelete {
            do {
                try await apiClient.deleteChild(id: child.id)
            } catch {
                // 409 (linked device) or other — keep the child, show why.
                childOpError = ChildCRUDMapper.deleteErrorMessage(for: error)
                break
            }
        }
        await familyStore.refresh()
        children = familyStore.childProfiles                // truth wins; failed delete stays
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
    var onSave: (_ name: String, _ age: Int) -> Void

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
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), age)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}
