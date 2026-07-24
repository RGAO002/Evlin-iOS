#if DEBUG
import SwiftUI

struct MeteringDaemonDiagnosticsView: View {
    private let journal = MeteringDaemonDiagnosticJournal()
    private let inspector = MeteringDaemonInspector()

    @State private var snapshot = MeteringDaemonDiagnosticsSnapshot.make(
        ownerChildDeviceID: nil,
        persistedOwnerChildDeviceID: nil,
        appMode: "",
        localSelection: nil,
        entries: []
    )
    @State private var exportText = "{}"
    @State private var refreshing = false
    @State private var activationEvidence = MeteringDaemonActivationEvidence.derive(
        ownerChildDeviceID: nil,
        state: nil,
        entries: []
    )

    var body: some View {
        List {
            Section("Identity and protocol") {
                row("app mode", snapshot.appMode.isEmpty ? "not set" : snapshot.appMode)
                row("identity ready", snapshot.identityReady ? "yes" : "NO")
                row("owner mirror", snapshot.ownerChildDeviceID?.uuidString ?? "missing")
                row("epoch owner", snapshot.persistedOwnerChildDeviceID?.uuidString ?? "missing")
                row("local protocol", snapshot.protocolSelection)
            }

            Section("V2 activation evidence") {
                row("stage", activationEvidence.stage.rawValue)
                row("V2 READY", activationEvidence.v2Ready ? "YES" : "NO")
                row("advertised version", String(activationEvidence.advertisedVersion))
                row("local selection", activationEvidence.localSelection.rawValue)
                row("epoch", activationEvidence.epochID?.uuidString ?? "missing")
                row("route", activationEvidence.routeID?.uuidString ?? "missing")
                row("route lifecycle", activationEvidence.routeLifecycle?.rawValue ?? "missing")
                row("install phase", activationEvidence.installPhase?.rawValue ?? "missing")
                row("activation ack", activationEvidence.activationAcknowledged ? "yes" : "NO")
                row("exact daemon readback", activationEvidence.exactDaemonReadback ? "match" : "NO")
            }

            Section("Daemon operations") {
                row("starts", String(snapshot.startCount))
                row("named stops", String(snapshot.stopNamesCount))
                row("GLOBAL STOPS", String(snapshot.stopAllCount))
                ForEach(snapshot.namespaceCounts, id: \.namespace) { item in
                    row(item.namespace, String(item.count))
                }
            }

            Section("Latest daemon readback") {
                if let latest = snapshot.latestReadback {
                    row("result", latest.result.rawValue)
                    row("activity", latest.activityName ?? "missing")
                    row("namespace", latest.namespace ?? "unknown")
                    row("arm id", latest.armID?.uuidString ?? "none")
                    row("differences", latest.mismatchReasons.isEmpty
                        ? "none"
                        : latest.mismatchReasons.joined(separator: ", "))
                    if let actual = latest.actual {
                        row("actual events", actual.events.map {
                            "\($0.name)=\($0.threshold) past=\($0.includesPastActivity)"
                        }.joined(separator: " | "))
                    }
                    if let expected = latest.expected {
                        row("expected events", expected.events.map {
                            "\($0.name)=\($0.threshold) past=\($0.includesPastActivity)"
                        }.joined(separator: " | "))
                    }
                } else {
                    Text("No daemon readback recorded.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Journal (newest first)") {
                if snapshot.entries.isEmpty {
                    Text("No metering operations recorded.")
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.entries, id: \.sequence) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("#\(entry.sequence) \(entry.operation.rawValue) · \(entry.result.rawValue)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(entry.activityName ?? entry.namespace ?? "-")
                            .font(.system(size: 10, design: .monospaced))
                        if !entry.mismatchReasons.isEmpty {
                            Text(entry.mismatchReasons.joined(separator: ", "))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        if let message = entry.message {
                            Text(message)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.timestamp.formatted(.iso8601))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }

            Section {
                Button {
                    Task { await refreshReadbacks() }
                } label: {
                    Label(refreshing ? "Reading daemon..." : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(refreshing)

                ShareLink(item: exportText) {
                    Label("Export journal", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    journal.clear()
                    reloadSnapshot()
                } label: {
                    Label("Clear journal", systemImage: "trash")
                }
            } footer: {
                Text("This page is read-only. Refresh only reads configurations already recorded as armed.")
            }
        }
        .navigationTitle("Metering Daemon")
        .navigationBarTitleDisplayMode(.inline)
        .task { reloadSnapshot() }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        }
    }

    @MainActor
    private func refreshReadbacks() async {
        refreshing = true
        let requests = MeteringDaemonDiagnosticsSnapshot.manualInspectionRequests(
            entries: journal.read(),
            ownerChildDeviceID: MeteringOwnerMirror.current(),
            state: try? DeviceEpochStore.shared.read()
        )
        for request in requests {
            await inspector.request(request)
        }
        reloadSnapshot()
        refreshing = false
    }

    @MainActor
    private func reloadSnapshot() {
        let owner = MeteringOwnerMirror.current()
        let state = try? DeviceEpochStore.shared.read()
        let entries = journal.read()
        snapshot = MeteringDaemonDiagnosticsSnapshot.make(
            ownerChildDeviceID: owner,
            persistedOwnerChildDeviceID: state?.ownerChildDeviceID,
            appMode: UserDefaults.standard.string(forKey: "appMode") ?? "",
            localSelection: owner.flatMap { state?.ratchets[$0]?.localSelection },
            entries: entries
        )
        activationEvidence = MeteringDaemonActivationEvidence.derive(
            ownerChildDeviceID: owner,
            state: state,
            entries: entries
        )
        exportText = String(data: journal.exportData(), encoding: .utf8) ?? "{}"
    }
}
#endif
