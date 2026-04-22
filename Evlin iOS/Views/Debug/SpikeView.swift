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
                Section("Bundle ID block") {
                    Button("Block Instagram") { blockInstagram() }
                    Button("Block Roblox") { blockRoblox() }
                    Button("Clear all blocks") { clearBlocks() }
                }
                Section("denyAppRemoval") {
                    Button("Enable") { setDenyRemoval(true) }
                    Button("Disable") { setDenyRemoval(false) }
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
