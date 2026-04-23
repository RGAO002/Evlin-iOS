// Evlin iOS/Evlin iOS/Views/Debug/SpikeView.swift
import SwiftUI
import FamilyControls
import ManagedSettings

struct SpikeView: View {
    @EnvironmentObject var apiClient: APIClient
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""
    @State private var log: [String] = []
    @State private var testFamilyID: String = UserDefaults.standard.string(forKey: "evlin.familyID") ?? ""
    @State private var testChildDeviceID: String = UserDefaults.standard.string(forKey: "evlin.childDeviceID") ?? ""
    @State private var testParentDeviceID: String = UserDefaults.standard.string(forKey: "evlin.parentDeviceID") ?? ""
    private let store = ManagedSettingsStore()

    var body: some View {
        NavigationStack {
            List {
                Section("Test Mode Quickstart") {
                    Text("One-tap setup that skips onboarding and makes this single device switch between Parent and Child mode. Creates a family on the backend, pairs it, grants auth, and seeds a test Saved List.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("🔧 Setup test mode (creates family + pairs)") {
                        Task { await setupTestMode() }
                    }

                    HStack {
                        Text("Current mode:").foregroundStyle(.secondary)
                        Text(appMode.isEmpty ? "not set" : appMode).bold()
                    }
                    .font(.caption)

                    Button("👨‍👩 Switch to PARENT mode") {
                        appMode = "parent"
                        onboardingComplete = true
                        record("→ appMode=parent, onboardingComplete=true. Close + reopen app.")
                    }

                    Button("🧒 Switch to CHILD mode") {
                        appMode = "child"
                        onboardingComplete = true
                        record("→ appMode=child, onboardingComplete=true. Close + reopen app.")
                    }

                    if !testFamilyID.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("family_id:").font(.caption2).foregroundStyle(.secondary)
                            Text(testFamilyID).font(.caption.monospaced())
                            Text("child_device_id:").font(.caption2).foregroundStyle(.secondary)
                            Text(testChildDeviceID).font(.caption.monospaced())
                        }
                    }
                }

                Section("Reset (for testing)") {
                    Button("Reset onboarding + appMode") {
                        UserDefaults.standard.removeObject(forKey: "onboardingComplete")
                        UserDefaults.standard.removeObject(forKey: "appMode")
                        UserDefaults.standard.removeObject(forKey: "evlin.familyID")
                        UserDefaults.standard.removeObject(forKey: "evlin.childDeviceID")
                        UserDefaults.standard.removeObject(forKey: "evlin.protectionMode")
                        record("onboarding reset — close + reopen app to re-enter onboarding")
                    }
                    .foregroundStyle(.red)

                    Button("Clear all Evlin UserDefaults (hard reset)") {
                        let keys = UserDefaults.standard.dictionaryRepresentation().keys
                        for k in keys where k.hasPrefix("evlin") || k == "onboardingComplete" || k == "appMode" || k == "childId" || k == "childName" || k == "serverURL" || k == "targetChildId" {
                            UserDefaults.standard.removeObject(forKey: k)
                        }
                        // Also clear the shared App Group UserDefaults (ActiveLockStore, LocalAliasStore)
                        if let shared = UserDefaults(suiteName: "group.com.evlin.ios") {
                            for k in shared.dictionaryRepresentation().keys {
                                shared.removeObject(forKey: k)
                            }
                        }
                        record("HARD reset complete — close + reopen app")
                    }
                    .foregroundStyle(.red)
                }

                Section("Backend URL") {
                    Text("baseURL:").font(.caption2).foregroundStyle(.secondary)
                    Text(apiClient.baseURL).font(.caption.monospaced())
                    Button("Use default Railway URL") {
                        apiClient.saveServerURL(APIClient.defaultURL)
                        record("baseURL reset to \(APIClient.defaultURL)")
                    }
                    Button("Ping /family/create (dry test)") {
                        Task { await pingBackend() }
                    }
                }

                Section("Authorization") {
                    Button("Check auth status") {
                        let status = AuthorizationCenter.shared.authorizationStatus
                        record("auth status = \(status)")
                    }
                    Button("Request authorization (.individual)") {
                        Task {
                            do {
                                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                                await MainActor.run { record("auth granted ✓") }
                            } catch {
                                await MainActor.run { record("auth failed: \(error)") }
                            }
                        }
                    }
                }
                Section("Bundle ID block") {
                    Button("Block Instagram") { blockInstagram() }
                    Button("Block Roblox") { blockRoblox() }
                    Button("Clear all blocks") { clearBlocks() }
                }
                Section("denyAppRemoval") {
                    Button("Enable") { setDenyRemoval(true) }
                    Button("Disable") { setDenyRemoval(false) }
                }
                Section("ActionExecutor") {
                    Button("Lock IG for 15 min (min allowed)") {
                        Task {
                            let cmd = LockCommand(
                                id: UUID(),
                                action: .lock,
                                tier: .exactBundle,
                                target: CommandTarget(
                                    bundleID: "com.burbn.instagram",
                                    originalRequest: "IG",
                                    targetDisplay: "Instagram"
                                ),
                                durationMinutes: 15,
                                issuedAt: Date()
                            )
                            let result = await ActionExecutor.shared.execute(cmd)
                            await MainActor.run { record("execute lock: \(result)") }
                        }
                    }
                    Button("Unlock everything") {
                        Task {
                            let cmd = LockCommand(
                                id: UUID(),
                                action: .unlockAll,
                                tier: nil,
                                target: CommandTarget(originalRequest: "all"),
                                durationMinutes: nil,
                                issuedAt: Date()
                            )
                            let result = await ActionExecutor.shared.execute(cmd)
                            await MainActor.run { record("execute unlockAll: \(result)") }
                        }
                    }
                    Button("Show active locks") {
                        Task {
                            let locks = await ActiveLockStore.shared.current()
                            await MainActor.run { record("active locks: \(locks.count) — \(locks.map(\.displayName))") }
                        }
                    }
                }
                Section("Log") {
                    ForEach(log, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("Spike tests")
        }
    }

    private func record(_ line: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .standard)) \(line)", at: 0)
        print("[Spike] \(line)")
    }

    private func blockInstagram() {
        let app = Application(bundleIdentifier: "com.burbn.instagram")
        var current = store.application.blockedApplications ?? []
        current.insert(app)
        store.application.blockedApplications = current
        record("blockedApplications = \(current.count) entries (added IG)")
    }

    private func blockRoblox() {
        let app = Application(bundleIdentifier: "com.roblox.robloxmobile")
        var current = store.application.blockedApplications ?? []
        current.insert(app)
        store.application.blockedApplications = current
        record("blockedApplications = \(current.count) entries (added Roblox)")
    }

    private func clearBlocks() {
        store.application.blockedApplications = nil
        record("blockedApplications = nil")
    }

    private func setDenyRemoval(_ flag: Bool) {
        store.application.denyAppRemoval = flag
        record("denyAppRemoval = \(flag)")
    }

    // MARK: - Test mode quickstart

    private func setupTestMode() async {
        record("setup: creating family…")
        do {
            // 1. Create family (as parent)
            let createURL = URL(string: "\(apiClient.baseURL)/family/create")!
            var req = URLRequest(url: createURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "child_name": "TestKid",
                "protection_mode": "std",
            ])
            let (data1, resp1) = try await URLSession.shared.data(for: req)
            guard (resp1 as? HTTPURLResponse)?.statusCode == 200 else {
                let body = String(data: data1, encoding: .utf8) ?? "?"
                record("setup FAIL /create: \(body.prefix(200))")
                return
            }
            struct CreateR: Codable {
                let family_id: UUID
                let parent_device_id: UUID
                let pairing_code: String
            }
            let c = try JSONDecoder().decode(CreateR.self, from: data1)
            record("setup: got code \(c.pairing_code), pairing…")

            // 2. Pair (as child, same device)
            let pairURL = URL(string: "\(apiClient.baseURL)/family/pair")!
            var req2 = URLRequest(url: pairURL)
            req2.httpMethod = "POST"
            req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req2.httpBody = try JSONSerialization.data(withJSONObject: [
                "code": c.pairing_code,
                "device_label": UIDevice.current.name + " (child-mode)",
            ])
            let (data2, resp2) = try await URLSession.shared.data(for: req2)
            guard (resp2 as? HTTPURLResponse)?.statusCode == 200 else {
                let body = String(data: data2, encoding: .utf8) ?? "?"
                record("setup FAIL /pair: \(body.prefix(200))")
                return
            }
            struct PairR: Codable {
                let family_id: UUID
                let child_device_id: UUID
                let parent_device_id: UUID
                let protection_mode: String
            }
            let p = try JSONDecoder().decode(PairR.self, from: data2)

            // 3. Persist IDs
            UserDefaults.standard.set(p.family_id.uuidString, forKey: "evlin.familyID")
            UserDefaults.standard.set(p.child_device_id.uuidString, forKey: "evlin.childDeviceID")
            UserDefaults.standard.set(p.parent_device_id.uuidString, forKey: "evlin.parentDeviceID")
            UserDefaults.standard.set(p.protection_mode, forKey: "evlin.protectionMode")

            await MainActor.run {
                testFamilyID = p.family_id.uuidString
                testChildDeviceID = p.child_device_id.uuidString
                testParentDeviceID = p.parent_device_id.uuidString
                record("setup ✓ family=\(p.family_id.uuidString.prefix(8))… child=\(p.child_device_id.uuidString.prefix(8))…")
                record("next: use Switch to PARENT / CHILD buttons")
            }

            // 4. Request .individual auth if not already
            if AuthorizationCenter.shared.authorizationStatus != .approved {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                await MainActor.run { record("setup: auth granted") }
            }
        } catch {
            await MainActor.run { record("setup ERROR: \(error.localizedDescription)") }
        }
    }

    private func pingBackend() async {
        do {
            let url = URL(string: "\(apiClient.baseURL)/family/create")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "child_name": "ping",
                "protection_mode": "std",
            ])
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            record("ping: HTTP \(code) — \(body.prefix(120))")
        } catch {
            record("ping FAILED: \(error.localizedDescription)")
        }
    }
}
