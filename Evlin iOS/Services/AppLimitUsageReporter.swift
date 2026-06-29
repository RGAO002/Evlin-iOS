import Foundation

/// Posts per-app limit USAGE samples to `POST {base}/child/app-limit/usage-sample`
/// for the usage bar. Mirrors `EarnedSampleReporter`: idempotent client_sample_id,
/// `X-Evlin-Child-Device-ID` header (== body.child_device_id), and an App Group
/// retry queue so a transient failure isn't lost. Reports usage ONLY — it never
/// shields (enforcement is the separate limit command/event).
enum AppLimitUsageReporter {

    private static let retryKey = "evlin.appLimitUsageRetryQueue"

    // MARK: - Body

    /// `client_sample_id` is deterministic & lowercase: `applimit:<rule>:<date>:t<N>`
    /// (or `:budget` via `clientSampleID`). Lowercase rule_id avoids the savedList
    /// UUID-case duplicate-identity class.
    static func makeBody(
        deviceID: UUID,
        ruleID: UUID,
        usageDate: String,
        timezone: String,
        thresholdMinutes: Int,
        estimatedMinutes: Int,
        observedAt: String,
        clientSampleID: String? = nil
    ) -> [String: Any] {
        let ruleLower = ruleID.uuidString.lowercased()
        let csid = clientSampleID
            ?? "applimit:\(ruleLower):\(usageDate):t\(thresholdMinutes)"
        return [
            "child_device_id":   deviceID.uuidString,
            "rule_id":           ruleLower,
            "usage_date":        usageDate,
            "timezone":          timezone,
            "threshold_minutes": thresholdMinutes,
            "estimated_minutes": estimatedMinutes,
            "observed_at":       observedAt,
            "client_sample_id":  csid,
        ]
    }

    // MARK: - Network POST + retry enqueue

    static func report(
        baseURL: URL,
        deviceID: UUID,
        ruleID: UUID,
        usageDate: String,
        timezone: String,
        thresholdMinutes: Int,
        estimatedMinutes: Int,
        clientSampleID: String? = nil,
        suiteName: String = "group.com.evlin.ios"
    ) async {
        let observedAt = ISO8601DateFormatter().string(from: Date())
        let body = makeBody(
            deviceID: deviceID, ruleID: ruleID, usageDate: usageDate,
            timezone: timezone, thresholdMinutes: thresholdMinutes,
            estimatedMinutes: estimatedMinutes, observedAt: observedAt,
            clientSampleID: clientSampleID
        )

        var req = URLRequest(url: baseURL.appendingPathComponent("child/app-limit/usage-sample"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Evlin-Child-Device-ID")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let entry = RetryEntry(
            deviceID: deviceID, ruleID: ruleID, usageDate: usageDate, timezone: timezone,
            thresholdMinutes: thresholdMinutes, estimatedMinutes: estimatedMinutes,
            clientSampleID: body["client_sample_id"] as? String, observedAt: observedAt
        )
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let success = (status >= 200 && status < 300) || status == 409
            if !success { enqueueRetry(entry, suiteName: suiteName) }
        } catch {
            enqueueRetry(entry, suiteName: suiteName)
        }
    }

    /// Drain the retry queue: re-POST each pending entry; re-enqueue failures.
    static func drainRetryQueue(baseURL: URL, suiteName: String = "group.com.evlin.ios") async {
        let queue = loadQueue(suiteName: suiteName)
        guard !queue.isEmpty else { return }
        clearQueue(suiteName: suiteName)
        for entry in queue {
            var req = URLRequest(url: baseURL.appendingPathComponent("child/app-limit/usage-sample"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(entry.deviceID.uuidString, forHTTPHeaderField: "X-Evlin-Child-Device-ID")
            let body = makeBody(
                deviceID: entry.deviceID, ruleID: entry.ruleID, usageDate: entry.usageDate,
                timezone: entry.timezone, thresholdMinutes: entry.thresholdMinutes,
                estimatedMinutes: entry.estimatedMinutes, observedAt: entry.observedAt,
                clientSampleID: entry.clientSampleID
            )
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let success: Bool
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                success = (status >= 200 && status < 300) || status == 409
            } catch {
                success = false
            }
            if !success { enqueueRetry(entry, suiteName: suiteName) }
        }
    }

    // MARK: - Retry queue (App Group)

    struct RetryEntry: Codable {
        let deviceID: UUID
        let ruleID: UUID
        let usageDate: String
        let timezone: String
        let thresholdMinutes: Int
        let estimatedMinutes: Int
        let clientSampleID: String?
        let observedAt: String
    }

    private static func enqueueRetry(_ entry: RetryEntry, suiteName: String) {
        var queue = loadQueue(suiteName: suiteName)
        queue.append(entry)
        // Bound the queue so a long offline stretch can't grow it unbounded.
        if queue.count > 200 { queue = Array(queue.suffix(200)) }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: retryKey)
    }

    private static func loadQueue(suiteName: String) -> [RetryEntry] {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: retryKey),
              let queue = try? JSONDecoder().decode([RetryEntry].self, from: data)
        else { return [] }
        return queue
    }

    private static func clearQueue(suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: retryKey)
    }
}
