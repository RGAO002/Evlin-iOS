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
    @State private var pendingWork: MeteringDaemonPendingWorkEvidence?
    @State private var memoryTraceRecords: [DAMMemoryTrace.Record] = []
    @State private var memoryTraceExportText = "No DAM memory trace recorded."

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

            if let pendingWork {
                Section("Selected route work") {
                    row("route", pendingWork.routeID.uuidString)
                    row("install", "\(pendingWork.installPhase) / \(pendingWork.installAuthorization)")
                    row("install retry", retryText(
                        attempts: pendingWork.installAttempts,
                        terminal: pendingWork.installTerminal,
                        error: pendingWork.installLastErrorCode,
                        nextAttemptAt: pendingWork.installNextAttemptAt
                    ))
                    row("registration retry", optionalRetryText(
                        attempts: pendingWork.registrationAttempts,
                        terminal: pendingWork.registrationTerminal,
                        error: pendingWork.registrationLastErrorCode,
                        nextAttemptAt: pendingWork.registrationNextAttemptAt
                    ))
                    row("activation retry", optionalRetryText(
                        attempts: pendingWork.activationAttempts,
                        terminal: pendingWork.activationTerminal,
                        error: pendingWork.activationLastErrorCode,
                        nextAttemptAt: pendingWork.activationNextAttemptAt
                    ))
                }
            }

            Section("Daemon operations") {
                row("starts", String(snapshot.startCount))
                row("named stops", String(snapshot.stopNamesCount))
                row("GLOBAL STOPS", String(snapshot.stopAllCount))
                ForEach(snapshot.namespaceCounts, id: \.namespace) { item in
                    row(item.namespace, String(item.count))
                }
            }

            Section {
                row("records", String(memoryTraceRecords.count))
                row(
                    "completed callbacks",
                    String(DAMMemoryTraceLifecycle.summarize(memoryTraceRecords).completedCallbackCount)
                )
                row(
                    "entries without exit",
                    String(DAMMemoryTraceLifecycle.summarize(memoryTraceRecords).incompleteCallbacks.count)
                )
                row(
                    "timed-out drains not completed",
                    String(
                        DAMMemoryTraceLifecycle.summarize(memoryTraceRecords)
                            .unfinishedTimedOutDrainCallbackIDs.count
                    )
                )
                if let latest = memoryTraceRecords.last {
                    row("latest available", memoryText(latest.availableBytes))
                    row("latest footprint", memoryText(latest.footprintBytes))
                    row("process peak", memoryText(latest.peakFootprintBytes))
                    row("metering state file", memoryText(latest.stateFileBytes))
                }
                if memoryTraceRecords.isEmpty {
                    Text("No callback trace recorded.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(memoryTraceRecords.suffix(64).reversed()), id: \.sequence) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("#\(record.sequence) cb=\(record.callbackID) \(kindText(record.kind)) · \(stageText(record.stage))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text("pid=\(record.pid) avail=\(memoryText(record.availableBytes)) footprint=\(memoryText(record.footprintBytes)) peak=\(memoryText(record.peakFootprintBytes))")
                            .font(.system(size: 9, design: .monospaced))
                        Text("state=\(record.stateFileBytes)B flags=0x\(String(record.flags.rawValue, radix: 16)) act=\(String(record.activityHash, radix: 16)) evt=\(String(record.eventHash, radix: 16))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }

                ShareLink(item: memoryTraceExportText) {
                    Label("Export memory trace", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("DAM callback memory trace")
            } footer: {
                Text("Read-only fixed-size trace. An entry without exit is evidence of an interrupted callback, but is not by itself proof of a memory kill.")
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

    private func retryText(
        attempts: Int,
        terminal: String,
        error: String?,
        nextAttemptAt: Date
    ) -> String {
        "attempts=\(attempts) terminal=\(terminal) error=\(error ?? "none") next=\(nextAttemptAt.formatted(.iso8601))"
    }

    private func optionalRetryText(
        attempts: Int?,
        terminal: String?,
        error: String?,
        nextAttemptAt: Date?
    ) -> String {
        guard let attempts, let terminal, let nextAttemptAt else { return "missing" }
        return retryText(
            attempts: attempts,
            terminal: terminal,
            error: error,
            nextAttemptAt: nextAttemptAt
        )
    }

    private func memoryText(_ bytes: UInt32) -> String {
        String(format: "%.2f MB", Double(bytes) / 1_048_576)
    }

    private func kindText(_ kind: DAMMemoryTrace.CallbackKind) -> String {
        switch kind {
        case .intervalStart: "interval-start"
        case .intervalEnd: "interval-end"
        case .thresholdPool: "threshold-pool"
        case .thresholdAppLimit: "threshold-app-limit"
        case .thresholdOther: "threshold-other"
        }
    }

    private func stageText(_ stage: DAMMemoryTrace.Stage) -> String {
        switch stage {
        case .entry: "entry"
        case .beforeState: "before-state"
        case .afterState: "after-state"
        case .afterJournal: "after-journal"
        case .beforeDrain: "before-drain"
        case .afterDrainWait: "after-drain-wait"
        case .afterShield: "after-shield"
        case .exit: "exit"
        }
    }

    private func memoryTraceExport(_ records: [DAMMemoryTrace.Record]) -> String {
        records.map { record in
            [
                "seq=\(record.sequence)",
                "callback=\(record.callbackID)",
                "kind=\(kindText(record.kind))",
                "stage=\(stageText(record.stage))",
                "flags=\(record.flags.rawValue)",
                "pid=\(record.pid)",
                "available=\(record.availableBytes)",
                "footprint=\(record.footprintBytes)",
                "peak=\(record.peakFootprintBytes)",
                "state=\(record.stateFileBytes)",
                "wall=\(record.wallEpochSeconds)",
                "monotonic=\(record.monotonicMilliseconds)",
                "activity=\(record.activityHash)",
                "event=\(record.eventHash)",
            ].joined(separator: " ")
        }.joined(separator: "\n")
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
        pendingWork = MeteringDaemonPendingWorkEvidence.derive(
            ownerChildDeviceID: owner,
            state: state
        )
        memoryTraceRecords = DAMMemoryTrace.shared.readRecords()
        memoryTraceExportText = memoryTraceExport(memoryTraceRecords)
        exportText = String(data: journal.exportData(), encoding: .utf8) ?? "{}"
    }
}
#endif
