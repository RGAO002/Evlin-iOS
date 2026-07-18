import Foundation

/// Shared production seam that owns R-15 before the extension can enter any
/// accepted-threshold side effects.
nonisolated enum EarnedThresholdProductionCoordinator {
    enum Outcome: Equatable, Sendable {
        case accepted
        case rejected
    }

    @discardableResult
    static func process(
        generation: EarnedActivityGeneration.Generation,
        eventName: String,
        rawThresholdMinutes: Int,
        adjustedEstimateMinutes: Int,
        callbackAt: Date,
        currentUsageDate: String,
        recordDiagnostic: (String) -> Void,
        runAcceptedProductionPath: () -> Void
    ) -> Outcome {
        let plausibility = EarnedThresholdPlausibility.evaluate(
            generation: generation,
            adjustedEstimateMinutes: adjustedEstimateMinutes,
            callbackAt: callbackAt,
            currentUsageDate: currentUsageDate
        )
        guard plausibility.isPlausible else {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let timestamp = formatter.string(from: callbackAt)
            let armedAt = generation.armedAt.map(formatter.string(from:)) ?? "(missing)"
            let maximum = plausibility.maximumTrusted.map(String.init) ?? "(missing)"
            recordDiagnostic(
                "\(timestamp) event=\(eventName) activity=\(generation.activityName) "
                    + "raw=\(rawThresholdMinutes) adjusted=\(adjustedEstimateMinutes) "
                    + "offset=\(generation.offsetMinutes) generation.armedAt=\(armedAt) "
                    + "maximum=\(maximum)"
            )
            return .rejected
        }

        runAcceptedProductionPath()
        return .accepted
    }
}

nonisolated private final class EarnedSampleRetryQueueLock: @unchecked Sendable {
    static let shared = EarnedSampleRetryQueueLock()
    private let processLock = NSLock()

    func withLock<T>(suiteName: String, _ body: () -> T) -> T? {
        processLock.lock()
        defer { processLock.unlock() }

        let directory: URL
        if suiteName == EarnedTimeStore.appGroupSuiteName,
           let container = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: EarnedTimeStore.appGroupSuiteName
           ) {
            directory = container
        } else {
            directory = FileManager.default.temporaryDirectory
        }
        let safeSuite = suiteName.map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let url = directory.appendingPathComponent("earned-sample-retry-\(String(safeSuite)).lock")
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            return nil
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return body()
    }
}

private struct ClosureMeteringTransport: MeteringHTTPTransport, @unchecked Sendable {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

/// B5 — Lean earned-time sample reporter.
///
/// Responsibilities:
///   - Build the idempotent POST body for `{base}/child/earned-time/sample`
///     (A2 backend schema). Body is a `[String: Any]` map for cheap JSON serialization
///     inside the extension's tight memory budget.
///   - Durably enqueue before POST; remove only after an accepted response.
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
    nonisolated private static let sharedSuiteName = "group.com.evlin.ios"

    enum RetryQueueFault: CaseIterable, Sendable {
        case lockUnavailable
        case synchronizeFailed
        case readbackFailed
    }

    private struct SampleSnapshot: Decodable {
        let usageDate: String
        let estimatedMinutes: Int
        let counted: Bool?
    }

    enum SuccessDisposition: Equatable {
        case counted
        case paused
        case acceptedWithoutReconciliation
        case deferred
        case identityMismatch
    }

    struct ThresholdHandlingDecision: Equatable {
        let thresholdMinutes: Int
        let shouldReport: Bool
        let shouldMutateLocalEstimate: Bool
        let shouldApplyLocalShield: Bool
    }

