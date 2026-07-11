import Foundation

/// B5 — Lean earned-time sample reporter.
///
/// Responsibilities:
///   - Build the idempotent POST body for `{base}/child/earned-time/sample`
///     (A2 backend schema). Body is a `[String: Any]` map for cheap JSON serialization
///     inside the extension's tight memory budget.
///   - POST to backend; on failure enqueue to App Group retry queue (drained
///     on next threshold fire).
///   - Expose pure helpers for tripwire math and shield-apply gate so they are
///     unit-testable without any DeviceActivity / ManagedSettings types.
///
/// Membership: `Evlin iOS` app target AND `EvlinDeviceActivityMonitor` extension target
/// (via membershipExceptions). Keep free of any app-only or extension-only API. NO actor,
/// NO UserDefaults beyond the App Group suite, NO ManagedSettingsStore.
enum EarnedSampleReporter {

    // MARK: - App Group keys

    static let retryQueueKey = "evlin.earnedSampleRetryQueue"
    static let lastSamplePostDebugKey = "evlin.earned.lastSamplePost"

    private struct SampleSnapshot: Decodable {
        let usageDate: String
        let estimatedMinutes: Int
        let counted: Bool?
    }

    enum SuccessDisposition: Equatable {
        case counted
        case paused
        case acceptedWithoutReconciliation
    }

    @discardableResult
    static func processSuccessfulResponse(
        _ data: Data,
        store: EarnedTimeStore = .shared,
        suiteName: String = "group.com.evlin.ios"
    ) -> SuccessDisposition {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = try? decoder.decode(SampleSnapshot.self, from: data) else {
            recordDebug("post success response_decode_failed", suiteName: suiteName)
            return .acceptedWithoutReconciliation
        }
        guard isCanonicalUsageDate(snapshot.usageDate),
              (0...1_440).contains(snapshot.estimatedMinutes)
        else {
            recordDebug(
                "post success response_semantically_invalid date=\(snapshot.usageDate) estimate=\(snapshot.estimatedMinutes)",
                suiteName: suiteName
            )
            return .acceptedWithoutReconciliation
        }
        let reconciliation = store.reconcileAcceptedUsageIfNotStale(
            usageDate: snapshot.usageDate,
            serverEstimatedMinutes: snapshot.estimatedMinutes,
            allowSameDayDecrease: snapshot.counted == false
        )
        if case .stale(let acceptedDate) = reconciliation {
            recordDebug(
                "post success stale_response date=\(snapshot.usageDate) accepted_date=\(acceptedDate)",
                suiteName: suiteName
            )
            return .acceptedWithoutReconciliation
        }

        if snapshot.counted == false {
            recordDebug(
                "backend_counting_paused date=\(snapshot.usageDate) estimate=\(snapshot.estimatedMinutes)",
                suiteName: suiteName
            )
            return .paused
        }
        return .counted
    }

    private static func isCanonicalUsageDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    // MARK: - Sample body builder (pure)

    /// Build the JSON-serializable body for `POST /child/earned-time/sample`.
    ///
    /// `client_sample_id` is deterministic: `"earned:<device_id>:<usage_date>:t<N>"`.
    /// Identical inputs produce the same id → the backend can de-duplicate
    /// on repeated extension fires for the same threshold slot.
    static func makeSampleBody(
        deviceID: UUID,
        usageDate: String,
        timezone: String,
        thresholdMinutes: Int,
        estimatedMinutes: Int,
        observedAt: String
    ) -> [String: Any] {
        let clientSampleID = "earned:\(deviceID.uuidString.lowercased()):\(usageDate):t\(thresholdMinutes)"
        return [
            "device_id":         deviceID.uuidString,
            "usage_date":        usageDate,
            "timezone":          timezone,
            "activity_name":     "evlin.earned.budget",
            "event_name":        "evlin.earned.t\(thresholdMinutes)",
            "threshold_minutes": thresholdMinutes,
            "estimated_minutes": estimatedMinutes,
            "observed_at":       observedAt,
            "client_sample_id":  clientSampleID,
        ]
    }

