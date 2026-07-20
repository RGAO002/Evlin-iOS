import CryptoKit
import FamilyControls
import Foundation
import ManagedSettings

nonisolated struct AppLimitNSEAck: Equatable, Sendable {
    let status: String
    let disposition: String
    let reason: String?
    let orderingToken: Int64
    let latestOrderingToken: Int64?
    let receiptRevision: UInt64?
    let receiptSource: String?
    let armID: UUID?

    var detail: [String: Any] {
        var value: [String: Any] = [
            "ordering_token": orderingToken,
            "disposition": disposition,
        ]
        if let reason { value["reason"] = reason }
        if let latestOrderingToken { value["latest_ordering_token"] = latestOrderingToken }
        if let receiptRevision { value["receipt_revision"] = receiptRevision }
        if let receiptSource { value["receipt_source"] = receiptSource }
        if let armID { value["arm_id"] = armID.uuidString }
        return value
    }
}

nonisolated struct AppLimitNSEPersistenceOutcome: Sendable {
    let envelope: AppLimitCommandEnvelope
    let ack: AppLimitNSEAck
    let requestOwnerWake: Bool
    let alertBody: String
}

nonisolated struct AppLimitNSEDeliveryResult: Sendable {
    let outcome: AppLimitNSEPersistenceOutcome
    let ackSucceeded: Bool

    var ack: AppLimitNSEAck { outcome.ack }
    var alertBody: String { outcome.alertBody }
}

