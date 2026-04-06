import SwiftUI
import FamilyControls

struct SettingsView: View {
    @EnvironmentObject var apiClient: APIClient
    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage("childName") private var childName: String = "Liam"
    @AppStorage("targetChildId") private var targetChildId: String = ""
    @AppStorage("appMode") private var appMode: String = ""
    @State private var serverURL: String = ""
    @State private var isPickerPresented = false
    @State private var pairingInput: String = ""
    @State private var pairingMessage: String?

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

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Child Device ID")
                            .font(.evLabelMedium)
                            .foregroundStyle(Color.evOutline)
                            .evLabelStyle()
                        TextField("Paste child's device ID here", text: $targetChildId)
                            .font(.system(size: 12, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Pair with Code")
                            .font(.evLabelMedium)
                            .foregroundStyle(Color.evOutline)
                            .evLabelStyle()
                        HStack(spacing: Spacing.md) {
                            TextField("6-digit code", text: $pairingInput)
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                                .keyboardType(.numberPad)
                            Button {
                                pairWithCode()
                            } label: {
                                Text("Pair")
                                    .font(.evLabelLarge)
                                    .foregroundStyle(Color.evOnPrimary)
                                    .padding(.horizontal, Spacing.xl)
                                    .padding(.vertical, Spacing.md)
                                    .background(
                                        RoundedRectangle(cornerRadius: CornerRadius.md)
                                            .fill(pairingInput.count == 6 ? Color.evPrimary : Color.evPrimary.opacity(0.4))
                                    )
                            }
                            .disabled(pairingInput.count != 6)
                        }
                        if let msg = pairingMessage {
                            Text(msg)
                                .font(.evBodySmall)
                                .foregroundStyle(msg.contains("Paired") ? Color.evSecondary : Color.evError)
                        }
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

    private func pairWithCode() {
        Task {
            guard let url = URL(string: "\(apiClient.baseURL)/parent/pair") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["code": pairingInput])

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pairedId = result["child_id"] as? String,
                      let pairedName = result["child_name"] as? String
                else {
                    await MainActor.run { pairingMessage = "Invalid code" }
                    return
                }
                await MainActor.run {
                    targetChildId = pairedId
                    childName = pairedName
                    pairingMessage = "Paired with \(pairedName)!"
                    pairingInput = ""
                }
            } catch {
                await MainActor.run { pairingMessage = "Connection error" }
            }
        }
    }
}
