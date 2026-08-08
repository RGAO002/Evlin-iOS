import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringEpochWireTests: XCTestCase {
    private let ownerID = UUID(uuidString: "A0A0A0A0-0000-4000-8000-000000000001")!
    private let deviceID = UUID(uuidString: "B0B0B0B0-0000-4000-8000-000000000002")!
    private let epochID = UUID(uuidString: "C0C0C0C0-0000-4000-8000-000000000003")!
    private let routeID = UUID(uuidString: "D0D0D0D0-0000-4000-8000-000000000004")!
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testAppleCallbackEncodesOnlyCallbackFields() throws {
        let callback = MeteringAppleCallback(
            activityName: "evlin.earned.v2.\(routeID.uuidString.lowercased())",
            eventName: "evlin.earned.v2.\(routeID.uuidString.lowercased()).t15",
            observedAt: observedAt
        )

        let object = try encodedObject(callback)

        XCTAssertEqual(Set(object.keys), ["activityName", "eventName", "observedAt"])
        XCTAssertEqual(object["activityName"] as? String, callback.activityName)
        XCTAssertEqual(object["eventName"] as? String, callback.eventName)
    }

    func testSampleRequestsUseExactAliasesAndV1V2WireShapes() throws {
        XCTAssertEqual(
            MeteringSampleWireAliases.activityName(routeID: routeID),
            "evlin.earned.budget.d0d0d0d0-0000-4000-8000-000000000004"
        )
        XCTAssertEqual(MeteringSampleWireAliases.eventName(thresholdMinutes: 15), "evlin.earned.t15")
        XCTAssertEqual(
            MeteringSampleWireAliases.clientSampleID(lane: .v2, routeID: routeID, thresholdMinutes: 15),
            "earned:v2:d0d0d0d0-0000-4000-8000-000000000004:t15"
        )

        let v1 = sample()
        let v1WithMetadata = sample(generationArmedAt: observedAt, generationOffsetMinutes: 10)
        let v2 = sample(protocolVersion: 2, epochID: epochID)

        XCTAssertEqual(v1.lane, .v1)
        XCTAssertEqual(v1WithMetadata.lane, .v1)
        XCTAssertEqual(v2.lane, .v2)
        XCTAssertNil(sample(generationArmedAt: observedAt).lane)
        XCTAssertNil(sample(protocolVersion: 2, epochID: epochID, generationOffsetMinutes: 10).lane)

        let v1Request = try MeteringEpochRequests.sample(
            baseURL: baseURL,
            ownerChildDeviceID: ownerID,
            body: v1
        )
        let v1WithMetadataRequest = try MeteringEpochRequests.sample(
            baseURL: baseURL,
            ownerChildDeviceID: ownerID,
            body: v1WithMetadata
        )
        let v2Request = try MeteringEpochRequests.sample(
            baseURL: baseURL,
            ownerChildDeviceID: ownerID,
            body: v2
        )
        XCTAssertEqual(v1Request.httpMethod, "POST")
        XCTAssertEqual(v1Request.url?.path, "/api/v1/child/earned-time/sample")
        XCTAssertEqual(v1Request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(
            v1Request.value(forHTTPHeaderField: "X-Evlin-Child-Device-ID"),
            ownerID.uuidString.lowercased()
        )

        XCTAssertEqual(
            try requestBody(v1Request),
            "{\"activity_name\":\"evlin.earned.budget.d0d0d0d0-0000-4000-8000-000000000004\",\"client_sample_id\":\"earned:v1:d0d0d0d0-0000-4000-8000-000000000004:t15\",\"device_id\":\"B0B0B0B0-0000-4000-8000-000000000002\",\"estimated_minutes\":15,\"event_name\":\"evlin.earned.t15\",\"observed_at\":\"2023-11-14T22:13:20Z\",\"threshold_minutes\":15,\"timezone\":\"America\\/New_York\",\"usage_date\":\"2026-07-17\"}"
        )
        XCTAssertEqual(
            try requestBody(v1WithMetadataRequest),
            "{\"activity_name\":\"evlin.earned.budget.d0d0d0d0-0000-4000-8000-000000000004\",\"client_sample_id\":\"earned:v1:d0d0d0d0-0000-4000-8000-000000000004:t15\",\"device_id\":\"B0B0B0B0-0000-4000-8000-000000000002\",\"estimated_minutes\":15,\"event_name\":\"evlin.earned.t15\",\"generation_armed_at\":\"2023-11-14T22:13:20Z\",\"generation_offset_minutes\":10,\"observed_at\":\"2023-11-14T22:13:20Z\",\"threshold_minutes\":15,\"timezone\":\"America\\/New_York\",\"usage_date\":\"2026-07-17\"}"
        )
        XCTAssertEqual(
            try requestBody(v2Request),
            "{\"activity_name\":\"evlin.earned.budget.d0d0d0d0-0000-4000-8000-000000000004\",\"client_sample_id\":\"earned:v2:d0d0d0d0-0000-4000-8000-000000000004:t15\",\"device_id\":\"B0B0B0B0-0000-4000-8000-000000000002\",\"epoch_id\":\"C0C0C0C0-0000-4000-8000-000000000003\",\"estimated_minutes\":15,\"event_name\":\"evlin.earned.t15\",\"observed_at\":\"2023-11-14T22:13:20Z\",\"protocol_version\":2,\"threshold_minutes\":15,\"timezone\":\"America\\/New_York\",\"usage_date\":\"2026-07-17\"}"
        )
    }

    func testRegistrationAndActivationRequestsUseExactPathsHeadersAndBodies() throws {
        let registration = EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: epochID,
            deviceID: deviceID,
            usageDate: "2026-07-17",
            timezone: "America/New_York",
            policyRevision: "policy-r17",
            measurementSelectionDigest: String(repeating: "a", count: 64),
            enforcementSetID: routeID,
            startedAt: observedAt,
            baseAcceptedMinutes: 15,
            reason: .gateResumeConservative
        )
        let activation = EpochActivationRequestDTO(
            protocolVersion: 2,
            deviceID: deviceID,
            routeID: routeID,
            verifiedAt: observedAt
        )

        let childState = MeteringEpochRequests.childState(baseURL: baseURL, ownerChildDeviceID: ownerID)
        XCTAssertEqual(childState.httpMethod, "GET")
        XCTAssertEqual(childState.url?.path, "/api/v1/child/state")
        XCTAssertEqual(childState.value(forHTTPHeaderField: "X-Child-Id"), ownerID.uuidString.lowercased())

        let registrationRequest = try MeteringEpochRequests.registration(baseURL: baseURL, ownerChildDeviceID: ownerID, body: registration)
        XCTAssertEqual(registrationRequest.httpMethod, "POST")
        XCTAssertEqual(registrationRequest.url?.path, "/api/v1/child/earned-time/epochs")
        XCTAssertEqual(registrationRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(registrationRequest.value(forHTTPHeaderField: "X-Evlin-Child-Device-ID"), ownerID.uuidString.lowercased())
        XCTAssertEqual(
            try requestBody(registrationRequest),
            "{\"base_accepted_minutes\":15,\"device_id\":\"B0B0B0B0-0000-4000-8000-000000000002\",\"enforcement_set_id\":\"D0D0D0D0-0000-4000-8000-000000000004\",\"epoch_id\":\"C0C0C0C0-0000-4000-8000-000000000003\",\"measurement_selection_digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"policy_revision\":\"policy-r17\",\"protocol_version\":2,\"reason\":\"gate_resume_conservative\",\"started_at\":\"2023-11-14T22:13:20Z\",\"timezone\":\"America\\/New_York\",\"usage_date\":\"2026-07-17\"}"
        )

        let activationRequest = try MeteringEpochRequests.activation(baseURL: baseURL, ownerChildDeviceID: ownerID, epochID: epochID, body: activation)
        XCTAssertEqual(activationRequest.httpMethod, "POST")
        XCTAssertEqual(activationRequest.url?.path, "/api/v1/child/earned-time/epochs/c0c0c0c0-0000-4000-8000-000000000003/activation")
        XCTAssertEqual(activationRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(activationRequest.value(forHTTPHeaderField: "X-Evlin-Child-Device-ID"), ownerID.uuidString.lowercased())
        XCTAssertEqual(
            try requestBody(activationRequest),
            "{\"device_id\":\"B0B0B0B0-0000-4000-8000-000000000002\",\"protocol_version\":2,\"route_id\":\"D0D0D0D0-0000-4000-8000-000000000004\",\"verified_at\":\"2023-11-14T22:13:20Z\"}"
        )
    }

    func testRegistrationConflictActivationAndSnapshotResponsesDecode() throws {
        let active = try decode(EpochRegistrationResponseDTO.self, from: """
        {"status":"registered","epoch_id":"c0c0c0c0-0000-4000-8000-000000000003","metering_protocol_version":1,"epoch_status":"active","snapshot":\(snapshotJSON)}
        """)
        let paused = try decode(EpochRegistrationResponseDTO.self, from: """
        {"status":"already_registered","epoch_id":"c0c0c0c0-0000-4000-8000-000000000003","metering_protocol_version":1,"epoch_status":"paused","snapshot":\(snapshotJSON)}
        """)
        let missingEpochStatus = try decode(EpochRegistrationResponseDTO.self, from: """
        {"status":"registered","epoch_id":"c0c0c0c0-0000-4000-8000-000000000003","metering_protocol_version":1,"snapshot":\(snapshotJSON)}
        """)
        let conflict = try decode(EpochRegistrationConflictDTO.self, from: """
        {"code":"authoritative_base_mismatch","authoritative_snapshot":\(snapshotJSON)}
        """)
        let activation = try decode(EpochActivationResponseDTO.self, from: """
        {"status":"activated","epoch_id":"c0c0c0c0-0000-4000-8000-000000000003","epoch_status":"active","metering_protocol_version":2,"snapshot":\(snapshotJSON)}
        """)
        let sample = try decode(DeviceDaySnapshotDTO.self, from: snapshotJSON)

        XCTAssertEqual(active.status, .registered)
        XCTAssertEqual(active.epochStatus, .active)
        XCTAssertEqual(paused.status, .alreadyRegistered)
        XCTAssertEqual(paused.epochStatus, .paused)
        XCTAssertNil(missingEpochStatus.epochStatus)
        XCTAssertEqual(conflict.code, .authoritativeBaseMismatch)
        XCTAssertEqual(conflict.authoritativeSnapshot, sample)
        XCTAssertEqual(activation.status, .activated)
        XCTAssertEqual(activation.epochStatus, .active)
    }

    @MainActor
    func testChildStateDefaultsMissingProtocolAdvertisementAndDecodesRuntimePolicyRevision() throws {
        let absentProtocol = try JSONDecoder.bigKid.decode(ChildStateResponse.self, from: Data("""
        {"child_name":"Liam","minutes_left":75,"minutes_max":120,"tasks":[],"daily_complete_acknowledged":false,"screen_time_finished_acknowledged":false,"earned_time_runtime":{"usage_date":"2026-07-17","timezone":"America/New_York","policy_revision":"policy-r17","daily_pool_minutes":120,"device_cap_minutes":90,"remaining_minutes":75,"estimated_minutes":15}}
        """.utf8))
        let legacyRuntime = try JSONDecoder.bigKid.decode(ChildStateResponse.self, from: Data("""
        {"child_name":"Liam","minutes_left":75,"minutes_max":120,"tasks":[],"daily_complete_acknowledged":false,"screen_time_finished_acknowledged":false,"earned_time_runtime":{"usage_date":"2026-07-17","timezone":"America/New_York","daily_pool_minutes":120,"device_cap_minutes":90,"remaining_minutes":75,"estimated_minutes":15}}
        """.utf8))
        let advertisedV2 = try JSONDecoder.bigKid.decode(ChildStateResponse.self, from: Data("""
        {"metering_protocol_version":2,"child_name":"Liam","minutes_left":75,"minutes_max":120,"tasks":[],"daily_complete_acknowledged":false,"screen_time_finished_acknowledged":false}
        """.utf8))

        // V1 is retired end to end: the backend pins the field to literal 2
        // (schema `ge=2, le=2`, plus a device-table check constraint), and the
        // client floors it at 2 so a missing or stale advertisement can never
        // revive legacy counting.
        XCTAssertEqual(absentProtocol.meteringProtocolVersion, 2)
        XCTAssertEqual(absentProtocol.earnedTimeRuntime?.policyRevision, "policy-r17")
        XCTAssertEqual(legacyRuntime.earnedTimeRuntime?.policyRevision, "")
        XCTAssertEqual(advertisedV2.meteringProtocolVersion, 2)
    }

    private var baseURL: URL { URL(string: "https://api.example.test/api/v1")! }

    private var snapshotJSON: String {
        "{\"child_device_id\":\"b0b0b0b0-0000-4000-8000-000000000002\",\"usage_date\":\"2026-07-17\",\"estimated_minutes\":20,\"cap_minutes\":90,\"child_day_state\":\"active\",\"used_minutes\":20,\"remaining_minutes\":70,\"counted\":true,\"warning\":null}"
    }

    private func sample(
        protocolVersion: Int? = nil,
        epochID: UUID? = nil,
        generationArmedAt: Date? = nil,
        generationOffsetMinutes: Int? = nil
    ) -> EpochSampleRequestDTO {
        let lane: MeteringSampleLane = protocolVersion == 2 ? .v2 : .v1
        return EpochSampleRequestDTO(
            deviceID: deviceID,
            usageDate: "2026-07-17",
            timezone: "America/New_York",
            activityName: MeteringSampleWireAliases.activityName(routeID: routeID),
            eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: 15),
            thresholdMinutes: 15,
            estimatedMinutes: 15,
            observedAt: observedAt,
            clientSampleID: MeteringSampleWireAliases.clientSampleID(lane: lane, routeID: routeID, thresholdMinutes: 15),
            protocolVersion: protocolVersion,
            epochID: epochID,
            generationArmedAt: generationArmedAt,
            generationOffsetMinutes: generationOffsetMinutes
        )
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }

    private func requestBody(_ request: URLRequest) throws -> String {
        try XCTUnwrap(request.httpBody).withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }
}
