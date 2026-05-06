import SwiftUI
import FamilyControls
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
            .onAppear {
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
