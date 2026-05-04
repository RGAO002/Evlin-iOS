import SwiftUI
import FamilyControls

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

    /// DEBUG: family protection mode mirror — synced from backend on appear,
    /// PUT-back via apiClient when the segmented control changes.
    @State private var protectionMode: String = "std"
    @State private var protectionModeStatus: String = ""
    @State private var serverURL: String = ""
    @State private var isPickerPresented = false

    var body: some View {
        NavigationStack {
            List {
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
                                Task { await screenTimeManager.requestAuthorization() }
                            }
                            .font(.evBodySmall)
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
                                Text("Managed Apps")
                                    .font(.evBodyMedium)
                                    .foregroundStyle(Color.evOnSurface)
                                if appCount > 0 || catCount > 0 {
                                    Text("\(appCount) apps, \(catCount) categories")
                                        .font(.evBodySmall)
                                        .foregroundStyle(Color.evOutline)
                                } else {
                                    Text("No apps selected")
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

                // MARK: - Protection Mode (DEBUG)
                #if DEBUG
                Section {
                    if let famID = UUID(uuidString: familyID) {
                        Picker("Protection Mode", selection: $protectionMode) {
                            Text("Standard (.individual)").tag("std")
                            Text("Maximum (.child)").tag("max")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: protectionMode) { _, new in
                            Task {
                                do {
                                    try await apiClient.setProtectionMode(familyID: famID, mode: new)
                                    protectionModeStatus = "✅ Set to \(new.uppercased())"
                                } catch {
                                    protectionModeStatus = "⚠️ Failed: \(error.localizedDescription)"
                                }
                            }
                        }
                        if !protectionModeStatus.isEmpty {
                            Text(protectionModeStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Std blocks 'block' and 'shield single app' (E1/E2 cards). Max enables both. Toggling here only affects the backend family record — onboarding may have set local state independently.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No paired family — pair a device first to use this toggle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Protection Mode (DEBUG)")
                }
                #endif
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
                // Sync protection mode from backend so the segmented
                // control reflects truth, not stale @State.
                if let famID = UUID(uuidString: familyID) {
                    Task {
                        if let m = try? await apiClient.getProtectionMode(familyID: famID) {
                            await MainActor.run { protectionMode = m }
                        }
                    }
                }
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