nonisolated enum AppLimitProductionComposition {
    private struct CanonicalPayload: Encodable {
        let kind: AppLimitCommandKind
        let ruleID: UUID
        let orderingToken: Int64
        let rule: AppLimitRule?
        let clearReason: String?
        let clearUpdatedAt: Date?
    }

    enum CompositionError: Error {
        case malformed
        case applicationNotConfigured
    }

    /// Returns only a receipt that was durably reread from the current slot and
    /// still names the current command version and arm.
    static func currentAppliedReceipt(
        ruleID: UUID,
        store: AppLimitEpochStore = .shared
    ) throws -> AppLimitApplyReceipt? {
        let state = try store.read()
        guard let slot = state.slots[ruleID],
              let receipt = slot.appliedReceipt,
              receipt.ruleID == ruleID,
              receipt.orderingToken == slot.latestOrderingToken,
              receipt.commandKind == slot.latestKind,
              !receipt.source.isEmpty
        else { return nil }
        switch slot.latestKind {
        case .set:
            guard slot.activeRule?.id == ruleID,
                  let armID = slot.armProvenance?.armID,
                  slot.armProvenance?.ruleRevision == slot.latestOrderingToken,
                  receipt.armID == armID
            else { return nil }
        case .clear:
            guard slot.activeRule == nil,
                  slot.clearTombstone?.orderingToken == slot.latestOrderingToken,
                  receipt.armID == nil
            else { return nil }
        }
        return receipt
    }

    static func envelope(
        from command: LockCommand,
        source: AppLimitCommandSource
    ) throws -> AppLimitCommandEnvelope {
        let kind: AppLimitCommandKind
        let ruleID: UUID
        let orderingToken: Int64
        let rule: AppLimitRule?
        let clearReason: String?
        let clearUpdatedAt: Date?

        switch command.action {
        case .setLimit:
            guard let limit = command.limit else { throw CompositionError.malformed }
            guard let token = decodedApplicationToken(
                command.target.catalogTokenDataBase64
            ) else { throw CompositionError.applicationNotConfigured }
            kind = .set
            ruleID = limit.ruleId
            orderingToken = limit.orderingToken
            rule = AppLimitRule(
                id: limit.ruleId,
                appTokens: [token],
                bundleID: command.target.bundleID ?? "",
                displayName: command.target.targetDisplay ?? command.target.bundleID ?? "App",
                budgetMinutes: limit.dailyBudgetMinutes,
                window: AppLimitWindow(
                    startMinute: limit.startMinute,
                    endMinute: limit.endMinute,
                    repeats: limit.resetPolicy.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == "daily",
                    timezone: limit.timezone
                ),
                effectiveFrom: limit.effectiveFrom,
                expiresAt: limit.expiresAt
            )
            clearReason = nil
            clearUpdatedAt = nil
        case .clearLimit:
            guard let clear = command.clear else { throw CompositionError.malformed }
            kind = .clear
            ruleID = clear.ruleId
            orderingToken = clear.orderingToken
            rule = nil
            clearReason = clear.reason
            clearUpdatedAt = clear.updatedAt
        default:
            throw CompositionError.malformed
        }

        let payload = CanonicalPayload(
            kind: kind,
            ruleID: ruleID,
            orderingToken: orderingToken,
            rule: rule,
            clearReason: clearReason,
            clearUpdatedAt: clearUpdatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(payload))
            .map { String(format: "%02x", $0) }
            .joined()
        return AppLimitCommandEnvelope(
            commandID: command.id,
            ruleID: ruleID,
            orderingToken: orderingToken,
            kind: kind,
            payloadDigest: digest,
            receivedAt: command.issuedAt,
            source: source,
            rule: rule
        )
    }

    static func persistNSE(
        envelope: AppLimitCommandEnvelope,
        coordinator: AppLimitCommandCoordinator,
        now: Date
    ) throws -> AppLimitNSEPersistenceOutcome {
        if envelope.kind == .set,
           let expiresAt = envelope.rule?.expiresAt,
           expiresAt <= now {
            return AppLimitNSEPersistenceOutcome(
                envelope: envelope,
                ack: AppLimitNSEAck(
                    status: "confirmed",
                    disposition: "expired",
                    reason: "expired_command",
                    orderingToken: envelope.orderingToken,
                    latestOrderingToken: nil,
                    receiptRevision: nil,
                    receiptSource: nil,
                    armID: nil
                ),
                requestOwnerWake: false,
                alertBody: "Updating limit"
            )
        }

        let disposition = try coordinator.ingest(envelope)
        let ack: AppLimitNSEAck
        let requestOwnerWake: Bool
        switch disposition {
        case .acceptedNeedsOwner:
            ack = pendingAck(envelope: envelope, disposition: "accepted_needs_owner")
            requestOwnerWake = true
        case .duplicatePending:
            ack = pendingAck(envelope: envelope, disposition: "duplicate_pending")
            requestOwnerWake = true
        case .duplicateApplied(let receipt):
            ack = AppLimitNSEAck(
                status: "confirmed",
                disposition: "duplicate_applied",
                reason: nil,
                orderingToken: envelope.orderingToken,
                latestOrderingToken: nil,
                receiptRevision: receipt.storeRevision,
                receiptSource: receipt.source,
                armID: receipt.armID
            )
            requestOwnerWake = false
        case .superseded(let latestOrderingToken):
            ack = AppLimitNSEAck(
                status: "confirmed",
                disposition: "superseded",
                reason: "superseded_by_token",
                orderingToken: envelope.orderingToken,
                latestOrderingToken: latestOrderingToken,
                receiptRevision: nil,
                receiptSource: nil,
                armID: nil
            )
            requestOwnerWake = false
        case .equalTokenConflict:
            ack = AppLimitNSEAck(
                status: "failed",
                disposition: "equal_token_conflict",
                reason: "equal_token_conflict",
                orderingToken: envelope.orderingToken,
                latestOrderingToken: nil,
                receiptRevision: nil,
                receiptSource: nil,
                armID: nil
            )
            requestOwnerWake = false
        }
        return AppLimitNSEPersistenceOutcome(
            envelope: envelope,
            ack: ack,
            requestOwnerWake: requestOwnerWake,
            alertBody: "Updating limit"
        )
    }

    static func deliverNSE(
        envelope: AppLimitCommandEnvelope?,
        coordinator: AppLimitCommandCoordinator,
        now: Date,
        postAck: (AppLimitNSEAck) async throws -> Void,
        requestOwnerWake: () -> Void
    ) async -> AppLimitNSEDeliveryResult? {
        guard let envelope else { return nil }
        let outcome: AppLimitNSEPersistenceOutcome
        do {
            outcome = try persistNSE(
                envelope: envelope,
                coordinator: coordinator,
                now: now
            )
        } catch {
            outcome = AppLimitNSEPersistenceOutcome(
                envelope: envelope,
                ack: AppLimitNSEAck(
                    status: "failed",
                    disposition: "persistence_error",
                    reason: "app_limit_epoch_error",
                    orderingToken: envelope.orderingToken,
                    latestOrderingToken: nil,
                    receiptRevision: nil,
                    receiptSource: nil,
                    armID: nil
                ),
                requestOwnerWake: false,
                alertBody: "Updating limit"
            )
        }

        let ackSucceeded: Bool
        do {
            try await postAck(outcome.ack)
            ackSucceeded = true
        } catch {
            ackSucceeded = false
        }
        if outcome.requestOwnerWake { requestOwnerWake() }
        return AppLimitNSEDeliveryResult(
            outcome: outcome,
            ackSucceeded: ackSucceeded
        )
    }

    private static func pendingAck(
        envelope: AppLimitCommandEnvelope,
        disposition: String
    ) -> AppLimitNSEAck {
        AppLimitNSEAck(
            status: "pending",
            disposition: disposition,
            reason: "persisted_waiting_for_owner",
            orderingToken: envelope.orderingToken,
            latestOrderingToken: nil,
            receiptRevision: nil,
            receiptSource: nil,
            armID: nil
        )
    }

    private static func decodedApplicationToken(_ base64: String?) -> ApplicationToken? {
        guard let raw = base64?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = Data(base64Encoded: raw)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let token = try? decoder.decode(ApplicationToken.self, from: data) {
            return token
        }
        return try? PropertyListDecoder().decode(ApplicationToken.self, from: data)
    }
}
