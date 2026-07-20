#if DEBUG
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
    case tokenEncodingFailed
    case commandRejected(String)
    case receiptMissing

    var errorDescription: String? {
        switch self {
        case .exactlyOneAppRequired: "Select exactly one app."
        case .missingOwner: "No current child-device owner is configured."
        case .tokenEncodingFailed: "The selected app token could not be encoded."
        case .commandRejected(let reason): "Probe command rejected: \(reason)"
        case .receiptMissing: "The arm completed without a durable applied receipt."
        }
    }
}

struct AppLimitOneMinuteProbeView: View {
    private static let ruleIDKey = "evlin.debug.appLimitProbe.ruleID"
    private static let startedAtKey = "evlin.debug.appLimitProbe.startedAt"

    @State private var selection = FamilyActivitySelection(includeEntireCategory: false)
    @State private var pickerShown = false
    @State private var running = false
    @State private var status = "Select one unused app."
    @State private var refreshTick = 0

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: MeteringProductionComposition.appGroupSuiteName)
    }

    private var currentRuleID: UUID? {
        defaults?.string(forKey: Self.ruleIDKey).flatMap(UUID.init(uuidString:))
    }

    var body: some View {
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