    /// Build the backend request for POST /child/earned-time/sample.
    /// Backend auth is scoped by `X-Evlin-Child-Device-ID`, and the header must
    /// match body.device_id exactly.
    static func makeSampleRequest(
        baseURL: URL,
        childDeviceID: UUID,
        body: [String: Any]
    ) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("child/earned-time/sample"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(childDeviceID.uuidString, forHTTPHeaderField: "X-Evlin-Child-Device-ID")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Network POST + retry enqueue

    /// POST the sample to `{base}/child/earned-time/sample`.
    /// On any network failure or non-2xx/409 response, enqueues the entry to the
    /// App Group retry queue (key `evlin.earnedSampleRetryQueue`) so the next
    /// threshold fire can drain it.
    static func report(
        baseURL: URL,
        deviceID: UUID,
        usageDate: String,
        timezone: String,
        thresholdMinutes: Int,
        estimatedMinutes: Int,
        suiteName: String = "group.com.evlin.ios"
    ) async {
        let observedAt = ISO8601DateFormatter().string(from: Date())
        let body = makeSampleBody(
            deviceID: deviceID,
            usageDate: usageDate,
            timezone: timezone,
            thresholdMinutes: thresholdMinutes,
            estimatedMinutes: estimatedMinutes,
            observedAt: observedAt
        )

        guard let req = try? makeSampleRequest(
            baseURL: baseURL,
            childDeviceID: deviceID,
            body: body
        ) else {
            enqueueRetry(RetryEntry(
                deviceID: deviceID,
                usageDate: usageDate,
                timezone: timezone,
                thresholdMinutes: thresholdMinutes,
                estimatedMinutes: estimatedMinutes,
                observedAt: observedAt
            ), suiteName: suiteName)
            recordDebug("enqueue request_build_failed t\(thresholdMinutes)", suiteName: suiteName)
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // 2xx or 409 (already exists — idempotent) are both successes.
            let success = (status >= 200 && status < 300) || status == 409
            recordDebug("post t\(thresholdMinutes) status=\(status) success=\(success)", suiteName: suiteName)
            if success {
                processSuccessfulResponse(
                    data,
                    store: EarnedTimeStore(suiteName: suiteName),
                    suiteName: suiteName
                )
            } else {
                enqueueRetry(RetryEntry(
                    deviceID: deviceID,
                    usageDate: usageDate,
                    timezone: timezone,
                    thresholdMinutes: thresholdMinutes,
                    estimatedMinutes: estimatedMinutes,
                    observedAt: observedAt
                ), suiteName: suiteName)
            }
        } catch {
            recordDebug("enqueue network_error t\(thresholdMinutes) error=\(error.localizedDescription)", suiteName: suiteName)
            enqueueRetry(RetryEntry(
                deviceID: deviceID,
                usageDate: usageDate,
                timezone: timezone,
                thresholdMinutes: thresholdMinutes,
                estimatedMinutes: estimatedMinutes,
                observedAt: observedAt
            ), suiteName: suiteName)
        }
    }

    /// Drain the retry queue: attempt to POST each pending entry.
    /// Clears the queue first, then re-enqueues failures. This prevents
    /// an infinite-grow loop if the queue is partially drained.
    static func drainRetryQueue(
        baseURL: URL,
        suiteName: String = "group.com.evlin.ios"
    ) async {
        let queue = loadRetryQueue(suiteName: suiteName)
        guard !queue.isEmpty else { return }
        clearRetryQueue(suiteName: suiteName)

        for entry in queue {
            let body = makeSampleBody(
                deviceID: entry.deviceID,
                usageDate: entry.usageDate,
                timezone: entry.timezone,
                thresholdMinutes: entry.thresholdMinutes,
                estimatedMinutes: entry.estimatedMinutes,
                observedAt: entry.observedAt
            )
            guard let req = try? makeSampleRequest(
                baseURL: baseURL,
                childDeviceID: entry.deviceID,
                body: body
            ) else {
                enqueueRetry(entry, suiteName: suiteName)
                continue
            }

            let success: Bool
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                success = (status >= 200 && status < 300) || status == 409
                if success {
                    processSuccessfulResponse(
                        data,
                        store: EarnedTimeStore(suiteName: suiteName),
                        suiteName: suiteName
                    )
                }
            } catch {
                success = false
            }

            if !success {
                enqueueRetry(entry, suiteName: suiteName)
            }
        }
    }

    // MARK: - Retry queue (App Group)

    struct RetryEntry: Codable, Sendable {
        let deviceID: UUID
        let usageDate: String
        let timezone: String
        let thresholdMinutes: Int
        let estimatedMinutes: Int
        let observedAt: String
    }

    static func enqueueRetry(_ entry: RetryEntry, suiteName: String = "group.com.evlin.ios") {
        var queue = loadRetryQueue(suiteName: suiteName)
        queue.append(entry)
        saveRetryQueue(queue, suiteName: suiteName)
    }

