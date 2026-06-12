import SwiftUI
import ManagedSettings

struct CommandDeliveryDiagnosticsView: View {
    @State private var refreshTick: Int = 0

    var body: some View {
        List {
            Section {
                deliveryDiagnosticRow("APNs token registered", CommandDeliveryDiagnostics.keyTokenRegistered)
                deliveryDiagnosticRow("APNs token upload", CommandDeliveryDiagnostics.keyTokenUpload)
                deliveryDiagnosticRow("Remote notification", CommandDeliveryDiagnostics.keyRemoteNotification)
                deliveryDiagnosticRow("One-shot poll", CommandDeliveryDiagnostics.keyOneShotPoll)
                deliveryDiagnosticRow("Command poll", CommandDeliveryDiagnostics.keyCommandPoll)
                deliveryDiagnosticRow("Command ack", CommandDeliveryDiagnostics.keyCommandAck)
                deliveryDiagnosticRow("DAM heartbeat spike", CommandDeliveryDiagnostics.keyDAMHeartbeat)
                Button("Arm DAM heartbeat spike (starts in 2 min)") {
                    armDAMHeartbeatSpike()
                }
                Button(role: .destructive) {
                    BigKidActivityScheduler.shared.stopCommandHeartbeatSpike()
                    CommandDeliveryDiagnostics.record(
                        CommandDeliveryDiagnostics.keyDAMHeartbeat,
                        "stopped debug heartbeat schedule"
                    )
                    refreshTick += 1
                } label: {
                    Text("Stop DAM heartbeat spike")
                }
            } header: {
                Text("Command Delivery")
            } footer: {
                Text("Expected APNs path: token registered → token upload ok → remote notification received → one-shot poll completed → command ack ok. DAM heartbeat is a debug-only spike: arm it, background/lock/force-quit the app, then wait about 2 minutes to see whether the extension wakes and reports /child/heartbeat.")
            }

            heartbeatHistorySection
            nseSpikeSection
        }
        .navigationTitle("Command Delivery")
        .toolbar {
            Button("Refresh") {
                refreshTick += 1
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refreshTick += 1
            }
        }
    }

    /// SPIKE: shows the whole heartbeat-fire history (newest first) + the
    /// self-rearm result on each line, so a force-quit experiment reveals both
    /// the cadence and whether the extension can sustain its own heartbeat.
    @ViewBuilder
    private var heartbeatHistorySection: some View {
        Section {
            if heartbeatLog.isEmpty {
                Text("No heartbeat fires recorded yet.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(heartbeatLog.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Button(role: .destructive) {
                CommandDeliveryDiagnostics.clearHeartbeatLog()
                refreshTick += 1
            } label: {
                Text("Clear heartbeat history")
            }
        } header: {
            Text("Heartbeat history — total fires: \(heartbeatTotal)")
        } footer: {
            Text("Each line = one extension intervalDidStart fire + whether it could self-rearm. Several lines with rearm:ok = the extension sustains its own heartbeat (path A2, ~15-min). rearm:FAILED = only the main app can arm it (fall back to A1 tiled windows). Empty after force-quit + heavy phone use = the window doesn't wake under force-quit at all.")
        }
        .id("hb-\(refreshTick)")
    }

    private var heartbeatLog: [String] {
        CommandDeliveryDiagnostics.readLog(CommandDeliveryDiagnostics.keyHeartbeatLog)
    }

    private var heartbeatTotal: Int {
        CommandDeliveryDiagnostics.readInt(CommandDeliveryDiagnostics.keyHeartbeatCount)
    }

    /// SPIKE: shows whether the EvlinPushApplier NSE woke + applied a shield on
    /// each alert push — the decisive force-quit-resilience test. The block it
    /// applies (Safari, via an isolated named store) is cleared with the button.
    @ViewBuilder
    private var nseSpikeSection: some View {
        Section {
            if nseLog.isEmpty {
                Text("No NSE fires recorded yet.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(nseLog.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Button(role: .destructive) {
                ManagedSettingsStore(named: .init("evlin.nsespike")).clearAllSettings()
                refreshTick += 1
            } label: {
                Text("Clear NSE test block (unblocks Safari)")
            }
        } header: {
            Text("NSE force-quit spike — total fires: \(nseTotal)")
        } footer: {
            Text("Force-quit the kid app, then have the backend fire one alert push. If a line appears here saying the shield applied AND Safari shows the block screen while Evlin is force-quit, the NSE path works. The test block uses an isolated store; tap Clear to remove it.")
        }
        .id("nse-\(refreshTick)")
    }

    private var nseLog: [String] {
        CommandDeliveryDiagnostics.readLog(CommandDeliveryDiagnostics.keyNSELog)
    }

    private var nseTotal: Int {
        CommandDeliveryDiagnostics.readInt(CommandDeliveryDiagnostics.keyNSECount)
    }

    @ViewBuilder
    private func deliveryDiagnosticRow(_ title: String, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(CommandDeliveryDiagnostics.read(key))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .id("\(key)-\(refreshTick)")
        }
        .padding(.vertical, 2)
    }

    private func armDAMHeartbeatSpike() {
        do {
            try BigKidActivityScheduler.shared.startCommandHeartbeatSpike()
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyDAMHeartbeat,
                "armed debug heartbeat schedule; expected intervalDidStart in ~2 min"
            )
        } catch {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyDAMHeartbeat,
                "failed to arm debug heartbeat schedule error=\(error.localizedDescription)"
            )
        }
        refreshTick += 1
    }
}