    @discardableResult
    static func processSuccessfulResponse(
        _ data: Data,
        expectedDeviceID: UUID? = nil,
        store: EarnedTimeStore = .shared,
        suiteName: String = "group.com.evlin.ios",
        beforeReconciliationCommit: () -> Void = {}
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
        if let expectedDeviceID {
            let mirrored = EarnedActivityGeneration.canonicalDeviceID(
                UserDefaults(suiteName: suiteName)?.string(forKey: "evlin.childId")
            )
            guard mirrored == expectedDeviceID.uuidString.lowercased() else {
                recordDebug(
                    "post success identity_mismatch expected=\(expectedDeviceID.uuidString.lowercased()) current=\(mirrored ?? "(missing)")",
                    suiteName: suiteName
                )
                return .identityMismatch
            }
        }
        let reconciliation = store.reconcileAcceptedUsageIfNotStale(
            usageDate: snapshot.usageDate,
            serverEstimatedMinutes: snapshot.estimatedMinutes,
            allowSameDayDecrease: snapshot.counted == false,
            expectedDeviceID: expectedDeviceID,
            beforeCommit: beforeReconciliationCommit
        )
        if reconciliation == .identityMismatch {
            recordDebug(
                "post success identity_mismatch_during_reconciliation date=\(snapshot.usageDate)",
                suiteName: suiteName
            )
            return .identityMismatch
        }
        if reconciliation == .lockUnavailable {
            if snapshot.counted == false, let expectedDeviceID {
                store.markPendingUncountedReconciliation(
                    deviceID: expectedDeviceID,
                    usageDate: snapshot.usageDate
                )
            }
            recordDebug(
                "post success reconciliation_deferred lock_unavailable date=\(snapshot.usageDate)",
                suiteName: suiteName
            )
            return .deferred
        }
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
        observedAt: String,
        generationArmedAt: Date? = nil,
        generationOffsetMinutes: Int? = nil
    ) -> [String: Any] {
        let clientSampleID = "earned:\(deviceID.uuidString.lowercased()):\(usageDate):t\(thresholdMinutes)"
        var body: [String: Any] = [
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
        if let generationArmedAt, let generationOffsetMinutes {
            body["generation_armed_at"] = ISO8601DateFormatter().string(from: generationArmedAt)
            body["generation_offset_minutes"] = generationOffsetMinutes
        }
        return body
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

    static func makeEpochSampleRequest(from entry: RetryEntry) -> EpochSampleRequestDTO? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observedAt = formatter.date(from: entry.observedAt)
            ?? ISO8601DateFormatter().date(from: entry.observedAt)
        guard let observedAt else { return nil }
        return EpochSampleRequestDTO(
            deviceID: entry.deviceID,
            usageDate: entry.usageDate,
            timezone: entry.timezone,
            activityName: "evlin.earned.budget",
            eventName: "evlin.earned.t\(entry.thresholdMinutes)",
            thresholdMinutes: entry.thresholdMinutes,
            estimatedMinutes: entry.estimatedMinutes,
            observedAt: observedAt,
            clientSampleID: "earned:\(entry.deviceID.uuidString.lowercased()):\(entry.usageDate):t\(entry.thresholdMinutes)",
            protocolVersion: nil,
            epochID: nil,
            generationArmedAt: entry.generationArmedAt,
            generationOffsetMinutes: entry.generationOffsetMinutes
        )
    }

    // MARK: - Network POST + retry enqueue

    /// POST the sample to `{base}/child/earned-time/sample`.
    /// Durably enqueues before request construction or authorization/network
    /// work, then removes that exact entry only after an accepted response.
    static func report(
        baseURL: URL,
        deviceID: UUID,
        usageDate: String,
        timezone: String,
        thresholdMinutes: Int,
        estimatedMinutes: Int,
        generationArmedAt: Date? = nil,
        generationOffsetMinutes: Int? = nil,
        suiteName: String = "group.com.evlin.ios",
        epochStore: DeviceEpochStore? = nil,
        authorizationIsCurrent: @escaping () -> Bool = { true },
        requestData: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) async {
        let observedAt = ISO8601DateFormatter().string(from: Date())
        let entry = RetryEntry(
            deviceID: deviceID,
            usageDate: usageDate,
            timezone: timezone,
            thresholdMinutes: thresholdMinutes,
            estimatedMinutes: estimatedMinutes,
            observedAt: observedAt,
            generationArmedAt: generationArmedAt,
            generationOffsetMinutes: generationOffsetMinutes
        )
        let deliveryStore: DeviceEpochStore?
        if let epochStore {
            deliveryStore = epochStore
        } else if suiteName == sharedSuiteName,
                  let mirrored = EarnedActivityGeneration.canonicalDeviceID(
                      UserDefaults(suiteName: suiteName)?.string(forKey: "evlin.childId")
                  ),
                  mirrored == deviceID.uuidString.lowercased() {
            deliveryStore = .shared
        } else {
            deliveryStore = nil
        }

        if let deliveryStore {
            guard let epochRequest = makeEpochSampleRequest(from: entry) else {
                recordDebug("enqueue epoch_request_failed t\(thresholdMinutes)", suiteName: suiteName)
                return
            }
            let transport = ClosureMeteringTransport(handler: requestData)
            let delivery = MeteringEpochDelivery(
                baseURL: baseURL,
                store: deliveryStore,
                transport: transport,
                legacySuiteName: suiteName
            )
            do {
                try delivery.enqueueV1(epochRequest, owner: deviceID)
            } catch {
                recordDebug("enqueue epoch_root_failed t\(thresholdMinutes) error=\(String(describing: error))", suiteName: suiteName)
                return
            }
            await delivery.drain(owner: deviceID, importLegacyWork: false)
            return
        }

        guard enqueueRetry(entry, suiteName: suiteName) else {
            recordDebug("enqueue durability_failed t\(thresholdMinutes)", suiteName: suiteName)
            return
        }

        let body = makeSampleBody(
            deviceID: deviceID,
            usageDate: usageDate,
            timezone: timezone,
            thresholdMinutes: thresholdMinutes,
            estimatedMinutes: estimatedMinutes,
            observedAt: observedAt,
            generationArmedAt: entry.generationArmedAt,
            generationOffsetMinutes: entry.generationOffsetMinutes
        )

        guard let req = try? makeSampleRequest(
            baseURL: baseURL,
            childDeviceID: deviceID,
            body: body
        ) else {
            recordDebug("enqueue request_build_failed t\(thresholdMinutes)", suiteName: suiteName)
            return
        }

        guard authorizationIsCurrent() else { return }
        do {
            let (data, response) = try await requestData(req)
            guard authorizationIsCurrent() else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // 2xx or 409 (already exists — idempotent) are both successes.
            let success = (status >= 200 && status < 300) || status == 409
            recordDebug("post t\(thresholdMinutes) status=\(status) success=\(success)", suiteName: suiteName)
            if success {
                let disposition = processSuccessfulResponse(
                    data,
                    expectedDeviceID: deviceID,
                    store: EarnedTimeStore(suiteName: suiteName),
                    suiteName: suiteName
                )
                if disposition != .identityMismatch {
                    removeAcceptedRetry(entry, suiteName: suiteName)
                }
            }
        } catch {
            guard authorizationIsCurrent() else { return }
            recordDebug("enqueue network_error t\(thresholdMinutes) error=\(error.localizedDescription)", suiteName: suiteName)
        }
    }

    /// Drain the retry queue while leaving each entry durable across its await.
    /// Accepted entries are removed individually; failures and authorization
    /// aborts remain queued for a later current-device drain.
    static func drainRetryQueue(
        baseURL: URL,
        suiteName: String = sharedSuiteName,
        onlyDeviceID: UUID? = nil,
        authorizationIsCurrent: @escaping () -> Bool = { true },
        requestData: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) async {
        if suiteName == sharedSuiteName,
           let deviceID = onlyDeviceID ?? UUID(uuidString: UserDefaults(suiteName: suiteName)?.string(forKey: "evlin.childId") ?? ""),
           EarnedActivityGeneration.canonicalDeviceID(
               UserDefaults(suiteName: suiteName)?.string(forKey: "evlin.childId")
           ) == deviceID.uuidString.lowercased() {
            let transport = ClosureMeteringTransport(handler: requestData)
            let delivery = MeteringEpochDelivery(
                baseURL: baseURL,
                store: .shared,
                transport: transport,
                clock: SystemMeteringClock(),
                legacySuiteName: suiteName
            )
            await delivery.drain(owner: deviceID)
            return
        }

        let queue = loadRetryQueue(suiteName: suiteName)
        guard !queue.isEmpty else { return }
        let partitioned = partitionRetryQueue(queue, onlyDeviceID: onlyDeviceID)

        for entry in partitioned.eligible {
            guard authorizationIsCurrent() else { return }
            let body = makeSampleBody(
                deviceID: entry.deviceID,
                usageDate: entry.usageDate,
                timezone: entry.timezone,
                thresholdMinutes: entry.thresholdMinutes,
                estimatedMinutes: entry.estimatedMinutes,
                observedAt: entry.observedAt,
                generationArmedAt: entry.generationArmedAt,
                generationOffsetMinutes: entry.generationOffsetMinutes
            )
            guard let req = try? makeSampleRequest(
                baseURL: baseURL,
                childDeviceID: entry.deviceID,
                body: body
            ) else {
                continue
            }

            let shouldRemove: Bool
            do {
                guard authorizationIsCurrent() else { return }
                let (data, response) = try await requestData(req)
                guard authorizationIsCurrent() else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let httpSucceeded = (status >= 200 && status < 300) || status == 409
                if httpSucceeded {
                    let disposition = processSuccessfulResponse(
                        data,
                        expectedDeviceID: entry.deviceID,
                        store: EarnedTimeStore(suiteName: suiteName),
                        suiteName: suiteName
                    )
                    shouldRemove = disposition != .identityMismatch
                } else {
                    shouldRemove = false
                }
            } catch {
                guard authorizationIsCurrent() else { return }
                shouldRemove = false
            }

            if !shouldRemove {
                continue
            }
            guard authorizationIsCurrent() else { return }
            removeAcceptedRetry(entry, suiteName: suiteName)
        }
    }

    static func drainRetryQueueFromStoredConfig(
        suiteName: String = sharedSuiteName,
        requestData: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) async {
        let defaults = UserDefaults(suiteName: suiteName)
        guard let baseRaw = defaults?.string(forKey: "evlin.baseURL"),
              let baseURL = URL(string: baseRaw),
              let childRaw = defaults?.string(forKey: "evlin.childId"),
              let childID = UUID(uuidString: childRaw)
        else {
            recordDebug("drain skipped missing stored baseURL/childId", suiteName: suiteName)
            return
        }
        await drainRetryQueue(
            baseURL: baseURL,
            suiteName: suiteName,
            onlyDeviceID: childID,
            requestData: requestData
        )
    }

    // MARK: - Retry queue (App Group)

    struct RetryEntry: Codable, Equatable, Sendable {
        let deviceID: UUID
        let usageDate: String
        let timezone: String
        let thresholdMinutes: Int
        let estimatedMinutes: Int
        let observedAt: String
        let generationArmedAt: Date?
        let generationOffsetMinutes: Int?

        init(
            deviceID: UUID,
            usageDate: String,
            timezone: String,
            thresholdMinutes: Int,
            estimatedMinutes: Int,
            observedAt: String,
            generationArmedAt: Date? = nil,
            generationOffsetMinutes: Int? = nil
        ) {
            self.deviceID = deviceID
            self.usageDate = usageDate
            self.timezone = timezone
            self.thresholdMinutes = thresholdMinutes
            self.estimatedMinutes = estimatedMinutes
            self.observedAt = observedAt
            if let generationArmedAt, let generationOffsetMinutes {
                self.generationArmedAt = generationArmedAt
                self.generationOffsetMinutes = generationOffsetMinutes
            } else {
                self.generationArmedAt = nil
                self.generationOffsetMinutes = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case deviceID
            case usageDate
            case timezone
            case thresholdMinutes
            case estimatedMinutes
            case observedAt
            case generationArmedAt
            case generationOffsetMinutes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                deviceID: try container.decode(UUID.self, forKey: .deviceID),
                usageDate: try container.decode(String.self, forKey: .usageDate),
                timezone: try container.decode(String.self, forKey: .timezone),
                thresholdMinutes: try container.decode(Int.self, forKey: .thresholdMinutes),
                estimatedMinutes: try container.decode(Int.self, forKey: .estimatedMinutes),
                observedAt: try container.decode(String.self, forKey: .observedAt),
                generationArmedAt: try container.decodeIfPresent(Date.self, forKey: .generationArmedAt),
                generationOffsetMinutes: try container.decodeIfPresent(Int.self, forKey: .generationOffsetMinutes)
            )
        }
    }

    static func makeRetryEntry(
        deviceID: UUID,
        usageDate: String,
        timezone: String,
        thresholdMinutes: Int,
        estimatedMinutes: Int,
        observedAt: String = ISO8601DateFormatter().string(from: Date()),
        generationArmedAt: Date? = nil,
        generationOffsetMinutes: Int? = nil
    ) -> RetryEntry {
        RetryEntry(
            deviceID: deviceID,
            usageDate: usageDate,
            timezone: timezone,
            thresholdMinutes: thresholdMinutes,
            estimatedMinutes: estimatedMinutes,
            observedAt: observedAt,
            generationArmedAt: generationArmedAt,
            generationOffsetMinutes: generationOffsetMinutes
        )
    }

    @discardableResult
    static func enqueueRetry(
        _ entry: RetryEntry,
        suiteName: String = "group.com.evlin.ios",
        faultInjection: RetryQueueFault? = nil,
        epochStore: DeviceEpochStore? = nil
    ) -> Bool {
        let primarySaved: Bool
        if faultInjection == .lockUnavailable {
            primarySaved = false
        } else {
            primarySaved = withRetryQueueLock(suiteName: suiteName) { defaults in
                let queue = deduplicatedRetryEntries(
                    loadRetryQueueUnlocked(defaults: defaults) + [entry]
                )
                return saveRetryQueueUnlocked(
                    queue,
                    defaults: defaults,
                    faultInjection: faultInjection
                )
            } ?? false
        }
        let durable = primarySaved || persistFallback(entry, suiteName: suiteName)
        if durable {
            if let epochStore {
                persistEpochSample(entry, store: epochStore)
            } else {
                persistEpochSampleIfCurrentOwner(entry, suiteName: suiteName)
            }
        }
        return durable
    }

    static func loadRetryQueue(suiteName: String = "group.com.evlin.ios") -> [RetryEntry] {
        let primary = withRetryQueueLock(suiteName: suiteName) { defaults in
            loadRetryQueueUnlocked(defaults: defaults)
        } ?? []
        return deduplicatedRetryEntries(primary + loadFallbackEntries(suiteName: suiteName))
    }

    static func legacyRetryEntries(suiteName: String = "group.com.evlin.ios") -> [RetryEntry] {
        loadRetryQueue(suiteName: suiteName)
    }

    static func removeRetryEntry(_ entry: RetryEntry, suiteName: String = "group.com.evlin.ios") {
        removeAcceptedRetry(entry, suiteName: suiteName)
    }

    static func clearRetryQueue(suiteName: String = "group.com.evlin.ios") {
        _ = withRetryQueueLock(suiteName: suiteName) { defaults in
            defaults.removeObject(forKey: retryQueueKey)
            return defaults.synchronize() && defaults.object(forKey: retryQueueKey) == nil
        }
        clearFallbackEntries(suiteName: suiteName)
    }

    static func retryQueueDebugSummary(suiteName: String = "group.com.evlin.ios") -> String {
        let queue = loadRetryQueue(suiteName: suiteName)
        guard let newest = queue.last else { return "0 pending" }
        return "\(queue.count) pending; newest t\(newest.thresholdMinutes) observed \(newest.observedAt)"
    }

    static func partitionRetryQueue(
        _ queue: [RetryEntry],
        onlyDeviceID: UUID?
    ) -> (eligible: [RetryEntry], deferred: [RetryEntry]) {
        guard let onlyDeviceID else { return (queue, []) }
        var eligible: [RetryEntry] = []
        var deferred: [RetryEntry] = []
        for entry in queue {
            if entry.deviceID == onlyDeviceID {
                eligible.append(entry)
            } else {
                deferred.append(entry)
            }
        }
        return (eligible, deferred)
    }

    private static func removeAcceptedRetry(_ entry: RetryEntry, suiteName: String) {
        _ = withRetryQueueLock(suiteName: suiteName) { defaults in
            var queue = loadRetryQueueUnlocked(defaults: defaults)
            queue.removeAll { logicalRetryKey($0) == logicalRetryKey(entry) }
            return saveRetryQueueUnlocked(queue, defaults: defaults)
        }
        removeFallback(entry, suiteName: suiteName)
    }

    private static func persistEpochSampleIfCurrentOwner(_ entry: RetryEntry, suiteName: String) {
        guard suiteName == sharedSuiteName,
              let mirrored = EarnedActivityGeneration.canonicalDeviceID(
                  UserDefaults(suiteName: suiteName)?.string(forKey: "evlin.childId")
              ),
              mirrored == entry.deviceID.uuidString.lowercased()
        else { return }

        persistEpochSample(entry, store: .shared)
    }

    private static func persistEpochSample(_ entry: RetryEntry, store: DeviceEpochStore) {
        guard let request = makeEpochSampleRequest(from: entry) else { return }
        let now = Date()
        try? store.transaction(expectedOwner: entry.deviceID) { state in
            guard !state.sampleWork.values.contains(where: { $0.request.clientSampleID == request.clientSampleID }) else { return }
            let workID = UUID()
            state.sampleWork[workID] = EpochSampleWork(
                workID: workID,
                ownerChildDeviceID: entry.deviceID,
                epochID: nil,
                routeID: nil,
                request: request,
                authorization: .legacyDeliverable,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: now,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: now
            )
        }
    }

    private static func withRetryQueueLock<T>(
        suiteName: String,
        _ body: (UserDefaults) -> T
    ) -> T? {
        EarnedSampleRetryQueueLock.shared.withLock(suiteName: suiteName) {
            guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
            defaults.synchronize()
            return body(defaults)
        } ?? nil
    }

    private static func loadRetryQueueUnlocked(defaults: UserDefaults) -> [RetryEntry] {
        guard let data = defaults.data(forKey: retryQueueKey),
              let queue = try? JSONDecoder().decode([RetryEntry].self, from: data)
        else { return [] }
        return deduplicatedRetryEntries(queue)
    }

    private static func saveRetryQueueUnlocked(
        _ queue: [RetryEntry],
        defaults: UserDefaults,
        faultInjection: RetryQueueFault? = nil
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(queue) else { return false }
        defaults.set(data, forKey: retryQueueKey)
        if faultInjection == .synchronizeFailed { return false }
        guard defaults.synchronize() else { return false }
        if faultInjection == .readbackFailed { return false }
        guard let readback = defaults.data(forKey: retryQueueKey),
              let decoded = try? JSONDecoder().decode([RetryEntry].self, from: readback)
        else { return false }
        return decoded == queue
    }

    private static func logicalRetryKey(_ entry: RetryEntry) -> String {
        "\(entry.deviceID.uuidString.lowercased()):\(entry.usageDate):t\(entry.thresholdMinutes)"
    }

    private static func deduplicatedRetryEntries(_ entries: [RetryEntry]) -> [RetryEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert(logicalRetryKey($0)).inserted }
    }