    static func loadRetryQueue(suiteName: String = "group.com.evlin.ios") -> [RetryEntry] {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: retryQueueKey),
              let queue = try? JSONDecoder().decode([RetryEntry].self, from: data)
        else { return [] }
        return queue
    }

    static func clearRetryQueue(suiteName: String = "group.com.evlin.ios") {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: retryQueueKey)
    }

    static func retryQueueDebugSummary(suiteName: String = "group.com.evlin.ios") -> String {
        let queue = loadRetryQueue(suiteName: suiteName)
        guard let newest = queue.last else { return "0 pending" }
        return "\(queue.count) pending; newest t\(newest.thresholdMinutes) observed \(newest.observedAt)"
    }

    private static func saveRetryQueue(_ queue: [RetryEntry], suiteName: String) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: retryQueueKey)
    }

    private static func recordDebug(_ message: String, suiteName: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        UserDefaults(suiteName: suiteName)?.set("\(ts) \(message)", forKey: lastSamplePostDebugKey)
    }

    // MARK: - Tripwire math (pure)

    /// Compute the effective cap threshold for earned-time enforcement.
    ///
    /// Formula: `(latestEstimate + backendRemaining)` rounded up to the next
    /// multiple of `bucketMinutes`, then capped at `min(poolMinutes, capMinutes)`.
    ///
    /// - `latestEstimate`: the extension's most recent on-device usage estimate (minutes).
    /// - `backendRemaining`: minutes remaining as of last backend sync.
    /// - `poolMinutes`: the total earned pool for today (from backend).
    /// - `capMinutes`: the hard parent-set cap (from backend).
    /// - `bucketMinutes`: ladder bucket granularity (matches `EarnedBudgetScheduler.earnedBucketMinutes`).
    ///
    /// Returns `min(poolMinutes, capMinutes)` as a ceiling when the sum exceeds it.
    static func effectiveCapThreshold(
        latestEstimate: Int,
        backendRemaining: Int,
        poolMinutes: Int,
        capMinutes: Int,
        bucketMinutes: Int = 5
    ) -> Int {
        let ceiling = min(poolMinutes, capMinutes)
        guard ceiling > 0 else { return ceiling }
        let raw = latestEstimate + backendRemaining
        guard raw > 0 else { return ceiling }

        // Round up to next multiple of bucketMinutes.
        let rounded: Int
        if bucketMinutes > 0 {
            rounded = Int(ceil(Double(raw) / Double(bucketMinutes))) * bucketMinutes
        } else {
            rounded = raw
        }

        return min(rounded, ceiling)
    }

    // MARK: - Shield-apply gate (pure)

    /// Returns `true` when the `.earnedTime` shield should be applied.
    ///
    /// Conditions (ALL must hold):
    ///   - `thresholdN >= effectiveCap` (usage has hit or exceeded the tripwire)
    ///   - Override flag for `usageDate` is absent in `store`
    static func shouldApplyEarnedShield(
        thresholdN: Int,
        effectiveCap: Int,
        usageDate: String,
        store: EarnedTimeStore
    ) -> Bool {
        guard !store.isOverridden(forUsageDate: usageDate) else { return false }
        return thresholdN >= effectiveCap
    }

    // MARK: - Fresh-at-fire-time gate (Fix 4)

    /// Fresh-at-fire-time earned-shield gate. The tripwire is the parent-set
    /// budget `min(poolMinutes, capMinutes)` read fresh — NOT a function of the
    /// device's own estimate (which made the gate a tautology). Applies the
    /// shield iff usage has reached the budget and no override is set.
    static func shouldApplyEarnedShieldFresh(
        adjustedN: Int,
        poolMinutes: Int,
        capMinutes: Int,
        usageDate: String,
        store: EarnedTimeStore
    ) -> Bool {
        guard !store.isOverridden(forUsageDate: usageDate) else { return false }
        let budget = min(poolMinutes, capMinutes)
        guard budget > 0 else { return false }   // no budget known → do not self-lock
        return adjustedN >= budget
    }

    /// Defense-in-depth: refuse a LOCAL self-lock when the last synced backend
    /// remaining says there is comfortable headroom AND that sync is fresh.
    /// (Prevents the extension locking while the backend same-second reports
    /// `available rem=40`.) A stale or absent sync does NOT suppress — offline
    /// enforcement must still work.
    static func backendVetoesSelfLock(
        lastBackendRemaining: Int?,
        lastBackendSyncAt: Date?,
        now: Date,
        marginMinutes: Int = 5,
        freshnessSeconds: TimeInterval = 600
    ) -> Bool {
        guard let rem = lastBackendRemaining, let at = lastBackendSyncAt else { return false }
        guard now.timeIntervalSince(at) < freshnessSeconds else { return false }
        return rem > marginMinutes
    }
}
