import SwiftUI
import FamilyControls
import AVFoundation

// MARK: - DEPRECATED / RETAINED FOR REFERENCE
// Replaced by HomeSettingsSheet (Views/Home/HomeSettingsSheet.swift),
// which consolidates all legacy sections (Connection / Screen Time /
// Device Status / Chat / Mode / About) with a new Children section on top
// and is forced into light color scheme.
// Kept on disk per spec preservation rule. Do not delete. Do not wire back in.

struct SettingsView: View {
    @EnvironmentObject var apiClient: APIClient
    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage("childName") private var childName: String = "Liam"
    @AppStorage("appMode") private var appMode: String = ""
    @AppStorage("evlin.familyID") private var familyID: String = ""
    @AppStorage("evlin.parentDeviceID") private var parentDeviceID: String = ""
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""

    /// Family protection mode — synced from backend on appear; PUT-back when the picker changes.
    @State private var protectionMode: String = "std"
    @State private var protectionModeStatus: String = ""
    @State private var serverURL: String = ""
    @State private var isPickerPresented = false

    @AppStorage("evlin.protectionMode") private var savedProtectionMode: String = "std"
    @State private var cameraPermissionFreshness: Int = 0

    /// Strategy-agent T11.13 — Smart Mode toggle store. Owned here so the
    /// SmartModeToggle section can read/write it as an EnvironmentObject.
    @StateObject private var smartMode = SmartModeStore()

