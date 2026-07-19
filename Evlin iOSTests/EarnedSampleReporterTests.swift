import XCTest
@testable import Evlin_iOS

/// B5 — Pure-logic tests for earned-time sample reporting + cap/tripwire math.
///
/// These tests cover:
///   1. Sample body shape + stable `client_sample_id`
///   2. Retry-queue enqueue on simulated POST failure
///   3. Tripwire math (`latestEstimate + backendRemaining`, rounded up to next armed
///      threshold, capped at `min(pool, cap)`)
///   4. Override flag present → no `.earnedTime` applied
///   5. Daily strip removes ONLY `.earnedTime` (preserves `.manual`/`.limit`)
///   6. Mixed `{.limit, .earnedTime}` strip of `.earnedTime` leaves `{.limit}` — B1 carry
///
/// No DeviceActivity types, no network calls, no ManagedSettingsStore — all pure logic.
final class EarnedSampleReporterTests: XCTestCase {

    private let suiteName = "group.com.evlin.ios"
    private let retryKey  = "evlin.earnedSampleRetryQueue"
    private let shieldsKey = "evlin.shieldRecords"

    override func setUp() {
        super.setUp()
        let d = UserDefaults(suiteName: suiteName)
        d?.removeObject(forKey: retryKey)
        d?.removeObject(forKey: shieldsKey)
        EarnedTimeStore.shared.removeAll()
    }

    override func tearDown() {
        let d = UserDefaults(suiteName: suiteName)
        d?.removeObject(forKey: retryKey)
        d?.removeObject(forKey: shieldsKey)
        EarnedTimeStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - 1. Sample body shape + stable client_sample_id

    func test_sampleBody_hasRequiredFields() throws {
        let deviceID = UUID()
        let usageDate = "2026-06-23"
        let n = 30
        let body = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: usageDate,
            timezone: "America/Los_Angeles",
            thresholdMinutes: n,
            estimatedMinutes: n,
            observedAt: "2026-06-23T10:00:00Z"
        )

        XCTAssertEqual(body["device_id"] as? String, deviceID.uuidString)
        XCTAssertEqual(body["usage_date"] as? String, usageDate)
        XCTAssertEqual(body["timezone"] as? String, "America/Los_Angeles")
        XCTAssertEqual(body["activity_name"] as? String, "evlin.earned.budget")
        XCTAssertEqual(body["event_name"] as? String, "evlin.earned.t\(n)")
        XCTAssertEqual(body["threshold_minutes"] as? Int, n)
        XCTAssertEqual(body["estimated_minutes"] as? Int, n)
        XCTAssertEqual(body["observed_at"] as? String, "2026-06-23T10:00:00Z")
        XCTAssertNotNil(body["client_sample_id"])
    }

