import SwiftUI
import FamilyControls

struct HomeSettingsSheet: View {
    @EnvironmentObject var apiClient: APIClient
    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    var onClose: () -> Void

    @AppStorage("parentName") private var parentName: String = "Morgan"
    @AppStorage("childName") private var childName: String = "Liam"
    @AppStorage("targetChildId") private var targetChildId: String = ""
    @AppStorage("appMode") private var appMode: String = ""

    @State private var children: [ChildProfile] = ChildProfile.all
    @State private var editing: ChildProfile? = nil
    @State private var adding: Bool = false

    @State private var serverURL: String = ""
    @State private var isPickerPresented = false
    @State private var pairingInput: String = ""
    @State private var pairingMessage: String?

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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Child Device ID")
                            .font(.custom("Inter", size: 11).weight(.bold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.evOutline)
                        TextField("Paste child's device ID here", text: $targetChildId)
                            .font(.system(size: 12, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pair with Code")
                            .font(.custom("Inter", size: 11).weight(.bold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.evOutline)
                        HStack(spacing: 10) {
                            TextField("6-digit code", text: $pairingInput)
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                                .keyboardType(.numberPad)
                            Button("Pair") { pairWithCode() }
                                .disabled(pairingInput.count != 6)
                                .buttonStyle(.borderedProminent)
                                .tint(Color.evPrimary)
                        }
                        if let msg = pairingMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(msg.contains("Paired") ? Color.evSecondary : Color.evError)
                        }
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
                                Task { await screenTimeManager.requestAuthorization() }
                            }
                        }
                    }

                    let appCount = screenTimeManager.selectedApps.applicationTokens.count
                    let catCount = screenTimeManager.selectedApps.categoryTokens.count

                    Button {
                        isPickerPresented = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Managed Apps")
                                    .foregroundStyle(Color.evOnSurface)
                                if appCount > 0 || catCount > 0 {
                                    Text("\(appCount) apps, \(catCount) categories")
                                        .font(.caption)
                                        .foregroundStyle(Color.evOutline)
                                } else {
                                    Text("No apps selected")
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
                        UserDefaults.standard.removeObject(forKey: "evlin_chat_history")
                        UserDefaults.standard.removeObject(forKey: "serverURL")
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
            .onChange(of: screenTimeManager.selectedApps) { _, _ in
                screenTimeManager.saveSelection()
            }
            .onAppear {
                serverURL = apiClient.baseURL
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