    var body: some View {
        NavigationStack {
            List {
                // MARK: - AI Behavior (Strategy-agent T11.13)
                SmartModeToggle().environmentObject(smartMode)

                // MARK: - Connection
                Section {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Server URL")
                            .font(.evLabelMedium)
                            .foregroundStyle(Color.evOutline)
                            .evLabelStyle()
                        TextField("http://192.168.1.x:8000/api/v1", text: $serverURL)
                            .font(.evBodyMedium)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Child Name")
                            .font(.evLabelMedium)
                            .foregroundStyle(Color.evOutline)
                            .evLabelStyle()
                        TextField("Liam", text: $childName)
                            .font(.evBodyMedium)
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
                } header: {
                    Text("Connection")
                }

                // MARK: - Screen Time
                Section {
                    HStack {
                        Text("Authorization")
                            .font(.evBodyMedium)
                        Spacer()
                        if screenTimeManager.isAuthorized {
                            Label("Authorized", systemImage: "checkmark.circle.fill")
                                .font(.evBodySmall)
                                .foregroundStyle(Color.evSecondary)
                        } else {
                            Button("Authorize") {
                                Task { await screenTimeManager.requestScreenTimeAuthorization() }
                            }
                            .font(.evBodySmall)
                        }
                    }

                    Text(
                        savedProtectionMode == "max"
                            ? "Maximum mode: Screen Time must be authorized for the child's Apple ID on this phone."
                            : "Standard mode: Screen Time is authorized for the Apple ID signed in on this phone."
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
                            .font(.evBodyMedium)
                    }

                    Toggle(isOn: Binding(
                        get: { screenTimeManager.deletionProtectionEnabled },
                        set: { screenTimeManager.setDeletionProtectionEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Prevent deleting apps")
                                .font(.evBodyMedium)
                            Text("When ON, uninstalling Evlin — and typically other apps — is restricted system-wide.")
                                .font(.evBodySmall)
                                .foregroundStyle(Color.evOutline)
                        }
                    }

                    // App selection
                    let appCount = screenTimeManager.selectedApps.applicationTokens.count
                    let catCount = screenTimeManager.selectedApps.categoryTokens.count

                    Button {
                        isPickerPresented = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Managed Apps & Categories")
                                    .font(.evBodyMedium)
                                    .foregroundStyle(Color.evOnSurface)
                                if appCount > 0 || catCount > 0 {
                                    Text("\(appCount) apps, \(catCount) categories")
                                        .font(.evBodySmall)
                                        .foregroundStyle(Color.evOutline)
                                } else {
                                    Text("Nothing selected yet")
                                        .font(.evBodySmall)
                                        .foregroundStyle(Color.evOutline)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.evBodySmall)
                                .foregroundStyle(Color.evOutline)
                        }
                    }

                    Text("Tip: tap a category header (e.g. \"Games\") to lock the whole group, or pick individual apps for finer control.")
                        .font(.caption)
                        .foregroundStyle(Color.evOutline)

                    ManagedActivitySelectionDiagnostics(selection: screenTimeManager.selectedApps)

                    // Lock/Unlock buttons
                    if appCount > 0 || catCount > 0 {
                        Button {
                            screenTimeManager.shieldApps()
                        } label: {
                            Label("Lock Selected Apps", systemImage: "lock.fill")
                                .font(.evBodyMedium)
                                .foregroundStyle(Color.evError)
                        }
                    }

                    Button {
                        screenTimeManager.clearAllShields()
                    } label: {
                        Label("Unlock All Apps", systemImage: "lock.open.fill")
                            .font(.evBodyMedium)
                            .foregroundStyle(Color.evSecondary)
                    }
                } header: {
                    Text("Screen Time")
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .foregroundStyle(Color.evOutline)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Camera")
                                .font(.evBodyMedium)
                            Text(cameraStatusText)
                                .font(.caption)
                                .foregroundStyle(Color.evOutline)
                        }
                        Spacer()
                    }
                    Group {
                        if cameraIsAuthorized {
                            Text("Ready for task evidence and profile photos.")
                                .font(.evBodySmall)
                                .foregroundStyle(Color.evSecondary)
                        } else {
                            Button(cameraPermissionActionTitle) {
                                handleCameraPermissionTap()
                            }
                            .font(.evBodyMedium)
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
                            .font(.evBodyMedium)
                    }

                    Label("Choosing profile photos uses the picker; Apple may ask for Photos access there.", systemImage: "photo.on.rectangle.angled")
                        .font(.caption)
                        .foregroundStyle(Color.evOutline)
                } header: {
                    Text("Camera & Photos")
                }

                // MARK: - Status
                Section {
                    HStack {
                        Text("Device Status")
                            .font(.evBodyMedium)
                        Spacer()
                        Text(screenTimeManager.isUnlocked ? "Unlocked" : "Locked")
                            .font(.evLabelLarge)
                            .foregroundStyle(screenTimeManager.isUnlocked ? Color.evSecondary : Color.evError)
                    }
                } header: {
                    Text("Status")
                }

                // MARK: - Chat
                Section {
                    Button(role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "evlin_chat_history")
                        NotificationCenter.default.post(name: .evlinClearChat, object: nil)
                    } label: {
                        Label("Clear Chat History", systemImage: "trash")
                            .font(.evBodyMedium)
                    }
                } header: {
                    Text("Chat")
                }

                // MARK: - Schedule diagnostic
                // Reads the last DeviceActivitySchedule result that ActionExecutor
                // wrote to App Group UserDefaults. If a timed shield isn't auto-
                // releasing, this tells us whether the schedule even registered.
                Section {
                    let lastResult = UserDefaults(suiteName: "group.com.evlin.ios")?
                        .string(forKey: "evlin.lastScheduleResult") ?? "(no schedule attempted yet)"
                    Text(lastResult)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(lastResult.contains("FAILED") ? Color.red : Color.evOnSurface)
                        .textSelection(.enabled)
                } header: {
                    Text("Last Auto-Unshield Schedule")
                } footer: {
                    Text("Should say 'schedule_ok' after every timed lock. If 'FAILED', the auto-unlock won't fire — paste the error.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // MARK: - Device Mode
                Section {
                    HStack {
                        Text("Current Mode")
                            .font(.evBodyMedium)
                        Spacer()
                        Text(appMode == "parent" ? "Parent" : "Child")
                            .font(.evLabelLarge)
                            .foregroundStyle(Color.evPrimary)
                    }

                    Button(role: .destructive) {
                        appMode = "setup"
                        dismiss()
                    } label: {
                        Label("Switch Device Mode", systemImage: "arrow.triangle.2.circlepath")
                            .font(.evBodyMedium)
                    }

                    if appMode == "parent" {
                        Button {
                            EvlinDemoShortcuts.seedPlaceholderChildUUIDIfMissing()
                            appMode = "child"
                            dismiss()
                        } label: {
                            Label("Switch to Child Mode", systemImage: "figure.child")
                                .font(.evBodyMedium)
                        }
                    } else if appMode == "child" {
                        Button {
                            appMode = "parent"
                            dismiss()
                        } label: {
                            Label("Switch to Parent Mode", systemImage: "person.fill")
                                .font(.evBodyMedium)
                        }
                    }

                    Button(role: .destructive) {
                        // Clear all state
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
                        dismiss()
                    } label: {
                        Label("Reset Everything (Re-run Onboarding)", systemImage: "arrow.counterclockwise")
                            .font(.evBodyMedium)
                    }
                } header: {
                    Text("Device")
                }

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
                                .foregroundStyle(.secondary)
                        }
                        Text(
                            """
                            Backend policy: Standard limits certain lock actions; Maximum enables broader blocks. \
                            This also ties to Screen Time authorization (Settings → Screen Time → Authorize).
                            """
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Pair a device first — we need a family id to sync protection mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        // Save server URL
                        if !serverURL.isEmpty {
                            apiClient.saveServerURL(serverURL)
                        }
                        dismiss()
                    }
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evPrimary)
                }
            }
            .familyActivityPicker(
                isPresented: $isPickerPresented,
                selection: $screenTimeManager.selectedApps
            )
            .onChange(of: screenTimeManager.selectedApps) { _, _ in
                screenTimeManager.saveSelection()
            }
            .onAppear {
                serverURL = apiClient.baseURL
                screenTimeManager.refreshAuthorizationStatus()
                // Sync protection mode from backend so the segmented
                // control reflects truth, not stale @State.
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
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.evLabelMedium)
                .foregroundStyle(Color.evOutline)
                .evLabelStyle()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .textSelection(.enabled)
        }
    }
}
