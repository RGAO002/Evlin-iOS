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

    // Spike: verify that one FamilyActivityPicker session can yield multiple
    // identifiable categories via `selection.categories[*].localizedDisplayName`.
    // See chat discussion 2026-04-24.
    @State private var spikeSelection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var spikePickerOpen = false

    var body: some View {
        NavigationStack {
            List {
                Section("One-Device Test Setup") {
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

                Section("Diagnostics") {
                    Button("Poll child commands NOW") {
                        Task { await pollChildCommandsNow() }
                    }
                    Button("Show last command in queue") {
                        Task { await showLastQueuedCommand() }
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
                Section("Hard Block Tests (Hides App Icon)") {
                    Text("These use ManagedSettings blockedApplications. They are intentionally different from shield mode and can make the app disappear from the home screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Block Instagram") { blockInstagram() }
                    Button("Block Roblox") { blockRoblox() }
                    Button("Clear all blocks") { clearBlocks() }
                }
                Section("denyAppRemoval") {
                    Button("Enable") { setDenyRemoval(true) }
                    Button("Disable") { setDenyRemoval(false) }
                }
                Section("ActionExecutor") {
                    Text("The IG test below uses exact_bundle, so it hard-blocks and may hide the app icon. Saved lists and categories use shield.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Block IG (permanent — Max only)") {
                        Task {
                            let cmd = LockCommand(
                                id: UUID(),
                                action: .block,
                                tier: nil,
                                target: CommandTarget(
                                    bundleID: "com.burbn.instagram",
                                    originalRequest: "IG",
                                    targetDisplay: "Instagram"
                                ),
                                durationMinutes: nil,
                                issuedAt: Date()
                            )
                            let result = await ActionExecutor.shared.execute(cmd)
                            await MainActor.run { record("execute block: \(result)") }
                        }
                    }
                    Button("Unshield everything") {
                        Task {
                            let cmd = LockCommand(
                                id: UUID(),
                                action: .unshieldAll,
                                tier: nil,
                                target: CommandTarget(originalRequest: "all"),
                                durationMinutes: nil,
                                issuedAt: Date()
                            )
                            let result = await ActionExecutor.shared.execute(cmd)
                            await MainActor.run { record("execute unshieldAll: \(result)") }
                        }
                    }
                    Button("Show active shields + blocks") {
                        Task {
                            let cur = await ActiveLockStore.shared.allCurrent()
                            await MainActor.run {
                                record("shields: \(cur.shields.count) — \(cur.shields.map(\.displayName))")
                                record("blocks: \(cur.blocks.count) — \(cur.blocks.map(\.displayName))")
                            }
                        }
                    }
                }

                Section("Category Token Spike") {
                    Text("Open Apple picker once. Select multiple categories (tap the category ROW header, not individual apps). The log prints what we got back — we're verifying `.categories[*].localizedDisplayName` gives us a stable, identifiable name per token.")
                        .font(.caption).foregroundStyle(.secondary)

                    Button("🧪 One picker → inspect categories") {
                        // Reset selection each time so we don't accumulate across runs.
                        spikeSelection = FamilyActivitySelection(includeEntireCategory: true)
                        spikePickerOpen = true
                    }
                    .familyActivityPicker(isPresented: $spikePickerOpen, selection: $spikeSelection)
                    .onChange(of: spikePickerOpen) { _, isOpen in
                        if !isOpen {
                            logSpikeResult(spikeSelection)
                        }
                    }
                }

                Section("Log") {
                    ForEach(log, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("Diagnostics")
        }
    }

    private func record(_ line: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .standard)) \(line)", at: 0)
        print("[Spike] \(line)")
    }

    /// Dump everything interesting from a FamilyActivitySelection so we can
    /// decide whether to collapse category-token setup to one picker.
    private func logSpikeResult(_ sel: FamilyActivitySelection) {
        record("═══ spike result ═══")
        record("includeEntireCategory=\(sel.includeEntireCategory)")
        record("categoryTokens.count=\(sel.categoryTokens.count)")
        record("categories.count=\(sel.categories.count)")
        for (i, c) in sel.categories.enumerated() {
            let name = c.localizedDisplayName ?? "<nil>"
            let hasToken = c.token != nil
            record("  [\(i)] name=\"\(name)\"  token=\(hasToken ? "✓" : "✗")")
        }
        record("applicationTokens.count=\(sel.applicationTokens.count)")
        record("applications.count=\(sel.applications.count)")
        for (i, a) in sel.applications.prefix(5).enumerated() {
            let name = a.localizedDisplayName ?? "<nil>"
            let bid = a.bundleIdentifier ?? "<nil>"
            record("  app[\(i)] name=\"\(name)\" bundle=\(bid)")
        }
        if sel.applications.count > 5 {
            record("  ... (\(sel.applications.count - 5) more apps omitted)")
        }
        record("webDomainTokens.count=\(sel.webDomainTokens.count)")
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
            // 1. Create family as the child side, then pair this same device as parent.
            let createURL = URL(string: "\(apiClient.baseURL)/family/create")!
            var req = URLRequest(url: createURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "child_device_label": UIDevice.current.name + " (child-mode)",
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
                let child_device_id: UUID
                let pairing_code: String
            }
            let c = try JSONDecoder().decode(CreateR.self, from: data1)
            record("setup: got code \(c.pairing_code), pairing…")

            // 2. Pair as the parent side on the same device.
            let pairURL = URL(string: "\(apiClient.baseURL)/family/pair")!
            var req2 = URLRequest(url: pairURL)
            req2.httpMethod = "POST"
            req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req2.httpBody = try JSONSerialization.data(withJSONObject: [
                "code": c.pairing_code,
                "parent_device_label": UIDevice.current.name + " (parent-mode)",
                "protection_mode": "std",
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

    private func pollChildCommandsNow() async {
        guard let idStr = UserDefaults.standard.string(forKey: "evlin.childDeviceID"),
              let deviceID = UUID(uuidString: idStr) else {
            await MainActor.run { record("no evlin.childDeviceID in UserDefaults") }
            return
        }
        do {
            let cmds = try await apiClient.pollCommands(deviceID: deviceID)
            await MainActor.run {
                record("pollCommands → \(cmds.count) pending")
                for c in cmds.prefix(3) {
                    record("  \(c.action) \(c.tier ?? "?") target=\(c.target.target_display ?? c.target.original_request)")
                }
            }
        } catch {
            await MainActor.run { record("poll error: \(error.localizedDescription)") }
        }
    }

    private func showLastQueuedCommand() async {
        guard let idStr = UserDefaults.standard.string(forKey: "evlin.childDeviceID"),
              let deviceID = UUID(uuidString: idStr) else {
            await MainActor.run { record("no evlin.childDeviceID in UserDefaults") }
            return
        }
        do {
            var comps = URLComponents(string: "\(apiClient.baseURL)/child/commands")!
            comps.queryItems = [URLQueryItem(name: "device_id", value: deviceID.uuidString)]
            let (data, resp) = try await URLSession.shared.data(from: comps.url!)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            await MainActor.run { record("GET /child/commands HTTP \(code): \(body.prefix(300))") }
        } catch {
            await MainActor.run { record("error: \(error.localizedDescription)") }
        }
    }

    private func pingBackend() async {
        do {
            let url = URL(string: "\(apiClient.baseURL)/family/create")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "child_device_label": "ping",
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