    func test_sampleBody_includesGenerationMetadataOnlyWhenBothValuesExist() {
        let deviceID = UUID()
        let armedAt = Date(timeIntervalSince1970: 1_784_003_200)
        let complete = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: "2026-07-13",
            timezone: "America/New_York",
            thresholdMinutes: 20,
            estimatedMinutes: 20,
            observedAt: "2026-07-13T12:05:00Z",
            generationArmedAt: armedAt,
            generationOffsetMinutes: 15
        )
        let missingOffset = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: "2026-07-13",
            timezone: "America/New_York",
            thresholdMinutes: 20,
            estimatedMinutes: 20,
            observedAt: "2026-07-13T12:05:00Z",
            generationArmedAt: armedAt
        )

        XCTAssertEqual(
            complete["generation_armed_at"] as? String,
            ISO8601DateFormatter().string(from: armedAt)
        )
        XCTAssertEqual(complete["generation_offset_minutes"] as? Int, 15)
        XCTAssertNil(missingOffset["generation_armed_at"])
        XCTAssertNil(missingOffset["generation_offset_minutes"])
    }

    func test_sampleBody_clientSampleId_isStable() {
        // Same inputs → same id (idempotency key).
        let deviceID = UUID()
        let usageDate = "2026-06-23"
        let n = 20

        let body1 = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: usageDate,
            timezone: "UTC",
            thresholdMinutes: n,
            estimatedMinutes: n,
            observedAt: "2026-06-23T08:00:00Z"
        )
        let body2 = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: usageDate,
            timezone: "UTC",
            thresholdMinutes: n,
            estimatedMinutes: n + 5, // estimatedMinutes intentionally different
            observedAt: "2026-06-23T09:00:00Z"
        )

        // client_sample_id is derived from deviceID + usageDate + thresholdN only.
        XCTAssertEqual(
            body1["client_sample_id"] as? String,
            body2["client_sample_id"] as? String,
            "client_sample_id must be stable across varying estimated_minutes / observed_at"
        )
    }

    func test_sampleBody_clientSampleId_format() {
        let deviceID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let body = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: "2026-06-23",
            timezone: "UTC",
            thresholdMinutes: 40,
            estimatedMinutes: 40,
            observedAt: "2026-06-23T10:00:00Z"
        )
        // Expected format: "earned:<device_id_uuidstring_lowercased>:<usage_date>:t<N>"
        let id = body["client_sample_id"] as? String ?? ""
        XCTAssertTrue(
            id.hasPrefix("earned:"),
            "client_sample_id must start with 'earned:' — got '\(id)'"
        )
        XCTAssertTrue(
            id.contains(":2026-06-23:"),
            "client_sample_id must include usage_date — got '\(id)'"
        )
        XCTAssertTrue(
            id.hasSuffix(":t40"),
            "client_sample_id must end with ':t<N>' — got '\(id)'"
        )
    }

    func test_sampleBody_clientSampleId_differsByThreshold() {
        let deviceID = UUID()
        let usageDate = "2026-06-23"

        let body10 = EarnedSampleReporter.makeSampleBody(deviceID: deviceID, usageDate: usageDate,
                                                          timezone: "UTC", thresholdMinutes: 10,
                                                          estimatedMinutes: 10, observedAt: "2026-06-23T10:00:00Z")
        let body20 = EarnedSampleReporter.makeSampleBody(deviceID: deviceID, usageDate: usageDate,
                                                          timezone: "UTC", thresholdMinutes: 20,
                                                          estimatedMinutes: 20, observedAt: "2026-06-23T10:00:00Z")

        XCTAssertNotEqual(
            body10["client_sample_id"] as? String,
            body20["client_sample_id"] as? String,
            "client_sample_id must differ across different threshold N values"
        )
    }

    func test_sampleRequest_usesBackendChildDeviceHeader() throws {
        let deviceID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let body = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: "2026-06-23",
            timezone: "UTC",
            thresholdMinutes: 10,
            estimatedMinutes: 10,
            observedAt: "2026-06-23T10:00:00Z"
        )

        let request = try EarnedSampleReporter.makeSampleRequest(
            baseURL: URL(string: "https://api.example.test")!,
            childDeviceID: deviceID,
            body: body
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Evlin-Child-Device-ID"), deviceID.uuidString)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Child-Id"))
    }

    func test_legacyRetryEntryCanBeReopenedAsByteStableV1Request() throws {
        let entry = EarnedSampleReporter.RetryEntry(
            deviceID: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
            usageDate: "2026-06-23",
            timezone: "UTC",
            thresholdMinutes: 40,
            estimatedMinutes: 40,
            observedAt: "2026-06-23T10:00:00Z"
        )

        let request = try XCTUnwrap(EarnedSampleReporter.makeEpochSampleRequest(from: entry))
        XCTAssertEqual(request.lane, .v1)
        XCTAssertEqual(request.clientSampleID, "earned:a1b2c3d4-e5f6-7890-abcd-ef1234567890:2026-06-23:t40")
    }

    func test_legacyV1RequestMatchesIndependentGoldenBytes() throws {
        let entry = EarnedSampleReporter.RetryEntry(
            deviceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            usageDate: "2026-07-16",
            timezone: "America/New_York",
            thresholdMinutes: 10,
            estimatedMinutes: 10,
            observedAt: "2026-07-16T05:20:00Z"
        )
        let request = try XCTUnwrap(EarnedSampleReporter.makeEpochSampleRequest(from: entry))
        let urlRequest = try MeteringEpochRequests.sample(
            baseURL: URL(string: "https://metering-epoch-delivery.test")!,
            ownerChildDeviceID: entry.deviceID,
            body: request
        )
        let golden = Data(#"{"activity_name":"evlin.earned.budget","client_sample_id":"earned:11111111-1111-1111-1111-111111111111:2026-07-16:t10","device_id":"11111111-1111-1111-1111-111111111111","estimated_minutes":10,"event_name":"evlin.earned.t10","observed_at":"2026-07-16T05:20:00Z","threshold_minutes":10,"timezone":"America\/New_York","usage_date":"2026-07-16"}"#.utf8)
        XCTAssertEqual(urlRequest.httpBody, golden)
    }

    // MARK: - 2. Retry-queue enqueue on simulated POST failure

    func test_enqueueRetry_appendsToAppGroup() throws {
        let deviceID = UUID()
        let entry = EarnedSampleReporter.RetryEntry(
            deviceID: deviceID,
            usageDate: "2026-06-23",
            timezone: "UTC",
            thresholdMinutes: 30,
            estimatedMinutes: 30,
            observedAt: "2026-06-23T10:00:00Z"
        )

        EarnedSampleReporter.enqueueRetry(entry, suiteName: suiteName)

        let queue = EarnedSampleReporter.loadRetryQueue(suiteName: suiteName)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.thresholdMinutes, 30)
        XCTAssertEqual(queue.first?.deviceID, deviceID)
    }

    func test_retryEntryRoundTripsMetadataAndDecodesLegacyQueueJSON() throws {
        let armedAt = Date(timeIntervalSince1970: 1_784_003_200)
        let entry = EarnedSampleReporter.RetryEntry(
            deviceID: UUID(uuidString: "B21411CB-63A5-4489-BC68-BF8AC26EE15B")!,
            usageDate: "2026-07-13",
            timezone: "America/New_York",
            thresholdMinutes: 20,
            estimatedMinutes: 20,
            observedAt: "2026-07-13T12:05:00Z",
            generationArmedAt: armedAt,
            generationOffsetMinutes: 15
        )

        let roundTripped = try JSONDecoder().decode(
            EarnedSampleReporter.RetryEntry.self,
            from: JSONEncoder().encode(entry)
        )
        let legacyQueue = try JSONDecoder().decode(
            [EarnedSampleReporter.RetryEntry].self,
            from: Data("""
            [{"deviceID":"b21411cb-63a5-4489-bc68-bf8ac26ee15b","usageDate":"2026-07-13","timezone":"America/New_York","thresholdMinutes":20,"estimatedMinutes":20,"observedAt":"2026-07-13T12:05:00Z"}]
            """.utf8)
        )

        XCTAssertEqual(roundTripped, entry)
        XCTAssertEqual(roundTripped.generationArmedAt, armedAt)
        XCTAssertEqual(roundTripped.generationOffsetMinutes, 15)
        XCTAssertEqual(legacyQueue.count, 1)
        XCTAssertNil(legacyQueue[0].generationArmedAt)
        XCTAssertNil(legacyQueue[0].generationOffsetMinutes)
    }

    func test_makeRetryEntryNormalizesPartialGenerationMetadata() throws {
        let commonDeviceID = UUID()
        let armedAt = Date(timeIntervalSince1970: 1_784_003_200)
        let armedOnly = EarnedSampleReporter.makeRetryEntry(
            deviceID: commonDeviceID,
            usageDate: "2026-07-13",
            timezone: "America/New_York",
            thresholdMinutes: 20,
            estimatedMinutes: 20,
            generationArmedAt: armedAt
        )
        let offsetOnly = EarnedSampleReporter.makeRetryEntry(
            deviceID: commonDeviceID,
            usageDate: "2026-07-13",
            timezone: "America/New_York",
            thresholdMinutes: 20,
            estimatedMinutes: 20,
            generationOffsetMinutes: 15
        )

        for entry in [armedOnly, offsetOnly] {
            XCTAssertNil(entry.generationArmedAt)
            XCTAssertNil(entry.generationOffsetMinutes)
            let encoded = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
                    as? [String: Any]
            )
            XCTAssertNil(encoded["generationArmedAt"])
            XCTAssertNil(encoded["generationOffsetMinutes"])
        }
    }

    func test_retryEntryDecodingNormalizesPartialGenerationMetadata() throws {
        let complete = EarnedSampleReporter.RetryEntry(
            deviceID: UUID(),
            usageDate: "2026-07-13",
            timezone: "America/New_York",
            thresholdMinutes: 20,
            estimatedMinutes: 20,
            observedAt: "2026-07-13T12:05:00Z",
            generationArmedAt: Date(timeIntervalSince1970: 1_784_003_200),
            generationOffsetMinutes: 15
        )
        let completeJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(complete))
                as? [String: Any]
        )
        var armedOnlyJSON = completeJSON
        armedOnlyJSON.removeValue(forKey: "generationOffsetMinutes")
        var offsetOnlyJSON = completeJSON
        offsetOnlyJSON.removeValue(forKey: "generationArmedAt")

        for partialJSON in [armedOnlyJSON, offsetOnlyJSON] {
            let decoded = try JSONDecoder().decode(
                EarnedSampleReporter.RetryEntry.self,
                from: JSONSerialization.data(withJSONObject: partialJSON)
            )
            XCTAssertNil(decoded.generationArmedAt)
            XCTAssertNil(decoded.generationOffsetMinutes)
        }
    }

    func test_enqueueRetry_multipleEntries_accumulatesOrdered() {
        let deviceID = UUID()
        for n in [10, 20, 30] {
            EarnedSampleReporter.enqueueRetry(
                EarnedSampleReporter.RetryEntry(
                    deviceID: deviceID,
                    usageDate: "2026-06-23",
                    timezone: "UTC",
                    thresholdMinutes: n,
                    estimatedMinutes: n,
                    observedAt: "2026-06-23T10:00:00Z"
                ),
                suiteName: suiteName
            )
        }
        let queue = EarnedSampleReporter.loadRetryQueue(suiteName: suiteName)
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.map(\.thresholdMinutes), [10, 20, 30])
    }

    func test_enqueueRetry_logicallyDeduplicatesObservedAtVariants() {
        let isolatedSuite = "EarnedSampleReporterTests.\(UUID().uuidString)"
        defer {
            EarnedSampleReporter.clearRetryQueue(suiteName: isolatedSuite)
            UserDefaults.standard.removePersistentDomain(forName: isolatedSuite)
        }
        let deviceID = UUID()
        let first = EarnedSampleReporter.RetryEntry(
            deviceID: deviceID,
            usageDate: "2026-07-12",
            timezone: "America/New_York",
            thresholdMinutes: 60,
            estimatedMinutes: 60,
            observedAt: "2026-07-12T12:00:00Z"
        )
        let duplicate = EarnedSampleReporter.RetryEntry(
            deviceID: deviceID,
            usageDate: first.usageDate,
            timezone: first.timezone,
            thresholdMinutes: first.thresholdMinutes,
            estimatedMinutes: first.estimatedMinutes,
            observedAt: "2026-07-12T12:05:00Z"
        )

        XCTAssertTrue(EarnedSampleReporter.enqueueRetry(first, suiteName: isolatedSuite))
        XCTAssertTrue(EarnedSampleReporter.enqueueRetry(duplicate, suiteName: isolatedSuite))

        XCTAssertEqual(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite), [first])
        let firstID = EarnedSampleReporter.makeSampleBody(
            deviceID: first.deviceID,
            usageDate: first.usageDate,
            timezone: first.timezone,
            thresholdMinutes: first.thresholdMinutes,
            estimatedMinutes: first.estimatedMinutes,
            observedAt: first.observedAt
        )["client_sample_id"] as? String
        let duplicateID = EarnedSampleReporter.makeSampleBody(
            deviceID: duplicate.deviceID,
            usageDate: duplicate.usageDate,
            timezone: duplicate.timezone,
            thresholdMinutes: duplicate.thresholdMinutes,
            estimatedMinutes: duplicate.estimatedMinutes,
            observedAt: duplicate.observedAt
        )["client_sample_id"] as? String
        XCTAssertEqual(firstID, duplicateID)
    }

    func test_enqueueRetryPrimaryPersistenceFaultsRecoverThroughDurableFallback() async throws {
        for fault in EarnedSampleReporter.RetryQueueFault.allCases {
            let isolatedSuite = "EarnedSampleReporterTests.\(UUID().uuidString)"
            defer {
                EarnedSampleReporter.clearRetryQueue(suiteName: isolatedSuite)
                UserDefaults.standard.removePersistentDomain(forName: isolatedSuite)
            }
            let entry = EarnedSampleReporter.RetryEntry(
                deviceID: UUID(),
                usageDate: "2026-07-12",
                timezone: "America/New_York",
                thresholdMinutes: 65,
                estimatedMinutes: 65,
                observedAt: "2026-07-12T12:05:00Z"
            )

            XCTAssertTrue(EarnedSampleReporter.enqueueRetry(
                entry,
                suiteName: isolatedSuite,
                faultInjection: fault
            ), "fault \(fault) must fall back durably")
            XCTAssertEqual(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite), [entry])

            await EarnedSampleReporter.drainRetryQueue(
                baseURL: URL(string: "https://earned-sample-reporter.test")!,
                suiteName: isolatedSuite,
                onlyDeviceID: entry.deviceID,
                requestData: { request in
                    let response = HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 409,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return (Data(), response)
                }
            )
            XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
        }
    }

    func test_retryQueueDebugSummary_reportsPendingCountAndNewestThreshold() {
        let deviceID = UUID()
        XCTAssertEqual(EarnedSampleReporter.retryQueueDebugSummary(suiteName: suiteName), "0 pending")

        for n in [15, 20] {
            EarnedSampleReporter.enqueueRetry(
                EarnedSampleReporter.RetryEntry(
                    deviceID: deviceID,
                    usageDate: "2026-06-28",
                    timezone: "America/New_York",
                    thresholdMinutes: n,
                    estimatedMinutes: n,
                    observedAt: "2026-06-28T20:00:00Z"
                ),
                suiteName: suiteName
            )
        }

        XCTAssertEqual(
            EarnedSampleReporter.retryQueueDebugSummary(suiteName: suiteName),
            "2 pending; newest t20 observed 2026-06-28T20:00:00Z"
        )
    }

    func test_retryQueueFilteringKeepsOnlyCurrentDeviceEligibleForDrain() {
        let current = UUID(uuidString: "B21411CB-63A5-4489-BC68-BF8AC26EE15B")!
        let previous = UUID(uuidString: "0D45589A-722C-4E43-A06E-7501F484A46C")!
        let queue = [
            EarnedSampleReporter.RetryEntry(
                deviceID: previous,
                usageDate: "2026-07-03",
                timezone: "America/New_York",
                thresholdMinutes: 5,
                estimatedMinutes: 5,
                observedAt: "2026-07-04T00:10:00Z"
            ),
            EarnedSampleReporter.RetryEntry(
                deviceID: current,
                usageDate: "2026-07-03",
                timezone: "America/New_York",
                thresholdMinutes: 10,
                estimatedMinutes: 10,
                observedAt: "2026-07-04T00:20:00Z"
            ),
        ]

        let filtered = EarnedSampleReporter.partitionRetryQueue(queue, onlyDeviceID: current)

        XCTAssertEqual(filtered.eligible.map(\.deviceID), [current])
        XCTAssertEqual(filtered.deferred.map(\.deviceID), [previous])
    }

    func test_terminalThresholdIsReportedButNotLocallyMutatedOrShieldedWhenLockUnavailable() {
        let decision = EarnedSampleReporter.thresholdHandlingDecision(
            thresholdMinutes: 300,
            localReconciliationAvailable: false
        )

        XCTAssertTrue(decision.shouldReport)
        XCTAssertFalse(decision.shouldMutateLocalEstimate)
        XCTAssertFalse(decision.shouldApplyLocalShield)
        XCTAssertEqual(decision.thresholdMinutes, 300)
    }

    func test_implausibleThresholdCoordinatorRecordsOnlyDiagnostic() {
        let spy = EarnedThresholdProductionPathSpy()
        let armedAt = Date(timeIntervalSince1970: 1_784_003_200)
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 50,
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York",
            armedAt: armedAt
        )

        let outcome = EarnedThresholdProductionCoordinator.process(
            generation: generation,
            eventName: "evlin.earned.t70",
            rawThresholdMinutes: 70,
            adjustedEstimateMinutes: 120,
            callbackAt: armedAt.addingTimeInterval(3 * 60),
            currentUsageDate: "2026-07-13",
            recordDiagnostic: spy.recordDiagnostic,
            runAcceptedProductionPath: spy.runAcceptedProductionPath
        )

        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(spy.diagnostics.count, 1)
        XCTAssertEqual(spy.estimateMutationCount, 0)
        XCTAssertEqual(spy.retryEnqueueCount, 0)
        XCTAssertEqual(spy.networkDispatchCount, 0)
        XCTAssertEqual(spy.shieldWorkCount, 0)
        XCTAssertEqual(spy.acceptedPathCount, 0)
    }

    func test_strictThresholdCoordinatorReachesAcceptedProductionPathAtBoundary() {
        let spy = EarnedThresholdProductionPathSpy()
        let armedAt = Date(timeIntervalSince1970: 1_784_003_200)
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 50,
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York",
            armedAt: armedAt
        )

        let outcome = EarnedThresholdProductionCoordinator.process(
            generation: generation,
            eventName: "evlin.earned.t5",
            rawThresholdMinutes: 5,
            adjustedEstimateMinutes: 55,
            callbackAt: armedAt.addingTimeInterval(270),
            currentUsageDate: "2026-07-13",
            recordDiagnostic: spy.recordDiagnostic,
            runAcceptedProductionPath: spy.runAcceptedProductionPath
        )

        XCTAssertEqual(outcome, .accepted)
        XCTAssertTrue(spy.diagnostics.isEmpty)
        XCTAssertEqual(spy.acceptedPathCount, 1)
    }

    func test_implausibleThresholdDiagnosticIncludesStableGenerationArmedAt() throws {
        let spy = EarnedThresholdProductionPathSpy()
        let armedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-13T16:00:00Z")
        )
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: UUID().uuidString,
            offsetMinutes: 50,
            usageDate: "2026-07-13",
            timezoneIdentifier: "America/New_York",
            armedAt: armedAt
        )

        EarnedThresholdProductionCoordinator.process(
            generation: generation,
            eventName: "evlin.earned.t70",
            rawThresholdMinutes: 70,
            adjustedEstimateMinutes: 120,
            callbackAt: armedAt.addingTimeInterval(3 * 60),
            currentUsageDate: "2026-07-13",
            recordDiagnostic: spy.recordDiagnostic,
            runAcceptedProductionPath: spy.runAcceptedProductionPath
        )

        let diagnostic = try XCTUnwrap(spy.diagnostics.first)
        XCTAssertTrue(
            diagnostic.contains("generation.armedAt=2026-07-13T16:00:00Z"),
            diagnostic
        )
    }

    func test_newSampleIsDurablyQueuedBeforeAuthorizationCheckAndKeepsDevicePartition() async {
        let isolatedSuite = "EarnedSampleReporterTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: isolatedSuite) }
        let currentDevice = UUID()
        let deferredDevice = UUID()
        EarnedSampleReporter.enqueueRetry(
            .init(
                deviceID: deferredDevice,
                usageDate: "2026-07-12",
                timezone: "America/New_York",
                thresholdMinutes: 10,
                estimatedMinutes: 10,
                observedAt: "2026-07-12T12:00:00Z"
            ),
            suiteName: isolatedSuite
        )
        var requestCount = 0

        await EarnedSampleReporter.report(
            baseURL: URL(string: "https://earned-sample-reporter.test")!,
            deviceID: currentDevice,
            usageDate: "2026-07-12",
            timezone: "America/New_York",
            thresholdMinutes: 15,
            estimatedMinutes: 15,
            suiteName: isolatedSuite,
            authorizationIsCurrent: { false },
            requestData: { _ in
                requestCount += 1
                throw URLError(.badServerResponse)
            }
        )

        XCTAssertEqual(requestCount, 0)
        let queue = EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite)
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.map(\.deviceID), [deferredDevice, currentDevice])
        XCTAssertEqual(queue.last?.thresholdMinutes, 15)
    }

    func test_newSampleRemainsQueuedWhenAuthorizationChangesDuringPost() async throws {
        let isolatedSuite = "EarnedSampleReporterTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: isolatedSuite) }
        let deviceID = UUID()
        var isAuthorized = true
        var resumeRequest: CheckedContinuation<Void, Never>?

        let reporting = Task {
            await EarnedSampleReporter.report(
                baseURL: URL(string: "https://earned-sample-reporter.test")!,
                deviceID: deviceID,
                usageDate: "2026-07-12",
                timezone: "America/New_York",
                thresholdMinutes: 20,
                estimatedMinutes: 20,
                suiteName: isolatedSuite,
                authorizationIsCurrent: { isAuthorized },
                requestData: { request in
                    await withCheckedContinuation { resumeRequest = $0 }
                    let response = HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return (
                        Data(#"{"usage_date":"2026-07-12","estimated_minutes":20,"counted":true}"#.utf8),
                        response
                    )
                }
            )
        }
        while resumeRequest == nil { await Task.yield() }
        let queuedDuringPost = EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite)
        XCTAssertEqual(queuedDuringPost.count, 1)
        XCTAssertEqual(queuedDuringPost.first?.deviceID, deviceID)

        isAuthorized = false
        resumeRequest?.resume()
        await reporting.value

        let retained = EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.thresholdMinutes, 20)
    }

    func testReportEnqueuesRootBeforeDrainAndTerminalizesThroughProductionPath() async throws {
        let isolatedSuite = "EarnedSampleReporterTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: isolatedSuite) }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-reporter-epoch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let deviceID = UUID()
        let store = DeviceEpochStore(
            fileURL: fileURL,
            ownerProvider: { deviceID }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(DeviceEpochStoreState(ownerChildDeviceID: deviceID)).write(to: fileURL)
        let transport = ReporterRootTransport(store: store)

        await EarnedSampleReporter.report(
            baseURL: URL(string: "https://earned-sample-reporter.test")!,
            deviceID: deviceID,
            usageDate: "2026-07-12",
            timezone: "America/New_York",
            thresholdMinutes: 20,
            estimatedMinutes: 20,
            suiteName: isolatedSuite,
            epochStore: store,
            requestData: { request in try await transport.data(for: request) }
        )

        XCTAssertEqual(transport.sampleCountBeforePost, 1)
        XCTAssertEqual(try store.read().sampleWork.values.first?.retry.terminal, .succeeded)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
    }

    func testInjectedReporterStoreIsOnlyEpochRootAndProductionPathDispatchesOnce() async throws {
        let isolatedSuite = "EarnedSampleReporterTests.injected.\(UUID().uuidString)"
        defer {
            EarnedSampleReporter.clearRetryQueue(suiteName: isolatedSuite)
            UserDefaults.standard.removePersistentDomain(forName: isolatedSuite)
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-reporter-injected-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let deviceID = UUID()
        let store = DeviceEpochStore(fileURL: fileURL, ownerProvider: { deviceID })
        try JSONEncoder().encode(DeviceEpochStoreState(ownerChildDeviceID: deviceID)).write(to: fileURL)
        let transport = ReporterRootTransport(store: store)

        await EarnedSampleReporter.report(
            baseURL: URL(string: "https://earned-sample-reporter.test")!,
            deviceID: deviceID,
            usageDate: "2026-07-12",
            timezone: "America/New_York",
            thresholdMinutes: 20,
            estimatedMinutes: 20,
            suiteName: isolatedSuite,
            epochStore: store,
            requestData: { request in try await transport.data(for: request) }
        )

        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(try store.read().sampleWork.count, 1)
        XCTAssertEqual(try store.read().sampleWork.values.first?.retry.terminal, .succeeded)
    }

    func testReportWritesInjectedEpochRootOnceBeforeItsSingleDrain() async throws {
        let isolatedSuite = "EarnedSampleReporterTests.root-writes.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: isolatedSuite) }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-reporter-write-count-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let deviceID = UUID()
        let fileIO = CountingReporterFileIO()
        let store = DeviceEpochStore(
            fileURL: fileURL,
            fileIO: fileIO,
            ownerProvider: { deviceID }
        )
        try JSONEncoder().encode(DeviceEpochStoreState(ownerChildDeviceID: deviceID)).write(to: fileURL)
        let transport = ReporterRootTransport(store: store, fileIO: fileIO)

        await EarnedSampleReporter.report(
            baseURL: URL(string: "https://earned-sample-reporter.test")!,
            deviceID: deviceID,
            usageDate: "2026-07-12",
            timezone: "America/New_York",
            thresholdMinutes: 20,
            estimatedMinutes: 20,
            suiteName: isolatedSuite,
            epochStore: store,
            requestData: { request in try await transport.data(for: request) }
        )

        XCTAssertEqual(transport.writeCountBeforePost, 2)
        XCTAssertEqual(fileIO.writeCount, 3)
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(try store.read().sampleWork.values.first?.retry.terminal, .succeeded)
    }

    func testEpochTransportClosureContractIsSendable() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Evlin iOS/Services/EarnedSampleReporter.swift")
        )
        XCTAssertEqual(source.components(separatedBy: "requestData: @escaping @Sendable").count - 1, 3)
    }

    func test_clearRetryQueue_emptiesQueue() {
        let deviceID = UUID()
        EarnedSampleReporter.enqueueRetry(
            EarnedSampleReporter.RetryEntry(
                deviceID: deviceID,
                usageDate: "2026-06-23",
                timezone: "UTC",
                thresholdMinutes: 10,
                estimatedMinutes: 10,
                observedAt: "2026-06-23T10:00:00Z"
            ),
            suiteName: suiteName
        )
        EarnedSampleReporter.clearRetryQueue(suiteName: suiteName)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: suiteName).isEmpty)
    }

    func test_identityCleanupPurgesOnlyCapturedOldOwnerRetryState() {
        let isolatedSuite = "EarnedSampleReporterTests.identity.\(UUID().uuidString)"
        defer { EarnedSampleReporter.clearRetryQueue(suiteName: isolatedSuite) }
        let oldOwner = UUID()
        let newOwner = UUID()
        let oldEntry = EarnedSampleReporter.makeRetryEntry(
            deviceID: oldOwner,
            usageDate: "2026-07-18",
            timezone: "America/New_York",
            thresholdMinutes: 5,
            estimatedMinutes: 5
        )
        let newEntry = EarnedSampleReporter.makeRetryEntry(
            deviceID: newOwner,
            usageDate: "2026-07-18",
            timezone: "America/New_York",
            thresholdMinutes: 10,
            estimatedMinutes: 10
        )
        XCTAssertTrue(EarnedSampleReporter.enqueueRetry(
            oldEntry,
            suiteName: isolatedSuite,
            faultInjection: .lockUnavailable
        ))
        XCTAssertTrue(EarnedSampleReporter.enqueueRetry(newEntry, suiteName: isolatedSuite))

        let captured = EarnedSampleReporter.retryKeys(
            deviceID: oldOwner,
            suiteName: isolatedSuite
        )
        XCTAssertEqual(captured, ["\(oldOwner.uuidString.lowercased()):2026-07-18:t5"])

        let purged = EarnedSampleReporter.purgeRetryState(
            deviceID: oldOwner,
            capturedKeys: captured,
            suiteName: isolatedSuite
        )

        XCTAssertEqual(purged, Set(captured))
        XCTAssertEqual(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite), [newEntry])
    }

    func test_concurrentRetryEnqueuesDoNotOverwriteEntries() {
        let isolatedSuite = "EarnedSampleReporterTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: isolatedSuite) }
        let deviceID = UUID()

        DispatchQueue.concurrentPerform(iterations: 80) { index in
            EarnedSampleReporter.enqueueRetry(
                EarnedSampleReporter.RetryEntry(
                    deviceID: deviceID,
                    usageDate: "2026-07-12",
                    timezone: "America/New_York",
                    thresholdMinutes: index,
                    estimatedMinutes: index,
                    observedAt: "2026-07-12T12:00:\(index)Z"
                ),
                suiteName: isolatedSuite
            )
        }

        let queue = EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite)
        XCTAssertEqual(queue.count, 80)
        XCTAssertEqual(Set(queue.map(\.thresholdMinutes)), Set(0..<80))
    }

    // MARK: - 3. Tripwire math

    func test_effectiveCap_latestPlusRemaining_roundedUp_thenCappedAtMinPoolCap() {
        // latest=25 + remaining=12 = 37, nearest armed threshold (bucket=10) → 40
        // min(pool=60, cap=50) = 50, 40 < 50 → result = 40
        let result = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 25,
            backendRemaining: 12,
            poolMinutes: 60,
            capMinutes: 50,
            bucketMinutes: 10
        )
        XCTAssertEqual(result, 40)
    }

    func test_effectiveCap_cappedAtMinPoolCap() {
        // latest=45 + remaining=20 = 65, rounded to 70, but min(pool=60, cap=80) = 60 → capped at 60
        let result = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 45,
            backendRemaining: 20,
            poolMinutes: 60,
            capMinutes: 80,
            bucketMinutes: 10
        )
        XCTAssertEqual(result, 60)
    }

    func test_effectiveCap_alreadyOnBoundary_noRoundUp() {
        // latest=20 + remaining=10 = 30, already a multiple of 10 → stays at 30
        // min(pool=60, cap=90) = 60, 30 ≤ 60 → result = 30
        let result = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 20,
            backendRemaining: 10,
            poolMinutes: 60,
            capMinutes: 90,
            bucketMinutes: 10
        )
        XCTAssertEqual(result, 30)
    }

    func test_effectiveCap_zeroRemaining_usesLatestRounded() {
        // latest=33 + remaining=0 = 33, rounded up to 40; min(pool=60, cap=60)=60 → result=40
        let result = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 33,
            backendRemaining: 0,
            poolMinutes: 60,
            capMinutes: 60,
            bucketMinutes: 10
        )
        XCTAssertEqual(result, 40)
    }

    func test_effectiveCap_sumExceedsMinPoolCap_cappedAtCeiling() {
        // latest=70 + remaining=30 = 100, rounded=100; min(pool=80, cap=90)=80 → 80
        let result = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 70,
            backendRemaining: 30,
            poolMinutes: 80,
            capMinutes: 90,
            bucketMinutes: 10
        )
        XCTAssertEqual(result, 80)
    }

    // MARK: - 4. Override flag present → no .earnedTime apply

    func test_shouldApplyEarnedShield_overridePresent_returnsFalse() {
        let store = EarnedTimeStore.shared
        store.setOverride(true, forUsageDate: "2026-06-23")
        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 60,
            effectiveCap: 60,
            usageDate: "2026-06-23",
            store: store
        )
        XCTAssertFalse(result, "override flag set → must not apply .earnedTime shield")
    }

    func test_shouldApplyEarnedShield_noOverride_thresholdMeetsCap_returnsTrue() {
        let store = EarnedTimeStore.shared
        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 60,
            effectiveCap: 60,
            usageDate: "2026-06-23",
            store: store
        )
        XCTAssertTrue(result, "no override, threshold meets cap → should apply .earnedTime shield")
    }

    func test_shouldApplyEarnedShield_thresholdBelowCap_returnsFalse() {
        let store = EarnedTimeStore.shared
        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 50,
            effectiveCap: 60,
            usageDate: "2026-06-23",
            store: store
        )
        XCTAssertFalse(result, "threshold below cap → must not apply .earnedTime shield yet")
    }

    func test_shouldApplyEarnedShield_thresholdExceedsCap_returnsTrue() {
        let store = EarnedTimeStore.shared
        // threshold > cap is treated as >= cap — the cap was reached
        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 70,
            effectiveCap: 60,
            usageDate: "2026-06-23",
            store: store
        )
        XCTAssertTrue(result, "threshold exceeds cap → should apply .earnedTime shield")
    }

    // MARK: - 5. Daily strip removes ONLY .earnedTime

    func test_stripEarnedTime_removesOnlyEarnedTimeSource() {
        // A dict with one .manual, one .limit, one .earnedTime, one mixed record.
        let manual  = Self.makeRecord(key: "savedList:list1", sources: [.manual])
        let limit   = Self.makeRecord(key: "exactApp:com.foo", sources: [.limit])
        let earned  = Self.makeRecord(key: "savedList:lockedSet", sources: [.earnedTime])
        let mixed   = Self.makeRecord(key: "savedList:list2", sources: [.manual, .earnedTime])

        let input: [String: ShieldRecord] = [
            manual.recordKey: manual,
            limit.recordKey: limit,
            earned.recordKey: earned,
            mixed.recordKey: mixed,
        ]

        let result = ShieldSourceLogic.strippingSource(.earnedTime, from: input)

        // .manual record untouched
        XCTAssertNotNil(result[manual.recordKey])
        XCTAssertEqual(result[manual.recordKey]?.sources, [.manual])

        // .limit record untouched
        XCTAssertNotNil(result[limit.recordKey])
        XCTAssertEqual(result[limit.recordKey]?.sources, [.limit])

        // .earnedTime-only record deleted
        XCTAssertNil(result[earned.recordKey])

        // mixed record: .earnedTime stripped, .manual preserved
        XCTAssertNotNil(result[mixed.recordKey])
        XCTAssertEqual(result[mixed.recordKey]?.sources, [.manual])
    }

    // MARK: - 6. Mixed-source strip — B1 carry

    func test_mixedLimitEarnedTime_stripEarnedTime_leavesLimit() {
        let mixed = Self.makeRecord(key: "savedList:lockedSet", sources: [.limit, .earnedTime])
        let input = [mixed.recordKey: mixed]

        let result = ShieldSourceLogic.strippingSource(.earnedTime, from: input)

        // Record must survive with only .limit
        let surviving = result[mixed.recordKey]
        XCTAssertNotNil(surviving, "record with {.limit, .earnedTime} must survive after .earnedTime strip")
        XCTAssertEqual(surviving?.sources, [.limit])
    }

    func test_mixedLimitEarnedTime_stripLimit_leavesEarnedTime() {
        let mixed = Self.makeRecord(key: "savedList:lockedSet", sources: [.limit, .earnedTime])
        let input = [mixed.recordKey: mixed]

        let result = ShieldSourceLogic.strippingSource(.limit, from: input)

        let surviving = result[mixed.recordKey]
        XCTAssertNotNil(surviving, "record with {.limit, .earnedTime} must survive after .limit strip")
        XCTAssertEqual(surviving?.sources, [.earnedTime])
    }

    func test_strippingLimitShields_mixedRecord_preservesNonLimitSources() {
        // The B1 carry fix: LimitShieldLogic.strippingLimitShields must use
        // source-aware removal, not a blanket filter-out of any record with .limit.
        let pure  = Self.makeRecord(key: "exactApp:com.roblox", sources: [.limit])
        let mixed = Self.makeRecord(key: "savedList:lockedSet", sources: [.limit, .earnedTime])
        let input = [pure.recordKey: pure, mixed.recordKey: mixed]

        let result = LimitShieldLogic.strippingLimitShields(from: input)

        // Pure .limit record must be fully deleted
        XCTAssertNil(result[pure.recordKey])

        // Mixed record: .limit stripped, .earnedTime preserved
        let surviving = result[mixed.recordKey]
        XCTAssertNotNil(surviving, "mixed {.limit,.earnedTime} record must survive after limit strip")
        XCTAssertEqual(surviving?.sources, [.earnedTime])
    }

    func test_reconcileLimitShieldsFromDisk_mixedRecord_preservesNonLimitSources() {
        // Simulates the B1 carry scenario: a record on disk transitions from
        // {.limit, .earnedTime} → {.earnedTime} (extension stripped .limit at reset).
        // reconcileLimitShieldsFromDisk must NOT delete the whole in-memory record;
        // it should update it to match disk (remove .limit, keep .earnedTime).
        // We test via ShieldSourceLogic.strippingSource directly since the pure
        // helper is what the B1-carry-fixed reconcile delegates to.
        let mixed = Self.makeRecord(key: "savedList:lockedSet", sources: [.limit, .earnedTime])
        let inMemory: [String: ShieldRecord] = [mixed.recordKey: mixed]

        // Disk equivalent: the extension stripped .limit → disk record has only .earnedTime
        // Reconcile should bring in-memory in line: remove .limit, keep .earnedTime.
        let diskAfterLimitReset = ShieldSourceLogic.removing(.limit, from: mixed)
        XCTAssertNotNil(diskAfterLimitReset, "removing .limit from {.limit,.earnedTime} must not return nil")
        XCTAssertEqual(diskAfterLimitReset?.sources, [.earnedTime])

        // Also verify that a record with only .limit resolves to nil (full delete)
        let pureLimit = Self.makeRecord(key: "exactApp:com.foo", sources: [.limit])
        XCTAssertNil(ShieldSourceLogic.removing(.limit, from: pureLimit),
                     "removing .limit from {.limit} must return nil → caller deletes record")

        // Verify dict-level helper: strippingSource on a dict with only .limit records
        // should leave any record missing that source intact
        let manualOnly = Self.makeRecord(key: "savedList:other", sources: [.manual])
        let dictInput = [inMemory, [pureLimit.recordKey: pureLimit, manualOnly.recordKey: manualOnly]]
            .reduce([String:ShieldRecord]()) { acc, d in acc.merging(d) { _, new in new } }

        let stripped = ShieldSourceLogic.strippingSource(.limit, from: dictInput)
        XCTAssertNil(stripped[pureLimit.recordKey])
        XCTAssertNotNil(stripped[manualOnly.recordKey])
        XCTAssertEqual(stripped[mixed.recordKey]?.sources, [.earnedTime])
    }

    // MARK: - Helpers

    private static func makeRecord(key: String, sources: Set<ShieldSource>) -> ShieldRecord {
        // Derive tier from recordKey prefix; default to savedList.
        let tier: ShieldTier
        let targetKey: String
        if key.hasPrefix("savedList:") {
            tier = .savedList
            targetKey = String(key.dropFirst("savedList:".count))
        } else if key.hasPrefix("exactApp:") {
            tier = .exactApp
            targetKey = String(key.dropFirst("exactApp:".count))
        } else {
            tier = .savedList
            targetKey = key
        }
        return ShieldRecord(
            recordKey: key,
            tier: tier,
            targetKey: targetKey,
            displayName: "Test \(key)",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "test",
            targetChildID: UUID(),
            sources: sources
        )
    }
}

