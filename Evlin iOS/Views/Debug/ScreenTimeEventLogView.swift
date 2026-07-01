import SwiftUI

/// Reads the App-Group `ScreenTimeEventLog` ring buffer and shows the events
/// newest-first. Verification surface for every screen-time fix.
struct ScreenTimeEventLogView: View {
    @State private var refreshTick = 0
    @State private var memoryShields: [ShieldRecord] = []
    @State private var memoryBlocks: [BlockRecord] = []

    private var events: [ScreenTimeEvent] {
        _ = refreshTick
        return ScreenTimeEventLog.read()
    }

    @MainActor
    private func refreshCurrentRestrictions() async {
        let cur = await ActiveLockStore.shared.allCurrent()
        memoryShields = cur.shields
        memoryBlocks = cur.blocks
    }

    var body: some View {
        List {
            Section {
                let truthShields = CurrentRestrictionsReader.persistedShields()
                let truthBlocks = CurrentRestrictionsReader.persistedBlocks()
                let shieldDiverges = Set(truthShields.map(\.recordKey)) != Set(memoryShields.map(\.recordKey))
                let blockDiverges = Set(truthBlocks.map(\.bundleID)) != Set(memoryBlocks.map(\.bundleID))
                let diverges = shieldDiverges || blockDiverges

                Text(diverges
                     ? "⚠️ App-Group truth and ActiveLockStore in-memory DIVERGE"
                     : "✓ enforcement truth == in-memory")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(diverges ? .orange : .secondary)

                Text("— enforcement truth (App-Group) — shields \(truthShields.count) / blocks \(truthBlocks.count)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                ForEach(Array(truthShields.enumerated()), id: \.offset) { _, s in
                    Text("SHIELD \(s.recordKey) · tier \(s.tier.rawValue) · \(s.displayName) · sources \(s.sources.map(\.rawValue).sorted().joined(separator: ",")) · exp \(s.expiresAt.map { "\($0)" } ?? "—")")
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                ForEach(Array(truthBlocks.enumerated()), id: \.offset) { _, b in
                    Text("BLOCK \(b.bundleID) · \(b.displayName)")
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                Text("— ActiveLockStore in-memory — shields \(memoryShields.count) / blocks \(memoryBlocks.count)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            } header: {
                Text("Current restrictions (device truth)")
            }

            Section {
                if events.isEmpty {
                    Text("No screen-time events recorded yet.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(events.reversed().enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.kind.rawValue.uppercased())  \(e.source?.rawValue ?? "-")  \(e.app ?? "-")")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text("\(e.reason ?? "-")  ·  \(e.emitter.rawValue)  ·  \(e.dayKey ?? "-")")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(e.ts)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Screen-time events (newest first) · \(events.count)")
            }

            Section {
                Button {
                    refreshTick += 1
                    Task { await refreshCurrentRestrictions() }
                } label: { Text("Refresh") }
                Button(role: .destructive) {
                    ScreenTimeEventLog.clear()
                    refreshTick += 1
                } label: { Text("Clear all events") }
            }
        }
        .navigationTitle("Screen-Time Events")
        .task { await refreshCurrentRestrictions() }
    }
}
