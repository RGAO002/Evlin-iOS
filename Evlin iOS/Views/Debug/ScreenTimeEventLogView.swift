import SwiftUI

/// Reads the App-Group `ScreenTimeEventLog` ring buffer and shows the events
/// newest-first. Verification surface for every screen-time fix.
struct ScreenTimeEventLogView: View {
    @State private var refreshTick = 0

    private var events: [ScreenTimeEvent] {
        _ = refreshTick
        return ScreenTimeEventLog.read()
    }

    var body: some View {
        List {
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
                Button { refreshTick += 1 } label: { Text("Refresh") }
                Button(role: .destructive) {
                    ScreenTimeEventLog.clear()
                    refreshTick += 1
                } label: { Text("Clear all events") }
            }
        }
        .navigationTitle("Screen-Time Events")
    }
}