    private static func fallbackDirectory(suiteName: String) -> URL? {
        let base: URL
        if suiteName == sharedSuiteName,
           let container = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: sharedSuiteName
           ) {
            base = container
        } else {
            base = FileManager.default.temporaryDirectory
        }
        let safeSuite = suiteName.map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let directory = base.appendingPathComponent(
            "earned-sample-retry-fallback-\(String(safeSuite))",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory
        } catch {
            return nil
        }
    }

    private static func fallbackURL(_ entry: RetryEntry, suiteName: String) -> URL? {
        fallbackDirectory(suiteName: suiteName)?.appendingPathComponent(
            "\(logicalRetryKey(entry)).json"
        )
    }

    private static func persistFallback(_ entry: RetryEntry, suiteName: String) -> Bool {
        guard let url = fallbackURL(entry, suiteName: suiteName),
              let data = try? JSONEncoder().encode(entry)
        else { return false }
        do {
            try data.write(to: url, options: .atomic)
            guard (try? Data(contentsOf: url)) == data else { return false }
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            return fsync(descriptor) == 0
        } catch {
            return false
        }
    }

    private static func loadFallbackEntries(suiteName: String) -> [RetryEntry] {
        guard let directory = fallbackDirectory(suiteName: suiteName),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              )
        else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(RetryEntry.self, from: data)
            }
    }

    private static func removeFallback(_ entry: RetryEntry, suiteName: String) {
        guard let url = fallbackURL(entry, suiteName: suiteName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func clearFallbackEntries(suiteName: String) {
        guard let directory = fallbackDirectory(suiteName: suiteName) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func recordDebug(_ message: String, suiteName: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        UserDefaults(suiteName: suiteName)?.set("\(ts) \(message)", forKey: lastSamplePostDebugKey)
    }

    // MARK: - Tripwire math (pure)

    static func thresholdHandlingDecision(
        thresholdMinutes: Int,
        isPlausible: Bool = true,
        localReconciliationAvailable: Bool
    ) -> ThresholdHandlingDecision {
        ThresholdHandlingDecision(
            thresholdMinutes: thresholdMinutes,
            shouldReport: isPlausible,
            shouldMutateLocalEstimate: isPlausible && localReconciliationAvailable,
            shouldApplyLocalShield: isPlausible && localReconciliationAvailable
        )
    }

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
