#if DEBUG
import CryptoKit
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import SwiftUI

@MainActor
private struct AppLimitProbeEffectPort: AppLimitOwnerEffectPort, @unchecked Sendable {
    func apply(
        work: AppLimitOwnerWork,
        slot: AppLimitVersionSlot
    ) async throws -> AppLimitOwnerEffectResult {
        guard let owner = MeteringOwnerMirror.current() else {
            throw AppLimitProbeError.missingOwner
        }
        return try await ActionExecutor.shared.recoverAppLimitOwnerEffect(
            work: work,
            slot: slot,
            expectedChildID: owner
        )
    }
}

private struct AppLimitProbeReadbackPort: AppLimitOwnerReadbackPort, @unchecked Sendable {
    func confirm(commandID: UUID, receipt: AppLimitApplyReceipt) async throws {
        // This command is local-only. The durable receipt is the physical proof;
        // there is deliberately no fabricated backend command to acknowledge.
    }
}

private enum AppLimitProbeError: LocalizedError {
    case exactlyOneAppRequired
    case missingOwner
    case ownerMismatch
    case topologyProbeAlreadyActive
    case tokenEncodingFailed
    case commandRejected(String)
    case receiptMissing

    var errorDescription: String? {
        switch self {
        case .exactlyOneAppRequired: "Select exactly one app."
        case .missingOwner: "No current child-device owner is configured."
        case .ownerMismatch: "Owner mirror and epoch-store owner do not match."
        case .topologyProbeAlreadyActive: "Stop the active topology probe before starting another."
        case .tokenEncodingFailed: "The selected app token could not be encoded."
        case .commandRejected(let reason): "Probe command rejected: \(reason)"
        case .receiptMissing: "The arm completed without a durable applied receipt."
        }
    }
}

struct AppLimitOneMinuteProbeView: View {
    private static let ruleIDKey = "evlin.debug.appLimitProbe.ruleID"
    private static let startedAtKey = "evlin.debug.appLimitProbe.startedAt"
    private static let topologyActiveModeKey = "evlin.debug.appLimitTopologyProbe.activeMode"
    private static let topologyStartedAtKey = "evlin.debug.appLimitTopologyProbe.startedAt"

