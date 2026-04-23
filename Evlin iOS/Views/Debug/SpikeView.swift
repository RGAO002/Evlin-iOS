// Evlin iOS/Evlin iOS/Views/Debug/SpikeView.swift
import SwiftUI
import FamilyControls
import ManagedSettings

struct SpikeView: View {
    @State private var log: [String] = []
    private let store = ManagedSettingsStore()

    var body: some View {
        NavigationStack {
            List {
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
}
