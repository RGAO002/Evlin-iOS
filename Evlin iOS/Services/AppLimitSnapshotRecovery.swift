import CryptoKit
import Foundation

/// Hydrates the local app-limit store from GET /child/app-limits/snapshot.
///
/// The re-login recovery leg (2026-08-11): `set_limit` commands are delivered
/// exactly once, so a device whose identity teardown wiped the local rule
/// store could never hear about its rules again — per-app metering silently
/// died while the pool, which re-delivers daily, kept counting.
///
/// The snapshot's `set` payloads are byte-identical to wire commands (one
/// canonical builder on the backend), so hydration re-uses the entire command
/// pipeline: decode into the same `PollCommandDTO`, build the same envelope,
/// and let `AppLimitCommandCoordinator.ingest` arbitrate against whatever the
/// store already holds — newer local state wins exactly as it would against a
/// replayed command.
///
/// Invariants (backend contract, pinned by tests on both sides):
/// - `set` → ensure the rule is present and armed;
/// - `clear` → ensure it is cleared (a lost clear_limit heals here);
/// - `unknown` → touch NOTHING for that rule;
/// - a rule id absent from the snapshot entirely → UNKNOWN, never "delete";
/// - only a successful, scoped, EMPTY snapshot means "this device has no
///   rules". A failed fetch means nothing at all.
nonisolated enum AppLimitSnapshotRecovery {

    enum Outcome: Equatable {
        case hydrated(ingested: Int, tombstones: Int, unknown: Int)
        case emptyNoRules
        case fetchFailed
        case malformed
    }

    /// Synthetic command ids must be DETERMINISTIC: retrying the same snapshot
    /// entry has to dedupe against the pending work it created last time
    /// (`duplicatePending` / `duplicateApplied`), not stack a second copy.
    static func syntheticCommandID(
        ruleID: UUID, orderingToken: Int64, kind: String
    ) -> UUID {
        let seed = "evlin.appLimitSnapshot:\(ruleID.uuidString):\(orderingToken):\(kind)"
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5-style marker
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC variant
        return NSUUID(uuidBytes: bytes) as UUID
    }

    @discardableResult
    static func run(
        apiClient: APIClient,
        deviceID: UUID,
        coordinator: AppLimitCommandCoordinator = AppLimitCommandCoordinator()
    ) async -> Outcome {
        await run(
            fetch: { try await apiClient.fetchAppLimitSnapshot(deviceID: deviceID) },
            deviceID: deviceID,
            coordinator: coordinator
        )
    }

    /// Seams for tests: everything below the network is pure data flow, and
    /// `makeEnvelope` exists because a real `ApplicationToken` cannot be
    /// fabricated outside a Screen-Time-authorized process — the same reason
    /// every other app-limit test hand-builds its envelopes.
    @discardableResult
    static func run(
        fetch: () async throws -> (AppLimitSnapshotDTO, Data),
        deviceID: UUID,
        coordinator: AppLimitCommandCoordinator,
        makeEnvelope: (LockCommand) throws -> AppLimitCommandEnvelope = {
            try AppLimitProductionComposition.envelope(
                from: $0,
                source: .wakeRecovery,
                confirmationMode: .localSnapshot
            )
        }
    ) async -> Outcome {
        let snapshot: AppLimitSnapshotDTO
        let raw: Data
        do {
            (snapshot, raw) = try await fetch()
        } catch {
            // A failed GET is NOT "no rules". Leave every slot alone.
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyAppLimitSnapshot,
                "fetch_failed \(String(describing: error).prefix(120))"
            )
            return .fetchFailed
        }
        guard snapshot.child_device_id == deviceID else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyAppLimitSnapshot,
                "scope_mismatch got=\(snapshot.child_device_id.uuidString)"
            )
            return .malformed
        }
        if snapshot.items.isEmpty {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyAppLimitSnapshot,
                "empty_no_rules digest=\(snapshot.rules_digest.prefix(12))"
            )
            return .emptyNoRules
        }

        // Raw JSON, not the typed DTO: each `set` item's payload is re-serialized
        // with a synthetic command_id injected so the standard PollCommandDTO
        // decoder — and everything after it — runs unchanged.
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let rawItems = root["items"] as? [[String: Any]]
        else { return .malformed }

        var ingested = 0
        var tombstones = 0
        var unknown = 0
        for item in rawItems {
            guard let kind = item["kind"] as? String,
                  let ruleIDString = item["rule_id"] as? String,
                  let ruleID = UUID(uuidString: ruleIDString),
                  let orderingToken = (item["ordering_token"] as? NSNumber)?.int64Value
            else { continue }

            let commandJSON: [String: Any]
            switch kind {
            case "set":
                guard var payload = item["payload"] as? [String: Any] else {
                    unknown += 1
                    continue
                }
                payload["command_id"] = syntheticCommandID(
                    ruleID: ruleID, orderingToken: orderingToken, kind: kind
                ).uuidString
                commandJSON = payload
            case "clear":
                guard let clear = item["clear"] as? [String: Any] else {
                    unknown += 1
                    continue
                }
                commandJSON = [
                    "command_id": syntheticCommandID(
                        ruleID: ruleID, orderingToken: orderingToken, kind: kind
                    ).uuidString,
                    "action": "clear_limit",
                    "tier": "exactApp",
                    "target": ["target_display": "App"],
                    "issued_at": item["updated_at"] as? String
                        ?? ISO8601DateFormatter().string(from: Date()),
                    "clear": clear,
                ]
            default:
                // "unknown" (token unavailable) or a kind this build does not
                // recognise: the rule's local state, whatever it is, stands.
                unknown += 1
                continue
            }

            do {
                let data = try JSONSerialization.data(withJSONObject: commandJSON)
                let dto = try JSONDecoder().decode(PollCommandDTO.self, from: data)
                let command = CommandPoller.lockCommand(from: dto)
                let envelope = try makeEnvelope(command)
                _ = try coordinator.ingest(envelope)
                if kind == "clear" { tombstones += 1 } else { ingested += 1 }
            } catch {
                // One sick entry must not sink the rest of the snapshot.
                CommandDeliveryDiagnostics.record(
                    CommandDeliveryDiagnostics.keyAppLimitSnapshot,
                    "item_failed rule=\(ruleID.uuidString.prefix(8)) \(String(describing: error).prefix(80))"
                )
                unknown += 1
            }
        }

        CommandDeliveryDiagnostics.record(
            CommandDeliveryDiagnostics.keyAppLimitSnapshot,
            "hydrated set=\(ingested) clear=\(tombstones) unknown=\(unknown) digest=\(snapshot.rules_digest.prefix(12))"
        )
        return .hydrated(ingested: ingested, tombstones: tombstones, unknown: unknown)
    }
}
