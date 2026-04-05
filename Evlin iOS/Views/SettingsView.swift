import SwiftUI
import FamilyControls

struct SettingsView: View {
    @EnvironmentObject var apiClient: APIClient
    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage("childName") private var childName: String = "Liam"
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

                        Button {
                            screenTimeManager.clearAllShields()
                        } label: {
                            Label("Unlock All Apps", systemImage: "lock.open.fill")
                                .font(.evBodyMedium)
                                .foregroundStyle(Color.evSecondary)
                        }
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
            }
        }
    }
}