    @State private var selection = FamilyActivitySelection(includeEntireCategory: false)
    @State private var pickerShown = false
    @State private var running = false
    @State private var status = "Select one unused app."
    @State private var refreshTick = 0
    @State private var topologyMode: AppLimitTopologyProbeMode = .legacyWindow
    @State private var topologyStatus = "Run legacy and v2 separately with the same unused app."

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: MeteringProductionComposition.appGroupSuiteName)
    }

    private var currentRuleID: UUID? {
        defaults?.string(forKey: Self.ruleIDKey).flatMap(UUID.init(uuidString:))
    }

    var body: some View {
        Section {
            Picker("Topology", selection: $topologyMode) {
                Text("Legacy").tag(AppLimitTopologyProbeMode.legacyWindow)
                Text("V2").tag(AppLimitTopologyProbeMode.v2PerRule)
            }
            .pickerStyle(.segmented)

            Button {
                runTopologyProbe()
            } label: {
                Label("Arm \(topologyMode.rawValue) 1-minute probe", systemImage: "scope")
            }
            .disabled(running || selection.applicationTokens.count != 1 || topologyProbeIsActive)

            Button(role: .destructive) {
                stopTopologyProbe()
            } label: {
                Label("Stop topology probe", systemImage: "stop.circle")
            }
            .disabled(!topologyProbeIsActive)

            probeRow("topology status", topologyStatus)
            probeRow("active topology", defaults?.string(forKey: Self.topologyActiveModeKey) ?? "none")
            probeRow("topology callbacks", topologyCallbackReadback)
        } header: {
            Text("Per-App Legacy / V2 A-B")
        } footer: {
            Text("DEBUG only. Both modes use the same app token, 1-minute threshold, timezone, and includesPastActivity=true. Only reserved probe names are stopped; backend policy and AppLimitEpochStore are untouched.")
        }

        Section {
            Button {
                pickerShown = true
            } label: {
                Label(
                    selection.applicationTokens.count == 1
                        ? "One app selected"
                        : "Select one unused app",
                    systemImage: "app.badge.checkmark"
                )
            }

            Button {
                Task { await arm() }
            } label: {
                Label("Arm real 1-minute limit", systemImage: "timer")
            }
            .disabled(running || selection.applicationTokens.count != 1)

            Button {
                refreshTick += 1
            } label: {
                Label("Refresh raw readback", systemImage: "arrow.clockwise")
            }

            probeRow("status", status)
            probeRow("arm provenance", armProvenanceReadback)
            probeRow("includesPastActivity", "false (production planner event)")
            probeRow("callback decision / reason", callbackReadback)
            probeRow("current token / tombstone", tokenReadback)
            probeRow("shield source", shieldReadback)
            probeRow("applied receipt", receiptReadback)
        } header: {
            Text("Per-App Physical Gate")
        } footer: {
            Text("DEBUG only. This arms the selected app through the production command, owner-recovery, planner, and epoch-store path. It does not synthesize callbacks or alter timing, trust, owner, or gate inputs.")
        }
        .id("app-limit-one-minute-\(refreshTick)")
        .familyActivityPicker(isPresented: $pickerShown, selection: $selection)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refreshTick += 1
            }
        }
    }

    private var topologyProbeIsActive: Bool {
        defaults?.string(forKey: Self.topologyActiveModeKey) != nil
    }

    private var topologyCallbackReadback: String {
        let callbacks = AppLimitTopologyProbeCallbackStore.read(defaults: defaults)
        guard !callbacks.isEmpty else { return "(none)" }
        return callbacks.map {
            "\(timestamp($0.timestamp)) \($0.activityName) event=\($0.eventName)"
        }.joined(separator: " | ")
    }

    private func runTopologyProbe() {
        do {
            guard selection.applicationTokens.count == 1,
                  let token = selection.applicationTokens.first
            else { throw AppLimitProbeError.exactlyOneAppRequired }
            guard let owner = MeteringOwnerMirror.current() else {
                throw AppLimitProbeError.missingOwner
            }
            guard (try? DeviceEpochStore.shared.read().ownerChildDeviceID) == owner else {
                throw AppLimitProbeError.ownerMismatch
            }
            guard !topologyProbeIsActive else {
                throw AppLimitProbeError.topologyProbeAlreadyActive
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let tokenData = try? encoder.encode(token) else {
                throw AppLimitProbeError.tokenEncodingFailed
            }
            let tokenDigest = SHA256.hash(data: tokenData)
                .map { String(format: "%02x", $0) }
                .joined()
            let now = Date()
            let plan = try AppLimitTopologyProbePlan.make(
                mode: topologyMode,
                tokenDigest: tokenDigest,
                now: now,
                timezone: TimeZone.current.identifier
            )
            let schedule = try plan.schedule()
            let event = DeviceActivityEvent(
                applications: [token],
                categories: [],
                webDomains: [],
                threshold: DateComponents(minute: 1),
                includesPastActivity: true
            )
            let scheduler = DiagnosticDeviceActivityScheduler(base: DeviceActivityCenterScheduler())
            scheduler.stopMonitoring(plan.stopActivityNames.map { DeviceActivityName($0) })
            AppLimitTopologyProbeCallbackStore.clear(defaults: defaults)
            try scheduler.startMonitoring(
                DeviceActivityName(plan.activityName),
                during: schedule,
                events: [DeviceActivityEvent.Name(plan.eventName): event]
            )
            defaults?.set(topologyMode.rawValue, forKey: Self.topologyActiveModeKey)
            defaults?.set(ISO8601DateFormatter().string(from: now), forKey: Self.topologyStartedAtKey)
            topologyStatus = "\(timestamp(now)) armed \(topologyMode.rawValue); use only the selected app"
            refreshTick += 1
        } catch {
            topologyStatus = "\(timestamp()) error=\(error.localizedDescription)"
        }
    }

    private func stopTopologyProbe() {
        let scheduler = DiagnosticDeviceActivityScheduler(base: DeviceActivityCenterScheduler())
        scheduler.stopMonitoring(
            AppLimitTopologyProbePlan.reservedActivityNames.map { DeviceActivityName($0) }
        )
        defaults?.removeObject(forKey: Self.topologyActiveModeKey)
        defaults?.removeObject(forKey: Self.topologyStartedAtKey)
        topologyStatus = "\(timestamp()) stopped reserved topology probes"
        refreshTick += 1
    }

    private func arm() async {
        running = true
        defer { running = false }
        do {
            guard selection.applicationTokens.count == 1,
                  let token = selection.applicationTokens.first
            else { throw AppLimitProbeError.exactlyOneAppRequired }
            guard MeteringOwnerMirror.current() != nil else {
                throw AppLimitProbeError.missingOwner
            }

            let now = Date()
            let ruleID = UUID()
            let command = try makeSetCommand(
                ruleID: ruleID,
                token: token,
                issuedAt: now
            )
            let envelope = try AppLimitProductionComposition.envelope(
                from: command,
                source: .poll
            )
            let disposition = try AppLimitCommandCoordinator().ingest(envelope)
            guard disposition == .acceptedNeedsOwner else {
                throw AppLimitProbeError.commandRejected(String(describing: disposition))
            }

            let driver = AppLimitOwnerRecoveryDriver(
                effectPort: AppLimitProbeEffectPort(),
                readbackPort: AppLimitProbeReadbackPort()
            )
            await driver.recover(ownerChildDeviceID: MeteringOwnerMirror.current()!)
            guard try AppLimitProductionComposition.currentAppliedReceipt(
                ruleID: ruleID
            ) != nil else {
                throw AppLimitProbeError.receiptMissing
            }

            defaults?.set(ruleID.uuidString, forKey: Self.ruleIDKey)
            defaults?.set(ISO8601DateFormatter().string(from: now), forKey: Self.startedAtKey)
            status = "\(timestamp()) armed rule=\(ruleID.uuidString.lowercased())"
            refreshTick += 1
        } catch {
            status = "\(timestamp()) error=\(error.localizedDescription)"
        }
    }

    private func makeSetCommand(
        ruleID: UUID,
        token: ApplicationToken,
        issuedAt: Date
    ) throws -> LockCommand {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let tokenData = try? encoder.encode(token) else {
            throw AppLimitProbeError.tokenEncodingFailed
        }
        let timezone = TimeZone.current.identifier
        let target = CommandTarget(
            bundleID: "debug.physical-gate",
            listName: nil,
            listID: nil,
            categoryHint: nil,
            originalRequest: "DEBUG one-minute physical gate",
            targetDisplay: "Physical gate app",
            targetChildID: MeteringOwnerMirror.current(),
            catalogTokenDataBase64: tokenData.base64EncodedString()
        )
        return LockCommand(
            id: UUID(),
            action: .setLimit,
            tier: nil,
            target: target,
            durationMinutes: nil,
            issuedAt: issuedAt,
            limit: LimitRule(
                ruleId: ruleID,
                orderingToken: 1,
                dailyBudgetMinutes: 1,
                resetPolicy: "daily",
                startMinute: 0,
                endMinute: 1439,
                timezone: timezone,
                effectiveFrom: issuedAt,
                expiresAt: nil,
                updatedAt: issuedAt
            )
        )
    }

    private var slot: AppLimitVersionSlot? {
        guard let ruleID = currentRuleID else { return nil }
        return try? AppLimitEpochStore.shared.read().slots[ruleID]
    }

    private var armProvenanceReadback: String {
        guard let provenance = slot?.armProvenance else { return "(none)" }
        return "\(timestamp(provenance.startedAt)) arm=\(provenance.armID.uuidString.lowercased()) activity=\(provenance.activityName) usageDate=\(provenance.usageDate) base=\(provenance.baseAcceptedMinutes) raw=\(provenance.lastRawThresholdMinutes) ignored=\(provenance.ignoredWhilePausedMinutes)"
    }

    private var callbackReadback: String {
        guard let ruleID = currentRuleID else { return "(none)" }
        if let event = ScreenTimeEventLog.read().last(where: {
            $0.source == .perAppLimit
                && ($0.app?.contains(ruleID.uuidString.lowercased()) == true
                    || $0.app?.contains(ruleID.uuidString) == true)
        }) {
            return "\(event.ts) \(event.kind.rawValue) reason=\(event.reason ?? "none")"
        }
        guard let provenance = slot?.armProvenance else { return "(none)" }
        if provenance.ignoredWhilePausedMinutes > 0 {
            return "paused reason=usage_counting_disabled raw=\(provenance.ignoredWhilePausedMinutes)"
        }
        if provenance.lastRawThresholdMinutes > 0 {
            return "accepted raw=\(provenance.lastRawThresholdMinutes); effect readback pending"
        }
        return "pending reason=no physical callback recorded"
    }

    private var tokenReadback: String {
        guard let slot else { return "(none)" }
        if let tombstone = slot.clearTombstone {
            return "token=\(tombstone.orderingToken) tombstone=clear digest=\(tombstone.payloadDigest)"
        }
        return "token=\(slot.latestOrderingToken) tombstone=none digest=\(slot.latestPayloadDigest)"
    }

    private var shieldReadback: String {
        guard let ruleID = currentRuleID else { return "(none)" }
        let persistence = AppLimitShieldPersistence(store: defaults)
        let records = ((try? persistence.load()) ?? [:]).values.filter {
            $0.limitRuleIDs.contains(ruleID)
        }
        guard !records.isEmpty else { return "(none)" }
        return records.map {
            "key=\($0.recordKey) sources=\($0.sources.map(\.rawValue).sorted().joined(separator: ","))"
        }.joined(separator: " | ")
    }

    private var receiptReadback: String {
        guard let ruleID = currentRuleID,
              let receipt = try? AppLimitProductionComposition.currentAppliedReceipt(
                ruleID: ruleID
              )
        else { return "(none)" }
        return "\(timestamp(receipt.appliedAt)) token=\(receipt.orderingToken) arm=\(receipt.armID?.uuidString.lowercased() ?? "none") source=\(receipt.source) revision=\(receipt.storeRevision)"
    }

    private func probeRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
#endif