@MainActor
final class EarnedSampleReporterResponseTests: XCTestCase {

    func test_successForOldExpectedDeviceDoesNotReconcileNewMirroredIdentity() {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let oldID = UUID()
        let newID = UUID()
        UserDefaults(suiteName: isolatedSuite)?.set(newID.uuidString, forKey: "evlin.childId")
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        let data = Data(
            #"{"usage_date":"2026-07-12","estimated_minutes":300,"counted":true}"#.utf8
        )

        let result = EarnedSampleReporter.processSuccessfulResponse(
            data,
            expectedDeviceID: oldID,
            store: store,
            suiteName: isolatedSuite
        )

        XCTAssertEqual(result, .identityMismatch)
        XCTAssertNil(store.acceptedEstimateMinutes)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
    }

    func test_identitySwitchInsideSuccessfulResponseTransactionCannotRestoreOldUsage() {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let oldID = UUID()
        let newID = UUID()
        let defaults = UserDefaults(suiteName: isolatedSuite)
        defaults?.set(oldID.uuidString, forKey: "evlin.childId")
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-12",
            serverEstimatedMinutes: 25
        )

        let result = EarnedSampleReporter.processSuccessfulResponse(
            Data(#"{"usage_date":"2026-07-12","estimated_minutes":300,"counted":true}"#.utf8),
            expectedDeviceID: oldID,
            store: store,
            suiteName: isolatedSuite,
            beforeReconciliationCommit: {
                defaults?.removeObject(forKey: "evlin.childId")
                store.clearUsageStateForIdentityChange()
                defaults?.set(newID.uuidString, forKey: "evlin.childId")
            }
        )

        XCTAssertEqual(result, .identityMismatch)
        XCTAssertNil(store.acceptedUsageDate)
        XCTAssertNil(store.acceptedEstimateMinutes)
        XCTAssertNil(store.latestDeviceEstimate)
        XCTAssertEqual(
            EarnedActivityGeneration.canonicalDeviceID(
                defaults?.string(forKey: "evlin.childId")
            ),
            newID.uuidString.lowercased()
        )
    }

