import CryptoKit
import Foundation

/// A1 — batch-uploads the App-Group `ScreenTimeEvent` ring buffer to the
/// backend unified timeline (`POST /device/screen-time/events`), so the
/// cross-device P/K/backend chain is queryable server-side with SQL.
///
/// Design:
///   - Watermark = bare SHA-256 hex of the last successfully uploaded
///     ring-buffer line (`evlin.screentime.uploadedThroughHash`, App-Group
///     defaults) — device-independent, computed before attribution. Lines
///     after it are pending. If the watermark line rotated out of the capped
///     buffer, the whole buffer is re-sent — the backend dedupes on
///     client_event_id, so that is safe.
///   - client_event_id = "line:<deviceID>:<lineHash>" — embeds the uploading
///     device so byte-identical lines from two devices never dedupe each
///     other (review decision 2026-07-01).
///   - Events are attributed by emitter: parent_app → parent device id,
///     kid_app/kid_extension → child device id (a dev phone can hold both
///     identities; each group is its own POST). If NO identity is resolvable,
///     the watermark does NOT advance — identity-missing periods are exactly
///     what we need to diagnose, so those lines wait for identity to appear.
///   - Fire-and-forget: on any failure the watermark stays put and the next
///     foreground retries. Never throws, never blocks UI.
///   - DEBUG builds only: the body is compiled out for Release/TestFlight
///     (device-header self-attestation is debug-only trust).
///
/// Membership: `Evlin iOS` app target ONLY (the extension just writes the
/// ring buffer; uploading from the extension's tight budget is forbidden).
enum ScreenTimeEventUploader {

    static let watermarkKey = "evlin.screentime.uploadedThroughHash"
    static let disableKey = "evlin.screentime.uploadDisabled"
    static let batchLimit = 200

    // MARK: - Pure helpers (unit-tested)

    /// Bare SHA-256 hex of a ring-buffer line (watermark currency).
    static func lineHash(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Server dedupe id: embeds the uploading device so identical lines from
    /// different devices stay distinct rows. "line:" + 36 + ":" + 64 = 106 ≤ 128.
    static func clientEventID(deviceID: String, line: String) -> String {
        "line:\(deviceID):\(lineHash(line))"
    }

    /// Lines strictly after the watermark line; the whole buffer when the
    /// watermark is missing or rotated out (server-side dedupe makes that safe).
    static func pendingLines(all: [String], lastUploadedHash: String?) -> [String] {
        guard let h = lastUploadedHash, !h.isEmpty,
              let idx = all.lastIndex(where: { lineHash($0) == h })
        else { return all }
        return Array(all[(idx + 1)...])
    }

    /// The device id an event is attributed to (nil = unattributable, skip).
    static func deviceID(
        for emitter: ScreenTimeEvent.Emitter,
        parentID: String?,
        childID: String?
    ) -> String? {
        switch emitter {
        case .parentApp: return parentID
        case .kidApp, .kidExtension: return childID
        case .backend: return nil
        }
    }

    /// Decode + group pending lines into per-device upload payloads
    /// (backend `ScreenTimeEventIn` shape, snake_case keys). Undecodable or
    /// unattributable lines are skipped.
    static func groupedPayloads(
        lines: [String],
        parentID: String?,
        childID: String?
    ) -> [String: [[String: Any]]] {
        var groups: [String: [[String: Any]]] = [:]
        for l in lines {
            guard let e = ScreenTimeEvent.from(jsonLine: l),
                  let dev = deviceID(for: e.emitter, parentID: parentID, childID: childID)
            else { continue }
            var payload: [String: Any] = [
                "ts": e.ts,
                "emitter": e.emitter.rawValue,
                "kind": e.kind.rawValue,
                "client_event_id": clientEventID(deviceID: dev, line: l),
            ]
            payload["day_key"] = e.dayKey
            payload["source"] = e.source?.rawValue
            payload["app"] = e.app
            payload["reason"] = e.reason
            payload["policy_gen"] = e.policyGen
            payload["corr_id"] = e.corrID
            if let nums = e.nums,
               let data = try? JSONEncoder().encode(nums),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payload["nums"] = dict
            }
            if let tr = e.transition,
               let data = try? JSONEncoder().encode(tr),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payload["transition"] = dict
            }
            groups[dev, default: []].append(payload)
        }
        return groups
    }

    static func makeRequest(
        baseURL: URL,
        deviceID: String,
        events: [[String: Any]]
    ) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("device/screen-time/events"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceID, forHTTPHeaderField: "X-Evlin-Device-ID")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceID,
            "events": events,
        ])
        return req
    }

    // MARK: - Entry point (app foreground)

    /// Upload everything past the watermark. Safe to call often; no-ops fast.
    /// DEBUG builds only — Release compiles to a no-op (prod gate, review
    /// decision 2026-07-01; the backend endpoint is also off by default).
    static func uploadPending() async {
        #if DEBUG
        let std = UserDefaults.standard
        guard !std.bool(forKey: disableKey) else { return }
        guard let d = UserDefaults(suiteName: ScreenTimeEventLog.suiteName) else { return }

        let all = ScreenTimeEventLog.readLines(from: d)
        let pending = pendingLines(all: all, lastUploadedHash: d.string(forKey: watermarkKey))
        guard !pending.isEmpty else { return }
        guard let base = URL(string: APIClient.currentBaseURL) else { return }

        let groups = groupedPayloads(
            lines: pending,
            parentID: std.string(forKey: DeviceIdentity.parentKey),
            childID: std.string(forKey: DeviceIdentity.childKey)
        )
        guard !groups.isEmpty else {
            // No resolvable device identity: do NOT advance the watermark.
            // Identity-missing stretches are exactly what we need to diagnose —
            // the lines stay pending and upload once identity is restored.
            // (Ring-buffer cap + server dedupe keep the rescan cheap and safe.)
            return
        }

        var allOK = true
        for (dev, events) in groups {
            var start = 0
            while start < events.count {
                let chunk = Array(events[start..<min(start + batchLimit, events.count)])
                start += batchLimit
                guard let req = try? makeRequest(baseURL: base, deviceID: dev, events: chunk) else {
                    allOK = false
                    continue
                }
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200...299).contains(code) { allOK = false }
                } catch {
                    allOK = false
                }
            }
        }
        // Advance ONLY when every POST of the pending window succeeded.
        if allOK, let last = pending.last {
            d.set(lineHash(last), forKey: watermarkKey)
        }
        #endif
    }
}