    func test_countedSuccess_preservesSameDayMonotonicAcceptedUsage() {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-10",
            serverEstimatedMinutes: 15
        )
        let data = Data(
            #"{"usage_date":"2026-07-10","estimated_minutes":5,"counted":true}"#.utf8
        )

        let result = EarnedSampleReporter.processSuccessfulResponse(
            data,
            store: store,
            suiteName: isolatedSuite
        )

        XCTAssertEqual(result, .counted)
        XCTAssertEqual(store.acceptedEstimateMinutes, 15)
        XCTAssertEqual(store.latestDeviceEstimate, 15)
        XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
    }

    func test_successWithOmittedCounted_preservesSameDayMonotonicAcceptedUsage() {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-10",
            serverEstimatedMinutes: 15
        )
        let data = Data(
            #"{"usage_date":"2026-07-10","estimated_minutes":5}"#.utf8
        )

        let result = EarnedSampleReporter.processSuccessfulResponse(
            data,
            store: store,
            suiteName: isolatedSuite
        )

        XCTAssertEqual(result, .counted)
        XCTAssertEqual(store.acceptedEstimateMinutes, 15)
        XCTAssertEqual(store.latestDeviceEstimate, 15)
        XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
    }

    func test_uncountedSuccessPausesWithoutLoweringLegacyAcceptedHighWater() {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        store.earnedUsageOffsetMinutes = 4
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-10",
            serverEstimatedMinutes: 10
        )
        let data = Data(
            #"{"usage_date":"2026-07-10","estimated_minutes":0,"counted":false}"#.utf8
        )

        let result = EarnedSampleReporter.processSuccessfulResponse(
            data,
            store: store,
            suiteName: isolatedSuite
        )

        XCTAssertEqual(result, .paused)
        XCTAssertEqual(store.acceptedEstimateMinutes, 10)
        XCTAssertEqual(store.latestDeviceEstimate, 10)
        XCTAssertEqual(store.earnedUsageOffsetMinutes, 4)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
        let lastDebugValue = UserDefaults(suiteName: isolatedSuite)?
            .string(forKey: EarnedSampleReporter.lastSamplePostDebugKey) ?? ""
        XCTAssertTrue(lastDebugValue.contains("backend_counting_paused"))
    }

    func test_uncountedSuccessWithUnavailableLockIsDeferredWithoutRetry() {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let store = EarnedTimeStore(
            suiteName: isolatedSuite,
            lockSelection: .unavailable("test_lock_unavailable")
        )
        let data = Data(
            #"{"usage_date":"2026-07-10","estimated_minutes":0,"counted":false}"#.utf8
        )

        let result = EarnedSampleReporter.processSuccessfulResponse(
            data,
            store: store,
            suiteName: isolatedSuite
        )

        XCTAssertEqual(result, .deferred)
        XCTAssertNil(store.acceptedEstimateMinutes)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
        XCTAssertTrue(lastDebugValue(in: isolatedSuite).contains("reconciliation_deferred"))
    }

    func test_malformedSuccess_isAcceptedWithoutReconciliationOrRetry() {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-10",
            serverEstimatedMinutes: 12
        )

        let result = EarnedSampleReporter.processSuccessfulResponse(
            Data("not-json".utf8),
            store: store,
            suiteName: isolatedSuite
        )

        XCTAssertEqual(result, .acceptedWithoutReconciliation)
        XCTAssertEqual(store.acceptedEstimateMinutes, 12)
        XCTAssertEqual(store.latestDeviceEstimate, 12)
        XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
    }

    func test_staleSuccessAfterNewDay_isAcceptedWithoutMutationOrRetry() {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-11",
            serverEstimatedMinutes: 8
        )
        let data = Data(
            #"{"usage_date":"2026-07-10","estimated_minutes":0,"counted":false}"#.utf8
        )

        let result = EarnedSampleReporter.processSuccessfulResponse(
            data,
            store: store,
            suiteName: isolatedSuite
        )

        XCTAssertEqual(result, .acceptedWithoutReconciliation)
        assertAcceptedUsage(store, date: "2026-07-11", minutes: 8)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
        XCTAssertTrue(lastDebugValue(in: isolatedSuite).contains("stale_response"))
    }

    func test_invalidUsageDateSuccess_isAcceptedWithoutMutationOrRetry() {
        assertSemanticallyInvalidResponse(
            #"{"usage_date":"2026-02-30","estimated_minutes":10,"counted":true}"#
        )
    }

    func test_negativeEstimateSuccess_isAcceptedWithoutMutationOrRetry() {
        assertSemanticallyInvalidResponse(
            #"{"usage_date":"2026-07-10","estimated_minutes":-1,"counted":true}"#
        )
    }

    func test_estimateAboveDailyMaximumSuccess_isAcceptedWithoutMutationOrRetry() {
        assertSemanticallyInvalidResponse(
            #"{"usage_date":"2026-07-10","estimated_minutes":1441,"counted":true}"#
        )
    }

    func test_report_200SuccessReconcilesImmediately() async {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let deviceID = UUID()
        UserDefaults(suiteName: isolatedSuite)?.set(deviceID.uuidString, forKey: "evlin.childId")
        EarnedSampleReporterURLProtocol.responseData = Data(
            #"{"usage_date":"2026-07-10","estimated_minutes":9,"counted":true}"#.utf8
        )
        EarnedSampleReporterURLProtocol.statusCode = 200
        URLProtocol.registerClass(EarnedSampleReporterURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(EarnedSampleReporterURLProtocol.self)
            EarnedSampleReporterURLProtocol.reset()
        }

        await EarnedSampleReporter.report(
            baseURL: URL(string: "https://earned-sample-reporter.test")!,
            deviceID: deviceID,
            usageDate: "2026-07-10",
            timezone: "America/New_York",
            thresholdMinutes: 10,
            estimatedMinutes: 10,
            suiteName: isolatedSuite
        )

        assertAcceptedUsage(
            EarnedTimeStore(suiteName: isolatedSuite),
            date: "2026-07-10",
            minutes: 9
        )
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
    }

    func test_report_409MalformedSuccess_isAcceptedWithoutRetry() async {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-10",
            serverEstimatedMinutes: 12
        )
        EarnedSampleReporterURLProtocol.responseData = Data("not-json".utf8)
        EarnedSampleReporterURLProtocol.statusCode = 409
        URLProtocol.registerClass(EarnedSampleReporterURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(EarnedSampleReporterURLProtocol.self)
            EarnedSampleReporterURLProtocol.reset()
        }

        await EarnedSampleReporter.report(
            baseURL: URL(string: "https://earned-sample-reporter.test")!,
            deviceID: UUID(),
            usageDate: "2026-07-10",
            timezone: "America/New_York",
            thresholdMinutes: 15,
            estimatedMinutes: 15,
            suiteName: isolatedSuite
        )

        assertAcceptedUsage(store, date: "2026-07-10", minutes: 12)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
        XCTAssertTrue(lastDebugValue(in: isolatedSuite).contains("response_decode_failed"))
    }

    func test_retryDrain_uncountedSuccessRemovesEntryInsteadOfRequeueing() async {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        let deviceID = UUID()
        UserDefaults(suiteName: isolatedSuite)?.set(deviceID.uuidString, forKey: "evlin.childId")
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-10",
            serverEstimatedMinutes: 10
        )
        EarnedSampleReporter.enqueueRetry(
            EarnedSampleReporter.RetryEntry(
                deviceID: deviceID,
                usageDate: "2026-07-10",
                timezone: "America/New_York",
                thresholdMinutes: 10,
                estimatedMinutes: 10,
                observedAt: "2026-07-10T12:00:00Z"
            ),
            suiteName: isolatedSuite
        )
        EarnedSampleReporterURLProtocol.responseData = Data(
            #"{"usage_date":"2026-07-10","estimated_minutes":0,"counted":false}"#.utf8
        )
        EarnedSampleReporterURLProtocol.statusCode = 200
        URLProtocol.registerClass(EarnedSampleReporterURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(EarnedSampleReporterURLProtocol.self)
            EarnedSampleReporterURLProtocol.reset()
        }

        await EarnedSampleReporter.drainRetryQueue(
            baseURL: URL(string: "https://earned-sample-reporter.test")!,
            suiteName: isolatedSuite
        )

        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
        XCTAssertEqual(store.acceptedEstimateMinutes, 0)
        XCTAssertEqual(store.latestDeviceEstimate, 0)
        XCTAssertEqual(store.earnedUsageOffsetMinutes, 0)
    }

    func test_retryDrain_staleSuccessAfterNewDayRemovesEntryWithoutRollback() async {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        let deviceID = UUID()
        UserDefaults(suiteName: isolatedSuite)?.set(deviceID.uuidString, forKey: "evlin.childId")
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-11",
            serverEstimatedMinutes: 8
        )
        EarnedSampleReporter.enqueueRetry(
            EarnedSampleReporter.RetryEntry(
                deviceID: deviceID,
                usageDate: "2026-07-10",
                timezone: "America/New_York",
                thresholdMinutes: 10,
                estimatedMinutes: 10,
                observedAt: "2026-07-10T12:00:00Z"
            ),
            suiteName: isolatedSuite
        )
        EarnedSampleReporterURLProtocol.responseData = Data(
            #"{"usage_date":"2026-07-10","estimated_minutes":10,"counted":true}"#.utf8
        )
        EarnedSampleReporterURLProtocol.statusCode = 200
        URLProtocol.registerClass(EarnedSampleReporterURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(EarnedSampleReporterURLProtocol.self)
            EarnedSampleReporterURLProtocol.reset()
        }

        await EarnedSampleReporter.drainRetryQueue(
            baseURL: URL(string: "https://earned-sample-reporter.test")!,
            suiteName: isolatedSuite
        )

        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
        assertAcceptedUsage(store, date: "2026-07-11", minutes: 8)
        XCTAssertTrue(lastDebugValue(in: isolatedSuite).contains("stale_response"))
    }

    func test_retryDrainLeavesEntryQueuedDuringAwaitAndPreservesConcurrentEnqueue() async throws {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let deviceID = UUID()
        UserDefaults(suiteName: isolatedSuite)?.set(
            deviceID.uuidString,
            forKey: "evlin.childId"
        )
        let first = EarnedSampleReporter.RetryEntry(
            deviceID: deviceID,
            usageDate: "2026-07-12",
            timezone: "America/New_York",
            thresholdMinutes: 60,
            estimatedMinutes: 60,
            observedAt: "2026-07-12T12:00:00Z"
        )
        let concurrent = EarnedSampleReporter.RetryEntry(
            deviceID: deviceID,
            usageDate: "2026-07-12",
            timezone: "America/New_York",
            thresholdMinutes: 65,
            estimatedMinutes: 65,
            observedAt: "2026-07-12T12:05:00Z"
        )
        EarnedSampleReporter.enqueueRetry(first, suiteName: isolatedSuite)
        var resumeRequest: CheckedContinuation<Void, Never>?

        let drain = Task {
            await EarnedSampleReporter.drainRetryQueue(
                baseURL: URL(string: "https://earned-sample-reporter.test")!,
                suiteName: isolatedSuite,
                onlyDeviceID: deviceID,
                requestData: { request in
                    await withCheckedContinuation { resumeRequest = $0 }
                    let response = HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return (Data(#"{"usage_date":"2026-07-12","estimated_minutes":60,"counted":true}"#.utf8), response)
                }
            )
        }
        while resumeRequest == nil { await Task.yield() }

        XCTAssertEqual(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite), [first])
        EarnedSampleReporter.enqueueRetry(concurrent, suiteName: isolatedSuite)
        resumeRequest?.resume()
        await drain.value

        XCTAssertEqual(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite), [concurrent])
    }

    func test_retryDrainKeepsOldEntryQueuedWhenAuthorizationStopsDuringRequest() async throws {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let deviceID = UUID()
        let entry = EarnedSampleReporter.RetryEntry(
            deviceID: deviceID,
            usageDate: "2026-07-12",
            timezone: "America/New_York",
            thresholdMinutes: 60,
            estimatedMinutes: 60,
            observedAt: "2026-07-12T12:00:00Z"
        )
        EarnedSampleReporter.enqueueRetry(entry, suiteName: isolatedSuite)
        var isAuthorized = true
        var resumeRequest: CheckedContinuation<Void, Never>?

        let drain = Task {
            await EarnedSampleReporter.drainRetryQueue(
                baseURL: URL(string: "https://earned-sample-reporter.test")!,
                suiteName: isolatedSuite,
                onlyDeviceID: deviceID,
                authorizationIsCurrent: { isAuthorized },
                requestData: { request in
                    await withCheckedContinuation { resumeRequest = $0 }
                    let response = HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return (
                        Data(#"{"usage_date":"2026-07-12","estimated_minutes":60,"counted":true}"#.utf8),
                        response
                    )
                }
            )
        }
        while resumeRequest == nil { await Task.yield() }
        isAuthorized = false
        resumeRequest?.resume()
        await drain.value

        XCTAssertEqual(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite), [entry])
        XCTAssertNil(EarnedTimeStore(suiteName: isolatedSuite).acceptedEstimateMinutes)
    }

    func test_terminalDeferredEntryDrainsFromStoredConfigOnForeground() async throws {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let deviceID = UUID()
        let defaults = UserDefaults(suiteName: isolatedSuite)
        defaults?.set("https://earned-sample-reporter.test", forKey: "evlin.baseURL")
        defaults?.set(deviceID.uuidString, forKey: "evlin.childId")
        let decision = EarnedSampleReporter.thresholdHandlingDecision(
            thresholdMinutes: 60,
            localReconciliationAvailable: false
        )
        XCTAssertTrue(decision.shouldReport)
        XCTAssertFalse(decision.shouldApplyLocalShield)
        EarnedSampleReporter.enqueueRetry(
            .init(
                deviceID: deviceID,
                usageDate: "2026-07-12",
                timezone: "America/New_York",
                thresholdMinutes: 60,
                estimatedMinutes: 60,
                observedAt: "2026-07-12T12:00:00Z"
            ),
            suiteName: isolatedSuite
        )
        var postedDeviceID: String?

        await EarnedSampleReporter.drainRetryQueueFromStoredConfig(
            suiteName: isolatedSuite,
            requestData: { request in
                postedDeviceID = request.value(forHTTPHeaderField: "X-Evlin-Child-Device-ID")
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }
        )

        XCTAssertEqual(postedDeviceID, deviceID.uuidString)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty)
    }

    private func assertSemanticallyInvalidResponse(
        _ json: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let isolatedSuite = makeIsolatedSuiteName()
        defer { removeIsolatedSuite(isolatedSuite) }
        let store = EarnedTimeStore(suiteName: isolatedSuite)
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-10",
            serverEstimatedMinutes: 12
        )

        let result = EarnedSampleReporter.processSuccessfulResponse(
            Data(json.utf8),
            store: store,
            suiteName: isolatedSuite
        )

        XCTAssertEqual(result, .acceptedWithoutReconciliation, file: file, line: line)
        assertAcceptedUsage(store, date: "2026-07-10", minutes: 12, file: file, line: line)
        XCTAssertTrue(
            EarnedSampleReporter.loadRetryQueue(suiteName: isolatedSuite).isEmpty,
            file: file,
            line: line
        )
        XCTAssertTrue(
            lastDebugValue(in: isolatedSuite).contains("response_semantically_invalid"),
            file: file,
            line: line
        )
    }

    private func assertAcceptedUsage(
        _ store: EarnedTimeStore,
        date: String,
        minutes: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(store.acceptedUsageDate, date, file: file, line: line)
        XCTAssertEqual(store.acceptedEstimateMinutes, minutes, file: file, line: line)
        XCTAssertEqual(store.latestDeviceEstimate, minutes, file: file, line: line)
        XCTAssertEqual(store.earnedUsageOffsetMinutes, 0, file: file, line: line)
    }

    private func lastDebugValue(in suiteName: String) -> String {
        UserDefaults(suiteName: suiteName)?
            .string(forKey: EarnedSampleReporter.lastSamplePostDebugKey) ?? ""
    }

    private func makeIsolatedSuiteName() -> String {
        "group.com.evlin.ios.tests.EarnedSampleReporterTests.\(UUID().uuidString)"
    }

    private func removeIsolatedSuite(_ suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

private final class ReporterRootTransport: @unchecked Sendable {
    let store: DeviceEpochStore
    let fileIO: CountingReporterFileIO?
    var sampleCountBeforePost: Int?
    var writeCountBeforePost: Int?
    var requestCount = 0

    init(store: DeviceEpochStore, fileIO: CountingReporterFileIO? = nil) {
        self.store = store
        self.fileIO = fileIO
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        writeCountBeforePost = fileIO?.writeCount
        sampleCountBeforePost = try store.read().sampleWork.count
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 409,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(#"{"code":"duplicate"}"#.utf8), response)
    }
}

private final class CountingReporterFileIO: DeviceEpochFileIO, @unchecked Sendable {
    private let lock = NSLock()
    private let backing = SystemDeviceEpochFileIO()
    private(set) var writeCount = 0

    func read(from url: URL) throws -> Data? {
        try backing.read(from: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.lock()
        writeCount += 1
        lock.unlock()
        try backing.writeAtomically(data, to: url)
    }

    func remove(at url: URL) throws {
        try backing.remove(at: url)
    }
}

private final class EarnedThresholdProductionPathSpy {
    private(set) var diagnostics: [String] = []
    private(set) var acceptedPathCount = 0
    private(set) var estimateMutationCount = 0
    private(set) var retryEnqueueCount = 0
    private(set) var networkDispatchCount = 0
    private(set) var shieldWorkCount = 0

    func recordDiagnostic(_ diagnostic: String) {
        diagnostics.append(diagnostic)
    }

    func runAcceptedProductionPath() {
        acceptedPathCount += 1
        estimateMutationCount += 1
        retryEnqueueCount += 1
        networkDispatchCount += 1
        shieldWorkCount += 1
    }
}

private final class EarnedSampleReporterURLProtocol: URLProtocol {
    static var responseData = Data()
    static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "earned-sample-reporter.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        responseData = Data()
        statusCode = 200
    }
}
